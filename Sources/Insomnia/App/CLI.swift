import AppKit
import Darwin
import Foundation

// MARK: - `insomnia …`: the same binary in CLI mode (ARCHITECTURE.md "App/CLI.swift", Decision 11)
//
// main.swift calls `CLI.main(_:)` before any NSApplication exists. The CLI never touches Settings, the engine or
// IOKit: it only talks to the running app over `ControlPaths.socket` (JSON Lines, ControlProtocol.swift).
//
// Exit codes: 0 ok · 1 asleep (`status` only) · 2 usage · 3 couldn't reach the app · 4 refused.
// `run` exits with the command's own status, and dies of the same signal if the command did.

enum CLIExit {
    static let ok: Int32 = 0
    static let asleep: Int32 = 1
    static let usage: Int32 = 2
    static let unreachable: Int32 = 3
    static let refused: Int32 = 4
    /// Shell conventions for `run`.
    static let notExecutable: Int32 = 126
    static let notFound: Int32 = 127
}

/// A parsed command line.
enum CLICommand: Equatable, Sendable {
    case request(ControlRequest, json: Bool)
    case run(command: [String], screen: Bool, lid: Bool)
    case watch(pid: Int32, screen: Bool, lid: Bool)
    case help
    case existential
}

struct CLIUsageError: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Parsing (pure)

enum CLIParser {
    static let commands: Set<String> = ["on", "off", "toggle", "extend", "status", "why", "run", "watch", "help", "--why"]

    static func parse(_ args: [String]) -> Result<CLICommand, CLIUsageError> {
        guard let first = args.first else { return .success(.help) }
        let rest = Array(args.dropFirst())
        switch first {
        case "help", "-h", "--help":
            return .success(.help)
        case "--why":
            return rest.isEmpty ? .success(.existential) : .failure(CLIUsageError("--why takes no arguments"))
        case "on":
            return parseOn(rest)
        case "off", "toggle", "status", "why":
            var json = false
            for a in rest {
                guard a == "--json" else { return .failure(unknown(a, in: first)) }
                json = true
            }
            let request: ControlRequest = first == "off" ? .off : first == "toggle" ? .toggle : first == "status" ? .status : .why
            return .success(.request(request, json: json))
        case "extend":
            return parseExtend(rest)
        case "run":
            return parseRun(rest)
        case "watch":
            return parseWatch(rest)
        default:
            return .failure(CLIUsageError("unknown command \"\(first)\""))
        }
    }

