import Darwin
import Foundation
import IOKit.ps
import InsomniaShared

/// The helper's whole state, confined to one serial queue (docs/CLOSED_LID.md §2.5). Decisions come from the pure
/// `HelperPolicy`; this class gathers the inputs and carries them out. Every timer here exists only while it has work:
/// per-session deadlines while engaged, the reset retry while a reset failed, the backstop poll on battery ≤ 15%.
final class HelperDaemon: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.gdeml.Insomnia.helper.state")
    let selfInfo: CodeSignature.SelfInfo
    private let flag = FlagController()

    // State (queue only).
    private var sessions: [ObjectIdentifier: HelperSession] = [:]
    private var ownsFlag = false
    private var resetRetry: DispatchSourceTimer?
    private var backstopPoll: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var powerSource: CFRunLoopSource?

    init(selfInfo: CodeSignature.SelfInfo) {
        self.selfInfo = selfInfo
    }

    private var engagedUID: UInt32? { sessions.values.first?.uid }

    // MARK: Start-up (main thread, before the listener is resumed)

    /// SIGTERM handling, boot / restart reset, battery backstop. Runs in every mode, including reset-only.
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
            startUpReset(context: "boot reset")
        case .restartReset:
            // The previous helper instance died holding the flag; no session survives a restart.
            startUpReset(context: "restart reset")
        case .none:
            break
        }
    }

    /// Boot / restart reset. Anything but a verified 0 (1, or unreadable) is reset: `pmset -a disablesleep 0` is always
    /// safe. Ownership is recorded on disk BEFORE trying, so if this instance dies or the reset keeps failing, the
    /// next start in the same boot takes the restart-reset path instead of forgetting the flag. The file is deleted
    /// only after a verified 0 (resetOwnedFlag).
    private func startUpReset(context: String) {
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
        resetOwnedFlag(context: context)
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
        var now = flag.read()
        if ownsFlag && now == false && !sessions.isEmpty {
            handleOverride()
            now = flag.read()
        }
        let battery = PowerSourceReading.current()
        let decision = HelperPolicy.engage(alreadyEngaged: session.engaged, engagedUID: engagedUID,
                                           requesterUID: session.uid, onBattery: !battery.isOnAC,
                                           batteryPercent: battery.percent, flag: now, ownsFlag: ownsFlag)
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
                resetOwnedFlag(context: "failed engage")
                reply(HelperResult.setFailed.rawValue, flag.read() ?? false)
            }
        }
        checkBackstop(reason: "engage")
    }

    func release(_ session: HelperSession, _ reply: @escaping @Sendable (Int32, Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard session.engaged else {
            reply(HelperResult.notEngaged.rawValue, flag.read() ?? false)
            return
        }
        remove(session, reason: .notEngaged)
        var result = HelperResult.ok
        if HelperPolicy.resetsAfterDrop(remainingSessions: sessions.count, ownsFlag: ownsFlag),
           !resetOwnedFlag(context: "release") { result = .setFailed }
        reply(result.rawValue, flag.read() ?? false)
    }

    func heartbeat(_ session: HelperSession, _ reply: @escaping @Sendable (Int32) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let decision = HelperPolicy.heartbeat(sessionEngaged: session.engaged, dropReason: session.dropReason,
                                              flag: session.engaged ? flag.read() : nil, ownsFlag: ownsFlag)
        switch decision {
        case .ok:
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
            resetOwnedFlag(context: "connection lost")
        }
    }

    // MARK: Sessions

    private func add(_ session: HelperSession) {
        session.engaged = true
        session.dropReason = nil
        sessions[ObjectIdentifier(session)] = session
        cancelResetRetry()   // we own the flag again and it's wanted
        armDeadline(session)
    }

    private func remove(_ session: HelperSession, reason: HelperResult) {
        session.engaged = false
        session.dropReason = reason
        session.deadline?.cancel()
        session.deadline = nil
        sessions.removeValue(forKey: ObjectIdentifier(session))
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
            resetOwnedFlag(context: "heartbeat timeout")
        }
    }

    // MARK: Flag reset

    /// Clears a flag we own. Success: forget ownership, delete the file. Failure: keep both, retry every 5 s, log.
    @discardableResult
    private func resetOwnedFlag(context: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        if flag.set(false) {
            ownsFlag = false
            flag.deleteOwnershipFile()
            cancelResetRetry()
            HelperLog.flag.notice("\(context, privacy: .public): SleepDisabled = 0")
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
            self.resetOwnedFlag(context: "reset retry")
        }
        resetRetry = timer
        timer.resume()
    }

    private func cancelResetRetry() {
        resetRetry?.cancel()
        resetRetry = nil
    }

    /// Someone cleared the flag while we owned it (§2.5 "External override"): respected, never re-applied.
    private func handleOverride() {
        HelperLog.flag.notice("SleepDisabled was cleared by something else; dropping \(self.sessions.count, privacy: .public) session(s)")
        dropAll(.overridden)
        ownsFlag = false
        cancelResetRetry()
        flag.deleteOwnershipFile()
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
        if flag.set(false) {
            ownsFlag = false
            cancelResetRetry()
            flag.deleteOwnershipFile()
        } else if ownsFlag {
            scheduleResetRetry()
        }
        SystemSleeper.sleepNow()
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
