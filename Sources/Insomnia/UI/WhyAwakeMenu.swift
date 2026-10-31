import AppKit
import Foundation

// MARK: - Why is my Mac awake? (UX.md §1.5): one report, three renderings
//
// `WhyAwakeReport` is a pure value built from `WhyAwakeInput` (unit-tested). The ⌥-click menu (`WhyAwakeMenu.make()`),
// Settings ▸ Diagnostics (table) and "Copy Report" / `insomnia why` (`text`, `cliRows`) all render the same report, so
// they can't disagree. Labels are plain in every personality.

struct WhyAwakeReport: Equatable {
    struct Row: Equatable, Identifiable {
        var id: String
        /// Table "Who" column: "You", "Rule", "Watching", "zoom.us", "SleepDisabled".
        var who: String
        /// Table "What" column: "1h timer · screen on · lid", "Preventing display sleep".
        var what: String
        /// The one-line menu title ("You · 1h timer · screen on · lid", "SleepDisabled: Yes (set by Insomnia)").
        var title: String
        var since: Date?
        /// Extra detail for tooltips and the copied report (an assertion's own name).
        var detail: String?
    }

    struct Section: Equatable, Identifiable {
        enum Kind: String, Equatable { case insomnia = "Insomnia", guards = "Guards", otherApps = "Other apps", system = "System" }
        var kind: Kind
        var rows: [Row]
        var id: String { kind.rawValue }
        var title: String { kind.rawValue }
    }

    static let title = "Why is my Mac awake?"
    static let nothingText = "Nothing. Your Mac is free to sleep."

    var headline: String
    /// Only sections with rows, in the order Insomnia, Guards, Other apps, System.
    var sections: [Section]
    /// No holds, guards or other apps' assertions: the menu says `nothingText` above the System section.
    var isNothing: Bool
    /// Footer lines for the copied report only (backend, versions).
    var footer: [String] = []

    func section(_ kind: Section.Kind) -> Section? { sections.first { $0.kind == kind } }

    /// Plain text for Copy Report and bug reports.
    func text(generatedAt date: Date) -> String {
        var lines = ["\(Self.title)  (\(Self.stampFormatter.string(from: date)))", headline, ""]
        if isNothing { lines += [Self.nothingText, ""] }
        for section in sections {
            lines.append(section.title)
            for row in section.rows {
                var line = "  " + row.title
                if let detail = row.detail, !detail.isEmpty { line += " — \"\(detail)\"" }
                if let since = row.since { line += "  (since \(Self.sinceText(since, now: date)))" }
                lines.append(line)
            }
        }
        if !footer.isEmpty { lines += [""] + footer }
        return lines.joined(separator: "\n")
    }

    /// Flat rows for `insomnia why` (M5 `WhyRow(section:who:what:)`).
    var cliRows: [(section: String, who: String, what: String)] {
        sections.flatMap { s in s.rows.map { (s.title, $0.who, $0.what) } }
    }

