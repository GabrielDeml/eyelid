import AppKit
import Foundation
import EyelidShared
import Observation
import os
import ServiceManagement

/// Lid mode: sets the system's `SleepDisabled` flag through the root helper while the engine wants it, and gives it
/// back. The helper owns every safety reset (connection lost, 45 s without a heartbeat, crash, boot, 10% battery, heat)
/// and sleeps a shut-in Mac after the ones nobody else can follow up; this side says "on" while it is alive, verifies
/// "off" by reading the flag back, and follows its own releases with a sleep when the Mac is unattended.
/// All engage/release work runs one step at a time in `work()`.
@MainActor
@Observable
final class LidController: LidControlling {
    enum Failure: Equatable, Sendable {
        /// Another app (or an admin) has SleepDisabled set. Never taken over; retried once it reads 0.
        case foreignFlag
        /// Another user's session holds lid mode (fast user switching). Retried once the flag reads 0.
        case otherUser
        /// The helper refused or dropped lid mode at its own 10% battery backstop.
        case lowBattery
        /// The helper refused or dropped lid mode at its own heat backstop (and slept a shut-in Mac).
        case hot
        case setFailed
        /// The helper connection dropped or stopped answering (the helper resets the flag itself).
        case lost
        /// Someone cleared the flag while we held it (e.g. `sudo pmset -a disablesleep 0`). Never re-applied.
        case overridden
    }

    enum State: Equatable, Sendable {
        case off, engaging, engaged, releasing
        /// Sticky until a user action (or, for foreign flag / other user, until the flag reads 0).
        case failed(Failure)
        /// A release failed and the flag still reads 1: sleep is off and we couldn't turn it back on.
        case stuck
    }

    private(set) var setup: LidSetup
    /// `install()` is registering the lid helper right now.
    private(set) var installing = false
    private(set) var state: State = .off
    private(set) var setupError: String?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let client: HelperClienting
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let stuckWait: Duration
    @ObservationIgnored private let lostWait: Duration
    @ObservationIgnored private let pollStep: Duration
    @ObservationIgnored private let heartbeatInterval: TimeInterval
    @ObservationIgnored private let runsTimers: Bool

