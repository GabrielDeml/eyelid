import Foundation

// MARK: - Narrator: every line of personality copy (docs/PRODUCT.md §4, docs/UX.md §11)
//
// Rules this file enforces (PRODUCT.md §4):
//   5  Rotation: a shuffle bag per (kind, personality). A line never shows twice in a row, and a bag empties before any
//      line repeats.
//   7  Professional is really plain: `line()` returns nil for every moment (its quip row is hidden), so a Professional
//      moment never spends the quip budget. Its plain lines live only in notification bodies.
//   3  Safety is never a joke: headlines and notification titles come from the one plain source (`FallbackCopy` /
//      `PlainCopy`) in every tier. Only notification *bodies* get personality, and only for the ids UX §10 allows.
//   8  Labels never change with personality (they don't live here at all).
//  10  Date lines (3–5 a.m., Oct 31, New Year 00:00–00:10) replace an `activated` or `idle` line with 1-in-3 probability,
//      at most once per window. They are earned: `dateLine` is separate from `line` so the engine shows them outside
//      the quip budget without spending it. Never in Professional.
// The quip *budget* (one rotating line per 4 h, idle once a day) is the engine's job; the Narrator only picks words.

/// Every pool of copy. Several `Moment`s map onto one kind (e.g. `.deactivated(.user)` and `.deactivated(.sleepNow)`),
/// and a few kinds exist only for notification bodies (`endingSoon`).
enum CopyKind: String, CaseIterable, Hashable, Sendable {
    case activated
    case deactivatedUser, deactivatedTimer, deactivatedBattery
    case idle
    case awake2, awake8, awake24, awake72
    case watching, targetExited
    case lidEngaged, lidReopened
    case thermal, lowPowerMode, batteryFloor, acRequired, lidCap
    case recovered, setupDone, setupCancelled
    /// Body of the `ending-soon` notification ("Want a refill?").
    case endingSoon
    case poke5, poke10, poke20, poke50
    case milestone100, milestone500, milestone1000
    case date3am, dateHalloween, dateNewYear

    /// PRODUCT.md §4 rule 7: the only kinds with Professional copy. Its quip row is hidden, so these are the bodies of
    /// the notifications that take a pool (UX.md §10), plus `lidEngaged` for the Settings personality sample.
    static let professionalKinds: Set<CopyKind> = [
        .endingSoon, .deactivatedTimer, .batteryFloor, .thermal, .recovered, .targetExited, .lidEngaged,
    ]

    /// The four "main moments" that need ≥ 10 lines in Cheeky and Unhinged (PRODUCT.md §4 rule 6). `awake` counts its
    /// four escalation buckets together.
    static let mainMoments: [String: [CopyKind]] = [
        "activated": [.activated],
        "deactivated": [.deactivatedUser, .deactivatedTimer, .deactivatedBattery],
        "idle": [.idle],
        "awake": [.awake2, .awake8, .awake24, .awake72],
    ]

    static let dateKinds: [CopyKind] = [.dateNewYear, .dateHalloween, .date3am]
}

/// The copy tables live in `Core/Copy/Copy+<Tier>.swift` (Swift source, never resources: `Bundle.module` breaks in a
/// hand-assembled bundle). Placeholders: `{name}`, `{floor}`, `{cap}`, `{duration}`.
enum Copy {
    static func pool(_ kind: CopyKind, _ p: Personality) -> [String] {
        switch p {
        case .professional: return professional[kind] ?? []
        case .cheeky: return cheeky[kind] ?? []
        case .unhinged: return unhinged[kind] ?? []
        }
    }
}

/// Small, fast, seedable PRNG (SplitMix64) so tests are deterministic and production needs no global state.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A shuffle bag over the indices of one pool: every index once per round, and never the same index twice in a row
/// (also across rounds).
struct ShuffleBag: Sendable {
    let count: Int
    private var remaining: [Int] = []
    private(set) var last: Int?

    init(count: Int) { self.count = count }

    mutating func draw(using rng: inout SplitMix64) -> Int? {
        guard count > 0 else { return nil }
        if count == 1 { last = 0; return 0 }
        if remaining.isEmpty {
            remaining = Array(0..<count).shuffled(using: &rng)
            // The bag is drawn from the end: keep the previous round's last line away from the first draw.
            if let last, remaining.last == last { remaining.swapAt(remaining.count - 1, 0) }
        }
        let next = remaining.removeLast()
        last = next
        return next
    }
}

@MainActor
final class Narrator: Narrating {
    static let shared = Narrator()

    private let settings: Settings
    private let calendar: Calendar
    private var rng: SplitMix64
    private var bags: [BagKey: ShuffleBag] = [:]

    private struct BagKey: Hashable {
        let kind: CopyKind
        let personality: Personality
    }

