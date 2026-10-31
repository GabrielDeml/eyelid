import Foundation

// MARK: - Policy: holds → guards → derived status. Pure: no clocks, no singletons, no side effects.
// Contract: ARCHITECTURE.md "Core/Policy.swift". Guard trip/clear rules: docs/CLOSED_LID.md §5–§7.

struct PolicyInput: Equatable, Sendable {
    /// Every hold the engine knows about (manual, babysit, client, rule). Holds whose `end` is ≤ `now` are ignored.
    var holds: [Hold] = []
    /// Conditions of the rules behind `.rule` holds, for `AwakeStatus.automatic`. Missing ids are skipped.
    var ruleConditions: [Rule.ID: RuleCondition] = [:]

    var hasBattery = false
    var batteryPercent: Int?
    var isOnAC = true
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPowerMode = false

    var batteryFloor = 20
    var awakeBatteryFloorEnabled = false
    var lidRequiresAC = false

    /// Lid closed && no external display && !isOnAC.
    var isBag = false
    /// Engine counter: engaged + bag seconds since the lid last opened. Feeds `lidBatteryCap` (always applies).
    var lidBagSeconds: TimeInterval = 0
    var lidBatteryCapMinutes = 60
    /// Engine counter: engaged + closed (no ext. display) on AC seconds since the lid last opened.
    var lidClosedACSeconds: TimeInterval = 0
    /// nil when `Settings.lidCapOnACEnabled` is off: no cap on AC.
    var lidACCapMinutes: Int?

    /// Last evaluation's guards, for hysteresis.
    var previousGuards: Set<GuardReason> = []
    /// Since when thermal ≥ .fair while `isBag` (fed back from the previous `PolicyOutput`).
    var thermalBagFairSince: Date?
    /// Since when the thermal trip condition has been false while the guard was still tripped (fed back likewise).
    var thermalClearSince: Date?
    var now = Date(timeIntervalSinceReferenceDate: 0)
}

struct PolicyOutput: Equatable, Sendable {
    /// Every tripped guard (facts, independent of whether anything wants lid mode).
    var guards: Set<GuardReason>
    var assertSystem: Bool
    /// Any live hold has `options.screen`. The engine forces it false while the lid is closed and engaged.
    var assertDisplay: Bool
    /// Some live, non-suspended hold asks for lid mode.
    var wantLid: Bool
    /// `wantLid` and no lid guard tripped. hasLid, helper readiness and the latch are checked by the engine
    /// (`Policy.desiredLid`).
    var lidAllowed: Bool
    var status: AwakeStatus
    /// `awakeBatteryFloor` tripped while a manual hold is live: end it with `.batteryFloor`.
    var endManualForBatteryFloor: Bool

    /// Feed back into the next `PolicyInput` (the engine stores them; Policy stays pure).
    var thermalBagFairSince: Date?
    var thermalClearSince: Date?
    /// Earliest moment at which this output would change with time alone (thermal 5 min / 60 s windows).
    /// Hold end times and cap deadlines are scheduled by the engine.
    var recheckAt: Date?

    /// Tripped lid guards in display priority (`Policy.lidGuardPriority`); `.first` is what `LidStatus.suspended` shows.
    var lidGuards: [GuardReason] { Policy.lidGuardPriority.filter(guards.contains) }
}

enum Policy {
    /// Lid guards in the order `LidStatus.suspended(_)` reports them: alarms first, then user-chosen limits.
    static let lidGuardPriority: [GuardReason] = [.batteryFloor, .thermal, .lowPowerMode, .acRequired,
                                                  .lidBatteryCap, .lidACCap]
    /// Battery floors clear only at floor + 3 % (CLOSED_LID.md §6).
    static let batteryHysteresis = 3
    /// Thermal ≥ .fair this long in the bag condition trips the thermal guard.
    static let thermalBagWindow: TimeInterval = 5 * 60
    /// The thermal guard clears after its trip condition has been false this long.
    static let thermalClearWindow: TimeInterval = 60