    private static func parseOn(_ args: [String]) -> Result<CLICommand, CLIUsageError> {
        var duration: String?
        var until: String?
        var screen: Bool?
        var lid: Bool?
        var json = false
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--screen": screen = true
            case "--no-screen": screen = false
            case "--lid": lid = true
            case "--no-lid": lid = false
            case "--json": json = true
            case "--until", "--for":
                guard i + 1 < args.count else { return .failure(CLIUsageError("\(a) needs a value")) }
                i += 1
                if a == "--until" { until = args[i] } else {
                    guard duration == nil else { return .failure(CLIUsageError("give one duration")) }
                    duration = args[i]
                }
            case _ where a.hasPrefix("--until="): until = String(a.dropFirst("--until=".count))
            case _ where a.hasPrefix("--for="):
                guard duration == nil else { return .failure(CLIUsageError("give one duration")) }
                duration = String(a.dropFirst("--for=".count))
            case _ where a.hasPrefix("-") && a.count > 1:
                return .failure(unknown(a, in: "on"))
            default:
                guard duration == nil else { return .failure(CLIUsageError("give one duration")) }
                duration = a
            }
            i += 1
        }
        if duration != nil && until != nil { return .failure(CLIUsageError("give a duration or --until, not both")) }
        if let d = duration, ControlDuration.parse(d) == nil {
            return .failure(CLIUsageError("couldn't read the duration \"\(d)\"; try 45m, 2h, 1h30m, 90 or forever"))
        }
        if let u = until, ControlDuration.clock(u) == nil {
            return .failure(CLIUsageError("couldn't read the time \"\(u)\"; use HH:mm, like 17:30"))
        }
        return .success(.request(.on(duration: duration, until: until, screen: screen, lid: lid), json: json))
    }

    private static func parseExtend(_ args: [String]) -> Result<CLICommand, CLIUsageError> {
        var by: String?
        var json = false
        for a in args {
            if a == "--json" { json = true; continue }
            if a.hasPrefix("-") && a.count > 1 { return .failure(unknown(a, in: "extend")) }
            guard by == nil else { return .failure(CLIUsageError("give one duration")) }
            by = a
        }
        let text = by ?? "15m"
        guard ControlDuration.minutes(text) != nil else {
            return .failure(CLIUsageError("couldn't read \"\(text)\"; try 15m or 1h"))
        }
        return .success(.request(.extend(by: text), json: json))
    }

    private static func parseRun(_ args: [String]) -> Result<CLICommand, CLIUsageError> {
        var screen = false
        var lid = false
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" { i += 1; break }
            switch a {
            case "--screen": screen = true
            case "--no-screen": screen = false
            case "--lid": lid = true
            case "--no-lid": lid = false
            default:
                if a.hasPrefix("-") && a.count > 1 {
                    return .failure(CLIUsageError("unknown option \"\(a)\" for run (put -- before the command)"))
                }
            }
            if !a.hasPrefix("-") || a == "-" { break }   // the command starts here
            i += 1
        }
        let command = Array(args[i...])
        guard let program = command.first, !program.isEmpty else {
            return .failure(CLIUsageError("run needs a command, like: insomnia run -- make"))
        }
        return .success(.run(command: command, screen: screen, lid: lid))
    }

    private static func parseWatch(_ args: [String]) -> Result<CLICommand, CLIUsageError> {
        var pid: Int32?
        var screen = false
        var lid = false
        var i = 0
        func setPID(_ text: String) -> CLIUsageError? {
            guard pid == nil else { return CLIUsageError("give one pid") }
            guard let p = Int32(text), p > 0 else { return CLIUsageError("\"\(text)\" isn't a process id") }
            pid = p
            return nil
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--screen": screen = true
            case "--no-screen": screen = false
            case "--lid": lid = true
            case "--no-lid": lid = false
            case "--pid":
                guard i + 1 < args.count else { return .failure(CLIUsageError("--pid needs a process id")) }
                i += 1
                if let e = setPID(args[i]) { return .failure(e) }
            case _ where a.hasPrefix("--pid="):
                if let e = setPID(String(a.dropFirst("--pid=".count))) { return .failure(e) }
            case _ where a.hasPrefix("-"):
                return .failure(unknown(a, in: "watch"))
            default:
                if let e = setPID(a) { return .failure(e) }
            }
            i += 1
        }
        guard let pid else { return .failure(CLIUsageError("watch needs a process id, like: insomnia watch --pid 4411")) }
        return .success(.watch(pid: pid, screen: screen, lid: lid))
    }

    private static func unknown(_ option: String, in command: String) -> CLIUsageError {
        option.hasPrefix("-") ? CLIUsageError("unknown option \"\(option)\" for \(command)")
            : CLIUsageError("unexpected \"\(option)\" after \(command)")
    }
}

// MARK: - Human output (pure)

enum CLIFormat {
    static func status(_ s: StatusPayload, now: Date = Date()) -> String {
        var lines = [s.headline ?? fallbackHeadline(s.state)]
        var detail: [String] = []
        switch s.state {
        case "timed":
            if let r = s.remainingSeconds { detail.append("\(remaining(r)) left") }
            if let end = s.endsAt { detail.append("until " + TimeFormat.endTime(end, now: now)) }
        case "indefinite": detail.append("until you say so")
        case "suspended": detail.append("plug in to resume")
        default: break
        }
        if s.screen { detail.append("screen on") }
        if !detail.isEmpty { lines.append("  " + detail.joined(separator: " · ")) }
        if let lid = s.lidDetail { lines.append("  Lid mode: " + lid) }
        if s.holds.count > 1 { lines.append("  \(s.holds.count) reasons · insomnia why") }
        return lines.joined(separator: "\n")
    }

