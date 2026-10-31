import Carbon.HIToolbox
import Foundation
import Observation

/// UserDefaults-backed preferences. SwiftUI views observe it directly (@Observable);
/// AppKit/engine code listens for `.insomniaSettingsDidChange` (userInfo["key"] = UserDefaults key).
///
/// Deliberately absent (see ARCHITECTURE.md Decisions log): lookBusy, thermalGuardEnabled,
/// batteryCutoffEnabled, dockClickToggles, lastCustomMinutes, separate trigger Bools.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: Awake behaviour
    /// "Keep screen on": settings-following manual and babysit holds also prevent display sleep (rules have their own box).
    var keepScreenOn: Bool { didSet { store(keepScreenOn, "keepScreenOn") } }
    /// "Stay awake with lid closed": EVERY settings-following hold (manual, babysit, rule) requests lid mode.
    /// Never written by the CLI or URL scheme. Needs the one-time setup (helper, or sudoers on unsigned builds).
    var closedLidMode: Bool { didSet { store(closedLidMode, "closedLidMode") } }
    /// Default duration for toggle / hotkey / Dock click, in minutes. 0 == indefinite.
    var defaultDurationMinutes: Int { didSet { store(defaultDurationMinutes, "defaultDurationMinutes") } }
    /// Start a manual hold (default duration) when the app launches.
    var activateOnLaunch: Bool { didSet { store(activateOnLaunch, "activateOnLaunch") } }

    // MARK: Lid & Safety (lid battery floor + thermal + Low Power Mode guards are always on)
    private var floorStore: Int
    private var batteryCapStore: Int
    private var acCapStore: Int
    /// Lid mode turns off on battery at or below this percent (mandatory). Clamped 10…50.
    var batteryFloorPercent: Int {
        get { floorStore }
        set { floorStore = Settings.clampFloor(newValue); store(floorStore, "batteryFloorPercent") }
    }
    /// Opt-in: at the same floor, also stop keeping awake (ends manual holds, suspends the rest).
    var awakeBatteryFloorEnabled: Bool { didSet { store(awakeBatteryFloorEnabled, "awakeBatteryFloorEnabled") } }
    /// Lid mode only engages on the power adapter.
    var lidRequiresAC: Bool { didSet { store(lidRequiresAC, "lidRequiresAC") } }
    /// Max bag-condition time (lid closed, no ext. display, on battery). Always applies; no "unlimited".
    /// Snapped to lidBatteryCapChoices (15 min – 8 h), default 60.
    var lidMaxOnBatteryMinutes: Int {
        get { batteryCapStore }
        set { batteryCapStore = Settings.snapBatteryCap(newValue); store(batteryCapStore, "lidMaxOnBatteryMinutes") }
    }
    /// Optional limit for lid closed on the power adapter (no ext. display). Off by default: on AC, no cap.
    var lidCapOnACEnabled: Bool { didSet { store(lidCapOnACEnabled, "lidCapOnACEnabled") } }
    /// Snapped to lidACCapChoices (1–24 h), default 240. Used only when lidCapOnACEnabled.
    var lidMaxOnACMinutes: Int {
        get { acCapStore }
        set { acCapStore = Settings.snapACCap(newValue); store(acCapStore, "lidMaxOnACMinutes") }
    }

    // MARK: Automations
    var rules: [Rule] { didSet { storeCodable(rules, "rules.v1") } }

    // MARK: Interface
    var leftClickAction: ClickAction { didSet { store(leftClickAction.rawValue, "leftClickAction") } }
    var showInDock: Bool { didSet { store(showInDock, "showInDock") } }
    var menuBarTimer: MenuBarTimerStyle { didSet { store(menuBarTimer.rawValue, "menuBarTimer") } }
    /// "Notify before a timer ends and when it ends" (+ babysit target finished). Safety notifications always fire.
    var sessionNotifications: Bool { didSet { store(sessionNotifications, "sessionNotifications") } }
    var personality: Personality { didSet { store(personality.rawValue, "personality") } }

    // MARK: Global hotkey (Carbon key code + Carbon modifier mask: cmdKey | optionKey | controlKey | shiftKey)
    var hotKeyEnabled: Bool { didSet { store(hotKeyEnabled, "hotKeyEnabled") } }
    var hotKeyCode: UInt32 { didSet { store(Int(hotKeyCode), "hotKeyCode") } }
    var hotKeyModifiers: UInt32 { didSet { store(Int(hotKeyModifiers), "hotKeyModifiers") } }

    // MARK: One-time flags
    var hasCompletedOnboarding: Bool { didSet { store(hasCompletedOnboarding, "hasCompletedOnboarding") } }
    var lidBatteryCalloutShown: Bool { didSet { store(lidBatteryCalloutShown, "lidBatteryCalloutShown") } }
    var hiddenItemCardShown: Bool { didSet { store(hiddenItemCardShown, "hiddenItemCardShown") } }

    // MARK: Helper bookkeeping (not shown in UI; CLOSED_LID.md §2.6)
    /// cdhash of the bundled helper at the last successful register(); nil when not registered. Lets an unanswering
    /// helper after a rebuild be treated as `.versionMismatch` (silent re-register), not `.unreachable`.
    var helperRegisteredCDHash: String? { didSet { storeOptional(helperRegisteredCDHash, "helperRegisteredCDHash") } }

    var defaultDuration: AwakeDuration { AwakeDuration(storedMinutes: defaultDurationMinutes) }
    /// Options for settings-following manual and babysit holds. Rule holds use
    /// AwakeOptions(screen: rule.keepScreenOn, lid: rule.allowLid || closedLidMode).
    var manualOptions: AwakeOptions { AwakeOptions(screen: keepScreenOn, lid: closedLidMode) }

    static let lidBatteryCapChoices = [15, 30, 60, 120, 240, 480]
    static let lidACCapChoices = [60, 120, 240, 480, 720, 1440]
    static func clampFloor(_ v: Int) -> Int { min(50, max(10, v)) }
    static func snapBatteryCap(_ v: Int) -> Int { snap(v, to: lidBatteryCapChoices, default: 60) }
    static func snapACCap(_ v: Int) -> Int { snap(v, to: lidACCapChoices, default: 240) }
    private static func snap(_ v: Int, to choices: [Int], default d: Int) -> Int {
        choices.min { abs($0 - v) < abs($1 - v) } ?? d
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }
        func int(_ k: String, _ d: Int) -> Int { defaults.object(forKey: k) == nil ? d : defaults.integer(forKey: k) }
        func decode<T: Decodable>(_ k: String, _ d: T) -> T {
            guard let data = defaults.data(forKey: k), let v = try? JSONDecoder().decode(T.self, from: data) else { return d }
            return v
        }

        keepScreenOn = bool("keepScreenOn", true)
        closedLidMode = bool("closedLidMode", false)
        defaultDurationMinutes = int("defaultDurationMinutes", 0)
        activateOnLaunch = bool("activateOnLaunch", false)

        floorStore = Settings.clampFloor(int("batteryFloorPercent", 20))
        awakeBatteryFloorEnabled = bool("awakeBatteryFloorEnabled", false)
        lidRequiresAC = bool("lidRequiresAC", false)
        batteryCapStore = Settings.snapBatteryCap(int("lidMaxOnBatteryMinutes", 60))
        lidCapOnACEnabled = bool("lidCapOnACEnabled", false)
        acCapStore = Settings.snapACCap(int("lidMaxOnACMinutes", 240))

        rules = decode("rules.v1", [Rule]())

        leftClickAction = ClickAction(rawValue: defaults.string(forKey: "leftClickAction") ?? "") ?? .openPanel
        showInDock = bool("showInDock", true)   // the user asked for a Dock widget; welcome card pre-selects it
        menuBarTimer = MenuBarTimerStyle(rawValue: defaults.string(forKey: "menuBarTimer") ?? "") ?? .lastTenMinutes
        sessionNotifications = bool("sessionNotifications", true)
        personality = Personality(rawValue: defaults.string(forKey: "personality") ?? "") ?? .cheeky

        hotKeyEnabled = bool("hotKeyEnabled", true)
        hotKeyCode = UInt32(int("hotKeyCode", kVK_ANSI_I))
        hotKeyModifiers = UInt32(int("hotKeyModifiers", cmdKey | optionKey | controlKey))

        hasCompletedOnboarding = bool("hasCompletedOnboarding", false)
        lidBatteryCalloutShown = bool("lidBatteryCalloutShown", false)
        hiddenItemCardShown = bool("hiddenItemCardShown", false)
        helperRegisteredCDHash = defaults.string(forKey: "helperRegisteredCDHash")
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .insomniaSettingsDidChange, object: self, userInfo: ["key": key])
    }

    private func storeOptional(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .insomniaSettingsDidChange, object: self, userInfo: ["key": key])
    }

    private func storeCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        NotificationCenter.default.post(name: .insomniaSettingsDidChange, object: self, userInfo: ["key": key])
    }
}
