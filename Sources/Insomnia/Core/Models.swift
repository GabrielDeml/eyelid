import AppKit
import Foundation

// MARK: - Shared contracts. Every module codes against these. See ARCHITECTURE.md + docs/*.md.
// Change a signature only together with the docs (and a Decisions-log entry if it changes behaviour).

// MARK: Durations

/// How long a manual hold should last.
enum AwakeDuration: Hashable, Codable, Sendable {
    case indefinite
    case minutes(Int)
    case until(Date)

    /// Panel chips, in order (keys 1–6): 30m, 1h, 2h, 4h, 8h, ∞.
    static let presets: [AwakeDuration] = [
        .minutes(30), .minutes(60), .minutes(120), .minutes(240), .minutes(480), .indefinite,
    ]

    /// nil == runs forever.
    func endDate(from start: Date) -> Date? {
        switch self {
        case .indefinite: return nil
        case .minutes(let m): return start.addingTimeInterval(TimeInterval(max(1, m)) * 60)
        case .until(let date): return date
        }
    }

    /// Compact label for chips / menus: "30m", "1h", "8h", "∞", "→ 17:30" (`TimeFormat.endTime`).
    var shortLabel: String {
        switch self {
        case .indefinite: return "∞"
        case .minutes(let m):
            if m % 60 == 0 { return "\(m / 60)h" }
            if m > 60 { return "\(m / 60)h \(m % 60)m" }
            return "\(m)m"
        case .until(let date):
            return "→ " + TimeFormat.endTime(date)
        }
    }

    /// Settings stores the default duration as minutes; 0 means indefinite.
    init(storedMinutes: Int) {
        self = storedMinutes <= 0 ? .indefinite : .minutes(storedMinutes)
    }

    var storedMinutes: Int {
        if case .minutes(let m) = self { return m }
        return 0
    }

    /// "Until 07:00": the next occurrence of hour:minute strictly after `now` (today, else tomorrow).
    static func nextOccurrence(hour: Int, minute: Int, after now: Date = Date(),
                               calendar: Calendar = .current) -> AwakeDuration {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let date = calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
        return .until(date)
    }
}

// MARK: Holds: every reason to stay awake is a Hold

/// Which surface started a manual hold.
enum SessionSource: String, Hashable, Codable, Sendable {
    case panel, menuBar, hotkey, urlScheme, dock, notification, launch, cli
}

/// Something we can watch until it exits ("While…" / babysit, CLI `watch`, rules).
enum WatchTarget: Hashable, Codable, Sendable {
    case app(bundleID: String, name: String)
    /// Matches (case-insensitive) if ANY of: proc_name, basename(proc_pidpath), basename(argv[0]) via
    /// KERN_PROCARGS2, or, for interpreters (node, bun, deno, ruby, Python*, python3*), basename of the
    /// first non-flag argument. Needed because e.g. `claude` renames itself and `npm`/`codex` show as `node`.
    case process(name: String)
    case pid(Int32, name: String)

    var displayName: String {
        switch self {
        case .app(_, let name): return name
        case .process(let name): return name
        case .pid(let pid, let name): return "\(name) (\(pid))"
        }
    }
}

/// What a hold asks for. System-idle-sleep prevention is implied by every hold.
struct AwakeOptions: Hashable, Codable, Sendable {
    /// Also hold PreventUserIdleDisplaySleep ("Keep screen on").
    var screen: Bool
    /// Also request closed-lid mode (SleepDisabled = 1). Subject to guards + privileged backend.
    var lid: Bool

    static let systemOnly = AwakeOptions(screen: false, lid: false)
}

/// Who owns a hold. Determines lifetime and how it is shown.
enum HoldOwner: Hashable, Sendable {
    /// At most one. Starting a new manual hold replaces it.
    case manual(SessionSource)
    /// At most one from the panel ("While…"). Ends when the target exits (5 s grace).
    case babysit(WatchTarget)
    /// Derived from an enabled Rule whose condition is currently true. Never stored.
    case rule(Rule.ID)
    /// CLI `run` / `watch`; lives exactly as long as its control-socket connection.
    case client(connection: UUID, label: String)
}

struct Hold: Identifiable, Equatable, Sendable {
    let id: UUID
    var owner: HoldOwner
    var options: AwakeOptions
    let start: Date
    /// nil == no end time (indefinite, babysit, rule, client).
    var end: Date?
    /// true: `options` are re-derived from Settings on every reevaluate (panel/hotkey/Dock manual holds, babysit,
    /// rules). false: options were given explicitly (CLI flags, URL scheme, client holds) and are never rewritten.
    let followsSettings: Bool

