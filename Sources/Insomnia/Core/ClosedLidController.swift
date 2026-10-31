import AppKit
import Foundation
import InsomniaShared
import Observation
import os
import ServiceManagement

/// Lid mode's main-actor face (ARCHITECTURE.md "Core/ClosedLidController.swift", docs/CLOSED_LID.md §4–§7).
///
/// The engine publishes a *desired* flag (`setDesired`); the controller converges on the latest value through one
/// serial job chain (engage, release, heartbeat failures, drift, recovery, setup, quit), so two privileged sequences
/// never overlap and changes that arrive mid-sequence coalesce. The privileged work itself runs on `LidReconciler`.
/// Guards, the latch and `.needsSetup` are the engine's business; this reports `.off / .engaging / .engaged / .error /
/// .stuck` only.
@MainActor
@Observable
final class ClosedLidController: LidControlling {
    static let shared = ClosedLidController()

    /// nil until `start()` resolves it; drives setup copy (UX.md §6) and Diagnostics.
    private(set) var backendKind: PrivilegeBackendKind?
    /// Our own Team ID (helper backend only), for Diagnostics.
    private(set) var teamID: String?
    private(set) var helper: HelperStatus = .notInstalled
    private(set) var status: LidStatus = .off
    /// SleepDisabled == 1 and not ours (Amphetamine, an admin, MDM). Never touched (Decision 23).
    private(set) var foreignSleepDisabled = false
    /// Set on lid open after ≥ 5 min engaged-closed; the engine shows each distinct report once.
    private(set) var reopenReport: ReopenReport?
    /// Signed builds: files from an earlier unsigned (sudoers) setup exist → "Remove old setup…".
    private(set) var hasLegacySudoers = false

    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    // MARK: Dependencies

    @ObservationIgnored private let reconciler: LidReconciler
    @ObservationIgnored private let power: any PowerReading
    @ObservationIgnored private let refreshLid: @MainActor () -> Void
    @ObservationIgnored private let liveSystem: Bool
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var backend: (any PrivilegedBackend)?
    @ObservationIgnored private let log = Logger(subsystem: "com.gdeml.Insomnia", category: "lid")

    // MARK: Convergence state

    @ObservationIgnored private var engineDesired = false
    /// Sleep Now released the flag; stay released until the screens wake (a DarkWake never re-arms a Mac in a bag).
    @ObservationIgnored private var sleepHold = false
    @ObservationIgnored private var quitting = false
    /// Remove… is running: release and stay released whatever the engine wants.
    @ObservationIgnored private var removing = false
    @ObservationIgnored private var retryRequested = false
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var upgradeAttemptedFor: String?

    // MARK: While engaged / stuck

    @ObservationIgnored private var heartbeatTimer: Timer?
    @ObservationIgnored private var driftTimer: Timer?
    @ObservationIgnored private var clamshellPoll: Timer?
    @ObservationIgnored private var stuckTimer: Timer?
    @ObservationIgnored private var heartbeatInFlight = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var approvalTask: Task<Void, Never>?
    /// One token per visible approval step (a sheet in Settings and the setup window can both be up).
    @ObservationIgnored private var approvalWatchers: Set<UUID> = []
    @ObservationIgnored private var resettingWithPassword = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastLidClosed = false
    @ObservationIgnored private var lastExternalDisplays = 0
    @ObservationIgnored private var lastOnAC = true
    /// Reopen-report counters (§7): started when the lid closes while engaged.
    @ObservationIgnored private var closedRun: (start: Date, battery: Int?, worst: ProcessInfo.ThermalState, end: Date?)?

    init(power: any PowerReading = PowerMonitor.shared,
         refreshLid: @escaping @MainActor () -> Void = { PowerMonitor.shared.refreshLid() },
         reconciler: LidReconciler = LidReconciler(),
         liveSystem: Bool = true,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.power = power
        self.refreshLid = refreshLid
        self.reconciler = reconciler
        self.liveSystem = liveSystem
        self.clock = clock
    }

    private var isEngaged: Bool { if case .engaged = status { return true } else { return false } }
    private var wantsEngaged: Bool { engineDesired && !sleepHold && !quitting && !removing }

