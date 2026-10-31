import Foundation
import InsomniaShared
import os

/// Unprivileged side effects of lid mode, faked in tests: the IORegistry readback and the two `pmset` verbs that need
/// no root (CLOSED_LID.md §1 side effects 3–4).
protocol LidSystem: Sendable {
    /// IOPMrootDomain SleepDisabled; nil if unreadable.
    func sleepDisabled() -> Bool?
    func run(_ command: LidSystemCommand)
}

enum LidSystemCommand: String, Sendable {
    /// `/usr/bin/pmset displaysleepnow`: the internal panel can stay lit with the lid shut (Apple Silicon).
    case displaySleepNow = "displaysleepnow"
    /// `/usr/bin/pmset sleepnow`: releasing with the lid shut doesn't reliably sleep the Mac; also Sleep Now.
    case sleepNow = "sleepnow"
}

struct LiveLidSystem: LidSystem {
    func sleepDisabled() -> Bool? { RootDomain.sleepDisabled() }
    func run(_ command: LidSystemCommand) {
        let r = Spawn.run("/usr/bin/pmset", [command.rawValue], timeout: 5)
        if !r.succeeded {
            Logger(subsystem: "com.gdeml.Insomnia", category: "lid").error("pmset \(command.rawValue, privacy: .public) exited \(r.status, privacy: .public)")
        }
    }
}