    init(id: UUID = UUID(), owner: HoldOwner, options: AwakeOptions, start: Date = Date(), end: Date? = nil,
         followsSettings: Bool = true) {
        self.id = id
        self.owner = owner
        self.options = options
        self.start = start
        self.end = end
        self.followsSettings = followsSettings
    }

    var isManual: Bool { if case .manual = owner { return true } else { return false } }
}

// MARK: Rules (persistent automations; Settings ▸ Automations)

enum RuleCondition: Hashable, Codable, Sendable {
    case app(bundleID: String, name: String)
    case process(name: String)
    case onAC
    case externalDisplay

    /// Plain sentence fragment: "Xcode is running", "on power adapter".
    var phrase: String {
        switch self {
        case .app(_, let name): return "\(name) is running"
        case .process(let name): return "\(name) is running"
        case .onAC: return "on power adapter"
        case .externalDisplay: return "an external display is connected"
        }
    }
}

struct Rule: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var condition: RuleCondition
    var keepScreenOn: Bool = false
    /// Lid for this rule even when the panel's lid switch is off. Effective lid = allowLid || Settings.closedLidMode.
    var allowLid: Bool = false
    var enabled: Bool = true

    var options: AwakeOptions { AwakeOptions(screen: keepScreenOn, lid: allowLid) }
}

// MARK: Guards (safety; always win over holds). See docs/CLOSED_LID.md §6.

enum GuardReason: String, Hashable, Codable, CaseIterable, Sendable {
    /// On battery at/below Settings.batteryFloorPercent. Lid only. Mandatory (disablesleep kills macOS low-battery sleep).
    case batteryFloor
    /// Opt-in (Settings.awakeBatteryFloorEnabled): same floor, but ends manual holds and suspends all holds.
    case awakeBatteryFloor
    /// Thermal ≥ .serious, or ≥ .fair for 5 min in the bag condition (lid closed, no ext. display, on battery). Lid only.
    case thermal
    /// Low Power Mode on. Lid only.
    case lowPowerMode
    /// "Only on power adapter" set and on battery. Lid only.
    case acRequired
    /// Engine counter of bag-condition seconds (lid closed, no ext. display, on battery) ≥ Settings.lidMaxOnBatteryMinutes.
    /// Always on. Resets only when the lid opens. Lid only.
    case lidBatteryCap
    /// Settings.lidCapOnACEnabled and engine counter of lid-closed-on-AC seconds (no ext. display) ≥ Settings.lidMaxOnACMinutes.
    /// Off by default. Resets only when the lid opens. Lid only.
    case lidACCap

    var affectsAllHolds: Bool { self == .awakeBatteryFloor }
    /// Alarm-type guards show `.squint`; user-chosen limits (acRequired, both caps) keep the normal mood.
    var squints: Bool { self != .acRequired && self != .lidBatteryCap && self != .lidACCap }
}

// MARK: Closed-lid status

/// Which privileged backend this build uses, chosen once at launch, off the main thread (docs/CLOSED_LID.md §2.1):
/// `.helper` when our own code signature carries a Team ID, `.sudoers` for builds explicitly made ad hoc.
enum PrivilegeBackendKind: String, Sendable {
    case helper, sudoers
}