    /// "15:01" today, "Mon 15:01" this week, "2026-10-29 15:01" otherwise.
    static func sinceText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 6 {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
        }
        return date.formatted(date: .numeric, time: .shortened)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

/// Everything the report needs, as plain values (tests build these by hand; `live()` reads the app).
struct WhyAwakeInput {
    var headline = "Sleep allowed"
    var holds: [Hold] = []
    var rules: [Rule] = []
    var pausedRuleIDs: Set<Rule.ID> = []
    var guards: Set<GuardReason> = []
    var lid: LidStatus = .off
    var batteryFloor = 20
    var lidBatteryCapMinutes = 60
    var lidACCapMinutes = 240
    /// PIDs to show next to babysit targets ("ffmpeg (4411)").
    var matchedPIDs: [WatchTarget: Int32] = [:]
    var foreign: [ForeignAssertion] = []
    /// PIDs of apps (Dock and menu bar apps): shown by name only; other processes get "(pid)".
    var appPIDs: Set<Int32> = []
    /// IORegistry SleepDisabled; nil = unreadable.
    var sleepDisabled: Bool?
    /// true = ours, false = something else's, nil = unknown.
    var sleepDisabledByInsomnia: Bool?
    var hasLid = false
    var lidClosed = false
    var thermal: ProcessInfo.ThermalState = .nominal
    var hasBattery = false
    var batteryPercent: Int?
    var isOnAC = true
    var isCharging = false
    var lowPowerMode = false
    var footer: [String] = []
}

extension WhyAwakeReport {
    static func build(_ input: WhyAwakeInput) -> WhyAwakeReport {
        var sections: [Section] = []

        // Insomnia: our holds (manual, babysit, clients, rules), then rules the eyes paused.
        var ours = input.holds.map { holdRow($0, input) }
        for rule in input.rules where input.pausedRuleIDs.contains(rule.id) {
            ours.append(Row(id: "paused-\(rule.id)", who: "Rule", what: "\(rule.condition.phrase) · paused",
                            title: "Rule · \(rule.condition.phrase) · paused until it stops", since: nil))
        }
        if !ours.isEmpty { sections.append(Section(kind: .insomnia, rows: ours)) }

        // Guards: only the ones that change something right now.
        var guards: [Row] = []
        if input.guards.contains(.awakeBatteryFloor) {
            let what = "battery at \(input.batteryFloor)%"
            guards.append(Row(id: "guard-awakeBatteryFloor", who: "Paused keeping awake", what: what,
                              title: "Paused keeping awake · \(what)"))
        }
        if input.lid != .off {
            for g in Policy.lidGuardPriority where input.guards.contains(g) {
                let what = guardText(g, input)
                guards.append(Row(id: "guard-\(g.rawValue)", who: "Paused lid mode", what: what,
                                  title: "Paused lid mode · \(what)"))
            }
            if input.lid == .latched {
                guards.append(Row(id: "guard-latched", who: "Paused lid mode", what: "until the lid opens",
                                  title: "Paused lid mode · until the lid opens"))
            }
        }
        if !guards.isEmpty { sections.append(Section(kind: .guards, rows: guards)) }

        // Other apps: one row per (who, what); the earliest start wins.
        var others: [Row] = []
        var index: [String: Int] = [:]
        for a in input.foreign {
            let who = a.displayName(isApp: { input.appPIDs.contains($0) })
            let what = AssertionInspector.describe(type: a.type)
            let key = who + "\u{1F}" + what
            if let i = index[key] {
                if let s = a.since, s < (others[i].since ?? .distantFuture) { others[i].since = s }
                continue
            }
            index[key] = others.count
            others.append(Row(id: "foreign-\(a.id)", who: who, what: what, title: "\(who) · \(what)",
                              since: a.since, detail: a.name.isEmpty ? nil : a.name))
        }
        if !others.isEmpty { sections.append(Section(kind: .otherApps, rows: others)) }

        let isNothing = sections.isEmpty
        sections.append(Section(kind: .system, rows: systemRows(input)))
        return WhyAwakeReport(headline: input.headline, sections: sections, isNothing: isNothing, footer: input.footer)
    }

    // MARK: Rows

    private static func holdRow(_ hold: Hold, _ input: WhyAwakeInput) -> Row {
        var who: String
        var parts: [String]
        switch hold.owner {
        case .manual(let source):
            who = switch source {
            case .urlScheme: "Link"
            case .cli: "Command line"
            default: "You"
            }
            parts = [durationText(hold)]
        case .babysit(let target):
            who = "Watching"
            if case .process(let name) = target, let pid = input.matchedPIDs[target] {
                parts = ["\(name) (\(pid))"]
            } else {
                parts = [target.displayName]
            }
        case .client(_, let label):
            who = "Command"
            parts = ["\(label) (CLI)"]
        case .rule(let id):
            who = "Rule"
            parts = [input.rules.first { $0.id == id }?.condition.phrase ?? "rule"]
        }
        if hold.options.screen { parts.append("screen on") }
        if hold.options.lid && input.hasLid { parts.append("lid") }
        let what = parts.joined(separator: " · ")
        return Row(id: "hold-\(hold.id)", who: who, what: what, title: "\(who) · \(what)", since: hold.start)
    }

    /// "1h timer" for a preset length, "until 17:30" otherwise, "until you stop it" without an end.
    static func durationText(_ hold: Hold) -> String {
        guard let end = hold.end else { return "until you stop it" }
        let minutes = Int((end.timeIntervalSince(hold.start) / 60).rounded())
        if AwakeDuration.presets.contains(.minutes(minutes)) { return "\(AwakeDuration.minutes(minutes).shortLabel) timer" }
        return "until \(end.formatted(date: .omitted, time: .shortened))"
    }

