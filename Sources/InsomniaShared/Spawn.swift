import Darwin
import Foundation

/// Child processes for both binaries. `posix_spawn` with a fixed argv, an explicit environment, stdin from /dev/null,
/// and POSIX_SPAWN_CLOEXEC_DEFAULT so no descriptor of ours (the sudoers watchdog pipe, sockets) leaks into the child.
/// Synchronous: callers run it on their own serial context (the helper's state queue, the app's `LidReconciler`),
/// never on the main thread.
public enum Spawn {
    public struct Result: Sendable, Equatable {
        /// Exit status (0…255); 128 + signal if the child was killed by a signal; -1 if it could not be spawned or
        /// was killed after `timeout`.
        public let status: Int32
        /// Captured standard error (only when requested), trimmed.
        public let stderr: String
        /// Captured standard output (only when requested), untrimmed; at most 64 KB.
        public let stdout: String
        public var succeeded: Bool { status == 0 }

        public init(status: Int32, stderr: String, stdout: String = "") {
            self.status = status
            self.stderr = stderr
            self.stdout = stdout
        }
    }

    /// Runs `path` with `arguments` (argv[0] is set to `path`'s last component) and waits at most `timeout`.
    /// - Parameters:
    ///   - environment: exact environment; empty by default (pmset needs none).
    ///   - captureStderr: pipe stderr back (osascript reports its error code there); otherwise /dev/null.
    ///   - captureStdout: pipe stdout back (launchctl print-disabled); otherwise /dev/null.
    public static func run(_ path: String, _ arguments: [String], environment: [String: String] = [:],
                           timeout: TimeInterval, captureStderr: Bool = false,
                           captureStdout: Bool = false) -> Result {
        var errPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        if captureStderr {
            guard pipe(&errPipe) == 0 else { return Result(status: -1, stderr: "pipe failed") }
        }
        if captureStdout {
            guard pipe(&outPipe) == 0 else {
                for fd in errPipe where fd >= 0 { close(fd) }
                return Result(status: -1, stderr: "pipe failed")
            }
        }
        defer {
            for fd in errPipe + outPipe where fd >= 0 { close(fd) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if captureStdout {
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        if captureStderr {
            posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        configureAttributes(&attr, extraFlags: 0)

        let argv = [(path as NSString).lastPathComponent] + arguments
        let env = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings(argv) { cArgv in
            withCStrings(env) { cEnv in posix_spawn(&pid, path, &actions, &attr, cArgv, cEnv) }
        }
        guard rc == 0 else { return Result(status: -1, stderr: "posix_spawn \(path): \(String(cString: strerror(rc)))") }

        func readSide(_ p: inout [Int32]) {
            close(p[1]); p[1] = -1
            _ = fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK)
        }
        if captureStderr { readSide(&errPipe) }
        if captureStdout { readSide(&outPipe) }
        var collectedErr = Data(), collectedOut = Data()
        func drainAll() {
            if captureStderr { drain(errPipe[0], into: &collectedErr) }
            if captureStdout { drain(outPipe[0], into: &collectedOut) }
        }
        let readable = (captureStderr ? [errPipe[0]] : []) + (captureStdout ? [outPipe[0]] : [])
        let status = wait(pid: pid, timeout: timeout, wakeOn: readable) { drainAll() }
        drainAll()
        let text = String(decoding: collectedErr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: status, stderr: text, stdout: String(decoding: collectedOut, as: UTF8.self))
    }

    /// Signals that were ignored or blocked in the parent go back to their defaults in the child (the helper ignores
    /// SIGTERM to handle it through a dispatch source; the app ignores SIGPIPE). Process-group/session flags on top.
    public static func configureAttributes(_ attr: inout posix_spawnattr_t?, extraFlags: Int32) {
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attr, &empty)
        let flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT) | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
            | extraFlags
        posix_spawnattr_setflags(&attr, Int16(truncatingIfNeeded: flags))
    }

    /// Waits for the child's exit event (a kqueue process source), with a 1 s `waitpid(WNOHANG)` safety net; no
    /// polling while a long-lived child (an admin password prompt) is up. SIGKILLs and reaps after `timeout`.
    /// `tick` runs on every wake-up (draining captured pipes); data arriving on `wakeOn` wakes it too, so a child
    /// writing more than a pipe buffer never waits a second per buffer.
    private static func wait(pid: pid_t, timeout: TimeInterval, wakeOn fds: [Int32] = [], tick: () -> Void) -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        let exited = DispatchSemaphore(value: 0)
        let queue = DispatchQueue.global(qos: .userInitiated)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { exited.signal() }
        source.resume()
        let cancelled = DispatchGroup()
        let readSources = fds.map { fd -> DispatchSourceRead in
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            cancelled.enter()
            s.setCancelHandler { cancelled.leave() }
            // At EOF a pipe stays readable: stop watching it, or a child that closed it early would spin this loop.
            s.setEventHandler { [unowned s] in
                if s.data == 0 { s.cancel() }
                exited.signal()
            }
            s.resume()
            return s
        }
        defer {
            source.cancel()
            for s in readSources { s.cancel() }
            cancelled.wait()   // the caller closes these descriptors next; a source must be gone first
        }
        var raw: Int32 = 0
        while true {
            let r = waitpid(pid, &raw, WNOHANG)
            if r == pid { return decode(raw) }
            if r == -1 && errno != EINTR { return -1 }
            tick()
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                kill(pid, SIGKILL)
                while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
                return -1
            }
            _ = exited.wait(timeout: .now() + min(remaining, 1))
        }
    }

    /// Exit code, or 128 + signal (the shell convention).
    public static func decode(_ raw: Int32) -> Int32 {
        switch WaitStatus(raw) {
        case .exited(let code): return code
        case .signaled(let sig): return 128 + sig
        }
    }

    private static func drain(_ fd: Int32, into data: inout Data) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            if data.count < 64 * 1024 { data.append(contentsOf: buf[0..<n]) }
        }
    }

    /// NULL-terminated C string array that lives for the duration of `body`.
    public static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        cStrings.append(nil)
        defer { for p in cStrings { free(p) } }
        return body(cStrings)
    }
}

/// `waitpid` status, decoded (WIFEXITED / WEXITSTATUS / WTERMSIG are macros Swift can't import).
public enum WaitStatus: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    public init(_ raw: Int32) {
        let low = raw & 0x7f
        self = low == 0 ? .exited((raw >> 8) & 0xff) : .signaled(low)
    }
}