    /// The date window a date line last showed in (kind + start of that day): at most one per window.
    private var lastDateWindow: (kind: CopyKind, day: Date)?

    /// `seed`: fixed in tests; random in the app. `calendar` follows time-zone changes unless a test pins one.
    init(settings: Settings = .shared, calendar: Calendar = .autoupdatingCurrent, seed: UInt64? = nil) {
        self.settings = settings
        self.calendar = calendar
        var system = SystemRandomNumberGenerator()
        self.rng = SplitMix64(seed: seed ?? system.next())
    }

    // MARK: - Lines

    /// A line for `m`, or nil (every Professional moment, moments without copy, poke counts between steps).
    /// Never a date line: those come from `dateLine`.
    func line(_ m: Moment, _ p: Personality, now: Date = Date()) -> String? {
        guard p != .professional, let kind = Self.kind(for: m) else { return nil }
        return draw(kind, p).map { fill($0, moment: m) }
    }

    /// A date line to show instead of an `activated` or `idle` line: 1 in 3 while `now` is in a date window, at most
    /// once per window, never in Professional. Earned (PRODUCT.md §4 rule 10): the engine doesn't spend the budget.
    func dateLine(_ p: Personality, now: Date) -> String? {
        guard p != .professional, let kind = dateKind(at: now) else { return nil }
        let day = calendar.startOfDay(for: now)
        if let last = lastDateWindow, last.kind == kind, last.day == day { return nil }
        guard Int.random(in: 0..<3, using: &rng) == 0, let line = draw(kind, p) else { return nil }
        lastDateWindow = (kind, day)
        return line
    }

    /// Maps a moment onto its pool. nil = no copy for this moment (e.g. a replaced hold, a client disconnecting).
    static func kind(for m: Moment) -> CopyKind? {
        switch m {
        case .activated: return .activated
        case .deactivated(let r):
            switch r {
            case .user, .sleepNow: return .deactivatedUser
            case .timerExpired: return .deactivatedTimer
            case .batteryFloor: return .deactivatedBattery
            case .targetExited: return .targetExited
            case .clientDisconnected, .appQuit, .replaced: return nil
            }
        case .idle: return .idle
        case .awake(let hours):
            switch hours {
            case 72...: return .awake72
            case 24...: return .awake24
            case 8...: return .awake8
            case 2...: return .awake2
            default: return nil
            }
        case .watching: return .watching
        case .lidEngaged: return .lidEngaged
        case .lidReopened: return .lidReopened
        case .guardTripped(let g):
            switch g {
            case .thermal: return .thermal
            case .lowPowerMode: return .lowPowerMode
            case .batteryFloor: return .batteryFloor
            case .awakeBatteryFloor: return .deactivatedBattery
            case .acRequired: return .acRequired
            case .lidBatteryCap, .lidACCap: return .lidCap
            }
        case .recoveredAfterCrash: return .recovered
        case .setupDone: return .setupDone
        case .setupCancelled: return .setupCancelled
        case .poke(let n):
            switch n {
            case 5: return .poke5
            case 10: return .poke10
            case 20: return .poke20
            case 50: return .poke50
            default: return nil   // between steps the previous poke line stays (UX §9)
            }
        case .milestone(let hours):
            switch hours {
            case 1000...: return .milestone1000
            case 500...: return .milestone500
            case 100...: return .milestone100
            default: return nil
            }
        }
    }

