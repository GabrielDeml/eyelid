import AppKit
import Foundation
import os

/// A parsed `insomnia://` URL (ARCHITECTURE.md "App/URLCommandHandler.swift"). Pure: parsing never touches state.
///
/// | Host       | Parameters                                                                  |
/// |------------|-----------------------------------------------------------------------------|
/// | `toggle`   | none                                                                        |
/// | `on`       | `for=45m|2h|90|1h30m|forever`, `until=HH:mm` (next occurrence), `screen=0|1` |
/// | `off`      | none                                                                        |
/// | `extend`   | `by=15m` (default 15 minutes)                                               |
/// | `sleep`    | none (asks first)                                                           |
/// | `panel`    | none                                                                        |
/// | `settings` | `tab=general|automations|lid|diagnostics`                                   |
///
/// Any web page can open `insomnia://`, so URL holds **never** get lid mode (Decision 10): `lid=` is ignored and logged,
/// and every `on` hold carries fixed options with `lid: false`. `sleep` asks for confirmation before it sleeps the Mac.
/// The URL scheme never writes Settings. Unknown hosts and parameters are ignored and logged (sanitised: the names are
/// the page's choice too).
struct URLCommand: Equatable, Sendable {
    enum When: Equatable, Sendable {
        /// `on` without `for`/`until`: Settings' default duration.
        case defaultDuration
        case minutes(Int)
        case forever
        /// Resolved to the next occurrence when handled (a past time means tomorrow).
        case until(hour: Int, minute: Int)
    }

    enum Action: Equatable, Sendable {
        case toggle
        case on(When, screen: Bool?)
        case off
        case extend(minutes: Int)
        case sleep
        case panel
        case settings(SettingsTab)
    }

    var action: Action
    /// Parameters that were present but ignored (unknown, malformed, or `lid`), for the event log.
    var ignored: [String] = []

    /// nil for a non-`insomnia` URL, an unknown host, or a malformed required value.
    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "insomnia",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // `insomnia://on?…` has host "on"; tolerate `insomnia:on?…` and `insomnia:///on` too.
        let host = (components.host?.isEmpty == false ? components.host : nil)
            ?? components.path.split(separator: "/").first.map(String.init)
        guard let verb = host?.lowercased() else { return nil }

        var params: [String: String] = [:]
        var ignored: [String] = []
        for item in components.queryItems ?? [] {
            let key = item.name.lowercased()
            if params[key] != nil { ignored.append(key); continue }   // first wins; duplicates are logged
            params[key] = item.value ?? ""
        }
        func take(_ key: String) -> String? { params.removeValue(forKey: key) }

        let action: Action
        switch verb {
        case "toggle":
            action = .toggle
        case "on":
            var when = When.defaultDuration
            if let value = take("until") {
                guard let t = ControlDuration.clock(value) else { return nil }
                when = .until(hour: t.hour, minute: t.minute)
                if take("for") != nil { ignored.append("for") }   // `until` wins over `for`
            } else if let value = take("for") {
                guard let w = parseDuration(value) else { return nil }
                when = w
            }
            var screen: Bool?
            if let value = take("screen") {
                if let b = parseBool(value) { screen = b } else { ignored.append("screen") }
            }
            if take("lid") != nil { ignored.append("lid") }   // never from a URL (Decision 10)
            action = .on(when, screen: screen)
        case "off":
            action = .off
        case "extend":
            var minutes = 15
            if let value = take("by") {
                guard case .minutes(let m)? = parseDuration(value) else { return nil }
                minutes = m
            }
            action = .extend(minutes: minutes)
        case "sleep":
            action = .sleep
        case "panel":
            action = .panel
        case "settings":
            var tab = SettingsTab.general
            if let value = take("tab") {
                if let t = parseTab(value) { tab = t } else { ignored.append("tab") }
            }
            action = .settings(tab)
        default:
            return nil
        }
        ignored += params.keys.sorted()
        return URLCommand(action: action, ignored: ignored)
    }

    // MARK: Value parsers (the CLI's: "45m", "2h", "90", "1h30m", "1h30", "1d", "forever"; "17:30", "0730")

    /// The CLI's parser with a 7-day cap; zero or negative is invalid. Any web page can send these values, so
    /// arithmetic saturates at the cap instead of overflowing.
    static func parseDuration(_ raw: String) -> When? {
        switch ControlDuration.parse(raw, cap: maxMinutes, saturating: true) {
        case .indefinite?: return .forever
        case .minutes(let m)?: return .minutes(m)
        default: return nil
        }
    }

    static let maxMinutes = 7 * 24 * 60

    static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    static func parseTab(_ raw: String) -> SettingsTab? {
        switch raw.lowercased() {
        case "general": return .general
        case "automations", "rules", "cli": return .automations
        case "lid", "lidsafety", "lid-safety", "safety": return .lidSafety
        case "diagnostics", "why", "log": return .diagnostics
        default: return SettingsTab(rawValue: raw)
        }
    }
}

