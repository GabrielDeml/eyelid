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

    /// Without lid mode, "Sleep with lid closed" is the same as "Stay awake", so it is offered and shown that way.
    static func choices(lidMode: Bool) -> [UnpluggedAction] { lidMode ? allCases : [.keepGoing, .turnOff] }
    static func shown(_ value: UnpluggedAction, lidMode: Bool) -> UnpluggedAction {
        !lidMode && value == .sleepWhenLidCloses ? .keepGoing : value
    }

    var title: String {
        switch self {
        case .keepGoing: "Stay awake"
        case .sleepWhenLidCloses: "Sleep with lid closed"
        case .turnOff: "Turn Insomnia off"
        }
    }
}

/// What clicking the menu bar icon does (right-click does the other).
enum ClickAction: String, CaseIterable, Identifiable, Sendable {
    case openPanel, toggle
    var id: String { rawValue }
    var title: String { self == .openPanel ? "Open the panel" : "Turn Insomnia on or off" }
}

/// Everything the user can set, in UserDefaults. SwiftUI binds to it directly; the engine is told through `onChange`.
/// `init` never writes (the observable init accessors run, not the setters).
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    /// "Turn Insomnia off after" choices, in minutes (0 = never).
    nonisolated static let durationChoices = [60, 120, 240, 480]

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any change. The engine reconciles.
    @ObservationIgnored var onChange: (() -> Void)?

    /// cdhash of the bundled helper at the last register() (silent-upgrade fallback). Not shown in the UI.
    var helperRegisteredCDHash: String? { didSet { save(helperRegisteredCDHash, Key.helperCDHash) } }

    var keepScreenOn: Bool { didSet { save(keepScreenOn, Key.keepScreenOn) } }
    var closedLidMode: Bool { didSet { save(closedLidMode, Key.closedLidMode) } }
    var whenUnplugged: UnpluggedAction { didSet { save(whenUnplugged.rawValue, Key.whenUnplugged) } }
    /// Turn Insomnia off after this many minutes; 0 = never. (The key name predates the switch.)
    var powerButtonMinutes: Int { didSet { save(powerButtonMinutes, Key.powerButtonMinutes) } }
    var clickAction: ClickAction { didSet { save(clickAction.rawValue, Key.clickAction) } }
    /// Ignored while lid mode keeps the Mac awake with the lid shut and no external display: then the check always applies.
    var overheatProtection: Bool { didSet { save(overheatProtection, Key.overheatProtection) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }
        func int(_ k: String, _ d: Int) -> Int { defaults.object(forKey: k) == nil ? d : defaults.integer(forKey: k) }
        // Optionals first: they start out initialised, so a later assignment would run the setter.
        helperRegisteredCDHash = defaults.string(forKey: Key.helperCDHash)
        keepScreenOn = bool(Key.keepScreenOn, true)
        closedLidMode = bool(Key.closedLidMode, false)
        whenUnplugged = UnpluggedAction(rawValue: defaults.string(forKey: Key.whenUnplugged) ?? "") ?? .sleepWhenLidCloses
        powerButtonMinutes = Self.snapDuration(int(Key.powerButtonMinutes, 0))
        clickAction = ClickAction(rawValue: defaults.string(forKey: Key.clickAction) ?? "") ?? .openPanel
        overheatProtection = bool(Key.overheatProtection, true)
    }

    /// A stored duration that isn't one of `durationChoices` (an older version's) becomes the next choice up, or the
    /// longest one, so the picker always has a selection and a timed session stays timed.
    nonisolated static func snapDuration(_ minutes: Int) -> Int {
        minutes <= 0 ? 0 : durationChoices.first { $0 >= minutes } ?? durationChoices.last ?? 0
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
        static let clickAction = "clickAction"
        static let overheatProtection = "overheatProtection"
    }
}

enum DurationText {
    /// Whole hours, spelled out: "1 hour", "8 hours".
    static func hours(minutes m: Int) -> String { m == 60 ? "1 hour" : "\(m / 60) hours" }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