/// Readiness of the privileged backend. Only `.installed` may engage. Mapping: docs/CLOSED_LID.md §2.6.
enum HelperStatus: Equatable, Sendable {
    /// Nothing set up; offer "Set Up…". Helper: SMAppService `.notRegistered` **or `.notFound`** (a never-registered
    /// daemon reports `.notFound` on macOS 27) while the bundle has the plist + helper and sits at a safe location.
    /// Sudoers: neither piece present.
    case notInstalled
    /// Helper registered but not allowed (first setup, or switched off later) in System Settings ▸ General ▸
    /// Login Items & Extensions. Offer "Open System Settings"; re-check until `.enabled`.
    case requiresApproval
    /// Helper enabled, but the running helper's cdhash differs from the bundled one (app updated or rebuilt), or the
    /// helper doesn't answer and the bundled cdhash differs from the one saved at register(). Upgrade silently
    /// (only while not engaged): unregister, register.
    case versionMismatch(running: String, bundled: String)
    /// Helper: the launchd plist or the helper binary is really missing from the bundle. "Reinstall Insomnia."
    case notFound
    /// Helper: this copy isn't `/Applications/Insomnia.app` owned by root and not group/other-writable
    /// (`InstallLocation.check`). Setup is refused; "Install with make install". CLOSED_LID.md §2.3.
    case unsafeLocation
    /// Helper enabled, but the XPC call fails, times out (2 s) or fails code-signing validation. Offer "Repair…".
    case unreachable
    /// Sudoers backend (ad-hoc build) while a helper from a signed build is still registered (SMAppService status
    /// `.enabled` / `.requiresApproval`). Never offer the sudoers install; offer "Remove…" (unregister).
    case leftoverHelper
    /// Sudoers fallback: exactly one of sudoers rule / safety daemon present → offer Repair.
    case partial(sudoers: Bool, safetyDaemon: Bool)
    /// Sudoers fallback: both present but the daemon is disabled in Login Items → refuse to engage.
    case daemonDisabled
    /// Ready. Helper: enabled, reachable, current. Sudoers: rule works and daemon enabled.
    case installed
}

enum LidError: Equatable, Sendable {
    case helperMissing
    /// Privileged call failed: sudo/pmset exit status, or a HelperResult raw value; -1 = spawn/XPC failure or timeout.
    case commandFailed(Int32)
    /// IORegistry SleepDisabled did not match what we set.
    case readbackMismatch
    /// The safety net died while engaged: helper connection interrupted/invalidated or heartbeat answered "not engaged"
    /// (helper backend), or the watchdog exited (sudoers backend). Either way the flag has been reset.
    case safetyNetLost
    /// Something else set SleepDisabled = 0 while engaged. Respected; never re-applied without a user action.
    case overridden
    /// SleepDisabled was already 1, set by something else. Not taken over (Decision 23). The Mac stays awake anyway.
    case foreignFlag
    /// Helper refused engage (`HelperResult.otherUser`): another user on this Mac (fast user switching) holds lid mode.
    /// Informational, like `.foreignFlag`.
    case otherUser

    /// `.foreignFlag` / `.otherUser` are informational (the Mac is awake, just not by us); the rest show `.alarmed`.
    var alarms: Bool { self != .foreignFlag && self != .otherUser }
}

/// Errors from the one-time setup/removal (docs/CLOSED_LID.md §2.6 helper, §2.7 sudoers).
enum LidSetupError: Error, Equatable, Sendable {
    /// The user cancelled an admin password prompt (sudoers install/uninstall, Reset with password…).
    case cancelled
    /// Sudoers: user name failed validation.
    case invalidUser
    /// Sudoers: /etc/sudoers lacks the stock #includedir.
    case includedirMissing
    /// Sudoers: the root script exited non-zero.
    case scriptFailed(code: Int32, detail: String)
    /// Helper: SMAppService register()/unregister() threw something other than "needs approval".
    case registrationFailed(code: Int, detail: String)
    /// Helper: enabled, but no valid XPC answer within 2 s after setup.
    case helperUnreachable
    /// Helper: register() refused because the bundle isn't root-owned at /Applications/Insomnia.app (InstallLocation).
    case unsafeLocation
    /// Helper: after unregister() the status is not `.notRegistered` / `.notFound`.
    case unregisterIncomplete
}

enum LidStatus: Equatable, Sendable {
    /// Not requested (setting off, or nothing awake wants lid).
    case off
    /// Requested but HelperStatus != .installed (the sublabel says which step is missing).
    case needsSetup
    /// Privileged call in flight.
    case engaging
    /// SleepDisabled == 1, verified by readback.
    case engaged(lidClosed: Bool)
    /// Requested, but a guard has released the flag. Re-engages when it clears (unless latched).
    case suspended(GuardReason)
    /// A guard released the flag while the lid was closed. Stays released until the lid physically
    /// opens or the user acts, so a DarkWake never re-engages inside a bag.
    case latched
    /// Apply/readback failed; flag verified 0. Mac sleeps normally. Offers Retry.
    case error(LidError)
    /// Flag is 1 and every reset failed (helper unreachable, sudoers rule removed). Red, persistent; "Reset with password…".
    case stuck
}

/// Mission report: set by ClosedLidController on lid open after ≥ 5 min engaged-closed; the engine turns it into
/// `Banner.reopen` and `Moment.lidReopened`. (Declared here, not in ClosedLidController.swift, because the engine and UI
/// need it from M1.)
struct ReopenReport: Equatable, Sendable {
    var closedFor: TimeInterval
    var batteryStart: Int?
    var batteryEnd: Int?
    var worstThermal: ProcessInfo.ThermalState
}