    static func guardText(_ g: GuardReason, _ input: WhyAwakeInput) -> String {
        switch g {
        case .batteryFloor, .awakeBatteryFloor: return "battery at \(input.batteryFloor)%"
        case .thermal: return "running hot"
        case .lowPowerMode: return "Low Power Mode"
        case .acRequired: return "waiting for power adapter"
        case .lidBatteryCap: return "\(PlainCopy.capText(input.lidBatteryCapMinutes)) limit on battery"
        case .lidACCap: return "\(PlainCopy.capText(input.lidACCapMinutes)) limit on power"
        }
    }

    private static func systemRows(_ input: WhyAwakeInput) -> [Row] {
        let flag: String = switch (input.sleepDisabled, input.sleepDisabledByInsomnia) {
        case (nil, _): "Unknown"
        case (false?, _): "No"
        case (true?, true?): "Yes (set by Insomnia)"
        case (true?, false?): "Yes (set by something else)"
        case (true?, nil): "Yes"
        }
        var rows = [Row(id: "sys-flag", who: "SleepDisabled", what: flag, title: "SleepDisabled: \(flag)")]

        var parts: [String] = []
        if input.hasLid { parts.append("Lid: \(input.lidClosed ? "closed" : "open")") }
        parts.append("Thermal: \(thermalText(input.thermal))")
        parts.append(powerText(input, includeCharging: false))
        if input.lowPowerMode { parts.append("Low Power Mode") }
        let line = parts.joined(separator: " · ")
        rows.append(Row(id: "sys-power", who: "Power", what: line, title: line))

        if input.hasLid, let lid = lidText(input.lid) {
            rows.append(Row(id: "sys-lid", who: "Lid mode", what: lid, title: "Lid mode: \(lid)"))
        }
        return rows
    }

    static func thermalText(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// "AC · 95%", "Battery · 61%", "AC" (desktop). With charging: "AC · 95% · charging" / "not charging".
    static func powerText(_ input: WhyAwakeInput, includeCharging: Bool) -> String {
        guard input.hasBattery else { return "AC" }
        var parts = [input.isOnAC ? "AC" : "Battery"]
        if let p = input.batteryPercent { parts.append("\(p)%") }
        if includeCharging && input.isOnAC { parts.append(input.isCharging ? "charging" : "not charging") }
        return parts.joined(separator: " · ")
    }

    /// nil when lid mode isn't requested.
    static func lidText(_ lid: LidStatus) -> String? {
        switch lid {
        case .off: return nil
        case .needsSetup: return "needs setup"
        case .engaging: return "applying"
        case .engaged(let closed): return closed ? "engaged · lid closed" : "engaged"
        case .suspended: return "paused"
        case .latched: return "paused until the lid opens"
        case .error(.foreignFlag): return "another app turned sleep off"
        case .error(.otherUser): return "in use by another user"
        case .error: return "needs attention"
        case .stuck: return "stuck on"
        }
    }
}

// MARK: - Live input

extension WhyAwakeInput {
    /// Optional hook (M2): `{ ClosedLidController.shared.foreignSleepDisabled }`. Without it, ownership is inferred
    /// from the lid controller's status (engaged / applying / stuck = ours).
    @MainActor static var foreignSleepDisabledProvider: (@MainActor () -> Bool)?

    @MainActor
    static func live() -> WhyAwakeInput {
        let engine = AwakeEngine.shared
        let settings = Settings.shared
        let power = PowerMonitor.shared
        var input = WhyAwakeInput()
        input.headline = engine.narrator?.headline(status: engine.status, lid: engine.lid)
            ?? FallbackCopy.headline(status: engine.status, lid: engine.lid, batteryFloor: settings.batteryFloorPercent)
        input.holds = engine.holds
        input.rules = settings.rules
        input.pausedRuleIDs = engine.pausedRuleIDs
        input.guards = engine.guards
        input.lid = engine.lid
        input.batteryFloor = settings.batteryFloorPercent
        input.lidBatteryCapMinutes = settings.lidMaxOnBatteryMinutes
        input.lidACCapMinutes = settings.lidMaxOnACMinutes

        if let monitor = engine.watchMonitor as? WatchMonitor {
            for hold in engine.holds {
                if case .babysit(let target) = hold.owner, let pid = monitor.matchedPID(for: target) {
                    input.matchedPIDs[target] = pid
                }
            }
        }

        input.foreign = AssertionInspector.foreignAssertions()
        input.appPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }.map(\.processIdentifier))

