import Foundation
import Observation

/// "When unplugged" (MacBooks).
enum UnpluggedAction: String, CaseIterable, Identifiable, Sendable {
    /// Nothing changes.
    case keepGoing
    /// No lid mode while on battery; with the lid already shut, the Mac sleeps.
    case sleepWhenLidCloses
    /// The moment the adapter is unplugged, Insomnia turns off.
    case turnOff

    var id: String { rawValue }

    /// Without lid mode, "Sleep with lid closed" is the same as "Keep going": offered and shown that way.
    static func choices(lidMode: Bool) -> [UnpluggedAction] { lidMode ? allCases : [.keepGoing, .turnOff] }
    static func shown(_ value: UnpluggedAction, lidMode: Bool) -> UnpluggedAction {
        !lidMode && value == .sleepWhenLidCloses ? .keepGoing : value
    }

    var title: String {
        switch self {
        case .keepGoing: "Keep going"
        case .sleepWhenLidCloses: "Sleep with lid closed"
        case .turnOff: "Turn off"
        }
    }
}

/// What a safety protection does when it trips with the lid open (with the lid shut it always sleeps the Mac).
enum TripAction: String, CaseIterable, Identifiable, Sendable {
    /// Sleep if nobody has touched the Mac for `Engine.idleForSleep`, otherwise turn Insomnia off.
    case sleepIfIdle
    case sleep
    case turnOff

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sleepIfIdle: "Sleep if idle, otherwise turn off"
        case .sleep: "Always sleep"
        case .turnOff: "Turn Insomnia off"
        }
    }
}

/// What clicking the moon does (the other button does the other thing).
enum ClickAction: String, CaseIterable, Identifiable, Sendable {
    case openPanel, toggle
    var id: String { rawValue }
    var title: String { self == .openPanel ? "Opens the panel" : "Turns Insomnia on or off" }
}

/// Everything the user can set, in UserDefaults. SwiftUI binds to it directly; the engine is told through `onChange`.
/// `init` never writes (the observable init accessors run, not the setters).
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    nonisolated static let presetChoices = [15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 600, 720]
    nonisolated static let defaultPresets = [60, 120, 240, 480]
    nonisolated static let lowBatteryRange = 11...50

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any change. The engine reconciles.
    @ObservationIgnored var onChange: (() -> Void)?

    /// cdhash of the bundled helper at the last register() (silent-upgrade fallback). Not shown in the UI.
    var helperRegisteredCDHash: String? { didSet { save(helperRegisteredCDHash, Key.helperCDHash) } }

    var keepScreenOn: Bool { didSet { save(keepScreenOn, Key.keepScreenOn) } }
    var closedLidMode: Bool { didSet { save(closedLidMode, Key.closedLidMode) } }
    var whenUnplugged: UnpluggedAction { didSet { save(whenUnplugged.rawValue, Key.whenUnplugged) } }
    /// Minutes the power button keeps awake for; 0 = until turned off.
    var powerButtonMinutes: Int { didSet { save(powerButtonMinutes, Key.powerButtonMinutes) } }
    /// The panel's four timer buttons, in minutes.
    var timerPresets: [Int] { didSet { save(timerPresets, Key.timerPresets) } }
    var clickAction: ClickAction { didSet { save(clickAction.rawValue, Key.clickAction) } }

    var overheatProtection: Bool { didSet { save(overheatProtection, Key.overheatProtection) } }
    var lowBatteryProtection: Bool { didSet { save(lowBatteryProtection, Key.lowBatteryProtection) } }
    private var lowBatteryStore: Int
    /// Clamped to `lowBatteryRange`: never at or below the helper's own 10% backstop.
    var lowBatteryPercent: Int {
        get { lowBatteryStore }
        set { lowBatteryStore = Self.clampBattery(newValue); save(lowBatteryStore, Key.lowBatteryPercent) }
    }
    static func clampBattery(_ v: Int) -> Int { min(lowBatteryRange.upperBound, max(lowBatteryRange.lowerBound, v)) }
    var tripAction: TripAction { didSet { save(tripAction.rawValue, Key.tripAction) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }
        func int(_ k: String, _ d: Int) -> Int { defaults.object(forKey: k) == nil ? d : defaults.integer(forKey: k) }
        // Optionals first: they start out initialised, so a later assignment would run the setter.
        helperRegisteredCDHash = defaults.string(forKey: Key.helperCDHash)
        keepScreenOn = bool(Key.keepScreenOn, true)
        closedLidMode = bool(Key.closedLidMode, false)
        whenUnplugged = UnpluggedAction(rawValue: defaults.string(forKey: Key.whenUnplugged) ?? "") ?? .sleepWhenLidCloses
        powerButtonMinutes = max(0, int(Key.powerButtonMinutes, 0))
        let stored = (defaults.array(forKey: Key.timerPresets) as? [Int])?.filter { $0 > 0 }
        timerPresets = stored?.count == 4 ? stored! : Self.defaultPresets
        clickAction = ClickAction(rawValue: defaults.string(forKey: Key.clickAction) ?? "") ?? .openPanel
        overheatProtection = bool(Key.overheatProtection, true)
        lowBatteryProtection = bool(Key.lowBatteryProtection, true)
        lowBatteryStore = Self.clampBattery(int(Key.lowBatteryPercent, 12))
        tripAction = TripAction(rawValue: defaults.string(forKey: Key.tripAction) ?? "") ?? .sleepIfIdle
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        onChange?()
    }

    /// Keys kept from the old app where the meaning is the same (`--unregister-helper` clears `closedLidMode`).
    enum Key {
        static let helperCDHash = "helperRegisteredCDHash"
        static let keepScreenOn = "keepScreenOn"
        static let closedLidMode = "closedLidMode"
        static let whenUnplugged = "whenUnplugged"
        static let powerButtonMinutes = "powerButtonMinutes"
        static let timerPresets = "timerPresets"
        static let clickAction = "clickAction"
        static let overheatProtection = "overheatProtection"
        static let lowBatteryProtection = "lowBatteryProtection"
        static let lowBatteryPercent = "lowBatteryPercent"
        static let tripAction = "tripAction"
    }
}

/// "1h 30m", "45m", "2h".
enum DurationText {
    static func short(minutes m: Int) -> String {
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// Time left, rounded up to the minute: "1h 42m left", "1m left".
    static func left(until end: Date, now: Date) -> String {
        let minutes = max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
        return short(minutes: minutes) + " left"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