    @ObservationIgnored private var desired = false
    /// Only for the `displaysleepnow` edge; every follow-up sleep asks `client.isUnattendedNow()` instead.
    @ObservationIgnored private var closedWithoutDisplay = false
    /// `asleepNanos()` when the last loss was noticed: the helper may sleep the Mac for the same loss.
    @ObservationIgnored private var lossMark: UInt64 = 0
    /// Logout, restart or shutdown is under way: the quit-time sleep would stall it.
    @ObservationIgnored private var poweringOff = false
    @ObservationIgnored private var powerOffObserver: NSObjectProtocol?
    @ObservationIgnored private var sleepRequested = false
    @ObservationIgnored private var verifyAfterLoss = false
    @ObservationIgnored private var working = false
    /// Launch recovery has finished: until then no engage/release work runs (it would race the flag check).
    @ObservationIgnored private var started = false
    /// The failure that ended in `.stuck`; restored (not cleared) when the flag reads 0 again, so it stays sticky.
    @ObservationIgnored private var stuckAfter: Failure?
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var recheck: Timer?
    @ObservationIgnored private var approvalPoll: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "com.gdeml.Eyelid", category: "lid")

    init(client: HelperClienting, prefs: Preferences, hasLid: Bool,
         stuckWait: Duration = .seconds(2), lostWait: Duration = .seconds(15), pollStep: Duration = .milliseconds(200),
         heartbeatInterval: TimeInterval = HelperInfo.heartbeatInterval, runsTimers: Bool = true) {
        self.client = client
        self.prefs = prefs
        self.setup = hasLid ? .notRegistered : .noLid
        self.stuckWait = stuckWait
        self.lostWait = lostWait
        self.pollStep = pollStep
        self.heartbeatInterval = heartbeatInterval
        self.runsTimers = runsTimers
    }

    // MARK: LidControlling

    var isReady: Bool { setup == .ready }
    var needsSetup: Bool { setup == .notRegistered }
    var isEngaged: Bool { state == .engaged }
    var isStuck: Bool { state == .stuck }
    var needsAttention: Bool {
        if case .failed = state { return true }
        return state == .stuck || setup == .needsApproval || setupError != nil
    }

    func setDesired(_ on: Bool) {
        desired = on
        kick()
    }

    func update(closedWithoutDisplay closed: Bool) {
        let wasClosed = closedWithoutDisplay
        closedWithoutDisplay = closed
        // The internal panel can stay lit with the lid shut (Apple Silicon). Never with an external display attached:
        // it would blank that one too (closedWithoutDisplay already excludes it).
        if closed, !wasClosed, state == .engaged {
            Task { await client.pmset("displaysleepnow") }
        }
    }

    func sleepNow() {
        sleepRequested = true
        kick()
    }

    func userActed() {
        stuckAfter = nil
        if case .failed = state {
            state = .off
            stopRecheck()
            kick()
        }
    }

    func install() {
        setupError = nil
        installing = true
        Task {
            let result = await client.install()
            setup = result.setup
            installing = false
            setupError = result.error
            if result.setup == .needsApproval || result.setup == .ready {
                prefs.helperRegisteredCDHash = await client.bundledCDHash()
            }
            if result.setup == .needsApproval {
                SMAppService.openSystemSettingsLoginItems()
                pollForApproval()
            }
            changed()
        }
    }

    func releaseForQuit() async {
        desired = false
        stopHeartbeat()
        stopRecheck()
        approvalPoll?.cancel()
        guard state == .engaged || state == .engaging || state == .releasing else { return }
        // At most ~2 s: release and read back; otherwise drop the connection and let the helper reset.
        let released = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [client] in
                let rc = await client.release()
                return rc == HelperResult.ok.rawValue || rc == HelperResult.notEngaged.rawValue
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        await client.abandon()
        if released, !poweringOff, await client.flag() == false, await client.isUnattendedNow() {
            await client.pmset("sleepnow")
        }
    }

    // MARK: Launch, setup and recovery

    func start() async {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { [weak self] in self?.poweringOff = true } }
        await refreshSetup()
        // v1's leftovers (its user-side marker and CLI socket, under its old name); the helper never used them.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Insomnia")
        for name in ["lid-engaged", "control.sock"] {
            if let url = support?.appendingPathComponent(name) { try? FileManager.default.removeItem(at: url) }
        }
        if setup == .ready, let registered = await client.upgradeIfNeeded(savedCDHash: prefs.helperRegisteredCDHash) {
            prefs.helperRegisteredCDHash = registered
            await refreshSetup()
            // A changed helper may need approval again: notice it as soon as it's given, as after install().
            if setup == .needsApproval { pollForApproval() }
        }
        // The flag is ours with no session: the helper's reset is pending (it retries every 5 s). Wait for it.
        if setup != .noLid, await client.flag() == true, let answer = await client.query(), answer.ownsFlag {
            if !(await waitForFlag(off: lostWait)), state == .off {
                stuckAfter = nil
                state = .stuck
                startRecheck()
            }
        }
        started = true
        kick()   // anything asked for during launch recovery
        changed()
    }

    /// Re-reads the registration (the panel calls this when it opens).
    func refreshSetup() async {
        let hasLid = setup != .noLid
        let next = await client.setup(hasLid: hasLid)
        if next != setup {
            setup = next
            if next == .ready { kick() }
            changed()
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
        pollForApproval()
    }

    func resetWithPassword() {
        Task {
            _ = await client.resetWithPassword()
            // The helper may have cleared it (and we re-engaged) while the prompt was open: only leave .stuck.
            guard state == .stuck, await client.flag() == false, state == .stuck else { changed(); return }
            stuckAfter = nil
            state = .off
            stopRecheck()
            kick()
            changed()
        }
    }

    /// Every 2 s for 3 minutes, whether or not the panel is open (System Settings takes focus and closes it).
    private func pollForApproval() {
        approvalPoll?.cancel()
        approvalPoll = Task { [weak self] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.refreshSetup()
                if self.setup != .needsApproval { return }
            }
        }
    }

    // MARK: Work (one step at a time)

    private func kick() {
        guard started, !working else { return }
        working = true
        Task {
            await work()
            working = false
            changed()
        }
    }

    private func work() async {
        while true {
            if verifyAfterLoss {
                verifyAfterLoss = false
                if await waitForFlag(off: lostWait) {
                    // Clearing the flag with the lid shut doesn't reliably sleep the Mac. The helper sleeps it itself
                    // after its own resets (and its backstops already did); this covers the rest (its crash or SIGTERM,
                    // an override). Skip if the Mac has slept since the loss: the helper's sleep for the same loss.
                    if state != .failed(.lowBattery), state != .failed(.hot), Self.asleepNanos() <= lossMark + 1_000_000_000,
                       await client.isUnattendedNow() {
                        await client.pmset("sleepnow")
                    }
                } else {
                    if case .failed(let reason) = state { stuckAfter = reason }
                    state = .stuck
                    startRecheck()
                }
                changed()
                continue
            }
            if sleepRequested {
                sleepRequested = false
                if state == .engaged { await release(thenSleep: false) }
                if state != .stuck { await client.pmset("sleepnow") }   // blocked while the flag is 1
                continue
            }
            if desired, state == .off, isReady {
                await engage()
                continue
            }
            if !desired, state == .engaged {
                await release(thenSleep: true)
                continue
            }
            return
        }
    }

    private func engage() async {
        state = .engaging
        changed()
        let rc = await client.engage(onLost: { [weak self] in
            Task { @MainActor in self?.lost(.lost) }
        })
        switch HelperResult(rawValue: rc) {
        case .ok:
            state = .engaged
            startHeartbeat()
            endActivity()
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Eyelid is keeping your Mac awake with the lid closed")
            if closedWithoutDisplay { await client.pmset("displaysleepnow") }
        case .foreignFlag:
            state = .failed(.foreignFlag)
            startRecheck()
        case .otherUser:
            state = .failed(.otherUser)
            startRecheck()
        case .backstop:
            state = .failed(.lowBattery)
        case .hot:
            state = .failed(.hot)
        default:
            // setFailed, or no answer (the helper may still finish: the invalidation makes it reset).
            log.error("engage failed: \(rc)")
            await client.abandon()
            if await waitForFlag(off: lostWait) {
                state = .failed(.setFailed)
            } else {
                stuckAfter = .setFailed
                state = .stuck
                startRecheck()
            }
        }
        changed()
    }

    /// `thenSleep`: follow with `sleepnow` if the Mac is unattended right then (read fresh, after the flag reads 0).
    private func release(thenSleep: Bool) async {
        state = .releasing
        stopHeartbeat()
        endActivity()
        changed()
        let rc = await client.release()
        // Dropped just before (deadline, battery or heat backstop): the helper has reset the flag itself.
        let answered = [HelperResult.ok, .notEngaged, .backstop, .hot].map(\.rawValue).contains(rc)
        if !answered { await client.abandon() }
        if await waitForFlag(off: answered ? stuckWait : lostWait) {
            state = .off
            // Clearing the flag with the lid shut doesn't reliably sleep the Mac.
            if thenSleep, await client.isUnattendedNow() { await client.pmset("sleepnow") }
        } else {
            log.error("release failed (\(rc)); SleepDisabled still reads 1")
            await client.abandon()
            stuckAfter = nil
            state = .stuck
            startRecheck()
        }
        changed()
    }

    /// The connection dropped, or a heartbeat came back anything but ok.
    private func lost(_ reason: Failure) {
        guard state == .engaged else { return }
        log.notice("lid mode lost: \(String(describing: reason), privacy: .public)")
        stopHeartbeat()
        endActivity()
        state = .failed(reason)
        lossMark = Self.asleepNanos()
        verifyAfterLoss = true
        kick()
        changed()
    }

    /// Reads the flag until it is 0 or `timeout` passes. true = it reads 0.
    private func waitForFlag(off timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: timeout)
        while true {
            if await client.flag() == false { return true }
            if clock.now >= end { return false }
            try? await Task.sleep(for: pollStep)
        }
    }

    // MARK: Timers

    private func startHeartbeat() {
        guard runsTimers else { return }
        stopHeartbeat()
        let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.beat() }
        }
        RunLoop.main.add(timer, forMode: .common)   // an open menu or panel must not look like a hang
        heartbeat = timer
    }

    /// Internal so tests can drive it without a timer.
    func beat() {
        Task {
            let rc = await client.heartbeat()
            guard state == .engaged, rc != HelperResult.ok.rawValue else { return }
            await client.abandon()
            switch HelperResult(rawValue: rc) {
            case .overridden: lost(.overridden)
            case .backstop: lost(.lowBattery)
            case .hot: lost(.hot)
            default: lost(.lost)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    /// Every 10 s while stuck or blocked by a foreign flag: back to normal once the flag reads 0.
    private func startRecheck() {
        guard runsTimers, recheck == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.recheckFlag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recheck = timer
    }

    func recheckFlag() {
        Task {
            @MainActor func retryable() -> Bool {
                state == .stuck || state == .failed(.foreignFlag) || state == .failed(.otherUser)
            }
            guard retryable() else { stopRecheck(); return }
            guard await client.flag() == false, retryable() else { return }
            let wasStuck = state == .stuck
            let reason = stuckAfter
            // A failure that ended stuck stays a failure (sticky until the user acts); a plain stuck release is over.
            if wasStuck, let reason { state = .failed(reason) } else { state = .off }
            stuckAfter = nil
            stopRecheck()
            // Sleep once it clears if lid mode isn't wanted any more, or a failure keeps it off while still wanted.
            if wasStuck, !desired || reason != nil, await client.isUnattendedNow() { await client.pmset("sleepnow") }
            kick()
            changed()
        }
    }

    private func stopRecheck() {
        recheck?.invalidate()
        recheck = nil
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Always asynchronous relative to the engine's call into us: every caller is inside a Task.
    private func changed() { onChange?() }

    /// Nanoseconds this Mac has spent asleep since boot (mach_continuous_time − mach_absolute_time): grows only across
    /// a sleep. The absolute clock is read first, so the difference can't go below zero on a Mac that hasn't slept
    /// since boot (the two clocks are then equal); it saturates anyway, and converts in Double so it can't overflow.
    nonisolated static func asleepNanos() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let awake = mach_absolute_time()
        let total = mach_continuous_time()
        guard total > awake, timebase.denom > 0 else { return 0 }
        return UInt64(Double(total - awake) * Double(timebase.numer) / Double(timebase.denom))
    }
}
