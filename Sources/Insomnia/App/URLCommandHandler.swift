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
/// | `sleep`    | none                                                                        |
/// | `panel`    | none                                                                        |
/// | `settings` | `tab=general|automations|lid|diagnostics`                                   |
///
/// Any web page can open `insomnia://`, so URL holds **never** get lid mode (Decision 10): `lid=` is ignored and logged,
/// and every `on` hold carries fixed options with `lid: false`. The URL scheme never writes Settings. Unknown hosts and
/// parameters are ignored and logged.
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
                guard let t = parseClock(value) else { return nil }
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

    // MARK: Value parsers (shared shapes with the CLI: "45m", "2h", "90", "1h30m", "forever")

    /// Minutes are capped at 7 days; zero or negative is invalid. Any web page can send these values, so arithmetic
    /// saturates at the cap instead of overflowing.
    static func parseDuration(_ raw: String) -> When? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if ["forever", "indefinite", "infinite", "inf", "∞"].contains(s) { return .forever }
        if !s.isEmpty, s.allSatisfy(\.isASCIIDigitChar) { return clampMinutes(saturatingNumber(s)) }
        // Sequence of <number><unit>, units h / m (also "hr", "min", "mins").
        var total = 0
        var digits = ""
        var sawUnit = false
        var rest = Substring(s)
        func add(_ n: Int, times scale: Int) { total = min(total + n * scale, maxMinutes + 1) }
        while let c = rest.first {
            if c.isASCIIDigitChar {
                digits.append(c)
                rest = rest.dropFirst()
                continue
            }
            guard !digits.isEmpty else { return nil }
            let n = saturatingNumber(digits)
            digits = ""
            if rest.hasPrefix("hours") || rest.hasPrefix("hour") || rest.hasPrefix("hrs") || rest.hasPrefix("hr") || rest.hasPrefix("h") {
                add(n, times: 60)
                rest = rest.drop { $0.isLetter }
            } else if rest.hasPrefix("minutes") || rest.hasPrefix("minute") || rest.hasPrefix("mins") || rest.hasPrefix("min") || rest.hasPrefix("m") {
                add(n, times: 1)
                rest = rest.drop { $0.isLetter }
            } else {
                return nil
            }
            sawUnit = true
        }
        if !digits.isEmpty {
            guard sawUnit else { return nil }
            add(saturatingNumber(digits), times: 1)   // "1h30" → trailing minutes
        }
        return sawUnit ? clampMinutes(total) : nil
    }

    private static let maxMinutes = 7 * 24 * 60

    /// ASCII digits → Int, saturating at 10,000,000 (anything that long is past the cap anyway).
    private static func saturatingNumber(_ digits: String) -> Int {
        guard digits.count <= 7, let n = Int(digits) else { return 10_000_000 }
        return n
    }

    private static func clampMinutes(_ m: Int) -> When? {
        guard m > 0 else { return nil }
        return .minutes(min(m, maxMinutes))
    }

    /// "17:30", "7:05", "0730" → (17, 30). 24-hour clock.
    static func parseClock(_ raw: String) -> (hour: Int, minute: Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let parts: [Substring]
        if s.contains(":") {
            parts = s.split(separator: ":", omittingEmptySubsequences: false)
        } else if s.count == 4, s.allSatisfy(\.isNumber) {
            parts = [s.prefix(2), s.suffix(2)]
        } else {
            return nil
        }
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), parts[1].count == 2,
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }

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

    static func handle(_ url: URL) {
        guard let command = URLCommand.parse(url) else {
            record("ignored \(redacted(url))")
            return
        }
        if !command.ignored.isEmpty {
            record("\(url.host ?? "?"): ignored \(command.ignored.joined(separator: ", "))")
        }
        perform(command, settings: .shared, engine: .shared)
    }

    static func perform(_ command: URLCommand, settings: Settings, engine: AwakeEngine, now: Date = Date()) {
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
            record("sleep now", engine)
            Task { await engine.sleepNow() }
        case .panel:
            AppRouter.shared.showPanel()
        case .settings(let tab):
            AppRouter.shared.openSettings(tab)
        }
    }

    private static func record(_ message: String, _ engine: AwakeEngine = .shared) {
        log.info("\(message, privacy: .public)")
        engine.eventLog?.log("url", message)
    }

    /// Host + parameter names only: query values could be anything a web page put there.
    private static func redacted(_ url: URL) -> String {
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        return "\(url.scheme ?? "?")://\(url.host ?? "")" + (names.isEmpty ? "" : "?" + names.joined(separator: "&"))
    }
}

private extension Character {
    var isASCIIDigitChar: Bool { isASCII && isNumber }
}