/// Runs a parsed command against the engine. Source is always `.urlScheme`.
@MainActor
enum URLCommandHandler {
    private static let log = Logger(subsystem: "com.gdeml.Insomnia", category: "url")

    static func handle(_ url: URL, settings: Settings = .shared, engine: AwakeEngine = .shared,
                       confirmSleep: @MainActor () -> Bool = askToSleep) {
        guard let command = URLCommand.parse(url) else {
            record("ignored \(redacted(url))", engine)
            return
        }
        if !command.ignored.isEmpty {
            record("\(LogText.oneLine(url.host ?? "?", limit: 40)): ignored \(names(command.ignored, separator: ", "))", engine)
        }
        perform(command, settings: settings, engine: engine, confirmSleep: confirmSleep)
    }

    /// `confirmSleep`: any web page can open `insomnia://sleep`, so it asks before sleeping (tests answer for it).
    static func perform(_ command: URLCommand, settings: Settings, engine: AwakeEngine, now: Date = Date(),
                        confirmSleep: @MainActor () -> Bool = askToSleep) {
        // Fixed options for a hold a URL starts; unset fields come from Settings now. Never lid (Decision 10).
        let noLid = AwakeOptions(screen: settings.keepScreenOn, lid: false)
        switch command.action {
        case .toggle:
            engine.toggle(source: .urlScheme, options: noLid)
        case .on(let when, let screen):
            let duration: AwakeDuration
            switch when {
            case .defaultDuration: duration = settings.defaultDuration
            case .minutes(let m): duration = .minutes(m)
            case .forever: duration = .indefinite
            case .until(let h, let m): duration = AwakeDuration.nextOccurrence(hour: h, minute: m, after: now)
            }
            // Fixed options for this hold only; unset fields come from Settings now. Never lid (Decision 10).
            let options = AwakeOptions(screen: screen ?? settings.keepScreenOn, lid: false)
            engine.activate(duration, source: .urlScheme, options: options)
            record("on \(duration.shortLabel)\(screen.map { $0 ? " screen" : " no-screen" } ?? "")", engine)
        case .off:
            engine.deactivate(.user(.urlScheme))
            record("off", engine)
        case .extend(let minutes):
            engine.extend(minutes: minutes, source: .urlScheme, options: noLid)
            record("extend +\(minutes)m", engine)
        case .sleep:
            guard confirmSleep() else {
                record("sleep now: declined", engine)
                return
            }
            record("sleep now", engine)
            Task { await engine.sleepNow() }
        case .panel:
            AppRouter.shared.showPanel()
        case .settings(let tab):
            AppRouter.shared.openSettings(tab)
        }
    }

    /// The confirmation for `insomnia://sleep`.
    static func askToSleep() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Put your Mac to sleep now?"
        alert.informativeText = "A link (insomnia://sleep) asked for it. Your Mac sleeps even if something is keeping it awake."
        alert.addButton(withTitle: "Sleep")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func record(_ message: String, _ engine: AwakeEngine) {
        let line = LogText.oneLine(message, limit: 300)   // belt and braces: never more than one log line
        log.info("\(line, privacy: .public)")
        engine.eventLog?.log("url", line)
    }

    /// Host + parameter names only: query values could be anything a web page put there. So could the names and the
    /// host, so they are made one short line each.
    static func redacted(_ url: URL) -> String {
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        return "\(LogText.oneLine(url.scheme ?? "?", limit: 40))://\(LogText.oneLine(url.host ?? "", limit: 40))"
            + (names.isEmpty ? "" : "?" + Self.names(names, separator: "&"))
    }

    /// Untrusted parameter names for the log: at most 5, each one line of at most 40 characters, then "+N more".
    static func names(_ names: [String], separator: String) -> String {
        let shown = names.prefix(5).map { name -> String in
            let clean = LogText.oneLine(name, limit: 40)
            return clean.isEmpty ? "\"\"" : clean
        }
        return shown.joined(separator: separator) + (names.count > 5 ? " +\(names.count - 5) more" : "")
    }
}
