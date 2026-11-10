import Darwin
import Foundation
import IOKit.ps
import EyelidShared

/// The helper's whole state, confined to one serial queue (docs/DESIGN.md "Security"). Decisions come from the pure
/// `HelperPolicy`; this class gathers the inputs and carries them out. Every timer here exists only while it has work:
/// per-session deadlines while engaged, the reset retry while a reset failed, the backstop poll on battery ≤ 15%, the
/// heat window while a session exists and the thermal state is `.serious`.
final class HelperDaemon: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.gdeml.Eyelid.helper.state")
    let selfInfo: CodeSignature.SelfInfo
    private let flag = FlagController()

    // State (queue only).
    private var sessions: [ObjectIdentifier: HelperSession] = [:]
    private var ownsFlag = false
    /// What follows the next successful reset of our flag (kept across a failed reset for its retry).
    private var afterReset = HelperPolicy.AfterReset.nothing
    private var resetRetry: DispatchSourceTimer?
    private var backstopPoll: DispatchSourceTimer?
    /// Uptime (ns) since the thermal state has been `.serious` or worse; nil below. Tracked all the time.
    private var seriousSince: UInt64?
    private var heatWindow: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var powerSource: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?

    init(selfInfo: CodeSignature.SelfInfo) {
        self.selfInfo = selfInfo
    }

    private var engagedUID: UInt32? { sessions.values.first?.uid }

    // MARK: Start-up (main thread, before the listener is resumed)

    /// SIGTERM handling, boot / restart reset, battery and heat backstops. Runs in every mode, including reset-only.
    func startUp() {
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        term.setEventHandler { [unowned self] in self.terminate() }
        term.resume()
        signalSources.append(term)

        queue.sync { self.startReset() }

        // IOPS notifications on the main run loop (main.swift runs it), hopping onto the state queue.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let daemon = Unmanaged<HelperDaemon>.fromOpaque(context).takeUnretainedValue()
            daemon.queue.async { daemon.checkBackstop(reason: "power source changed") }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        } else {
            HelperLog.backstop.error("IOPSNotificationCreateRunLoopSource failed; backstop checks only on engage")
        }
        queue.async { self.checkBackstop(reason: "start") }

        // Thermal changes drive the heat backstop; engage and heartbeat sample it too, in case a note is missed.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [unowned self] _ in
            self.queue.async { self.checkHeat(reason: "thermal state changed") }
        }
        queue.async { self.checkHeat(reason: "start") }
    }

    private func startReset() {
        dispatchPrecondition(condition: .onQueue(queue))
        let current = FlagController.bootSessionUUID()
        let decision = HelperPolicy.startReset(savedBootUUID: flag.readBootMarker(), currentBootUUID: current,
                                               ownershipFileExists: flag.ownershipFileExists)
        switch decision {
        case .bootReset:
            if let current { flag.writeBootMarker(current) }
            // The setting persists across reboots; nobody can still want it (Amphetamine/MDM re-apply their own).
            startUpReset(context: "boot reset", then: .nothing)
        case .restartReset:
            // The previous helper instance died holding the flag; no session survives a restart, and the app that
            // held it may be gone or stopped too: sleep a shut-in Mac.
            startUpReset(context: "restart reset", then: .sleepIfShutIn)
        case .none:
            break
        }
    }

    /// Boot / restart reset. Anything but a verified 0 (1, or unreadable) is reset: `pmset -a disablesleep 0` is always
    /// safe. Ownership is recorded on disk BEFORE trying, so if this instance dies or the reset keeps failing, the
    /// next start in the same boot takes the restart-reset path instead of forgetting the flag. The file is deleted
    /// only after a verified 0 (resetOwnedFlag).
    private func startUpReset(context: String, then: HelperPolicy.AfterReset) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard HelperPolicy.startUpResets(flag: flag.read()) else {
            flag.deleteOwnershipFile()
            return
        }
        HelperLog.main.notice("\(context, privacy: .public): SleepDisabled is not 0 at start; clearing it")
        if !flag.writeOwnershipFile() {
            HelperLog.flag.error("\(context, privacy: .public): couldn't write the ownership file; resetting anyway")
        }
        ownsFlag = true   // so a failed reset is retried like our own
        resetOwnedFlag(context: context, then: then)
    }

    /// The start-up self-check failed (the binary on disk isn't the one running): run only the reset step, which only
    /// ever clears the flag, before exiting for launchd to start the new binary.
    func resetBeforeSelfCheckExit() {
        queue.sync {
            self.startReset()
            self.cancelResetRetry()   // we're about to exit; the ownership file makes the next start retry
        }
    }

    // MARK: SIGTERM (unregister, Login Items switch off, shutdown, kill)

    private func terminate() {
        dispatchPrecondition(condition: .onQueue(queue))
        HelperLog.main.notice("SIGTERM (\(self.sessions.count, privacy: .public) session(s), owns flag: \(self.ownsFlag, privacy: .public))")
        dropAll(.notEngaged)
        afterReset = .nothing   // shutdown, logout, unregister: never sleep on the way out
        let wasOwned = ownsFlag
        var cleared = false
        if wasOwned, flag.set(false) {
            cleared = true
            ownsFlag = false
            flag.deleteOwnershipFile()
        }
        // A clean stop exits 0 (never respawned). If the reset failed, exit non-zero and keep the ownership file:
        // if launchd still has the job loaded it restarts us and the restart reset tries again.
        exit(HelperPolicy.terminateExitCode(ownsFlag: wasOwned, resetSucceeded: cleared))
    }

    // MARK: XPC methods (each hops here from the connection's queue)

    /// `ownsFlag` is per caller (HelperPolicy.statusOwnsFlag).
    func status(_ caller: HelperSession, _ reply: @escaping @Sendable (String, String, Bool, Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let ours = HelperPolicy.statusOwnsFlag(ownsFlag: ownsFlag, sessionUIDs: sessions.values.map(\.uid),
                                               callerUID: caller.uid)
        reply(HelperInfo.version, selfInfo.cdhash ?? "", flag.read() ?? false, ours)
    }

    func engage(_ session: HelperSession, _ reply: @escaping @Sendable (Int32, Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        // A trip drops any sessions (this one included) before the decision; while hot, engage is refused.
        let hot = checkHeat(reason: "engage")
        var now = flag.read()
        if ownsFlag && now == false && !sessions.isEmpty {
            handleOverride()
            now = flag.read()
        }
        let battery = PowerSourceReading.current()
        let decision = HelperPolicy.engage(alreadyEngaged: session.engaged, engagedUID: engagedUID,
                                           requesterUID: session.uid, onBattery: !battery.isOnAC,
                                           batteryPercent: battery.percent, flag: now, ownsFlag: ownsFlag, hot: hot)
        switch decision {
        case .alreadyEngaged:
            armDeadline(session)
            reply(HelperResult.ok.rawValue, now ?? false)
        case .join:
            add(session)
            reply(HelperResult.ok.rawValue, now ?? false)
        case .refuse(let result):
            HelperLog.xpc.notice("engage refused: \(String(describing: result), privacy: .public) (pid \(session.pid, privacy: .public), uid \(session.uid, privacy: .public))")
            reply(result.rawValue, now ?? false)
        case .setFlag:
            guard flag.writeOwnershipFile() else {
                HelperLog.flag.error("couldn't write the ownership file; refusing to set the flag")
                reply(HelperResult.setFailed.rawValue, now ?? false)
                return
            }
            ownsFlag = true
            if flag.set(true) {
                add(session)
                HelperLog.flag.notice("engaged: SleepDisabled = 1 (pid \(session.pid, privacy: .public), uid \(session.uid, privacy: .public))")
                reply(HelperResult.ok.rawValue, true)
            } else {
                // Nothing new to do after it, but keep what a pending reset (crash, backstop) still owes.
                resetOwnedFlag(context: "failed engage", then: afterReset)
                reply(HelperResult.setFailed.rawValue, flag.read() ?? false)
            }
        }
        checkBackstop(reason: "engage")
    }

    func release(_ session: HelperSession, _ reply: @escaping @Sendable (Int32, Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard session.engaged else {
            // Dropped earlier: say why, as heartbeat does (.hot / .backstop: the reset is already done).
            reply((session.dropReason ?? .notEngaged).rawValue, flag.read() ?? false)
            return
        }
        remove(session, reason: .notEngaged)
        var result = HelperResult.ok
        // The app follows an explicit release with its own sleep: only it can tell a bag from someone at a display.
        if HelperPolicy.resetsAfterDrop(remainingSessions: sessions.count, ownsFlag: ownsFlag),
           !resetOwnedFlag(context: "release", then: .nothing) { result = .setFailed }
        reply(result.rawValue, flag.read() ?? false)
    }

    func heartbeat(_ session: HelperSession, _ reply: @escaping @Sendable (Int32) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let decision = HelperPolicy.heartbeat(sessionEngaged: session.engaged, dropReason: session.dropReason,
                                              flag: session.engaged ? flag.read() : nil, ownsFlag: ownsFlag)
        switch decision {
        case .ok:
            // A trip drops this session too (reason .hot), replies first, then resets and sleeps.
            if tripsOnHeartbeat(reply: { reply(HelperResult.hot.rawValue) }) { return }
            armDeadline(session)
            reply(HelperResult.ok.rawValue)
        case .overridden:
            handleOverride()
            reply(HelperResult.overridden.rawValue)
        case .reply(let result):
            reply(result.rawValue)
        }
    }

    /// Crash watch: the client's connection went away (crash, Force Quit, kill -9, logout).
    func connectionInvalidated(_ session: HelperSession) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard session.engaged else { return }
        HelperLog.xpc.notice("session lost (pid \(session.pid, privacy: .public)); dropping it")
        remove(session, reason: .notEngaged)
        if HelperPolicy.resetsAfterDrop(remainingSessions: sessions.count, ownsFlag: ownsFlag) {
            resetOwnedFlag(context: "connection lost", then: .sleepIfShutIn)
        }
    }

    // MARK: Sessions

    private func add(_ session: HelperSession) {
        session.engaged = true
        session.dropReason = nil
        sessions[ObjectIdentifier(session)] = session
        cancelResetRetry()   // we own the flag again and it's wanted
        afterReset = .nothing
        armDeadline(session)
        armHeatWindow()
    }

    private func remove(_ session: HelperSession, reason: HelperResult) {
        session.engaged = false
        session.dropReason = reason
        session.deadline?.cancel()
        session.deadline = nil
        sessions.removeValue(forKey: ObjectIdentifier(session))
        if sessions.isEmpty { cancelHeatWindow() }
    }

    private func dropAll(_ reason: HelperResult) {
        for session in sessions.values { remove(session, reason: reason) }
    }

    /// Hang watch: one-shot deadline on uptime (DispatchTime), re-armed by every heartbeat.
    private func armDeadline(_ session: HelperSession) {
        let timer: DispatchSourceTimer
        if let existing = session.deadline {
            timer = existing
        } else {
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self, weak session] in
                guard let self, let session else { return }
                self.deadlineExpired(session)
            }
            session.deadline = timer
            timer.schedule(deadline: .now() + HelperInfo.heartbeatTimeout, leeway: .milliseconds(500))
            timer.resume()
            return
        }
        timer.schedule(deadline: .now() + HelperInfo.heartbeatTimeout, leeway: .milliseconds(500))
    }

    private func deadlineExpired(_ session: HelperSession) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard session.engaged else { return }
        HelperLog.xpc.notice("no heartbeat for \(Int(HelperInfo.heartbeatTimeout), privacy: .public) s (pid \(session.pid, privacy: .public)); dropping the session")
        remove(session, reason: .notEngaged)
        session.connection?.invalidate()
        if HelperPolicy.resetsAfterDrop(remainingSessions: sessions.count, ownsFlag: ownsFlag) {
            resetOwnedFlag(context: "heartbeat timeout", then: .sleepIfShutIn)
        }
    }

    // MARK: Flag reset

    /// Clears a flag we own, then does `then` (docs/DESIGN.md "Safety", sleep after its own resets). Success: forget
    /// ownership, delete the file. Failure: keep both, remember `then`, retry every 5 s, log.
    @discardableResult
    private func resetOwnedFlag(context: String, then: HelperPolicy.AfterReset) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        afterReset = then
        if flag.set(false) {
            ownsFlag = false
            flag.deleteOwnershipFile()
            cancelResetRetry()
            HelperLog.flag.notice("\(context, privacy: .public): SleepDisabled = 0")
            let after = afterReset
            afterReset = .nothing
            let shutIn = HelperPolicy.isShutIn(lidClosed: RootDomainRegistry.lidClosed(),
                                               lidCloseSleeps: RootDomainRegistry.lidCloseSleeps())
            if HelperPolicy.sleeps(after: after, shutIn: shutIn) {
                HelperLog.flag.notice("\(context, privacy: .public): sleeping the Mac (lid shut: \(shutIn, privacy: .public))")
                SystemSleeper.sleepNow()
            }
            return true
        }
        HelperLog.flag.fault("\(context, privacy: .public): couldn't clear SleepDisabled; retrying every 5 s")
        scheduleResetRetry()
        return false
    }

    private func scheduleResetRetry() {
        guard resetRetry == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.sessions.isEmpty, self.ownsFlag else { self.cancelResetRetry(); return }
            self.resetOwnedFlag(context: "reset retry", then: self.afterReset)
        }
        resetRetry = timer
        timer.resume()
    }

    private func cancelResetRetry() {
        resetRetry?.cancel()
        resetRetry = nil
    }

    /// Someone else cleared the flag while we owned it (an external override): respected, never re-applied.
    private func handleOverride() {
        HelperLog.flag.notice("SleepDisabled was cleared by something else; dropping \(self.sessions.count, privacy: .public) session(s)")
        dropAll(.overridden)
        ownsFlag = false
        afterReset = .nothing
        cancelResetRetry()
        flag.deleteOwnershipFile()
    }

    // MARK: Heat backstop (our own flag only)

    /// Samples the thermal state, keeps `seriousSince` and the window timer, and trips if the condition holds while a
    /// session holds our flag. Returns whether the condition holds right now (engage refuses then).
    @discardableResult
    private func checkHeat(reason: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let hot = heatCondition()
        if hot, !sessions.isEmpty, ownsFlag { trip(reason: reason, reply: nil) }
        armHeatWindow()
        return hot
    }

    /// The heartbeat's variant: `reply` goes out after the sessions are dropped and before the (slow) reset.
    private func tripsOnHeartbeat(reply: @escaping () -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard heatCondition(), !sessions.isEmpty, ownsFlag else { armHeatWindow(); return false }
        trip(reason: "heartbeat", reply: reply)
        return true
    }

    private func heatCondition() -> Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        let now = DispatchTime.now().uptimeNanoseconds
        if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            seriousSince = seriousSince.map { min($0, now) } ?? now
        } else {
            seriousSince = nil
        }
        let seriousFor = seriousSince.map { TimeInterval(now - $0) / 1_000_000_000 }
        let shutIn = HelperPolicy.isShutIn(lidClosed: RootDomainRegistry.lidClosed(),
                                           lidCloseSleeps: RootDomainRegistry.lidCloseSleeps())
        return HelperPolicy.heatTrips(thermal: thermal, seriousFor: seriousFor, shutIn: shutIn)
    }

    private func trip(reason: String, reply: (() -> Void)?) {
        HelperLog.backstop.fault("heat backstop (\(reason, privacy: .public), thermal \(ProcessInfo.processInfo.thermalState.rawValue, privacy: .public)): dropping \(self.sessions.count, privacy: .public) session(s), resetting")
        dropAll(.hot)
        reply?()
        resetOwnedFlag(context: "heat backstop", then: .sleepIfShutIn)
    }

    /// While a session exists and the state is `.serious`, a one-shot just after the end of the window re-checks. Once
    /// the window is over (the Mac wasn't shut in then), heartbeats (every 10 s) and thermal changes re-check instead:
    /// the helper doesn't watch the lid, so a lid closing later is seen within one heartbeat.
    private func armHeatWindow() {
        cancelHeatWindow()
        guard !sessions.isEmpty, let since = seriousSince else { return }
        let end = since + UInt64(HelperInfo.thermalSeriousWindow * 1_000_000_000) + 500_000_000
        guard end > DispatchTime.now().uptimeNanoseconds else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: end), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.checkHeat(reason: "serious window") }
        heatWindow = timer
        timer.resume()
    }

    private func cancelHeatWindow() {
        heatWindow?.cancel()
        heatWindow = nil
    }

    // MARK: Battery backstop (any setter; also in reset-only mode)

    func checkBackstop(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        let battery = PowerSourceReading.current()
        setBackstopPoll(HelperPolicy.needsBackstopPoll(onBattery: !battery.isOnAC, batteryPercent: battery.percent))
        guard HelperPolicy.backstopTrips(onBattery: !battery.isOnAC, batteryPercent: battery.percent,
                                         flag: flag.read()) else { return }
        HelperLog.backstop.fault("battery at \(battery.percent ?? -1, privacy: .public)% with SleepDisabled = 1 (\(reason, privacy: .public)): resetting and sleeping")
        dropAll(.backstop)
        if ownsFlag {
            // Sleeps once the reset succeeds, now or on a later retry (sleeping is blocked while the flag is 1).
            resetOwnedFlag(context: "battery backstop", then: .sleep)
        } else {
            // Someone else's flag: cleared once, never retried, never taken over.
            _ = flag.set(false)
            SystemSleeper.sleepNow()
        }
    }

    private func setBackstopPoll(_ on: Bool) {
        if on, backstopPoll == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + HelperInfo.backstopPollInterval, repeating: HelperInfo.backstopPollInterval,
                           leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.checkBackstop(reason: "poll") }
            backstopPoll = timer
            timer.resume()
        } else if !on, let timer = backstopPoll {
            timer.cancel()
            backstopPoll = nil
        }
    }
}