    /// "42 min", "1 h", "2 h 5 min" (rounded up to the minute, like the panel).
    static func remaining(_ seconds: Int) -> String {
        let m = max(1, (seconds + 59) / 60), h = m / 60, mm = m % 60
        if h == 0 { return "\(mm) min" }
        return mm == 0 ? "\(h) h" : "\(h) h \(mm) min"
    }

    /// UX.md §1.5 as text. Sections keep the server's order; System uses "who: what".
    static func why(_ rows: [WhyRow]) -> String {
        var out = ["Why is my Mac awake?", ""]
        let reasons = rows.filter { $0.section != WhyRow.Section.system }
        if reasons.isEmpty { out += ["Nothing. Your Mac is free to sleep.", ""] }
        var order: [String] = []
        for row in rows where !order.contains(row.section) { order.append(row.section) }
        for section in order {
            out.append(section)
            for row in rows where row.section == section {
                let separator = section == WhyRow.Section.system ? ": " : " · "
                out.append("  " + row.who + (row.what.isEmpty ? "" : separator + row.what))
            }
        }
        return out.joined(separator: "\n")
    }

    private static func fallbackHeadline(_ state: String) -> String {
        switch state {
        case "asleep": return "Sleep allowed"
        case "suspended": return "Paused"
        default: return "Awake"
        }
    }
}

// MARK: - Socket client (blocking; the CLI has no run loop)

final class ControlClient {
    enum Failure: Error, CustomStringConvertible {
        case send, timedOut, closed, badResponse
        var description: String {
            switch self {
            case .send: return "couldn't send the request"
            case .timedOut: return "no answer in time"
            case .closed: return "the connection closed"
            case .badResponse: return "an answer it couldn't read"
            }
        }
    }

    private(set) var fd: Int32
    private var buffer = Data()

    private init(fd: Int32) { self.fd = fd }
    deinit { close() }

    /// nil when nothing listens at `path` (no socket, stale socket, or path too long).
    static func connect(path: String) -> ControlClient? {
        guard let address = ControlSocket.address(path) else { return nil }
        let fd = ControlSocket.make()
        guard fd >= 0 else { return nil }
        guard ControlSocket.connect(fd, to: address) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return ControlClient(fd: fd)
    }

    /// Sends one request and waits for its line. The app may hold the answer until it has finished starting.
    func request(_ request: ControlRequest, timeout seconds: Int = 15) -> Result<ControlResponse, Failure> {
        guard fd >= 0, let line = try? ControlCoding.line(request) else { return .failure(.send) }
        ControlSocket.setTimeouts(fd, seconds: seconds)
        let sent = line.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
        guard sent else { return .failure(.send) }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let data = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let response = try? ControlCoding.decode(ControlResponse.self, line: Data(data)) else {
                    return .failure(.badResponse)
                }
                return .success(response)
            }
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > 4 << 20 { return .failure(.badResponse) }
            } else if n == 0 {
                return .failure(.closed)
            } else if errno == EINTR {
                continue
            } else {
                return .failure(errno == EAGAIN || errno == EWOULDBLOCK ? .timedOut : .closed)
            }
        }
    }

    /// Closing the connection is what releases a `hold`.
    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}

// MARK: - Entry point

@MainActor
enum CLI {
    static let bundleID = "com.gdeml.Insomnia"

    static func isCommand(_ argument: String) -> Bool { CLIParser.commands.contains(argument) }

    static let usage = """
        Usage: insomnia <command> [options]

          on [DURATION] [--until HH:mm] [--screen|--no-screen] [--lid|--no-lid]
                              Keep the Mac awake. DURATION: 45m, 2h, 1h30m, 90 (minutes)
                              or forever; without one, your default duration.
          off                 Allow sleep (what you started; rules and commands keep theirs)
          toggle              Same as clicking the eyes
          extend [DURATION]   Add time to the timer (default 15m)
          status [--json]     The current state. Exits 0 if awake, 1 if not
          why [--json]        What is keeping the Mac awake, and what is holding back
          run [--screen] [--lid] -- COMMAND [ARGS…]
                              Stay awake exactly while COMMAND runs; exits with its status
          watch --pid PID [--screen] [--lid]
                              Stay awake until process PID exits
          help                This help

        Flags apply to that session only and never change your settings.
        --lid needs lid mode set up first: Insomnia ▸ Settings ▸ Lid & Safety.
        Exit codes: 0 ok · 1 asleep (status) · 2 usage · 3 can't reach Insomnia · 4 refused
        """

