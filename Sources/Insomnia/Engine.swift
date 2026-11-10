import AppKit
import Foundation
import Observation

/// What the engine needs from lid mode. `LidController` is the real one; tests use a fake.
/// Implementations never call `onChange` synchronously from inside `setDesired` / `update` / `sleepNow`.
@MainActor
protocol LidControlling: AnyObject {
    /// The helper is registered, approved and reachable: lid mode can engage.
    var isReady: Bool { get }
    /// Registration is needed before lid mode can work (`install()` does it).
    var needsSetup: Bool { get }
    /// `SleepDisabled` is set by us right now.
    var isEngaged: Bool { get }
    /// Sleep is stuck off (a release failed): always shown.
    var isStuck: Bool { get }
    /// Failed, or waiting for approval: shown while lid mode is wanted.
    var needsAttention: Bool { get }
    var onChange: (() -> Void)? { get set }
    func setDesired(_ on: Bool)
    /// Lid shut with no external display at all (only for `displaysleepnow`; every follow-up sleep reads fresh).
    func update(closedWithoutDisplay: Bool)
    /// Release (if engaged), read back 0, then `pmset sleepnow`.
    func sleepNow()
    /// A user action: clears a sticky failure so the next `setDesired(true)` tries again.
    func userActed()
    func install()
    func releaseForQuit() async
}

/// The single place that decides: on/off, the time limit, the settings, When unplugged, and the safety checks.
/// Every input calls `reconcile()`; re-entrant calls fold into one more pass.
@MainActor
@Observable
final class Engine {
    enum Mode: Equatable, Sendable { case off, awake, screenOn, lid }
    struct Notice: Equatable, Sendable {
        var text: String
        var isWarning: Bool
    }

    /// Unless the Mac is closed with no external display: when a safety check trips, sleep only if nobody has touched
    /// the Mac for this long, otherwise turn off.
    static let idleForSleep: TimeInterval = PowerState.unattendedAfter
    /// How long `.serious` must last before overheat protection trips: shut in / otherwise.
    static let seriousWindowClosed: TimeInterval = 60
    static let seriousWindowOpen: TimeInterval = 300
    /// The bag rule: `.fair` for this long while lid mode is engaged and the Mac is unattended.
    static let bagWindow: TimeInterval = 300
    /// The low-battery protection clears this many points above its threshold (no flapping).
    static let batteryHysteresis = 3
    /// Low-battery protection: on battery at or below this. Above HelperInfo.backstopPercent (10), so the app acts
    /// before the lid helper does.
    static let lowBatteryPercent = 12
    static let lidPollInterval: TimeInterval = 5
    static let assertionReason = "Insomnia is keeping your Mac awake"

    let prefs: Preferences
    let lid: LidControlling
    @ObservationIgnored let power: PowerSource
    @ObservationIgnored private let assertions: AssertionApplying
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let armsTimers: Bool

    private(set) var isOn = false
    private(set) var endsAt: Date?
    /// The duration last started, in minutes (nil = until turned off). Not shown in the panel; kept for the engine's tests.
    private(set) var runMinutes: Int?
    private(set) var notice: Notice?
    /// A safety action happened and the panel hasn't been opened since: "!" on the moon.
    private(set) var unseenAlert = false
    /// A copy of `power.state` so SwiftUI can observe it.
    private(set) var powerState = PowerState()
    /// Overheat / low-battery condition currently active (each trips once on entry; lid mode stays paused meanwhile).
    private(set) var hotEpisode = false
    private(set) var lowEpisode = false

    @ObservationIgnored private var seriousSince: Date?
    /// Since when the bag condition holds: lid mode engaged, the Mac unattended (PowerState.isUnattended), at least `.fair`.
    @ObservationIgnored private var bagSince: Date?
    /// Lid mode was dropped while the lid was shut (a guard or the unplugged rule): don't re-engage until the lid
    /// opens or the user acts, so a DarkWake or re-plug inside a bag can't re-arm SleepDisabled.
    @ObservationIgnored private var latched = false
    @ObservationIgnored private var lastDesired: Bool?
    @ObservationIgnored private var wasOnAC: Bool?
    @ObservationIgnored private var wasLidClosed: Bool?
    @ObservationIgnored private var pendingSleep = false
    @ObservationIgnored private var passing = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var deadline: Timer?
    @ObservationIgnored private var deadlineDate: Date?
    @ObservationIgnored private var lidPoll: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private(set) var passCount = 0

    init(prefs: Preferences, power: PowerSource, lid: LidControlling, assertions: AssertionApplying,
         now: @escaping () -> Date = Date.init, armsTimers: Bool = true) {
        self.prefs = prefs
        self.power = power
        self.lid = lid
        self.assertions = assertions
        self.now = now
        self.armsTimers = armsTimers
    }

