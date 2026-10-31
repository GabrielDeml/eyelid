import AppKit
import Foundation
import Observation
import os

/// Replaces the panel quip row until dismissed or the next state change (UX.md §2.1).
enum Banner: Equatable, Sendable {
    /// Opt-in awake battery floor stopped keeping awake.
    case batteryFloor(percent: Int)
    /// A lid guard paused lid mode.
    case guardTripped(GuardReason)
    /// Launch recovery reset a stale lid flag.
    case recovered
    /// Mission report after reopening the lid.
    case reopen(ReopenReport)
    /// First engagement on battery: explains the bag cap.
    case lidBatteryCallout
    /// Lid setup finished / failed (set by the setup flow via `showBanner`).
    case setupResult(String)
}

/// The brain: holds → Policy (guards) → derived `status` / `lid` / `mood`, assertions, timers, moments.
/// Every surface renders from `status`, `lid` and `mood`. ARCHITECTURE.md "Core/AwakeEngine.swift".
@MainActor
@Observable
final class AwakeEngine {
    static let shared = AwakeEngine()

    // MARK: Published state

    /// manual + babysit + client + derived rule holds, in that order.
    private(set) var holds: [Hold] = []
    /// Every tripped guard (facts; `lid` says whether one is actually pausing lid mode).
    private(set) var guards: Set<GuardReason> = []
    private(set) var status: AwakeStatus = .asleep
    /// ClosedLidController.status merged with needsSetup / suspended(guard) / latched.
    private(set) var lid: LidStatus = .off
    private(set) var mood: EyeMood = .asleep
    /// Display clock: advanced on every re-evaluation and on the 1 Hz tick (see `setPanelVisible`).
    private(set) var now: Date
    /// Replaces the panel quip row.
    private(set) var banner: Banner?
    /// Narrator line for the current state; nil = hide the row.
    private(set) var quip: String?
    /// Rules paused by the eyes; a rule unpauses once its condition goes false.
    private(set) var pausedRuleIDs: Set<Rule.ID> = []
    /// A lid guard fired with the lid closed: lid mode stays released until the lid opens or the user acts.
    private(set) var latched = false
    /// Start of the current continuous-awake stretch (escalation moments, eye bags at 24 h / 72 h).
    private(set) var awakeSince: Date?
    /// Panel-eyes rapid-click counter (UX.md §9); resets after 8 s without a poke.
    private(set) var pokeCount = 0
    private(set) var isPanelVisible = false
    /// Engaged lid-closed seconds since the lid last opened (Diagnostics; feeds the caps).
    var lidBagSeconds: TimeInterval { counters.bagSeconds }
    var lidClosedACSeconds: TimeInterval { counters.closedACSeconds }

    // MARK: Derived conveniences