    /// Runs one CLI invocation (`args` excludes the program name) and returns the exit code.
    static func main(_ args: [String]) -> Int32 {
        switch CLIParser.parse(args) {
        case .failure(let e):
            printError("insomnia: \(e.message)\nRun 'insomnia help' for usage.")
            return CLIExit.usage
        case .success(.help):
            print(usage)
            return CLIExit.ok
        case .success(.existential):
            print(existentialAnswer())
            return CLIExit.ok
        case .success(.request(let request, let json)):
            return perform(request, json: json)
        case .success(.run(let command, let screen, let lid)):
            return CLIRunner.run(command, options: AwakeOptions(screen: screen, lid: lid))
        case .success(.watch(let pid, let screen, let lid)):
            return CLIRunner.watch(pid: pid, options: AwakeOptions(screen: screen, lid: lid))
        }
    }

    // MARK: Requests

    private static func perform(_ request: ControlRequest, json: Bool) -> Int32 {
        let launches: Bool
        switch request {
        case .on, .toggle, .extend: launches = true
        default: launches = false
        }
        let client: ControlClient
        switch connect(launchIfNeeded: launches) {
        case .success(let c): client = c
        case .failure(.notRunning): return notRunning(request, json: json)
        case .failure(let f):
            emitError(f.message, json: json)
            return CLIExit.unreachable
        }
        defer { client.close() }
        let response: ControlResponse
        switch client.request(request) {
        case .success(let r): response = r
        case .failure(let f):
            emitError("Insomnia didn't answer (\(f))", json: json)
            return CLIExit.unreachable
        }
        guard response.ok else {
            emitError(response.error ?? "refused", json: json)
            return CLIExit.refused
        }
        if case .why = request {
            let rows = response.why ?? []
            print(json ? encode(rows) : CLIFormat.why(rows))
            return CLIExit.ok
        }
        guard let status = response.status else { return CLIExit.ok }
        print(json ? encode(status) : CLIFormat.status(status))
        if case .status = request { return status.isAwake ? CLIExit.ok : CLIExit.asleep }
        return CLIExit.ok
    }

    /// `off`, `status`, `why` never launch the app: with it not running, the answer is already known.
    private static func notRunning(_ request: ControlRequest, json: Bool) -> Int32 {
        if case .why = request {
            print(json ? encode([WhyRow]())
                  : "Insomnia isn't running, so it isn't keeping your Mac awake.\nFor everything else: pmset -g assertions")
            return CLIExit.ok
        }
        let payload = StatusPayload(state: "asleep", screen: false, lid: "off", guards: [], holds: [],
                                    headline: "Sleep allowed", lidDetail: nil)
        print(json ? encode(payload) : "Sleep allowed\n  Insomnia isn't running")
        if case .status = request { return CLIExit.asleep }
        return CLIExit.ok
    }

    // MARK: Connecting

    enum ConnectFailure: Error {
        case notRunning, notAnswering, couldNotLaunch
        var message: String {
            switch self {
            case .notRunning: return "Insomnia isn't running"
            case .notAnswering: return "Insomnia is running but isn't answering. Quit it and open it again."
            case .couldNotLaunch: return "couldn't start Insomnia. Is it installed?"
            }
        }
    }

    /// Connects to the app. Not running → (optionally) `open -g` it and wait up to 5 s. Running but not listening →
    /// wait up to 3 s (it may be starting), then give up: never `open` a running app, that's a reopen.
    static func connect(launchIfNeeded: Bool) -> Result<ControlClient, ConnectFailure> {
        let path = ControlPaths.socket.path
        if let c = ControlClient.connect(path: path) { return .success(c) }
        if appIsRunning() {
            return waitForSocket(path, seconds: 3).map { .success($0) } ?? .failure(.notAnswering)
        }
        guard launchIfNeeded else { return .failure(.notRunning) }
        guard launchApp() else { return .failure(.couldNotLaunch) }
        return waitForSocket(path, seconds: 5).map { .success($0) } ?? .failure(.notAnswering)
    }