/// Notification identifiers (UX.md §10). Doubles as the UNNotificationRequest identifier, so posting the same id
/// replaces the previous one. (Declared here, not in Narrator.swift, because the engine posts them from M1.)
enum NotificationID: String, CaseIterable, Sendable {
    case endingSoon = "ending-soon", ended, batteryFloor = "battery-floor", batteryStop = "battery-stop"
    case lidHeat = "lid-heat", lidLPM = "lid-lpm", lidCap = "lid-cap", lidError = "lid-error", lidStuck = "lid-stuck"
    case foreignFlag = "foreign-flag", recovered, targetExited = "target-exited"

    /// Gated by Settings.sessionNotifications; every other id always posts (safety).
    var isSessionNotification: Bool { self == .endingSoon || self == .ended || self == .targetExited }
}

// MARK: Derived status (the one value every surface switches on)

enum AwakeStatus: Equatable, Sendable {
    case asleep
    case timed(end: Date)
    case indefinite
    case watching(WatchTarget)
    case client(label: String)
    case automatic([RuleCondition])
    /// Opt-in awakeBatteryFloor tripped: nothing is held.
    case suspended(GuardReason)

    var isAwake: Bool {
        switch self {
        case .asleep, .suspended: return false
        default: return true
        }
    }
}

/// Mascot mood. Priority: alarmed > squint > lid > awake > watching > asleep.
enum EyeMood: Equatable, Sendable {
    case asleep, awake, watching, lid, squint, alarmed

    init(status: AwakeStatus, lid: LidStatus) {
        switch lid {
        case .stuck: self = .alarmed; return
        case .error(let e) where e.alarms: self = .alarmed; return
        case .suspended(let g) where g.squints: self = .squint; return
        default: break
        }
        if case .suspended(let g) = status, g.squints { self = .squint; return }
        if case .engaged = lid { self = .lid; return }
        switch status {
        case .timed, .indefinite: self = .awake
        case .watching, .client, .automatic: self = .watching
        case .asleep, .suspended: self = .asleep
        }
    }
}

/// Why the engine ended a hold.
enum DeactivationReason: Hashable, Sendable {
    case user(SessionSource)
    case timerExpired
    case batteryFloor(percent: Int)
    case targetExited(WatchTarget)
    case clientDisconnected
    case sleepNow
    case appQuit
    /// A new manual hold replaced the old one (no copy shown).
    case replaced
}

// MARK: Narrator moments (Core/Narrator.swift maps these to copy; docs/UX.md §11)

enum Moment: Hashable, Sendable {
    case activated(AwakeDuration)
    case deactivated(DeactivationReason)
    /// The panel opens while asleep; at most once per day.
    case idle
    /// Escalation buckets: 2, 8, 24, 72 hours of continuous awake.
    case awake(hours: Int)
    case watching(WatchTarget)
    case lidEngaged
    case lidReopened
    case guardTripped(GuardReason)
    case recoveredAfterCrash
    case setupDone
    case setupCancelled
    case poke(Int)
    case milestone(hours: Int)
}

// MARK: Preferences enums

/// The app's sense of humour.
enum Personality: String, CaseIterable, Codable, Identifiable, Sendable {
    case professional, cheeky, unhinged
    var id: String { rawValue }
    var title: String {
        switch self {
        case .professional: return "Professional"
        case .cheeky: return "Cheeky"
        case .unhinged: return "Unhinged"
        }
    }
}

/// What a left-click on the menu bar item does. Right-click does the other one. ⌥-click is always "Why awake?".
enum ClickAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case openPanel, toggle
    var id: String { rawValue }
    var title: String { self == .openPanel ? "Opens panel" : "Toggles" }
}

/// Menu bar countdown text. Kept narrow so macOS 27 doesn't eject the item.
enum MenuBarTimerStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case off, lastTenMinutes, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .lastTenMinutes: return "Last 10 min"
        case .always: return "Always"
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, automations, lidSafety, diagnostics
    var id: String { rawValue }
    /// UI shows "Safety" when the Mac has no lid, and hides the tab when it also has no battery (UX.md §4.3).
    var title: String {
        switch self {
        case .general: return "General"
        case .automations: return "Automations"
        case .lidSafety: return "Lid & Safety"
        case .diagnostics: return "Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .automations: return "bolt.badge.automatic"
        case .lidSafety: return "laptopcomputer"
        case .diagnostics: return "stethoscope"
        }
    }
}