    func start() {
        power.onChange = { [weak self] in self?.reconcile() }
        lid.onChange = { [weak self] in self?.reconcile() }
        prefs.onChange = { [weak self] in self?.reconcile() }
        if armsTimers {
            // Run-loop timers count uptime: re-arm from the wall-clock deadline after sleep or a clock change.
            let rearm: @Sendable (Notification) -> Void = { _ in
                MainActor.assumeIsolated { [weak self] in self?.rearm() }
            }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: rearm))
            observers.append(NotificationCenter.default.addObserver(
                forName: .NSSystemClockDidChange, object: nil, queue: .main, using: rearm))
        }
        reconcile()
    }

    // MARK: User actions

    var mode: Mode {
        if lid.isEngaged { return .lid }
        guard isOn else { return .off }
        return prefs.keepScreenOn ? .screenOn : .awake
    }

    /// "!" on the moon.
    var needsAttention: Bool {
        unseenAlert || lid.isStuck || (isOn && prefs.closedLidMode && lid.needsAttention)
    }

    func toggle() {
        if isOn { stop() } else { start(minutes: prefs.powerButtonMinutes > 0 ? prefs.powerButtonMinutes : nil) }
    }

    /// nil = until turned off.
    func start(minutes: Int?) {
        userActed()
        isOn = true
        runMinutes = minutes
        endsAt = minutes.map { now().addingTimeInterval(TimeInterval($0) * 60) }
        notice = nil
        reconcile()
    }

    func stop() {
        userActed()
        turnOff()
        reconcile()
    }

    /// The lid switch. Turning it on also turns Insomnia on (for the usual time limit), so the switch always means what
    /// it says.
    func setLidMode(_ on: Bool) {
        userActed()
        if on {
            if !isOn {
                isOn = true
                runMinutes = prefs.powerButtonMinutes > 0 ? prefs.powerButtonMinutes : nil
                endsAt = runMinutes.map { now().addingTimeInterval(TimeInterval($0) * 60) }
                notice = nil
            }
            if lid.needsSetup { lid.install() }
        }
        prefs.closedLidMode = on   // → reconcile
        reconcile()
    }

    func dismissNotice() { notice = nil }

    func panelOpened() { unseenAlert = false }

    /// Quit: assertions first, then lid mode (released and read back, or abandoned to the helper's reset).
    func prepareForQuit() async {
        deadline?.invalidate()
        lidPoll?.invalidate()
        assertions.releaseAll()
        await lid.releaseForQuit()
    }

    // MARK: Reconcile

    func reconcile() {
        if passing { again = true; return }
        passing = true
        defer { passing = false }
        var n = 0
        repeat {
            again = false
            pass()
            n += 1
        } while again && n < 4
    }

    private func pass() {
        passCount += 1
        let t = now()
        let p = power.state
        if powerState != p { powerState = p }

        // 1. Edges.
        if wasLidClosed == true && !p.isLidClosed { latched = false }
        let unplugged = wasOnAC == true && p.isOnBattery
        wasLidClosed = p.isLidClosed
        wasOnAC = p.isOnAC

        // 2. Timer expiry.
        if isOn, let e = endsAt, e <= t { turnOff() }

        // 3. Safety. Each protection trips once on entering its condition, and acts only if we hold the Mac.
        // min(…, t): a clock set back restarts a window instead of pushing it into the future.
        seriousSince = p.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? min(seriousSince ?? t, t) : nil
        let inBag = p.thermal.rawValue >= ProcessInfo.ThermalState.fair.rawValue && lid.isEngaged
            && p.isUnattended(idleSeconds: power.idleSeconds)
        bagSince = inBag ? min(bagSince ?? t, t) : nil
        let ours = isOn || lid.isEngaged
        let hot = overheatGuarded(p) && Self.isHot(thermal: p.thermal, seriousSince: seriousSince,
                                        bagSince: bagSince, now: t, shutIn: p.isShutIn)
        if hot, !hotEpisode {
            hotEpisode = true
            if ours { letGo(.hot, p) }
        } else if !hot {
            hotEpisode = false
        }
        let low = Self.isLowBattery(p, threshold: Self.lowBatteryPercent, was: lowEpisode)
        if low, !lowEpisode {
            lowEpisode = true
            if ours { letGo(.lowBattery(p.batteryPercent ?? Self.lowBatteryPercent), p) }
        } else if !low {
            lowEpisode = false
        }

        // 4. When unplugged: Turn Insomnia off.
        if unplugged, isOn, prefs.whenUnplugged == .turnOff {
            turnOff()
            notice = Self.unpluggedNotice
        }

        // 5. Lid mode.
        lid.update(closedWithoutDisplay: p.isClosedWithoutDisplay)
        let blockedOnBattery = p.isOnBattery && prefs.whenUnplugged == .sleepWhenLidCloses
        let desired = isOn && prefs.closedLidMode && p.hasLid && lid.isReady
            && !hotEpisode && !lowEpisode && !latched && !blockedOnBattery
        if desired != lastDesired {
            if lastDesired == true, !desired, p.isLidClosed { latched = true }
            lastDesired = desired
            lid.setDesired(desired)
        }

        // 6. Assertions. The display assertion goes while lid mode holds a shut Mac with no external display.
        let display = isOn && prefs.keepScreenOn && !(lid.isEngaged && p.isClosedWithoutDisplay)
        assertions.update(system: isOn, display: display, reason: Self.assertionReason)

        // 7. A safety action that sleeps the Mac (after the lid release queued above).
        if pendingSleep {
            pendingSleep = false
            lid.sleepNow()
        }

        // 8. Timers.
        armTimers(now: t, state: p)
    }

    enum Trip { case hot, lowBattery(Int) }

    static let unpluggedNotice = Notice(text: "Your Mac was unplugged, so Insomnia turned off", isWarning: false)

    static func notice(for trip: Trip, slept: Bool) -> Notice {
        let text = switch trip {
        case .hot:
            slept ? "Your Mac got hot, so Insomnia put it to sleep" : "Your Mac got hot, so Insomnia turned off"
        case .lowBattery(let pct):
            "Your battery fell to \(pct)%, so Insomnia " + (slept ? "put your Mac to sleep" : "turned off")
        }
        return Notice(text: text, isWarning: true)
    }

    /// A safety check tripped. Closed with no external display at all: sleep. Otherwise sleep only if nobody is using
    /// the Mac (checked now, once). The release this causes sleeps only an unattended Mac, so the notice is right.
    private func letGo(_ trip: Trip, _ p: PowerState) {
        let sleep = p.isClosedWithoutDisplay || power.idleSeconds >= Self.idleForSleep
        turnOff()
        notice = Self.notice(for: trip, slept: sleep)
        unseenAlert = true
        if sleep { pendingSleep = true }
    }

    private func turnOff() {
        isOn = false
        endsAt = nil
        runMinutes = nil
    }

    private func userActed() {
        latched = false
        lid.userActed()
    }

    // MARK: Pure rules (unit-tested)

    static func isHot(thermal: ProcessInfo.ThermalState, seriousSince: Date?, bagSince: Date?, now: Date,
                      shutIn: Bool) -> Bool {
        if thermal.rawValue >= ProcessInfo.ThermalState.critical.rawValue { return true }
        if let s = seriousSince,
           now.timeIntervalSince(s) >= (shutIn ? seriousWindowClosed : seriousWindowOpen) { return true }
        if let b = bagSince, now.timeIntervalSince(b) >= bagWindow { return true }
        return false
    }

    /// On battery at or below `threshold`; clears at `threshold + batteryHysteresis` or on AC. Unknown % keeps `was`.
    static func isLowBattery(_ p: PowerState, threshold: Int, was: Bool) -> Bool {
        guard p.isOnBattery else { return false }
        guard let pct = p.batteryPercent else { return was }
        return was ? pct < threshold + batteryHysteresis : pct <= threshold
    }

    /// Whether the overheat check applies. The switch decides, except when lid mode keeps a shut-in Mac awake
    /// (PowerState.isShutIn): then the check always applies. Without lid mode, a shut lid sleeps the Mac anyway, so the
    /// switch still decides. "Wanted and ready" rather than "engaged": a trip releases the lid, and the check must not
    /// lapse (and re-arm lid mode) because of its own release.
    private func overheatGuarded(_ p: PowerState) -> Bool {
        prefs.overheatProtection
            || (p.isShutIn && (lid.isEngaged || (prefs.closedLidMode && lid.isReady)))
    }

    // MARK: Timers

    private func armTimers(now t: Date, state p: PowerState) {
        guard armsTimers else { return }
        var next = endsAt
        func consider(_ d: Date?) {
            guard let d, d > t else { return }
            next = next.map { min($0, d) } ?? d
        }
        if overheatGuarded(p), !hotEpisode {
            consider(seriousSince?.addingTimeInterval(p.isShutIn ? Self.seriousWindowClosed : Self.seriousWindowOpen))
            consider(bagSince?.addingTimeInterval(Self.bagWindow))
        }
        if next != deadlineDate || (next != nil && deadline?.isValid != true) {
            deadline?.invalidate()
            deadline = nil
            deadlineDate = next
            if let next {
                let timer = Timer(fire: max(next, t.addingTimeInterval(0.05)), interval: 0, repeats: false) { _ in
                    MainActor.assumeIsolated { [weak self] in self?.reconcile() }
                }
                timer.tolerance = 0.25
                RunLoop.main.add(timer, forMode: .common)
                deadline = timer
            }
        }

        // Fallback for a missed clamshell notification while lid mode holds the Mac, and the clock for "unattended":
        // HID idle time crossing PowerState.unattendedAfter isn't an event, so re-run the pass too.
        if lid.isEngaged, lidPoll == nil {
            let timer = Timer(timeInterval: Self.lidPollInterval, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in
                    self?.power.refreshLid()
                    self?.reconcile()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            lidPoll = timer
        } else if !lid.isEngaged, let timer = lidPoll {
            timer.invalidate()
            lidPoll = nil
        }
    }

    private func rearm() {
        deadline?.invalidate()
        deadline = nil
        deadlineDate = nil
        reconcile()
    }
}