    static func evaluate(_ input: PolicyInput) -> PolicyOutput {
        let now = input.now
        let live = input.holds.filter { hold in hold.end.map { $0 > now } ?? true }

        // Guards. Facts first; what they affect is decided below.
        var guards = Set<GuardReason>()
        let floorTripped = batteryFloorTripped(input, wasTripped: input.previousGuards.contains(.batteryFloor))
        if floorTripped { guards.insert(.batteryFloor) }
        if input.awakeBatteryFloorEnabled,
           batteryFloorTripped(input, wasTripped: input.previousGuards.contains(.awakeBatteryFloor)) {
            guards.insert(.awakeBatteryFloor)
        }
        let thermal = thermalGuard(input)
        if thermal.tripped { guards.insert(.thermal) }
        if input.lowPowerMode { guards.insert(.lowPowerMode) }
        if input.lidRequiresAC && input.hasBattery && !input.isOnAC { guards.insert(.acRequired) }
        if input.lidBagSeconds >= TimeInterval(input.lidBatteryCapMinutes) * 60 { guards.insert(.lidBatteryCap) }
        if let acCap = input.lidACCapMinutes, input.lidClosedACSeconds >= TimeInterval(acCap) * 60 {
            guards.insert(.lidACCap)
        }

        // Opt-in awake floor suspends everything: nothing is asserted, nothing wants lid.
        let suspendedAll = guards.contains(.awakeBatteryFloor) && !live.isEmpty
        let active = suspendedAll ? [] : live

        let wantLid = active.contains { $0.options.lid }
        let lidGuardTripped = guards.contains { !$0.affectsAllHolds }

        return PolicyOutput(
            guards: guards,
            assertSystem: !active.isEmpty,
            assertDisplay: active.contains { $0.options.screen },
            wantLid: wantLid,
            lidAllowed: wantLid && !lidGuardTripped,
            status: suspendedAll ? .suspended(.awakeBatteryFloor) : status(of: live, ruleConditions: input.ruleConditions),
            endManualForBatteryFloor: guards.contains(.awakeBatteryFloor) && live.contains(where: \.isManual),
            thermalBagFairSince: thermal.bagFairSince,
            thermalClearSince: thermal.clearSince,
            recheckAt: thermal.recheckAt
        )
    }

    // MARK: Status

    /// Priority: manual (timed / indefinite) > babysit (watching) > client > rules (automatic) > asleep.
    static func status(of live: [Hold], ruleConditions: [Rule.ID: RuleCondition]) -> AwakeStatus {
        if let manual = live.first(where: \.isManual) {
            return manual.end.map { .timed(end: $0) } ?? .indefinite
        }
        for hold in live { if case .babysit(let target) = hold.owner { return .watching(target) } }
        for hold in live { if case .client(_, let label) = hold.owner { return .client(label: label) } }
        let conditions: [RuleCondition] = live
            .sorted { $0.start < $1.start }
            .compactMap { hold in
                if case .rule(let id) = hold.owner { return ruleConditions[id] }
                return nil
            }
        let hasRuleHold = live.contains { if case .rule = $0.owner { return true } else { return false } }
        return hasRuleHold ? .automatic(conditions) : .asleep
    }

    // MARK: Guards

    /// Trips at `percent <= floor` on battery; clears on AC or at `percent >= floor + 3`.
    /// An unknown percentage keeps the previous state (never trips on missing data, never clears on it either).
    static func batteryFloorTripped(_ input: PolicyInput, wasTripped: Bool) -> Bool {
        guard input.hasBattery, !input.isOnAC else { return false }
        guard let percent = input.batteryPercent else { return wasTripped }
        if percent <= input.batteryFloor { return true }
        return wasTripped && percent < input.batteryFloor + batteryHysteresis
    }

    struct ThermalResult: Equatable {
        var tripped: Bool
        var bagFairSince: Date?
        var clearSince: Date?
        var recheckAt: Date?
    }

    /// Trips at ≥ .serious, or ≥ .fair for 5 min in the bag condition. Clears once the trip condition has been false
    /// for 60 s.
    static func thermalGuard(_ input: PolicyInput) -> ThermalResult {
        let now = input.now
        let level = input.thermal.rawValue
        let fairInBag = input.isBag && level >= ProcessInfo.ThermalState.fair.rawValue
        let bagFairSince = fairInBag ? min(input.thermalBagFairSince ?? now, now) : nil
        let bagWindowDone = bagFairSince.map { now.timeIntervalSince($0) >= thermalBagWindow } ?? false
        let tripCondition = level >= ProcessInfo.ThermalState.serious.rawValue || bagWindowDone

        // Pending bag window: re-check when it completes.
        let bagRecheck: Date? = (fairInBag && !tripCondition) ? bagFairSince?.addingTimeInterval(thermalBagWindow) : nil

        if tripCondition {
            return ThermalResult(tripped: true, bagFairSince: bagFairSince, clearSince: nil, recheckAt: nil)
        }
        guard input.previousGuards.contains(.thermal) else {
            return ThermalResult(tripped: false, bagFairSince: bagFairSince, clearSince: nil, recheckAt: bagRecheck)
        }
        // Was tripped, condition now false: hold it for the clear window.
        let clearSince = min(input.thermalClearSince ?? now, now)
        let clearAt = clearSince.addingTimeInterval(thermalClearWindow)
        if now >= clearAt {
            return ThermalResult(tripped: false, bagFairSince: bagFairSince, clearSince: nil, recheckAt: bagRecheck)
        }
        return ThermalResult(tripped: true, bagFairSince: bagFairSince, clearSince: clearSince,
                             recheckAt: [clearAt, bagRecheck].compactMap { $0 }.min())
    }

