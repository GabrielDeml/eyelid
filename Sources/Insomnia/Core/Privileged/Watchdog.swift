import Darwin
import Foundation
import InsomniaShared

/// Sudoers backend only (docs/CLOSED_LID.md §2.7): a detached `/bin/bash` that resets the flag with
/// `sudo -n /usr/bin/pmset -a disablesleep 0` on pipe EOF (we crashed), 45 s without a heartbeat (we hung), or
/// TERM/HUP/INT. Spawned BEFORE the flag is set, only from `LidReconciler`.
///
/// It resets twice, `resetSettle` apart: a `sudo -n pmset -a disablesleep 1` that was still in flight when the app
/// died (crash or quit timeout mid-engage; the `sudo` child outlives us) can land after the first reset, never after
/// the second. `resetSettle` is longer than the engage spawn timeout (5 s).
///
/// After the second reset reads back 0 it deletes the lid marker (`$M`), but only while the marker still names the
/// app that armed it (`$P`, its pid): a stale marker would otherwise make the next launch treat a later, foreign
/// `SleepDisabled = 1` as ours and clear it (Decision 23), and a newer instance's marker is never touched.
final class Watchdog: Sendable {
    static let resetSettle = 6
    static let script = "r(){ /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; sleep \(resetSettle); "
        + "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 && /usr/sbin/ioreg -r -c IOPMrootDomain -d 1 "
        + "| /usr/bin/grep -q '\"SleepDisabled\" = No' && [ -n \"$M\" ] && IFS=' ' read -r p _ < \"$M\" "
        + "&& [ \"$p\" = \"$P\" ] && /bin/rm -f \"$M\"; exit 0; }; trap r TERM HUP INT; "
        + "while IFS= read -r -t \(Int(HelperInfo.heartbeatTimeout)) l; do [ \"$l\" = disarm ] && exit 0; done; r"

    enum ArmError: Error { case pipe(Int32), spawn(Int32) }

    /// The pipe's write end and whether the coming exit is expected. Shared with the exit handler, which outlives us
    /// if needed (it holds its own source until the child is reaped).
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var writeFD: Int32
        var intentional = false
        /// Set (under `lock`) when the child has been reaped: from then on its pid may belong to someone else.
        var reaped = false
        init(writeFD: Int32) { self.writeFD = writeFD }

        func closeFD() {
            lock.lock(); defer { lock.unlock() }
            if writeFD >= 0 { close(writeFD); writeFD = -1 }
        }
    }

    let pid: pid_t
    private let state: State

    private init(pid: pid_t, state: State) {
        self.pid = pid
        self.state = state
    }

    /// `onExit` fires once, on a background queue, if the watchdog exits while armed (not after disarm/abandon).
    /// `environment` is added to the fixed PATH (`M` = the lid marker's path, `P` = our pid). `script` is replaced only
    /// by tests, which run the real script with harmless stand-ins for `sudo` and `ioreg`.
    static func arm(script: String = script, environment: [String: String] = [:],
                    onExit: @escaping @Sendable () -> Void) throws -> Watchdog {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw ArmError.pipe(errno) }
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[0], 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        Spawn.configureAttributes(&attr, extraFlags: Int32(POSIX_SPAWN_SETSID))

        var pid: pid_t = 0
        let argv = ["bash", "-c", script]
        let env = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"] + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let rc = Spawn.withCStrings(argv) { a in
            Spawn.withCStrings(env) { e in posix_spawn(&pid, "/bin/bash", &actions, &attr, a, e) }
        }
        close(fds[0])
        guard rc == 0 else {
            close(fds[1])
            throw ArmError.spawn(rc)
        }

        let state = State(writeFD: fds[1])
        let childPID = pid
        let source = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit,
                                                      queue: DispatchQueue.global(qos: .userInitiated))
        // The handler keeps `source` alive (a cycle broken by cancel) so the child is always reaped.
        source.setEventHandler {
            var status: Int32 = 0
            source.cancel()
            state.lock.lock()
            _ = waitpid(childPID, &status, WNOHANG)
            state.reaped = true
            let expected = state.intentional
            if state.writeFD >= 0 { close(state.writeFD); state.writeFD = -1 }
            state.lock.unlock()
            if !expected { onExit() }
        }
        source.resume()
        return Watchdog(pid: childPID, state: state)
    }

    /// Writes "h\n"; false on EPIPE (the watchdog is gone).
    func heartbeat() -> Bool { send("h\n") }

    /// Still armed: the pipe is open and the watchdog reads it (a heartbeat goes through).
    var isArmed: Bool { heartbeat() }

    /// Call only after the flag was reset and read back 0: the watchdog exits without touching anything.
    func disarm() {
        state.lock.lock()
        state.intentional = true
        state.lock.unlock()
        _ = send("disarm\n")
        state.closeFD()
    }

    /// Close WITHOUT disarming: the watchdog sees EOF and resets the flag itself.
    func abandon() {
        state.lock.lock()
        state.intentional = true
        state.lock.unlock()
        state.closeFD()
    }

    /// An abandoned watchdog that is about to be superseded by a new engagement: stop it before its (delayed) reset
    /// can clear the new flag. Only ever called after a NEW watchdog is armed, so the flag stays covered. Waits up to
    /// `wait` for it to go; a step that can't be killed (a root `pmset`) just finishes its reset.
    func stopSuperseded(wait: TimeInterval = 1) {
        state.lock.lock()
        if !state.reaped { kill(pid, SIGKILL) }   // under the lock: not reaped == the pid is still this child's
        state.lock.unlock()
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if state.lock.withLock({ state.reaped }) { return }
            usleep(50_000)
        }
    }

    private func send(_ line: String) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        guard state.writeFD >= 0 else { return false }
        let bytes = Array(line.utf8)
        let n = bytes.withUnsafeBytes { write(state.writeFD, $0.baseAddress, $0.count) }
        return n == bytes.count
    }
}