    /// The date window `now` falls in, most special first. Copy only (PRODUCT.md §3 "Date-aware lines").
    func dateKind(at now: Date) -> CopyKind? {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: now)
        guard let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute else { return nil }
        if month == 1 && day == 1 && hour == 0 && minute < 10 { return .dateNewYear }
        if month == 10 && day == 31 { return .dateHalloween }
        if (3..<5).contains(hour) { return .date3am }
        return nil
    }

    /// Next line from the (kind, personality) bag, unfilled.
    private func draw(_ kind: CopyKind, _ p: Personality) -> String? {
        let pool = Copy.pool(kind, p)
        guard !pool.isEmpty else { return nil }
        let key = BagKey(kind: kind, personality: p)
        var bag = bags[key] ?? ShuffleBag(count: pool.count)
        if bag.count != pool.count { bag = ShuffleBag(count: pool.count) }
        guard let index = bag.draw(using: &rng) else { return nil }
        bags[key] = bag
        return pool[index]
    }

    // MARK: - Placeholders

    private func fill(_ template: String, moment m: Moment) -> String {
        var values: [String: String] = [
            "floor": "\(settings.batteryFloorPercent)",
            "cap": PlainCopy.capText(settings.lidMaxOnBatteryMinutes),
        ]
        switch m {
        case .watching(let t), .deactivated(.targetExited(let t)): values["name"] = FallbackCopy.shortName(t)
        case .guardTripped(.lidACCap): values["cap"] = PlainCopy.capText(settings.lidMaxOnACMinutes)
        case .deactivated(.batteryFloor(let percent)): values["floor"] = "\(percent)"
        default: break
        }
        return Self.fill(template, values)
    }

    /// Replaces `{key}` with `values[key]`. An unknown placeholder falls back to a neutral word, never a raw brace.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        guard template.contains("{") else { return template }
        var out = template
        for (key, value) in values { out = out.replacingOccurrences(of: "{\(key)}", with: value) }
        let fallbacks = ["{name}": "it", "{floor}": "low", "{cap}": "the", "{duration}": "for now"]
        for (key, value) in fallbacks { out = out.replacingOccurrences(of: key, with: value) }
        return out
    }

    // MARK: - Plain copy (every tier; UX.md §5, §8). One source: FallbackCopy / PlainCopy.

    func headline(status: AwakeStatus, lid: LidStatus) -> String {
        FallbackCopy.headline(status: status, lid: lid, batteryFloor: settings.batteryFloorPercent)
    }

    func subline(status: AwakeStatus, lid: LidStatus, remaining: TimeInterval?, now: Date) -> String {
        PlainCopy.subline(plainState(status: status, lid: lid, remaining: remaining, now: now)).joined
    }

    func lidSublabel(_ lid: LidStatus, settingOn: Bool, isAwake: Bool) -> String? {
        var s = plainState(status: isAwake ? .indefinite : .asleep, lid: lid, remaining: nil, now: Date())
        s.closedLidMode = settingOn
        return PlainCopy.lidSublabel(s, nudge: false)?.joined
    }

    func durationName(_ d: AwakeDuration, _ p: Personality) -> String? {
        PlainCopy.durationName(d, p)
    }

    func accessibilityValue(status: AwakeStatus, lid: LidStatus, remaining: TimeInterval?) -> String {
        PlainCopy.accessibilityValue(plainState(status: status, lid: lid, remaining: remaining, now: Date()))
    }

    private func plainState(status: AwakeStatus, lid: LidStatus, remaining: TimeInterval?, now: Date) -> PanelState {
        var s = PanelState()
        s.status = status
        s.lid = lid
        s.now = now
        s.remaining = remaining
        s.batteryFloor = settings.batteryFloorPercent
        s.lidBatteryCapMinutes = settings.lidMaxOnBatteryMinutes
        s.lidACCapMinutes = settings.lidMaxOnACMinutes
        s.closedLidMode = settings.closedLidMode
        s.personality = settings.personality
        return s
    }

    // MARK: - Notifications (UX.md §10)

    /// Title: plain, identical in every tier. Body: personality only for the ids UX §10 marks, otherwise plain.
    func notification(_ id: NotificationID, _ p: Personality, context: [String: String]) -> (title: String, body: String) {
        var plain = FallbackCopy.notification(id, context: context)
        if id == .endingSoon, let minutes = context["minutes"].flatMap(Int.init), minutes != 5 {
            plain.title = "Insomnia: \(minutes) minute\(minutes == 1 ? "" : "s") left"
        }
        let kind: CopyKind?
        switch id {
        case .endingSoon: kind = .endingSoon
        case .ended: kind = .deactivatedTimer
        case .batteryFloor: kind = .batteryFloor
        case .lidHeat: kind = .thermal
        case .recovered: kind = .recovered
        case .targetExited: kind = .targetExited
        case .batteryStop, .lidLPM, .lidCap, .lidError, .lidStuck, .foreignFlag: kind = nil   // plain in every tier
        }
        if let kind, let line = draw(kind, p) {
            var values = context
            if values["floor"] == nil { values["floor"] = "\(settings.batteryFloorPercent)" }
            return (plain.title, Self.fill(line, values))
        }
        return (plain.title, plain.body.isEmpty ? Self.plainBody(id, context: context) : plain.body)
    }

    /// Plain bodies for ids whose FallbackCopy body is empty, so a notification never arrives blank.
    private static func plainBody(_ id: NotificationID, context: [String: String]) -> String {
        switch id {
        case .lidLPM: return "Lid mode resumes when Low Power Mode is off."
        case .lidCap: return "Open the lid to reset the limit."
        default: return ""
        }
    }

    // MARK: - Settings ▸ General live sample

    /// A sample line for the personality picker. Never consumes a real bag (so it can't break rotation).
    func sample(_ p: Personality) -> String {
        let kind: CopyKind = p == .professional ? .lidEngaged : [.lidEngaged, .activated, .idle].randomElement(using: &rng) ?? .lidEngaged
        let pool = Copy.pool(kind, p)
        let line = pool.randomElement(using: &rng) ?? "Lid mode is on."
        return Self.fill(line, ["duration": "for 1 hour", "floor": "\(settings.batteryFloorPercent)"])
    }
}