    // MARK: Lid (pure pieces of the engine's steps 6–7)

    /// CLOSED_LID.md §5: `desired = wantLid && hasLid && helper == .installed && lidGuards.isEmpty && !latched`.
    static func desiredLid(lidAllowed: Bool, hasLid: Bool, helper: HelperStatus, latched: Bool) -> Bool {
        lidAllowed && hasLid && helper == .installed && !latched
    }

    /// The latch: set while any lid guard is tripped with the lid closed (whether the guard tripped while closed, or
    /// the lid closed while it was tripped), so a DarkWake can never re-engage inside a bag once the guard clears.
    /// Cleared by a clamshell-open event or a user action (panel, hotkey, Dock, lid switch) — but a guard that is
    /// still tripped with the lid still closed re-latches immediately.
    static func latch(previous: Bool, lidGuardTripped: Bool, isLidClosed: Bool, lidOpened: Bool, userAction: Bool) -> Bool {
        var latched = previous
        if lidOpened || userAction { latched = false }
        if isLidClosed && lidGuardTripped { latched = true }
        return latched
    }

    /// ARCHITECTURE.md AwakeEngine step 7. `controller` is ClosedLidController.status (.off when there is none yet).
    static func lidStatus(controller: LidStatus, wantLid: Bool, hasLid: Bool, helper: HelperStatus,
                          lidGuards: [GuardReason], latched: Bool) -> LidStatus {
        if controller == .stuck { return .stuck }          // always shown: the Mac won't sleep
        guard wantLid, hasLid else { return .off }
        guard helper == .installed else { return .needsSetup }
        if let first = lidGuards.first { return .suspended(first) }
        if latched { return .latched }
        return controller
    }
}

// MARK: - Lid-closed counters (CLOSED_LID.md §5)

/// Engine-scoped seconds spent engaged with the lid closed and no external display, split by power source.
/// They accumulate only while engaged (any hold type) and reset **only** when the lid opens — never on a new hold
/// or a power change. Pure value type; the engine credits elapsed time on every re-evaluation.
struct LidCloseCounters: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Not accumulating (not engaged, lid open, or an external display is attached).
        case idle
        /// Engaged, closed, no external display, on battery.
        case bag
        /// Engaged, closed, no external display, on AC.
        case closedOnAC
    }

    private(set) var bagSeconds: TimeInterval = 0
    private(set) var closedACSeconds: TimeInterval = 0
    private(set) var mode: Mode = .idle
    private(set) var since: Date?

    /// Credits the time since the last call to the mode that was in effect, then switches to `newMode`.
    /// A clock that went backwards credits nothing.
    mutating func advance(to now: Date, mode newMode: Mode) {
        if let since {
            let elapsed = max(0, now.timeIntervalSince(since))
            switch mode {
            case .idle: break
            case .bag: bagSeconds += elapsed
            case .closedOnAC: closedACSeconds += elapsed
            }
        }
        mode = newMode
        since = now
    }

    /// Clamshell-open event: both counters back to zero.
    mutating func lidOpened(at now: Date) {
        bagSeconds = 0
        closedACSeconds = 0
        mode = .idle
        since = now
    }

    /// When the running counter reaches its cap, if it's running and the cap isn't reached yet.
    func capDeadline(batteryCapMinutes: Int, acCapMinutes: Int?) -> Date? {
        guard let since else { return nil }
        switch mode {
        case .idle:
            return nil
        case .bag:
            let left = TimeInterval(batteryCapMinutes) * 60 - bagSeconds
            return left > 0 ? since.addingTimeInterval(left) : nil
        case .closedOnAC:
            guard let acCapMinutes else { return nil }
            let left = TimeInterval(acCapMinutes) * 60 - closedACSeconds
            return left > 0 ? since.addingTimeInterval(left) : nil
        }
    }

    static func mode(engaged: Bool, isLidClosed: Bool, externalDisplays: Int, isOnAC: Bool) -> Mode {
        guard engaged, isLidClosed, externalDisplays == 0 else { return .idle }
        return isOnAC ? .closedOnAC : .bag
    }
}