    // MARK: - LidControlling

    /// Resolves the backend off the main thread and starts observing. Called first by AwakeEngine.start(). Idempotent.
    func start() async {
        guard !started else { return }
        started = true
        let resolved = await reconciler.resolve()
        backend = resolved.backend
        backendKind = resolved.kind
        teamID = resolved.teamID
        lastLidClosed = power.isLidClosed
        lastExternalDisplays = power.externalDisplayCount
        lastOnAC = power.isOnAC
        if liveSystem { observeSystem() }
        log.notice("lid backend: \(resolved.kind.rawValue, privacy: .public)")
        onChange?()
    }

    /// Launch: marker present → (flag 1 and ours → reset), delete marker; true = "recovered" banner.
    func recoverIfNeeded() async -> Bool {
        await serialized {
            switch await self.reconciler.recover() {
            case .nothing: return false
            case .recovered:
                self.log.notice("launch recovery: normal sleep restored")
                return true
            case .foreign:
                self.foreignSleepDisabled = true
                self.onChange?()
                return false
            case .stuck:
                self.setStatus(.stuck)
                return false
            }
        }
    }

    /// Re-reads the backend status; performs the silent upgrade on `.versionMismatch` (never while engaged).
    func refreshHelper() async {
        await serialized { await self.refreshHelperNow() }
    }

    func setDesired(_ engaged: Bool) {
        if engaged && !engineDesired { sleepHold = false }   // a new request after Sleep Now
        if !engaged { retryRequested = false }
        engineDesired = engaged
        enqueue { await self.converge() }
    }