/// Owns the privileged backend and runs the CLOSED_LID.md §4.3 sequences (Engage, Release, Drift, Launch recovery)
/// plus every SMAppService / signature read and every child-process spawn, off the main thread. `ClosedLidController`
/// serialises the mutating sequences, so actor reentrancy at the awaits below never interleaves two of them.
actor LidReconciler {
    enum EngageOutcome: Equatable, Sendable { case engaged, error(LidError), stuck }
    enum ReleaseOutcome: Equatable, Sendable { case off, error(LidError), stuck }
    enum RecoveryOutcome: Equatable, Sendable { case nothing, recovered, foreign, stuck }

    private let makeBackend: @Sendable () async -> any PrivilegedBackend
    private(set) var backend: (any PrivilegedBackend)?
    nonisolated let system: any LidSystem
    nonisolated let marker: LidMarker
    private let readbackInterval: Duration
    private let abandonWait: Duration
    /// How long a release after a lost safety net waits for the other side to reset (a crashed helper is respawned by
    /// launchd within ~10 s and runs its restart reset; CLOSED_LID.md T2 allows 15 s).
    private let lostWait: Duration
    private let log = Logger(subsystem: "com.gdeml.Insomnia", category: "lid")

    init(makeBackend: @escaping @Sendable () async -> any PrivilegedBackend = { await PrivilegedBackends.makeDefault() },
         system: any LidSystem = LiveLidSystem(), marker: LidMarker = .standard,
         readbackInterval: Duration = .milliseconds(200), abandonWait: Duration = .seconds(2),
         lostWait: Duration = .seconds(15)) {
        self.makeBackend = makeBackend
        self.system = system
        self.marker = marker
        self.readbackInterval = readbackInterval
        self.abandonWait = abandonWait
        self.lostWait = lostWait
    }

    /// Chooses the backend once (certificate reads happen here, off the main thread).
    func resolve() async -> (kind: PrivilegeBackendKind, teamID: String?, backend: any PrivilegedBackend) {
        let b: any PrivilegedBackend
        if let backend { b = backend } else {
            b = await makeBackend()
            backend = b
        }
        return (b.kind, (b as? HelperBackend)?.teamID, b)
    }

    func helperStatus() async -> HelperStatus {
        guard let backend else { return .notInstalled }
        return await backend.status()
    }

    func flag() -> Bool? { system.sleepDisabled() }

    func ownsFlag() async -> Bool { await backend?.ownsFlag() ?? false }

    func run(_ command: LidSystemCommand) { system.run(command) }

    // MARK: Engage (§4.3)

    func engage(onLost: @escaping @Sendable () -> Void) async -> EngageOutcome {
        guard let backend else { return .error(.helperMissing) }
        // 2. A flag that is already 1 and not ours is never taken over (Decision 34). The helper decides this itself
        //    (and tells another user's flag, `.otherUser`, from a foreign one); sudoers asks the marker.
        if backend.kind != .helper, system.sleepDisabled() == true, await !backend.ownsFlag() {
            return .error(.foreignFlag)
        }
        // 3. Marker before anything is set, so a crash from here on is recovered at the next launch.
        guard marker.write() else {
            log.error("couldn't write the lid marker; not engaging")
            return .error(.commandFailed(-1))
        }
        // 4. Safety net + flag.
        let rc = await backend.engage(onLost: onLost)
        if backend.kind == .helper, let refusal = HelperResult(rawValue: rc), Self.isRefusal(refusal) {
            // The helper changed nothing (and dropped the session): no release needed.
            marker.delete()
            switch refusal {
            case .foreignFlag: return .error(.foreignFlag)
            case .otherUser: return .error(.otherUser)
            default: return .error(.commandFailed(rc))
            }
        }
        // 5. Readback.
        if rc == 0, await readback(expect: true) {
            log.notice("engaged (readback ✓)")
            return .engaged
        }
        log.error("engage failed: rc \(rc, privacy: .public), readback \(String(describing: self.system.sleepDisabled()), privacy: .public)")
        switch await release(sleepAfter: false) {
        case .stuck: return .stuck
        default: return .error(rc == 0 ? .readbackMismatch : .commandFailed(rc))
        }
    }

    /// Helper replies that mean "nothing was set".
    private static func isRefusal(_ r: HelperResult) -> Bool {
        r == .foreignFlag || r == .otherUser || r == .backstop || r == .notEngaged || r == .overridden
    }

    // MARK: Release (§4.3)

    /// Only call when the flag may be ours (engaged/engaging, or the marker exists). `afterLoss`: the safety net is
    /// already gone (helper crash, watchdog exit, heartbeat failure), so wait up to `lostWait` for its reset instead
    /// of `abandonWait` before calling it stuck.
    func release(sleepAfter: Bool, afterLoss: Bool = false) async -> ReleaseOutcome {
        guard let backend else { return .stuck }
        let rc = await backend.release()
        let accepted = rc == 0 || (backend.kind == .helper && rc == HelperResult.notEngaged.rawValue)
        if accepted, await readback(expect: false) {
            marker.delete()
            if sleepAfter { system.run(.sleepNow) }
            log.notice("released (readback ✓)")
            return .off
        }
        // The safety net finishes the job: helper invalidation → the helper resets; sudoers EOF → the watchdog resets.
        log.error("release failed (rc \(rc, privacy: .public)); abandoning the session")
        await backend.abandon()
        let wait = afterLoss ? lostWait : abandonWait
        let clock = ContinuousClock()
        let deadline = clock.now + wait
        while clock.now < deadline, system.sleepDisabled() != false {
            try? await Task.sleep(for: min(.milliseconds(500), deadline - clock.now))
        }
        if system.sleepDisabled() == false {
            marker.delete()
            if sleepAfter { system.run(.sleepNow) }
            return .error(.commandFailed(rc))
        }
        log.fault("SleepDisabled is still 1 after every reset: stuck")
        return .stuck
    }

    /// Drop the session without disarming (quit timeout). Bypasses nothing: the backend locks its own state.
    func abandon() async { await backend?.abandon() }

    // MARK: Heartbeat and drift (§4.1, §4.3)

    func heartbeat() async -> LidError? {
        guard let backend else { return .safetyNetLost }
        return await backend.heartbeat()
    }

    /// While engaged: an unexpected 0 with the safety net alive is an intentional external override. Returns nil while
    /// the flag still reads 1 (or can't be read).
    func driftCheck(sleepAfter: Bool) async -> ReleaseOutcome? {
        guard system.sleepDisabled() == false else { return nil }
        log.notice("SleepDisabled went to 0 while engaged: external override")
        switch await release(sleepAfter: sleepAfter) {
        case .stuck: return .stuck
        default: return .error(.overridden)
        }
    }

    // MARK: Launch recovery (§4.3)

    func recover() async -> RecoveryOutcome {
        guard marker.exists, let backend else { return .nothing }
        guard system.sleepDisabled() == true else {
            marker.delete()   // layer 2 (helper / watchdog) already reset it
            return .recovered
        }
        let ours: Bool?
        if let helper = backend as? HelperBackend {
            ours = await helper.queryStatus()?.ownsFlag   // nil: the helper doesn't answer
        } else {
            ours = await backend.ownsFlag()
        }
        switch ours {
        case .some(true):
            return await release(sleepAfter: false) == .stuck ? .stuck : .recovered
        case .some(false):
            marker.delete()   // set by something else since; never touched (Decision 23)
            return .foreign
        case .none:
            // Our marker, the flag at 1, and no helper to clear it: say so loudly.
            return .stuck
        }
    }

    // MARK: Setup

    func install() async -> Result<HelperStatus, LidSetupError> {
        guard let backend else { return .failure(.helperUnreachable) }
        do { return .success(try await backend.install()) } catch { return .failure(error) }
    }

    func uninstall(resetFlag: Bool) async -> LidSetupError? {
        guard let backend else { return nil }
        do { try await backend.uninstall(resetFlag: resetFlag) } catch { return error }
        return nil
    }

    func resetWithPassword() async -> LidSetupError? {
        guard let backend else { return .helperUnreachable }
        do { try await backend.resetWithPassword() } catch { return error }
        await backend.abandon()   // whatever session was left is meaningless now
        return nil
    }

    func removeLegacySudoers() async -> LidSetupError? {
        do { try SudoersBackend.runUninstall(reset: false) } catch { return error }
        return nil
    }

    // MARK: Private

    /// Immediately, then up to 3 × 200 ms.
    private func readback(expect: Bool) async -> Bool {
        for attempt in 0...3 {
            if attempt > 0 { try? await Task.sleep(for: readbackInterval) }
            if system.sleepDisabled() == expect { return true }
        }
        return false
    }
}