// MARK: - App-wide notifications (AppKit consumers observe these; SwiftUI observes @Observable objects directly)

extension Notification.Name {
    /// AwakeEngine state changed (holds, guards, lid status, display tick).
    static let insomniaStateDidChange = Notification.Name("InsomniaStateDidChange")
    /// Any Settings property changed. userInfo["key"] = the UserDefaults key (e.g. "rules.v1").
    static let insomniaSettingsDidChange = Notification.Name("InsomniaSettingsDidChange")
    /// PowerMonitor observed a change (battery, AC, thermal, low power, lid, displays).
    static let insomniaPowerDidChange = Notification.Name("InsomniaPowerDidChange")
    /// WatchMonitor: set of satisfied rules / live watch targets changed.
    static let insomniaRulesDidChange = Notification.Name("InsomniaRulesDidChange")
}

// MARK: - Router: decouples UI pieces from each other. Handlers are wired by AppDelegate.

@MainActor
final class AppRouter {
    static let shared = AppRouter()

    var showPanelHandler: (() -> Void)?
    var closePanelHandler: (() -> Void)?
    var openSettingsHandler: ((SettingsTab) -> Void)?
    var showWhyAwakeHandler: (() -> Void)?
    var showAboutHandler: (() -> Void)?
    /// `requestedLid`: true only from the lid switch itself (finishing setup then turns lid mode on).
    var startLidSetupHandler: ((_ requestedLid: Bool) -> Void)?

    func showPanel() { showPanelHandler?() }
    func closePanel() { closePanelHandler?() }
    func openSettings(_ tab: SettingsTab = .general) {
        guard let openSettingsHandler else { return }   // no Settings window yet: keep the panel open
        closePanel()
        openSettingsHandler(tab)
    }
    func showWhyAwake() { showWhyAwakeHandler?() }
    func showAbout() { showAboutHandler?() }
    func startLidSetup(requestedLid: Bool = false) { startLidSetupHandler?(requestedLid) }
    /// Terminates from the run loop, never from inside a main-queue block (a dispatch source, a Task): quitting answers
    /// `.terminateLater` and replies from a main-actor Task, which can't run while one of the main queue's own blocks
    /// is still on the stack.
    func quit() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

// MARK: - Formatting helpers shared by UI

enum TimeFormat {
    /// "1:02:03", "12:03", "0:42"
    static func countdown(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Short menu-bar style: "2h", "1h 5m", "42m", "<1m"
    static func compact(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval.rounded(.up)))
        if s < 60 { return "<1m" }
        let totalMin = (s + 59) / 60
        let h = totalMin / 60, m = totalMin % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// When a hold ends, for every surface that shows it ("until …": panel subline, status item, Dock menu, CLI,
    /// Why awake, notifications). The time alone up to 20 h ahead ("7:13 AM"); the weekday up to 6 days ahead
    /// ("Sat 7:13 AM"), so a multi-day hold never reads like today; a date beyond that ("Nov 9 at 7:13 AM").
    static func endTime(_ end: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent,
                        timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let ahead = end.timeIntervalSince(now)
        var style: Date.FormatStyle
        if ahead <= endTimeOnlyHorizon {
            style = Date.FormatStyle(date: .omitted, time: .shortened)
        } else if ahead <= endWeekdayHorizon {
            style = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        } else {
            style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
            // A long hold can end in a later year, or ~a year out on today's month/day; name the year so it
            // never reads like tomorrow ("Nov 1, 2027 at 7:34 AM").
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            if cal.component(.year, from: end) != cal.component(.year, from: now) || ahead > 300 * 86_400 {
                style = style.year()
            }
        }
        style.locale = locale
        style.timeZone = timeZone
        return end.formatted(style)
    }

    /// Up to here an end time shows as a clock time only.
    static let endTimeOnlyHorizon: TimeInterval = 20 * 3600
    /// Up to here an end time shows weekday + time; beyond it, a date.
    static let endWeekdayHorizon: TimeInterval = 6 * 86_400

    /// Long human form for stats: "3 days, 4 hours", "12 hours, 5 minutes", "7 minutes"
    static func humanLong(_ interval: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: max(0, interval)) ?? "0 minutes"
    }
}