    func releaseForQuit(timeout: Duration) async {
        quitting = true
        approvalWatchers.removeAll()
        stopApprovalWatch()
        guard status != .off || reconcilerMarkerExists else { return }
        let job = enqueue { await self.converge() }
        let finished: Bool = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { await job.value; once.resume(true) }
            Task { try? await Task.sleep(for: timeout); once.resume(false) }
        }
        if !finished {
            log.error("quit: release timed out; leaving it to the safety net")
            await backend?.abandon()
        }
    }

    /// Sleep Now: release the flag (await), then `/usr/bin/pmset sleepnow`.
    func sleepNow() async {
        sleepHold = true
        await enqueue { await self.converge(sleepAfterRelease: false) }.value
        await reconciler.run(.sleepNow)
    }

    // MARK: - Setup (LidSetupView, Lid & Safety)

    /// Helper: register(); usually ends in `.requiresApproval` (the UI then shows the approval step).
    /// Sudoers: one admin prompt. Throws for the UI to show inline.
    func install() async throws(LidSetupError) {
        let result: Result<HelperStatus, LidSetupError> = await serialized {
            let r = await self.reconciler.install()
            if case .success(let s) = r { self.setHelper(s) } else { await self.refreshHelperNow() }
            return r
        }
        if case .failure(let e) = result { throw e }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// While an approval step is visible: re-check the helper status every 1 s; stops itself on `.installed`. Each
    /// view passes its own token, so closing one of two setup views doesn't stop the poll the other still needs.
    func watchApproval(_ on: Bool, by watcher: UUID) {
        if on { approvalWatchers.insert(watcher) } else { approvalWatchers.remove(watcher) }
        guard !approvalWatchers.isEmpty else { stopApprovalWatch(); return }
        guard approvalTask == nil else { return }
        approvalTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshHelper()
                if self.helper == .installed { break }
                try? await Task.sleep(for: .seconds(1))
            }
            // Cancelled: a replacement may already own `approvalTask`. Only a poll that ended by itself clears it.
            guard !Task.isCancelled else { return }
            self?.approvalTask = nil
        }
    }

    private func stopApprovalWatch() {
        approvalTask?.cancel()
        approvalTask = nil
    }

    /// Release → backend.uninstall → delete marker → Settings.closedLidMode = false. A cancelled or failed removal
    /// changes nothing: lid mode re-engages if it is still wanted.
    func uninstall() async throws(LidSetupError) {
        let error: LidSetupError? = await serialized {
            self.removing = true
            await self.converge()
            let err = await self.reconciler.uninstall(resetFlag: self.reconcilerMarkerExists)
            if err == nil {
                Settings.shared.closedLidMode = false
                if self.backendKind == .helper { Settings.shared.helperRegisteredCDHash = nil }
                // The helper resets an owned flag on SIGTERM; the sudoers script resets it when the marker exists.
                if await self.reconciler.flag() != true {
                    self.reconciler.marker.delete()
                    self.setStatus(.off)
                }
            }
            await self.refreshHelperNow()
            self.removing = false
            if err != nil { await self.converge() }
            return err
        }
        if let error { throw error }
    }

    /// Signed builds with old sudoers artefacts (CLOSED_LID.md §2.1). One admin prompt.
    func removeLegacySudoers() async throws(LidSetupError) {
        let error: LidSetupError? = await serialized {
            let err = await self.reconciler.removeLegacySudoers()
            await self.refreshHelperNow()
            return err
        }
        if let error { throw error }
    }

    /// From `.error`: try again (if lid mode is still wanted).
    func retry() {
        retryRequested = true
        enqueue { await self.converge() }
    }

    /// From `.stuck`: admin prompt running `pmset -a disablesleep 0` (none if the flag already reads 0), read back,
    /// then converge again (lid mode may still be wanted). Returns the failure for inline copy: nil on success, on a
    /// cancelled prompt, outside `.stuck`, or while another reset's prompt is already up (repeated clicks).
    @discardableResult
    func resetWithPassword() async -> LidSetupError? {
        guard !resettingWithPassword else { return nil }
        resettingWithPassword = true
        defer { resettingWithPassword = false }
        let error: LidSetupError? = await serialized {
            guard self.status == .stuck else { return nil }
            var err: LidSetupError?
            if await self.reconciler.flag() != false {
                err = await self.reconciler.resetWithPassword()
            }
            guard await self.reconciler.flag() == false else {
                return err ?? .scriptFailed(code: 0, detail: "SleepDisabled still reads 1 after the reset")
            }
            self.reconciler.marker.delete()
            self.setStatus(.off)
            await self.converge()
            return nil
        }
        return error == .cancelled ? nil : error
    }

    // MARK: - Convergence

    @discardableResult
    private func enqueue(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await op()
        }
        tail = task
        return task
    }

    private func serialized<T: Sendable>(_ op: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await op()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Waits until every queued job has run (tests).
    func idle() async {
        while let t = tail {
            await t.value
            if tail == t { return }
        }
    }

    /// Converges on `wantsEngaged`. Never loops: every branch either returns or moves to a state that returns.
    private func converge(sleepAfterRelease: Bool? = nil) async {
        for _ in 0..<4 {
            let want = wantsEngaged
            switch status {
            case .off:
                guard want, helper == .installed, backend != nil else { return }
                await runEngage()
            case .engaging, .engaged:
                guard !want else { return }
                let sleepAfter = sleepAfterRelease ?? power.isClosedWithoutExternalDisplay
                applyRelease(await reconciler.release(sleepAfter: sleepAfter), onSuccess: .off)
            case .error:
                if want {
                    guard retryRequested, helper == .installed else { return }
                    retryRequested = false
                    await runEngage()
                    return
                }
                setStatus(.off)
            case .stuck:
                return
            case .needsSetup, .suspended, .latched:
                setStatus(.off)   // engine-only states; never ours
            }
        }
    }

    private func runEngage() async {
        setStatus(.engaging)
        let outcome = await reconciler.engage(onLost: { [weak self] in
            Task { @MainActor in self?.safetyNetLost() }
        })
        switch outcome {
        case .engaged:
            setStatus(.engaged(lidClosed: power.isLidClosed))
            if power.isClosedWithoutExternalDisplay { await reconciler.run(.displaySleepNow) }
        case .error(let e):
            setStatus(.error(e))
            if e == .foreignFlag { foreignSleepDisabled = true }
        case .stuck:
            setStatus(.stuck)
        }
    }

    /// `lost`: the release follows a lost safety net, so whatever the release itself returned, the user-facing reason
    /// is that loss (a crashed helper answers the release with an error, then resets the flag on restart).
    private func applyRelease(_ outcome: LidReconciler.ReleaseOutcome, onSuccess: LidStatus, lost: LidError? = nil) {
        switch outcome {
        case .off: setStatus(onSuccess)
        case .error(let e): setStatus(.error(lost ?? e))
        case .stuck: setStatus(.stuck)
        }
    }

    /// The safety net died while engaged (helper connection interrupted/invalidated, watchdog exited).
    private func safetyNetLost() {
        enqueue {
            guard self.isEngaged else { return }
            self.log.error("safety net lost while engaged")
            let outcome = await self.reconciler.release(sleepAfter: self.power.isClosedWithoutExternalDisplay,
                                                        afterLoss: true)
            self.applyRelease(outcome, onSuccess: .error(.safetyNetLost), lost: .safetyNetLost)
            await self.refreshHelperNow()   // Login Items switched off → .requiresApproval → engine shows needsSetup
        }
    }

    /// Tests drive the 10 s heartbeat and the stuck re-check by hand (no timers without `liveSystem`).
    func heartbeatForTesting() { heartbeatTick() }
    func stuckCheckForTesting() { stuckCheck() }

    private func heartbeatTick() {
        guard isEngaged, !heartbeatInFlight else { return }
        heartbeatInFlight = true
        enqueue {
            defer { self.heartbeatInFlight = false }
            guard self.isEngaged else { return }
            guard let error = await self.reconciler.heartbeat() else { return }
            self.log.error("heartbeat: \(String(describing: error), privacy: .public)")
            let outcome = await self.reconciler.release(sleepAfter: self.power.isClosedWithoutExternalDisplay,
                                                        afterLoss: error == .safetyNetLost)
            self.applyRelease(outcome, onSuccess: .error(error), lost: error)
            if error == .safetyNetLost { await self.refreshHelperNow() }
        }
    }

    private func driftCheck() {
        guard isEngaged else { return }
        enqueue {
            guard self.isEngaged else { return }
            if let outcome = await self.reconciler.driftCheck(sleepAfter: self.power.isClosedWithoutExternalDisplay) {
                self.applyRelease(outcome, onSuccess: .error(.overridden))
            }
        }
    }

    private func stuckCheck() {
        enqueue {
            guard self.status == .stuck else { return }
            if await self.reconciler.flag() == false {
                self.log.notice("the stuck flag reads 0 again")
                self.reconciler.marker.delete()
                self.setStatus(.off)
                await self.converge()   // the engine may still want lid mode; nothing else would re-ask
            }
        }
    }

    private func refreshHelperNow() async {
        var s = await reconciler.helperStatus()
        if case .versionMismatch(_, let bundled) = s, !isEngaged, status != .engaging, !quitting,
           upgradeAttemptedFor != bundled {
            // Silent upgrade (§2.6): unregister + register, then up to 5 s for the new helper to answer.
            upgradeAttemptedFor = bundled
            log.notice("helper version mismatch; re-registering")
            if case .success(let after) = await reconciler.install() { s = after }
            // Wall-clock bound: each status read can itself wait on an unanswered XPC call.
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while s != .installed && s != .requiresApproval && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                s = await reconciler.helperStatus()
            }
        }
        setHelper(s)
        if backendKind == .helper {
            let legacy = SudoersBackend.legacyArtefactsPresent
            if legacy != hasLegacySudoers { hasLegacySudoers = legacy }
        }
        let flag = await reconciler.flag()
        let foreign: Bool
        if flag == true, !isEngaged, status != .engaging, status != .stuck {
            foreign = await !reconciler.ownsFlag()
        } else {
            foreign = false
        }
        if foreign != foreignSleepDisabled {
            foreignSleepDisabled = foreign
            onChange?()
        }
        // "Another app already turned sleep off" / another user's lid mode have no Retry link (UX §5): once the flag
        // is 0 again, try again by itself.
        if status == .error(.foreignFlag) || status == .error(.otherUser), flag == false, wantsEngaged {
            retryRequested = true
            enqueue { await self.converge() }
        }
    }

    // MARK: - State changes

    private func setHelper(_ s: HelperStatus) {
        guard s != helper else { return }
        log.notice("helper status: \(String(describing: s), privacy: .public)")
        helper = s
        onChange?()
    }

    private func setStatus(_ new: LidStatus) {
        guard new != status else { return }
        let wasEngaged = isEngaged
        // Debug only: the engine logs every lid transition it shows ("[lid] old → new"), so this would be a double.
        log.debug("lid: \(String(describing: self.status), privacy: .public) → \(String(describing: new), privacy: .public)")
        status = new
        if isEngaged && !wasEngaged { didEngage() }
        if !isEngaged && wasEngaged { didDisengage() }
        updateStuckTimer()
        onChange?()
    }

    private func didEngage() {
        if power.isLidClosed { beginClosedRun() }
        guard liveSystem else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Insomnia lid mode safety guards")
        // Main-actor timers in .common mode: a hung main actor stops the heartbeat (that's the point); menu tracking
        // and sheets don't.
        heartbeatTimer = makeTimer(HelperInfo.heartbeatInterval) { $0.heartbeatTick() }
        driftTimer = makeTimer(60) { $0.driftCheck() }
        clamshellPoll = makeTimer(5) { $0.refreshLid() }
    }

    private func didDisengage() {
        for t in [heartbeatTimer, driftTimer, clamshellPoll] { t?.invalidate() }
        heartbeatTimer = nil
        driftTimer = nil
        clamshellPoll = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if closedRun != nil && closedRun?.end == nil { closedRun?.end = clock() }
    }

    private func updateStuckTimer() {
        if status == .stuck, stuckTimer == nil, liveSystem {
            stuckTimer = makeTimer(10) { $0.stuckCheck() }
        } else if status != .stuck, let t = stuckTimer {
            t.invalidate()
            stuckTimer = nil
        }
    }

    private func makeTimer(_ interval: TimeInterval, _ fire: @escaping @MainActor (ClosedLidController) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                fire(self)
            }
        }
        timer.tolerance = min(1, interval / 5)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: - System observation

    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .insomniaPowerDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.powerChanged() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.driftCheck() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sleepHold else { return }
                self.sleepHold = false   // a user-visible wake after Sleep Now: lid mode may re-engage
                self.enqueue { await self.converge() }
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshHelper() }
            }
        })
        // Fast user switching: back in our session, another user's lid mode may have let go (`.error(.otherUser)`).
        observers.append(ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshHelper() }
            }
        })
    }

    /// Lid, displays, power source and heat, while engaged (§1 side effects 3–4, §7 reopen report). Returns the
    /// `displaysleepnow` task when it started one (tests await it).
    @discardableResult
    func powerChanged() -> Task<Void, Never>? {
        let closed = power.isLidClosed
        let ext = power.externalDisplayCount
        let onAC = power.isOnAC
        defer {
            lastLidClosed = closed
            lastExternalDisplays = ext
            lastOnAC = onAC
        }
        if var run = closedRun, run.end == nil, power.thermalState.rawValue > run.worst.rawValue {
            run.worst = power.thermalState
            closedRun = run
        }
        if !closed && lastLidClosed { finishClosedRun() }
        guard isEngaged else { return nil }
        if closed != lastLidClosed {
            setStatus(.engaged(lidClosed: closed))
            if closed { beginClosedRun() }
        }
        // The lid just closed, or the last external display went away with the lid shut: blank the internal panel.
        // Never with an external display attached (it would blank that too).
        var blank: Task<Void, Never>?
        if closed && ext == 0 && (!lastLidClosed || lastExternalDisplays > 0) {
            blank = Task { await reconciler.run(.displaySleepNow) }
        }
        if onAC != lastOnAC { driftCheck() }
        return blank
    }

    private func beginClosedRun() {
        guard closedRun == nil else { return }
        closedRun = (clock(), power.batteryPercent, power.thermalState, nil)
    }

    private func finishClosedRun() {
        guard let run = closedRun else { return }
        closedRun = nil
        let now = clock()
        let closedFor = (run.end ?? now).timeIntervalSince(run.start)
        guard closedFor >= 300 else { return }
        reopenReport = ReopenReport(closedFor: closedFor, batteryStart: run.battery, batteryEnd: power.batteryPercent,
                                    worstThermal: run.worst)
        onChange?()
    }

    private var reconcilerMarkerExists: Bool { reconciler.marker.exists }
}