        input.sleepDisabled = RootDomain.sleepDisabled()
        if input.sleepDisabled == true {
            if let provider = foreignSleepDisabledProvider {
                input.sleepDisabledByInsomnia = !provider()
            } else {
                switch engine.lidController?.status {
                case .engaged?, .engaging?, .stuck?: input.sleepDisabledByInsomnia = true
                default: input.sleepDisabledByInsomnia = engine.lidController == nil ? nil : false
                }
            }
        }

        input.hasLid = power.hasLid
        input.lidClosed = power.isLidClosed
        input.thermal = power.thermalState
        input.hasBattery = power.hasBattery
        input.batteryPercent = power.batteryPercent
        input.isOnAC = power.isOnAC
        input.isCharging = power.isCharging
        input.lowPowerMode = power.isLowPowerMode

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        var footer = ["Insomnia \(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        if let lc = engine.lidController {
            footer.append("Lid backend: \(lc.backendKind?.rawValue ?? "resolving") · \(HelperStatusText.short(lc.helper))")
        }
        input.footer = footer
        return input
    }
}

/// Plain wording for `HelperStatus` (Diagnostics, Copy Report). Lid & Safety (M2) owns the actionable copy.
enum HelperStatusText {
    static func short(_ h: HelperStatus) -> String {
        switch h {
        case .notInstalled: return "not set up"
        case .requiresApproval: return "waiting for approval in System Settings"
        case .versionMismatch: return "updating"
        case .notFound: return "missing from the app"
        case .unsafeLocation: return "not in /Applications (make install)"
        case .unreachable: return "not responding"
        case .leftoverHelper: return "a signed build's helper is still registered"
        case .partial(let sudoers, let daemon):
            return "partly installed (sudoers rule \(sudoers ? "✓" : "✗") · safety daemon \(daemon ? "✓" : "✗"))"
        case .daemonDisabled: return "safety daemon is off in Login Items"
        case .installed: return "ready"
        }
    }
}

// MARK: - The ⌥-click menu

@MainActor
enum WhyAwakeMenu {
    /// Builds the menu from a fresh live report. Rows are informational (disabled); the footer has
    /// Open Diagnostics… (when a Settings window exists) and Copy Report.
    static func make() -> NSMenu {
        make(report: WhyAwakeReport.build(.live()), now: Date())
    }

    static func make(report: WhyAwakeReport, now: Date) -> NSMenu {
        let menu = NSMenu(title: WhyAwakeReport.title)
        menu.autoenablesItems = false

        let header = NSMenuItem(title: WhyAwakeReport.title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if report.isNothing {
            let nothing = NSMenuItem(title: WhyAwakeReport.nothingText, action: nil, keyEquivalent: "")
            nothing.isEnabled = false
            menu.addItem(nothing)
        }
        for section in report.sections {
            menu.addItem(NSMenuItem.sectionHeader(title: section.title))
            for row in section.rows {
                let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.indentationLevel = 1
                var tip: [String] = []
                if let detail = row.detail { tip.append(detail) }
                if let since = row.since { tip.append("Since \(WhyAwakeReport.sinceText(since, now: now))") }
                if !tip.isEmpty { item.toolTip = tip.joined(separator: "\n") }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        if AppRouter.shared.openSettingsHandler != nil {
            menu.addItem(ActionItem("Open Diagnostics…") { AppRouter.shared.openSettings(.diagnostics) })
        }
        let text = report.text(generatedAt: now)
        menu.addItem(ActionItem("Copy Report") { copyToPasteboard(text) })
        return menu
    }

    /// Fresh live report as plain text.
    static func reportText() -> String {
        WhyAwakeReport.build(.live()).text(generatedAt: Date())
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A menu item that runs a closure (menus need an Objective-C target; the item is its own).
    @MainActor
    final class ActionItem: NSMenuItem {
        private var handler: (@MainActor () -> Void)?

        init(_ title: String, keyEquivalent: String = "", handler: @escaping @MainActor () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run(_:)), keyEquivalent: keyEquivalent)
            target = self
        }

        required init(coder: NSCoder) {
            super.init(coder: coder)
        }

        @objc private func run(_ sender: Any?) { handler?() }
    }
}