    var manualHold: Hold? { manual }
    var babysitHold: Hold? { babysit }
    var clientHolds: [Hold] { holds.filter { if case .client = $0.owner { return true } else { return false } } }
    var ruleHolds: [Hold] { holds.filter { if case .rule = $0.owner { return true } else { return false } } }
    var isAwake: Bool { status.isAwake }
    /// Manual timed hold only.
    var remaining: TimeInterval? {
        guard let end = manual?.end else { return nil }
        return max(0, end.timeIntervalSince(now))
    }
    /// 0…1 elapsed of the manual timed hold.
    var progress: Double? {
        guard let manual, let end = manual.end else { return nil }
        let total = end.timeIntervalSince(manual.start)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(manual.start) / total))
    }
    /// Only CLI/client holds keep the Mac awake: the eyes can't release them (UI disables the toggle).
    var isHeldOnlyByClients: Bool { !clients.isEmpty && manual == nil && babysit == nil && rules.isEmpty }
    /// Tripped lid guards in display priority.
    var lidGuards: [GuardReason] { Policy.lidGuardPriority.filter(guards.contains) }
    /// Lid mode could engage right now if asked (hasLid and the privileged backend is ready). ControlServer (M5) uses
    /// this to refuse `--lid` with "lid mode not set up".
    var canEngageLid: Bool { power.hasLid && lidController?.helper == .installed }

    // MARK: Integration points (EngineHooks.swift). nil until their milestone plugs them in.

    @ObservationIgnored var lidController: (any LidControlling)? {
        didSet {
            lidController?.onChange = { [weak self] in self?.reevaluate() }
            lastDesiredLid = nil   // republish the desired flag to the new controller
        }
    }
    @ObservationIgnored var watchMonitor: (any WatchMonitoring)?
    @ObservationIgnored var narrator: (any Narrating)?
    @ObservationIgnored var notifier: (any NotificationPosting.Type)?
    @ObservationIgnored var stats: (any StatsRecording)?
    @ObservationIgnored var eventLog: (any EventLogging)?

    // MARK: Dependencies

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let power: any PowerReading
    @ObservationIgnored private let assertions: any AssertionApplying
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let logger = Logger(subsystem: "com.gdeml.Insomnia", category: "engine")

    // MARK: Hold storage (published as `holds`)

    @ObservationIgnored private var manual: Hold?
    @ObservationIgnored private var babysit: Hold?
    @ObservationIgnored private var babysitWatchID: UUID?
    @ObservationIgnored private var clients: [UUID: Hold] = [:]
    @ObservationIgnored private var rules: [Rule.ID: Hold] = [:]

    // MARK: Evaluation memory

    @ObservationIgnored private var previousGuards: Set<GuardReason> = []
    @ObservationIgnored private var thermalBagFairSince: Date?
    @ObservationIgnored private var thermalClearSince: Date?
    @ObservationIgnored private var policyRecheckAt: Date?
    @ObservationIgnored private var counters = LidCloseCounters()
    @ObservationIgnored private var lastLidClosed = false
    @ObservationIgnored private var lastClosedLidMode: Bool
    @ObservationIgnored private var lastDesiredLid: Bool?
    @ObservationIgnored private var pendingUserLidAction = false
    @ObservationIgnored private var engagedWhileClosed = false

    // MARK: Moments, notifications, quips

    @ObservationIgnored private var pendingMoments: [Moment] = []
    @ObservationIgnored private var pendingAnnouncement = false
    @ObservationIgnored private var bannerIsFresh = false
    @ObservationIgnored private var notifiedLidGuards: Set<GuardReason> = []
    @ObservationIgnored private var endingSoonFiredFor: Date?
    @ObservationIgnored private var escalationsFired: Set<Int> = []
    @ObservationIgnored private var lastRotatingQuip: Date?
    @ObservationIgnored private var lastIdleQuip: Date?
    /// When a lid-engaged line last showed as the day's first (exempt) one; later engagements rotate under the budget.
    @ObservationIgnored private var lastLidEngagedQuip: Date?
    @ObservationIgnored private var lastShownReopen: ReopenReport?
    @ObservationIgnored private var lastPokeAt: Date?
    @ObservationIgnored private var foreignFlagNotifiedThisRun = false

    // MARK: Time accounting (Stats)

    /// nil while the system sleeps (that time is never counted as awake).
    @ObservationIgnored private var accountedUntil: Date?
    @ObservationIgnored private var wasAwakeForAccounting = false
    @ObservationIgnored private var wasEngagedClosedForAccounting = false

    // MARK: Plumbing

    @ObservationIgnored private var started = false
    @ObservationIgnored private var isQuitting = false
    @ObservationIgnored private var isEvaluating = false
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var scheduledDeadline: Date?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Rotating `activated` / `deactivated` quips: at most one per 4 h (PRODUCT.md §4 rule 11).
    static let quipBudget: TimeInterval = 4 * 3600
    /// The poke counter resets after this long without a poke.
    static let pokeIdleReset: TimeInterval = 8
    /// Poke counts that award the badge.
    static let pokeBadgeCount = 50

    init(settings: Settings = .shared,
         power: any PowerReading = PowerMonitor.shared,
         assertions: any AssertionApplying = PowerAssertions(),
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.settings = settings
        self.power = power
        self.assertions = assertions
        self.clock = clock
        self.now = clock()
        self.lastClosedLidMode = settings.closedLidMode
    }

    // MARK: - Lifecycle

    /// ClosedLidController.start → recoverIfNeeded → refreshHelper → activateOnLaunch. Idempotent.
    /// `activateOnLaunch: false` when the app was launched to serve a command (CLI or URL), which decides instead.
    func start(activateOnLaunch: Bool = true) async {
        guard !started else { return }
        started = true
        lastLidClosed = power.isLidClosed
        accountedUntil = clock()
        startObserving()
        reevaluate()

        if let lidController {
            await lidController.start()
            if await lidController.recoverIfNeeded() {
                showBanner(.recovered)
                pendingMoments.append(.recoveredAfterCrash)
                pendingAnnouncement = true
                notify(.recovered)
                log("lid", "recovered: stale lid flag reset after an unclean exit")
            }
            await lidController.refreshHelper()
        }
        if activateOnLaunch && settings.activateOnLaunch && manual == nil {
            activate(settings.defaultDuration, source: .launch)
        }
        reevaluate()
    }

    /// applicationShouldTerminate: release every assertion, then let the lid controller release (≤ 2 s).
    func prepareForQuit() async {
        guard !isQuitting else { return }
        accountTime(until: clock())
        if let since = awakeSince { stats?.recordSessionEnded(duration: clock().timeIntervalSince(since)) }
        isQuitting = true
        stopTimers()
        assertions.releaseAll()
        notifier?.clear(.endingSoon)
        log("engine", "quit: assertions released")
        await lidController?.releaseForQuit(timeout: .seconds(2))
    }

    // MARK: - Manual holds

    /// Replaces the manual hold. `options == nil` → follows Settings; non-nil (CLI flags, URL) → fixed for this hold.
    /// Never writes Settings. A `.until` date that is already past is ignored.
    func activate(_ d: AwakeDuration, source: SessionSource, options: AwakeOptions? = nil) {
        let start = clock()
        let end = d.endDate(from: start)
        if let end, end <= start {
            log("engine", "ignored activate: end \(end) is not in the future")
            return
        }
        manual = Hold(owner: .manual(source), options: options ?? settings.manualOptions, start: start, end: end,
                      followsSettings: options == nil)
        resetEndingSoon()
        noteUserAction(source)
        pendingMoments.append(.activated(d))
        log("engine", "activate \(d.shortLabel) from \(source.rawValue)\(options.map { " fixed \($0)" } ?? "")")
        reevaluate()
    }

    /// Ends the manual and babysit holds (rules and clients are unaffected).
    func deactivate(_ r: DeactivationReason) {
        guard manual != nil || babysit != nil else { return }
        endManual(r)
        endBabysit(nil)
        if case .user(let source) = r { noteUserAction(source) }
        reevaluate()
    }

    /// The eyes. Awake → deactivate(.user) and pause every satisfied rule until its condition goes false → true.
    /// Asleep → a manual hold with the default duration (`options` as in `activate`; the URL scheme passes fixed
    /// options without lid). Only client holds → no-op (the UI disables the control).
    func toggle(source: SessionSource, options: AwakeOptions? = nil) {
        if isAwake {
            if isHeldOnlyByClients { return }
            pausedRuleIDs.formUnion(rules.keys)
            rules.removeAll()
            noteUserAction(source)
            if manual != nil || babysit != nil {
                deactivate(.user(source))
            } else {
                pendingMoments.append(.deactivated(.user(source)))
                reevaluate()
            }
        } else {
            activate(settings.defaultDuration, source: source, options: options)
        }
    }

    /// Timed manual hold: push its end by `minutes`. Indefinite: no-op. No manual hold: start a `.minutes` hold with
    /// `options`. The URL scheme never prolongs lid mode (Decision 10): from `.urlScheme`, a hold with lid is left alone.
    func extend(minutes: Int, source: SessionSource = .panel, options: AwakeOptions? = nil) {
        guard minutes > 0 else { return }
        guard var hold = manual else {
            activate(.minutes(minutes), source: source, options: options)
            return
        }
        if source == .urlScheme && hold.options.lid {
            log("engine", "ignored extend from a URL: the hold has lid mode")
            return
        }
        guard let end = hold.end else { return }
        hold.end = max(end, clock()).addingTimeInterval(TimeInterval(minutes) * 60)
        manual = hold
        resetEndingSoon()
        noteUserAction(source)
        log("engine", "extend +\(minutes)m")
        reevaluate()
    }

    // MARK: - Babysit ("While…")

    /// Replaces the babysit hold; follows Settings. Ends when the target exits (via WatchMonitor, M3).
    func babysit(_ t: WatchTarget) {
        endBabysit(nil)
        let hold = Hold(owner: .babysit(t), options: settings.manualOptions, start: clock())
        babysit = hold
        if let watchMonitor {
            let holdID = hold.id
            babysitWatchID = watchMonitor.watch(t) { [weak self] in self?.babysitTargetExited(holdID: holdID) }
        } else {
            log("engine", "babysit \(t.displayName): no WatchMonitor attached; the hold lasts until released")
        }
        noteUserAction(.panel)
        pendingMoments.append(.watching(t))
        log("engine", "babysit \(t.displayName)")
        reevaluate()
    }

    func releaseBabysit() {
        guard babysit != nil else { return }
        endBabysit(.user(.panel))
        reevaluate()
    }

    private func babysitTargetExited(holdID: UUID) {
        guard let hold = babysit, hold.id == holdID, case .babysit(let target) = hold.owner else { return }
        endBabysit(.targetExited(target))
        notify(.targetExited, context: ["name": target.displayName])
        reevaluate()
    }

    // MARK: - Client holds (CLI run/watch; ControlServer, M5)

    func beginClientHold(connection: UUID, label: String, options: AwakeOptions) {
        clients[connection] = Hold(owner: .client(connection: connection, label: label), options: options,
                                   start: clock(), followsSettings: false)
        log("engine", "client hold \(label)")
        reevaluate()
    }

    func endClientHold(connection: UUID) {
        guard clients.removeValue(forKey: connection) != nil else { return }
        reevaluate()
    }

    // MARK: - Other actions

    /// Ends manual + babysit, then sleeps (via the lid controller, which releases the flag first).
    func sleepNow() async {
        deactivate(.sleepNow)
        if let lidController {
            await lidController.sleepNow()
        } else {
            await SystemSleep.now()
        }
    }

    /// 1 Hz ticks while visible. Opening while asleep may show the `idle` line (at most once a day).
    func setPanelVisible(_ v: Bool) {
        guard v != isPanelVisible else { return }
        isPanelVisible = v
        if v, !isAwake, banner == nil {
            let today = clock()
            if lastIdleQuip.map({ !Calendar.current.isDate($0, inSameDayAs: today) }) ?? true,
               let line = narrator?.line(.idle, settings.personality, now: today) {
                lastIdleQuip = today
                quip = line
            }
        }
        reevaluate()
    }

    /// Panel eyes rapid-click counter (UX.md §9). The UI still calls `toggle` for each click.
    func poke() {
        let t = clock()
        if let last = lastPokeAt, t.timeIntervalSince(last) <= Self.pokeIdleReset {
            pokeCount += 1
        } else {
            pokeCount = 1
        }
        lastPokeAt = t
        guard pokeCount >= 5 else { return }
        if pokeCount == Self.pokeBadgeCount { stats?.awardPokeBadge() }
        if let line = narrator?.line(.poke(pokeCount), settings.personality, now: t) { quip = line }
    }

    func dismissBanner() {
        banner = nil
        bannerIsFresh = false
    }

    /// For flows outside the engine (lid setup result). Survives until dismissed or the next state change.
    func showBanner(_ b: Banner) {
        banner = b
        bannerIsFresh = true
    }

    /// For flows outside the engine (the lid setup sheet's `setupDone` / `setupCancelled`): the line goes through the
    /// same Narrator, personality and quip budget as every other moment.
    func narrate(_ m: Moment) {
        pendingMoments.append(m)
        reevaluate()
    }

    // MARK: - Reconcile

    /// The single reconcile function. Re-entrant calls (e.g. from an observer of `.insomniaStateDidChange`) are
    /// folded into one more pass.
    func reevaluate() {
        if isEvaluating {
            needsAnotherPass = true
            return
        }
        isEvaluating = true
        defer { isEvaluating = false }
        var passes = 0
        repeat {
            needsAnotherPass = false
            evaluatePass()
            passes += 1
        } while needsAnotherPass && passes < 4
    }

    private func evaluatePass() {
        let t = clock()
        if now != t { now = t }
        let controllerStatus = lidController?.status ?? .off
        let helper = lidController?.helper ?? .notInstalled
        let previousStatus = status
        let previousLid = lid
        let wasAwake = status.isAwake

        // 0. Time accounting, then the clamshell-open event (resets the counters and the latch).
        accountTime(until: t)
        counters.advance(to: t, mode: counters.mode)
        let lidClosed = power.isLidClosed
        let lidOpened = lastLidClosed && !lidClosed
        lastLidClosed = lidClosed
        if lidOpened {
            counters.lidOpened(at: t)
            if engagedWhileClosed { stats?.recordLidCloseSurvival() }
            engagedWhileClosed = false
        }

        // 1. Rules: drop pauses whose condition went false; rebuild rule holds with stable ids and start dates.
        let satisfied = (watchMonitor?.satisfiedRules ?? []).filter(\.enabled)
        let satisfiedIDs = Set(satisfied.map(\.id))
        pausedRuleIDs.formIntersection(satisfiedIDs)
        var rebuilt: [Rule.ID: Hold] = [:]
        var conditions: [Rule.ID: RuleCondition] = [:]
        for rule in satisfied where !pausedRuleIDs.contains(rule.id) {
            conditions[rule.id] = rule.condition
            // 2 (rules). Options follow the rule and the lid setting.
            let options = AwakeOptions(screen: rule.keepScreenOn, lid: rule.allowLid || settings.closedLidMode)
            if var existing = rules[rule.id] {
                existing.options = options
                rebuilt[rule.id] = existing
            } else {
                rebuilt[rule.id] = Hold(owner: .rule(rule.id), options: options, start: t)
            }
        }
        rules = rebuilt

        // 2. Re-derive options for settings-following manual / babysit holds.
        if manual?.followsSettings == true { manual?.options = settings.manualOptions }
        if babysit?.followsSettings == true { babysit?.options = settings.manualOptions }

        // 3. Expire the timed manual hold.
        if let end = manual?.end, end <= t {
            endManual(.timerExpired)
            notify(.ended)
            pendingAnnouncement = true
        }

        // 4. Policy. The opt-in awake floor ends the manual hold, then we evaluate once more without it.
        var output = Policy.evaluate(policyInput(now: t, conditions: conditions))
        if output.endManualForBatteryFloor {
            let floor = settings.batteryFloorPercent
            endManual(.batteryFloor(percent: floor))
            showBanner(.batteryFloor(percent: floor))
            output = Policy.evaluate(policyInput(now: t, conditions: conditions))
        }
        if output.guards.contains(.awakeBatteryFloor) && !previousGuards.contains(.awakeBatteryFloor)
            && (output.status != .asleep || wasAwake) {
            notify(.batteryStop, context: ["floor": "\(settings.batteryFloorPercent)"])
            showBanner(.batteryFloor(percent: settings.batteryFloorPercent))
            pendingMoments.append(.guardTripped(.awakeBatteryFloor))
            pendingAnnouncement = true
        }
        let newlyTripped = output.guards.subtracting(previousGuards)
        let cleared = previousGuards.subtracting(output.guards)
        if !newlyTripped.isEmpty || !cleared.isEmpty {
            log("guard", "tripped \(newlyTripped.map(\.rawValue).sorted()) cleared \(cleared.map(\.rawValue).sorted())")
        }
        previousGuards = output.guards
        thermalBagFairSince = output.thermalBagFairSince
        thermalClearSince = output.thermalClearSince
        policyRecheckAt = output.recheckAt

        // 5. Assertions. No display assertion while engaged with the lid shut and no external display
        //    (the controller also runs `pmset displaysleepnow`, CLOSED_LID.md §1).
        let engaged: Bool = { if case .engaged = controllerStatus { return true } else { return false } }()
        let engagedClosedNoExt = engaged && power.isClosedWithoutExternalDisplay
        if isQuitting {
            assertions.releaseAll()
        } else {
            assertions.update(system: output.assertSystem,
                              display: output.assertDisplay && !engagedClosedNoExt,
                              reason: assertionReason(output.status))
        }

        // 6. Latch, then publish the desired flag.
        latched = Policy.latch(previous: latched, lidGuardTripped: !output.lidGuards.isEmpty,
                               isLidClosed: lidClosed, lidOpened: lidOpened, userAction: pendingUserLidAction)
        pendingUserLidAction = false
        let desired = !isQuitting && Policy.desiredLid(lidAllowed: output.lidAllowed, hasLid: power.hasLid,
                                                       helper: helper, latched: latched)
        if desired != lastDesiredLid, let lidController {
            lastDesiredLid = desired
            lidController.setDesired(desired)
        }

        // 7. Lid status, 8. mood.
        let newLid = Policy.lidStatus(controller: controllerStatus, wantLid: output.wantLid, hasLid: power.hasLid,
                                      helper: helper, lidGuards: output.lidGuards, latched: latched)
        setIfChanged(\.guards, output.guards)
        setIfChanged(\.status, output.status)
        setIfChanged(\.lid, newLid)
        setIfChanged(\.mood, EyeMood(status: output.status, lid: newLid))
        setIfChanged(\.holds, orderedHolds())

        // Counters accumulate from now on in the mode that is in effect after this pass.
        let mode = LidCloseCounters.mode(engaged: engaged, isLidClosed: lidClosed,
                                         externalDisplays: power.externalDisplayCount, isOnAC: power.isOnAC)
        counters.advance(to: t, mode: mode)
        if engaged && lidClosed { engagedWhileClosed = true }
        wasEngagedClosedForAccounting = engaged && lidClosed
        wasAwakeForAccounting = status.isAwake

        // 9. Diff → moments, notifications, banner, quip, stats.
        handleAwakeTransition(wasAwake: wasAwake, now: t)
        handleLidTransition(from: previousLid, to: newLid, output: output, lidUsable: power.hasLid && helper == .installed)
        handleTimedHeadsUp(now: t)
        handleEscalation(now: t)
        let stateChanged = previousStatus != status || previousLid != lid
        if stateChanged && !bannerIsFresh { banner = nil }
        bannerIsFresh = false
        flushMoments(stateChanged: stateChanged, now: t)
        if pendingAnnouncement {
            pendingAnnouncement = false
            announce()
        }

        scheduleTimers(now: t)
        NotificationCenter.default.post(name: .insomniaStateDidChange, object: self)
    }

    private func policyInput(now t: Date, conditions: [Rule.ID: RuleCondition]) -> PolicyInput {
        PolicyInput(
            holds: orderedHolds(),
            ruleConditions: conditions,
            hasBattery: power.hasBattery,
            batteryPercent: power.batteryPercent,
            isOnAC: power.isOnAC,
            thermal: power.thermalState,
            lowPowerMode: power.isLowPowerMode,
            batteryFloor: settings.batteryFloorPercent,
            awakeBatteryFloorEnabled: settings.awakeBatteryFloorEnabled,
            lidRequiresAC: settings.lidRequiresAC,
            isBag: power.isBag,
            lidBagSeconds: counters.bagSeconds,
            lidBatteryCapMinutes: settings.lidMaxOnBatteryMinutes,
            lidClosedACSeconds: counters.closedACSeconds,
            lidACCapMinutes: settings.lidCapOnACEnabled ? settings.lidMaxOnACMinutes : nil,
            previousGuards: previousGuards,
            thermalBagFairSince: thermalBagFairSince,
            thermalClearSince: thermalClearSince,
            now: t
        )
    }

    private func orderedHolds() -> [Hold] {
        var result: [Hold] = []
        if let manual { result.append(manual) }
        if let babysit { result.append(babysit) }
        result += clients.values.sorted { $0.start < $1.start }
        result += rules.values.sorted { $0.start < $1.start }
        return result
    }

    // MARK: - Hold endings

    private func endManual(_ reason: DeactivationReason) {
        guard manual != nil else { return }
        manual = nil
        resetEndingSoon()
        pendingMoments.append(.deactivated(reason))
        log("engine", "manual hold ended: \(reason)")
    }

    /// `reason == nil`: silent (replaced, or part of a deactivate that already reported).
    private func endBabysit(_ reason: DeactivationReason?) {
        if let id = babysitWatchID { watchMonitor?.cancelWatch(id) }
        babysitWatchID = nil
        guard babysit != nil else { return }
        babysit = nil
        if let reason {
            pendingMoments.append(.deactivated(reason))
            log("engine", "babysit ended: \(reason)")
        }
    }

    private func resetEndingSoon() {
        if endingSoonFiredFor != nil { notifier?.clear(.endingSoon) }
        endingSoonFiredFor = nil
    }

    /// A user action from a surface (panel, menu bar, hotkey, Dock, notification) clears the latch.
    private func noteUserAction(_ source: SessionSource) {
        switch source {
        case .panel, .menuBar, .hotkey, .dock, .notification: pendingUserLidAction = true
        case .urlScheme, .launch, .cli: break
        }
    }

    // MARK: - Transitions

    private func handleAwakeTransition(wasAwake: Bool, now t: Date) {
        let isAwakeNow = status.isAwake
        if isAwakeNow && !wasAwake {
            awakeSince = t
            escalationsFired = []
            stats?.recordSessionStarted()
        } else if !isAwakeNow && wasAwake {
            if let since = awakeSince { stats?.recordSessionEnded(duration: t.timeIntervalSince(since)) }
            awakeSince = nil
            escalationsFired = []
        }
    }

    private func handleLidTransition(from old: LidStatus, to new: LidStatus, output: PolicyOutput, lidUsable: Bool) {
        if old != new { log("lid", "\(old) → \(new)") }

        // New engagement: guard notifications re-arm; first engagement on battery explains the cap.
        if case .engaged = new {
            if !Self.isEngaged(old) {
                notifiedLidGuards = []
                pendingMoments.append(.lidEngaged)
                notifier?.clear(.lidError)
                if !power.isOnAC && !settings.lidBatteryCalloutShown {
                    settings.lidBatteryCalloutShown = true
                    showBanner(.lidBatteryCallout)
                }
            }
        }

        // Lid guards that pause a real lid request: once per engagement per guard.
        if output.wantLid && lidUsable {
            for g in output.lidGuards where !notifiedLidGuards.contains(g) {
                notifiedLidGuards.insert(g)
                pendingMoments.append(.guardTripped(g))
                if g != .acRequired { showBanner(.guardTripped(g)) }
                switch g {
                case .batteryFloor:
                    notify(.batteryFloor, context: ["floor": "\(settings.batteryFloorPercent)"])
                case .thermal:
                    notify(.lidHeat)
                case .lowPowerMode:
                    notify(.lidLPM)
                case .lidBatteryCap:
                    notify(.lidCap, context: ["cap": Self.capLabel(settings.lidMaxOnBatteryMinutes)])
                case .lidACCap:
                    notify(.lidCap, context: ["acCap": Self.capLabel(settings.lidMaxOnACMinutes)])
                case .acRequired, .awakeBatteryFloor:
                    break
                }
                if g != .acRequired { pendingAnnouncement = true }
            }
        }

        if new != old {
            switch new {
            case .error(let e) where e.alarms:
                notify(.lidError, context: e == .overridden || e == .safetyNetLost ? ["overridden": "1"] : [:])
                pendingAnnouncement = true
            case .error(.foreignFlag):
                notifyForeignFlagOncePerBoot()
            case .stuck:
                notify(.lidStuck)
                pendingAnnouncement = true
            default:
                break
            }
            if old == .stuck { notifier?.clear(.lidStuck) }
        }

        // Mission report.
        if let report = lidController?.reopenReport, report != lastShownReopen {
            lastShownReopen = report
            showBanner(.reopen(report))
            pendingMoments.append(.lidReopened)
        }
    }

    private func handleTimedHeadsUp(now t: Date) {
        guard let manual, let end = manual.end, endingSoonFiredFor != end else { return }
        let remaining = end.timeIntervalSince(t)
        guard remaining > 0, remaining <= TickPlanner.endingSoonLead,
              TickPlanner.endingSoonApplies(start: manual.start, end: end) else { return }
        endingSoonFiredFor = end
        notify(.endingSoon, context: ["minutes": "\(Int((remaining / 60).rounded(.up)))"])
    }

    private func handleEscalation(now t: Date) {
        guard let since = awakeSince else { return }
        let crossed = TickPlanner.crossedEscalations(since: since, now: t, fired: escalationsFired)
        guard let highest = crossed.last else { return }
        escalationsFired.formUnion(crossed)
        pendingMoments.append(.awake(hours: highest))   // one line for the biggest threshold, never a burst
    }

    // MARK: - Quips

    /// One line per flush. An earned (exempt) moment wins over rotating ones, so a rotating line that would only be
    /// overwritten never spends the 4 h budget; among rotating moments the last eligible one is drawn.
    private func flushMoments(stateChanged: Bool, now t: Date) {
        let moments = pendingMoments.filter { if case .deactivated(.replaced) = $0 { false } else { true } }   // no copy for a replaced hold
        pendingMoments = []
        var newLine: String?
        for moment in moments where !isRotating(moment, now: t) {
            guard let line = narrator?.line(moment, settings.personality, now: t) else { continue }
            if case .lidEngaged = moment { lastLidEngagedQuip = t }
            newLine = line
        }
        if newLine == nil, lastRotatingQuip.map({ t.timeIntervalSince($0) >= Self.quipBudget }) ?? true {
            for moment in moments.reversed() where isRotating(moment, now: t) {
                guard let line = narrator?.line(moment, settings.personality, now: t) else { continue }
                lastRotatingQuip = t
                newLine = line
                break
            }
        }
        if let newLine {
            quip = newLine
        } else if stateChanged {
            quip = nil   // silence is a valid line; never leave a stale quip under a new state
        }
    }

    /// `activated` / `deactivated` lines rotate under the 4 h budget, and so does `lidEngaged` after the day's first
    /// engagement (lid status cycles with every toggle, so it would otherwise joke on every click). Earned moments
    /// are exempt.
    private func isRotating(_ m: Moment, now t: Date) -> Bool {
        switch m {
        case .activated: return true
        case .deactivated(let r):
            switch r {
            case .batteryFloor, .targetExited: return false   // safety / babysit results are earned, not rotating
            default: return true
            }
        case .lidEngaged:
            return lastLidEngagedQuip.map { Calendar.current.isDate($0, inSameDayAs: t) } ?? false
        default: return false
        }
    }

    // MARK: - Notifications and announcements

    private func notify(_ id: NotificationID, context: [String: String] = [:]) {
        if id.isSessionNotification && !settings.sessionNotifications { return }
        log("notify", id.rawValue)
        guard let notifier else { return }
        let copy = narrator?.notification(id, settings.personality, context: context)
            ?? FallbackCopy.notification(id, context: context)
        notifier.post(id, title: copy.title, body: copy.body)
    }

    private func notifyForeignFlagOncePerBoot() {
        guard !foreignFlagNotifiedThisRun else { return }
        foreignFlagNotifiedThisRun = true
        let key = "engine.foreignFlagNotifiedBoot"
        let boot = Self.bootTime().map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: key) != boot else { return }
        defaults.set(boot, forKey: key)
        notify(.foreignFlag)
    }

    /// VoiceOver announcement of the plain headline (never the quip): timer end, guard stop, lid error, recovery.
    private func announce() {
        guard let app = NSApp else { return }
        let headline = narrator?.headline(status: status, lid: lid)
            ?? FallbackCopy.headline(status: status, lid: lid, batteryFloor: settings.batteryFloorPercent)
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: headline,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Timers

    private func scheduleTimers(now t: Date) {
        guard !isQuitting else { return stopTimers() }
        var extra: [Date] = []
        if let policyRecheckAt { extra.append(policyRecheckAt) }
        if let cap = counters.capDeadline(batteryCapMinutes: settings.lidMaxOnBatteryMinutes,
                                          acCapMinutes: settings.lidCapOnACEnabled ? settings.lidMaxOnACMinutes : nil) {
            extra.append(cap)
        }
        let plan = TickPlanner.plan(TickPlanner.Input(
            now: t,
            panelVisible: isPanelVisible,
            timedEnd: manual?.end,
            timedStart: manual?.start,
            endingSoonFired: manual?.end != nil && endingSoonFiredFor == manual?.end,
            menuBarTimer: settings.menuBarTimer,
            showInDock: settings.showInDock,
            awakeSince: awakeSince,
            escalationsFired: escalationsFired,
            extraDeadlines: extra
        ))
        setDeadline(plan.nextDeadline, now: t)
        setTicking(plan.everySecond)
    }

    private func setDeadline(_ date: Date?, now t: Date) {
        guard date != scheduledDeadline else { return }
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        scheduledDeadline = date
        guard let date else { return }
        let timer = Timer(fire: max(date, t.addingTimeInterval(0.05)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduledDeadline = nil
                self?.reevaluate()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func setTicking(_ on: Bool) {
        if on, tickTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else if !on, let timer = tickTimer {
            timer.invalidate()
            tickTimer = nil
        }
    }

    /// Light 1 Hz path: advance the display clock; a full re-evaluation only when a deadline has passed.
    private func tick() {
        let t = clock()
        if let deadline = scheduledDeadline, t >= deadline {
            reevaluate()
            return
        }
        now = t
        NotificationCenter.default.post(name: .insomniaStateDidChange, object: self)
    }

    private func stopTimers() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        scheduledDeadline = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Observation

    private func startObserving() {
        let center = NotificationCenter.default
        observe(center, .insomniaSettingsDidChange, object: settings) { engine, key in engine.settingsChanged(key: key) }
        observe(center, .insomniaPowerDidChange, object: power) { engine, _ in engine.reevaluate() }
        observe(center, .insomniaRulesDidChange, object: nil) { engine, _ in engine.reevaluate() }
        observe(center, .NSSystemClockDidChange, object: nil) { engine, _ in
            engine.rearmDeadline()
            engine.reevaluate()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, object: nil) { engine, _ in engine.systemWillSleep() }
        observe(workspace, NSWorkspace.didWakeNotification, object: nil) { engine, _ in engine.systemDidWake() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject?,
                         _ handler: @escaping @MainActor (AwakeEngine, _ settingsKey: String?) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
            // `queue: .main` delivers on the main thread. Only the Sendable settings key crosses over.
            let key = note.userInfo?["key"] as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, key)
            }
        }
        observers.append((center, token))
    }

    private func settingsChanged(key: String?) {
        if key == "closedLidMode" {
            let on = settings.closedLidMode
            defer { lastClosedLidMode = on }
            if on != lastClosedLidMode {
                pendingUserLidAction = true   // the lid switch is a user action (clears the latch)
                // Lid switch turned on while nothing holds the Mac → start a manual hold (UX.md §2.2 H).
                if on, !isAwake, canEngageLid {
                    lastClosedLidMode = on
                    activate(settings.defaultDuration, source: .panel)
                    return
                }
            }
        }
        reevaluate()
    }

    private func systemWillSleep() {
        accountTime(until: clock())
        accountedUntil = nil   // sleeping time is never awake time
        log("engine", "system will sleep")
    }

    /// Internal so tests can drive it (the live path is NSWorkspace.didWakeNotification).
    func systemDidWake() {
        accountedUntil = clock()
        log("engine", "system did wake")
        // A real sleep ended the continuous-awake stretch (eye bags, "awake 8 hours"); it starts again now.
        if status.isAwake {
            awakeSince = clock()
            escalationsFired = []
        }
        rearmDeadline()
        reevaluate()
    }

    /// Run-loop timers count uptime, which stops during sleep and ignores wall-clock changes: drop the pending one so
    /// the next `scheduleTimers` arms a fresh timer from the wall-clock deadline (ARCHITECTURE.md "re-evaluate on
    /// didWake / NSSystemClockDidChange").
    private func rearmDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        scheduledDeadline = nil
    }

    // MARK: - Stats accounting

    /// Credits wall time since the last call to Stats (awake / lid-closed). Never per second: only on re-evaluation.
    private func accountTime(until t: Date) {
        guard let from = accountedUntil else { return }
        accountedUntil = t
        guard let stats else { return }
        let elapsed = t.timeIntervalSince(from)
        guard elapsed > 0 else { return }
        if wasAwakeForAccounting, let milestone = stats.addAwakeTime(elapsed) {
            pendingMoments.append(.milestone(hours: milestone))
        }
        if wasEngagedClosedForAccounting { stats.addLidClosedTime(elapsed) }
    }

    // MARK: - Helpers

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AwakeEngine, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private static func isEngaged(_ s: LidStatus) -> Bool {
        if case .engaged = s { return true }
        return false
    }

    /// Shows in `pmset -g assertions`.
    private func assertionReason(_ s: AwakeStatus) -> String {
        switch s {
        case .asleep, .suspended: return "Insomnia"
        case .timed:
            guard let manual, let end = manual.end else { return "Insomnia: timer" }
            let minutes = Int((end.timeIntervalSince(manual.start) / 60).rounded())
            return "Insomnia: \(AwakeDuration.minutes(minutes).shortLabel) timer"
        case .indefinite: return "Insomnia: until stopped"
        case .watching(let target): return "Insomnia: watching \(target.displayName)"
        case .client(let label): return "Insomnia: held by \(label) (CLI)"
        case .automatic(let conditions): return "Insomnia: rule (\(conditions.map(\.phrase).joined(separator: ", ")))"
        }
    }

    static func capLabel(_ minutes: Int) -> String { AwakeDuration.minutes(minutes).shortLabel }

    private static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    private func log(_ kind: String, _ message: String) {
        logger.info("[\(kind, privacy: .public)] \(message, privacy: .public)")
        eventLog?.log(kind, message)
    }
}

/// M1 fallback for Sleep Now when no lid controller is attached (with one, the controller sleeps after releasing the
/// flag, and every spawn runs on its LidReconciler). `pmset sleepnow` needs no privileges.
enum SystemSleep {
    static func now() async {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Logger(subsystem: "com.gdeml.Insomnia", category: "engine")
                    .error("pmset sleepnow failed: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }
}