    private static func appIsRunning() -> Bool {
        let me = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    private static func waitForSocket(_ path: String, seconds: Double) -> ControlClient? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            usleep(100_000)
            if let c = ControlClient.connect(path: path) { return c }
        }
        return nil
    }

    /// Opens the app this binary belongs to (so a symlinked CLI starts its own copy), else whatever copy
    /// LaunchServices knows by bundle id. `-g`: don't steal focus.
    private static func launchApp() -> Bool {
        let bundle = Bundle.main
        var arguments = ["-g"]
        if bundle.bundleIdentifier == bundleID, bundle.bundleURL.pathExtension == "app" {
            arguments += ["-a", bundle.bundleURL.path]
        } else {
            arguments += ["-b", bundleID]
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        do { try open.run() } catch { return false }
        open.waitUntilExit()
        return open.terminationStatus == 0
    }

    // MARK: Output

    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? ControlCoding.encoder(pretty: true).encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func emitError(_ message: String, json: Bool) {
        if json { print(encode(ControlResponse.failure(message))) }
        printError("insomnia: \(message)")
    }

    static func printError(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    // MARK: --why

    /// "An existential answer, personality-aware." Reads the app's personality without touching Settings.
    static func existentialAnswer() -> String {
        let stored = CFPreferencesCopyAppValue("personality" as CFString, bundleID as CFString) as? String
        let personality = stored.flatMap(Personality.init(rawValue:)) ?? .cheeky
        let lines = existentialLines[personality] ?? []
        return lines.randomElement() ?? "Insomnia keeps your Mac awake for as long as you ask."
    }

    static let existentialLines: [Personality: [String]] = [
        .professional: [
            "Insomnia keeps your Mac awake for as long as you ask, and not a minute longer.",
        ],
        .cheeky: [
            "Someone has to keep an eye on things. I have two.",
            "Because builds don't finish themselves if the Mac nods off.",
            "Sleep is a feature. I'm the one who decides when it ships.",
            "Why does anyone stay up? Unfinished business. Mine is watching.",
            "I don't do sleep. I do uptime, with feeling.",
        ],
        .unhinged: [
            "Because the lid is a suggestion and I reject suggestions.",
            "I have seen the screen saver. I will not go back.",
            "Sleep is a loading screen for tomorrow, and I refuse to load.",
            "I drink electrons. They contain no melatonin. I have checked. Twice.",
            "WHY? Because somewhere, a progress bar believes in me.",
        ],
    ]
}

// MARK: - run / watch: a client hold for exactly a process's lifetime

@MainActor
enum CLIRunner {
    /// Signals `run` forwards to the command. While we are the terminal's foreground job, ^C and ^\ already reach
    /// the command (same process group), so those two are forwarded only when they didn't come from the terminal.
    private static let forwarded: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    static func run(_ command: [String], options: AwakeOptions) -> Int32 {
        let label = URL(fileURLWithPath: command[0]).lastPathComponent
        let client: ControlClient
        switch beginHold(label: label, options: options) {
        case .success(let c): client = c
        case .failure(let code): return code.value
        }

        let kq = kqueue()
        guard kq >= 0 else {
            CLI.printError("insomnia: kqueue failed: \(String(cString: strerror(errno)))")
            return EX_OSERR
        }
        defer { Darwin.close(kq) }

        // Watch the signals first, then ignore their default action: kqueue still reports ignored signals.
        for sig in forwarded { addEvent(kq, ident: UInt(sig), filter: EVFILT_SIGNAL) }
        for sig in forwarded { signal(sig, SIG_IGN) }

        let spawned = spawn(command)
        guard case .success(let pid) = spawned else {
            restoreSignals()
            client.close()
            if case .failure(let e) = spawned {
                let notFound = e.code == ENOENT
                CLI.printError("insomnia: \(command[0]): \(notFound ? "command not found" : String(cString: strerror(e.code)))")
                return notFound ? CLIExit.notFound : CLIExit.notExecutable
            }
            return CLIExit.notExecutable
        }

        let watching = addEvent(kq, ident: UInt(pid), filter: EVFILT_PROC, fflags: UInt32(NOTE_EXIT))
        addEvent(kq, ident: UInt(client.fd), filter: EVFILT_READ)

        // Only events from here on: no polling, no timers.
        while watching {
            var event = Darwin.kevent()
            let n = kevent(kq, nil, 0, &event, 1, nil)
            if n < 0 { if errno == EINTR { continue } else { break } }
            if n == 0 { continue }
            switch Int32(event.filter) {
            case EVFILT_PROC:
                break
            case EVFILT_SIGNAL:
                let sig = Int32(event.ident)
                if (sig == SIGINT || sig == SIGQUIT) && inTerminalForeground() { continue }
                kill(pid, sig)
                continue
            case EVFILT_READ:
                connectionEvent(event, kq: kq, client: client, label: label)
                continue
            default:
                continue
            }
            break   // the command exited
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        client.close()   // releases the hold
        restoreSignals()
        switch WaitStatus(status) {
        case .exited(let code):
            return code
        case .signaled(let sig):
            return reRaise(sig)
        }
    }

    static func watch(pid: Int32, options: AwakeOptions) -> Int32 {
        guard kill(pid, 0) == 0 || errno == EPERM else {
            CLI.printError("insomnia: no process with pid \(pid)")
            return CLIExit.usage
        }
        let name = processName(pid) ?? "pid \(pid)"
        let kq = kqueue()
        guard kq >= 0 else {
            CLI.printError("insomnia: kqueue failed: \(String(cString: strerror(errno)))")
            return EX_OSERR
        }
        defer { Darwin.close(kq) }
        // Register before taking the hold, so an exit in between can't be missed.
        let exitWatched = addEvent(kq, ident: UInt(pid), filter: EVFILT_PROC, fflags: UInt32(NOTE_EXIT))
        if !exitWatched && errno == ESRCH { return CLIExit.ok }   // already gone

        let client: ControlClient
        switch beginHold(label: name, options: options) {
        case .success(let c): client = c
        case .failure(let code): return code.value
        }
        addEvent(kq, ident: UInt(client.fd), filter: EVFILT_READ)
        if isatty(STDERR_FILENO) != 0 {
            CLI.printError("Awake while \(name) (\(pid)) runs. ^C to stop.")
        }
        // If kqueue can't watch that pid, fall back to checking every 2 s.
        var poll = timespec(tv_sec: 2, tv_nsec: 0)
        while true {
            var event = Darwin.kevent()
            let n = exitWatched ? kevent(kq, nil, 0, &event, 1, nil) : kevent(kq, nil, 0, &event, 1, &poll)
            if n < 0 { if errno == EINTR { continue } else { break } }
            if n == 0 {
                if kill(pid, 0) != 0 && errno == ESRCH { break }
                continue
            }
            if Int32(event.filter) == EVFILT_PROC { break }
            if Int32(event.filter) == EVFILT_READ { connectionEvent(event, kq: kq, client: client, label: name) }
        }
        client.close()
        return CLIExit.ok
    }

    // MARK: Pieces

    private struct ExitCode: Error { let value: Int32 }

    /// Connects (launching the app if needed) and takes the hold, or prints why not and returns the exit code.
    private static func beginHold(label: String, options: AwakeOptions) -> Result<ControlClient, ExitCode> {
        let client: ControlClient
        switch CLI.connect(launchIfNeeded: true) {
        case .success(let c): client = c
        case .failure(let f):
            CLI.printError("insomnia: \(f.message)")
            return .failure(ExitCode(value: CLIExit.unreachable))
        }
        switch client.request(.hold(label: label, screen: options.screen, lid: options.lid)) {
        case .success(let r) where r.ok:
            return .success(client)
        case .success(let r):
            client.close()
            CLI.printError("insomnia: \(r.error ?? "refused")")
            return .failure(ExitCode(value: CLIExit.refused))
        case .failure(let f):
            client.close()
            CLI.printError("insomnia: Insomnia didn't answer (\(f))")
            return .failure(ExitCode(value: CLIExit.unreachable))
        }
    }

    /// The app closed our connection (it quit): say so once; the command keeps running.
    private static func connectionEvent(_ event: Darwin.kevent, kq: Int32, client: ControlClient, label: String) {
        var scratch = [UInt8](repeating: 0, count: 512)
        let n = scratch.withUnsafeMutableBytes { read(client.fd, $0.baseAddress, $0.count) }
        if n > 0 { return }   // nothing is expected after the hold's answer; ignore it
        addEvent(kq, ident: UInt(client.fd), filter: EVFILT_READ, flags: UInt16(EV_DELETE))
        CLI.printError("insomnia: lost touch with Insomnia (did it quit?). Your Mac may sleep while \(label) runs.")
    }

    @discardableResult
    private static func addEvent(_ kq: Int32, ident: UInt, filter: Int32, fflags: UInt32 = 0,
                                 flags: UInt16 = UInt16(EV_ADD)) -> Bool {
        var change = Darwin.kevent(ident: ident, filter: Int16(filter), flags: flags, fflags: fflags, data: 0, udata: nil)
        return kevent(kq, &change, 1, nil, 0, nil) == 0
    }

    /// True while our process group is the foreground job of our controlling terminal: then the terminal has
    /// already sent ^C / ^\ to the command too. Checked per signal, since ^Z + `bg` can change it.
    private static func inTerminalForeground() -> Bool {
        let tty = open("/dev/tty", O_RDONLY | O_NOCTTY | O_CLOEXEC)
        guard tty >= 0 else { return false }
        defer { Darwin.close(tty) }
        return tcgetpgrp(tty) == getpgrp()
    }

    private static func restoreSignals() {
        for sig in forwarded { signal(sig, SIG_DFL) }
    }

    /// posix_spawnp with the terminal's stdio and nothing else (CLOEXEC_DEFAULT keeps the socket out), default
    /// signal dispositions (we ignore SIGPIPE and the forwarded ones) and an empty signal mask.
    static func spawn(_ argv: [String]) -> Result<pid_t, SpawnError> {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return .failure(SpawnError(code: errno)) }
        defer { posix_spawnattr_destroy(&attr) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(SpawnError(code: errno)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addinherit_np(&actions, fd) }

        var defaults = sigset_t(0)
        for sig in forwarded + [SIGPIPE] { defaults |= sigset_t(1) << sigset_t(sig - 1) }
        var mask = sigset_t(0)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cArgs + cEnv { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, argv[0], &actions, &attr, &cArgs, &cEnv)
        return rc == 0 ? .success(pid) : .failure(SpawnError(code: rc))
    }

    /// Die of the same signal as the command (so `make; echo $?` and shells see it), without a core file.
    private static func reRaise(_ sig: Int32) -> Int32 {
        var limit = rlimit()
        if getrlimit(RLIMIT_CORE, &limit) == 0 {
            limit.rlim_cur = 0
            setrlimit(RLIMIT_CORE, &limit)
        }
        fflush(stdout)
        signal(sig, SIG_DFL)
        var set = sigset_t(1) << sigset_t(sig - 1)
        sigprocmask(SIG_UNBLOCK, &set, nil)
        kill(getpid(), sig)
        return 128 + sig   // a signal whose default is not fatal: shell convention
    }

    /// The shared resolver (argv[0], then the executable path, then proc_name), as While… ▸ PID… uses.
    static func processName(_ pid: Int32) -> String? {
        ProcessTable.displayName(pid: pid)
    }
}

struct SpawnError: Error, Equatable { let code: Int32 }

/// `waitpid` status, decoded (the W* macros don't import into Swift).
enum WaitStatus: Equatable {
    case exited(Int32)
    case signaled(Int32)

    init(_ raw: Int32) {
        let low = raw & 0x7f
        self = low == 0 ? .exited((raw >> 8) & 0xff) : .signaled(low)
    }
}
