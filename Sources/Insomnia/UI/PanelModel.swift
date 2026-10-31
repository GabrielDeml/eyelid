import AppKit
import Observation
import SwiftUI

// MARK: - What the panel shows (a pure value) and what it can ask for (actions)
//
// PanelView renders only from `PanelState` and only talks back through `PanelAction`, so the same view serves the live
// app (state derived from AwakeEngine / Settings / PowerMonitor) and `--snapshot` (fixed states, actions ignored,
// nothing touches power management).

struct PanelBanner: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case info, warning, danger, success }
    var symbol: String
    var text: String
    var tone: Tone
}

struct PanelState: Equatable {
    var status: AwakeStatus = .asleep
    var lid: LidStatus = .off
    var mood: EyeMood = .asleep
    var now = Date()
    /// Manual timed hold only.
    var remaining: TimeInterval?
    /// 0…1 elapsed of a manual timed hold.
    var progress: Double?
    /// The preset chip that matches the running manual hold (filled amber), if any.
    var selectedPreset: AwakeDuration?
    /// Only CLI client holds remain: the eyes are disabled ("Held by a command").
    var clientOnly = false
    /// Holds beyond the primary one ("· 2 more ›").
    var extraHolds = 0
    /// "Xcode rule paused until Xcode quits" (rules paused by the eyes while asleep).
    var pausedRuleSummary: String?
    var hasLid = false
    var keepScreenOn = true
    var closedLidMode = false
    /// The privileged backend's readiness. Without a lid controller (M1) it is `.notInstalled`, exactly as the engine
    /// treats it, so the switch and H′ never promise lid mode that can't engage.
    var helper: HelperStatus = .notInstalled
    /// Settings… is available (a Settings window handler is wired; false only in bare snapshots).
    var canOpenSettings = true
    /// A fixed-options manual hold (CLI flags / URL) without lid is running: H′ "Off for this session".
    var fixedHoldWithoutLid = false
    var personality: Personality = .cheeky
    var quip: String?
    var banner: PanelBanner?
    /// Lid reopened after a long closed run: row J shows the mission report card instead of the plain banner.
    var reopenReport: ReopenReport?
    /// Continuous awake time (eye bags at 24 h / 72 h).
    var awakeFor: TimeInterval = 0
    var batteryFloor = 20
    var lidBatteryCapMinutes = 60
    var lidACCapMinutes = 240

    var isAwake: Bool { status.isAwake }
    var isTimed: Bool { if case .timed = status { return true } else { return false } }
    var isLidEngaged: Bool { if case .engaged = lid { return true } else { return false } }
    var heavyLids: Bool { isTimed && (remaining ?? .infinity) <= 60 }
    var bags: Int { !isAwake ? 0 : (awakeFor >= 72 * 3600 ? 2 : (awakeFor >= 24 * 3600 ? 1 : 0)) }
    /// The lid switch position (UX §5): off while setup is missing; otherwise the setting.
    var lidToggleOn: Bool { closedLidMode && helper == .installed && lid != .needsSetup }
}

enum PanelAction: Equatable {
    case eyes
    case start(AwakeDuration)
    case extend
    case setScreen(Bool)
    case setLid(Bool)
    case stopBabysit
    case babysit(WatchTarget)
    case sleepNow
    case whyAwake
    case settings(SettingsTab)
    case about
    case quit
    case dismissBanner
    case lidSetup
    case lidRetry
    case lidReset
    case closePanel
}

/// The panel's view model: current state + transient UI state (popovers, animation cues).
@MainActor
@Observable
final class PanelModel {
    @ObservationIgnored private let provider: () -> PanelState
    @ObservationIgnored private let clockFreeProvider: (() -> PanelState)?
    @ObservationIgnored private let handler: (PanelAction) -> Void
    /// Builds the While… menu (`WhileMenu.provider(for:)`: running apps, suggested processes, name / PID prompts).
    @ObservationIgnored var whileMenuProvider: (() -> NSMenu)?
    /// NSView the While… chip pops its menu from.
    @ObservationIgnored weak var whileAnchor: NSView?

    var state: PanelState { provider() }
    /// `state` without reading the display clock: `now`, `remaining`, `progress` and `awakeFor` are not current.
    /// For the parts of the panel that don't show them, so the 1 Hz tick doesn't re-render the whole panel.
    var layoutState: PanelState { clockFreeProvider?() ?? provider() }

    /// The panel window is on screen: the eyes animate only then.
    var isVisible = false
    var showUntil = false
    var cues = EyesCues()
    /// Set when the lid switch was flipped on but setup is missing and no setup flow is available yet.
    var lidSetupNudge = false
    /// Which kind of control has keyboard focus (mirrored from the view's FocusState for the key handler).
    @ObservationIgnored var focus: PanelFocus?

    @ObservationIgnored private var pokes: [Date] = []

    init(provider: @escaping () -> PanelState, clockFreeProvider: (() -> PanelState)? = nil,
         handler: @escaping (PanelAction) -> Void) {
        self.provider = provider
        self.clockFreeProvider = clockFreeProvider
        self.handler = handler
    }

    /// A static model for snapshots and previews: never touches the engine.
    static func fixed(_ state: PanelState) -> PanelModel {
        PanelModel(provider: { state }, handler: { _ in })
    }

    func send(_ action: PanelAction) {
        switch action {
        case .eyes:
            countPoke()
        case .extend:
            cues.extend += 1
        case .setLid(true):
            if state.helper != .installed {
                // UX §2.2 H: with the helper missing, turning the switch on opens setup instead of writing the setting.
                // Without a setup flow (bare snapshots) the sublabel says "Setup needed ›".
                if AppRouter.shared.startLidSetupHandler != nil { AppRouter.shared.startLidSetup(requestedLid: true) } else { lidSetupNudge = true }
                return
            }
        case .setLid(false):
            lidSetupNudge = false
        default: break
        }
        handler(action)
    }

    func presentWhileMenu() {
        guard let anchor = whileAnchor else { return }
        let menu = whileMenuProvider?() ?? PanelModel.stubWhileMenu()
        let y = anchor.isFlipped ? anchor.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: anchor)
    }

    /// UX §2.5 single-key shortcuts. Returns true if handled. The host skips this while a text field is first responder.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 36, 76:                                           // Return / Enter
            // Only when the eyes or nothing has focus: a focused control, or the welcome card's default "Got it",
            // gets the key instead.
            guard !EpicMoments.shared.welcomeVisible, focus == nil || focus == .eyes else { return false }
            send(.eyes); return true
        case 53: send(.closePanel); return true                // Esc
        default: break
        }
        guard let ch = event.charactersIgnoringModifiers?.lowercased(), ch.count == 1 else { return false }
        let s = state
        switch ch {
        case "1", "2", "3", "4", "5", "6":
            guard let i = Int(ch), AwakeDuration.presets.indices.contains(i - 1) else { return false }
            send(.start(AwakeDuration.presets[i - 1])); return true
        case "u": showUntil = true; return true
        case "w": presentWhileMenu(); return true
        case "=", "+": send(.extend); return true
        case "s": send(.setScreen(!s.keepScreenOn)); return true
        case "l":
            guard s.hasLid else { return false }
            send(.setLid(!s.lidToggleOn)); return true
        default: return false
        }
    }

    /// Poke egg (UX §9): 5+ clicks within 8 s. The engine owns the lines; the eyes cross at 20.
    private func countPoke() {
        let now = Date()
        pokes = pokes.filter { now.timeIntervalSince($0) < 8 } + [now]
        if pokes.count == 20, state.personality != .professional { cues.crossEyes += 1 }
    }

    private static func stubWhileMenu() -> NSMenu {
        let menu = NSMenu(title: "While…")
        let apps = NSMenuItem(title: "Running apps", action: nil, keyEquivalent: "")
        apps.isEnabled = false
        menu.addItem(apps)
        for title in ["Suggested", "Process name…", "PID…"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }
}

// MARK: - Plain copy (UX.md §5, §8; PRODUCT.md §5). Labels and headlines are plain in every tier.
// Narrator delegates its plain surfaces to these, so the panel, status item, Dock and CLI all say the same words.

enum PlainCopy {
    static func headline(_ s: PanelState) -> String {
        FallbackCopy.headline(status: s.status, lid: s.lid, batteryFloor: s.batteryFloor)
    }

    enum Tone: Equatable { case secondary, warning, danger }

    /// An action inside a subline or sublabel ("Stop", "Retry", "2 more ›"). Rendered as a real button (Tab-reachable,
    /// its own VoiceOver label), never as a link run inside one Text.
    struct InlineLink: Equatable {
        var title: String
        var action: PanelAction
        /// VoiceOver label, e.g. "Stop watching ffmpeg" (UX §12).
        var accessibilityLabel: String
    }

    struct Subline: Equatable {
        /// Plain text before the link ("While ffmpeg (4411) runs"); may be empty.
        var text: String
        var tone: Tone
        var link: InlineLink?
        /// "2 more ›" (opens Why awake). Kept apart so the view can put it on its own line instead of wrapping mid-phrase.
        var more: InlineLink?

        /// One line of plain text: "… · Stop · 2 more ›" (tooltips, the Dock header, the CLI).
        var joined: String { [text, link?.title, more?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
    }

    /// Lid error/stuck follow UX §8; the Retry link lives in H′ only, so it never shows twice.
    static func subline(_ s: PanelState) -> Subline {
        switch s.lid {
        case .stuck:
            return Subline(text: "Your Mac won't sleep", tone: .danger,
                           link: InlineLink(title: "Reset with password…", action: .lidReset,
                                            accessibilityLabel: "Reset sleep with your password"))
        case .error(let e) where e.alarms:
            return Subline(text: "Mac sleeps normally", tone: .danger)
        default: break
        }
        var text: String
        var tone = Tone.secondary
        var link: InlineLink?
        switch s.status {
        case .asleep:
            text = s.pausedRuleSummary ?? "Click the eyes to stay awake"
        case .timed(let end):
            let r = s.remaining ?? max(0, end.timeIntervalSince(s.now))
            let left = r <= 3600 ? TimeFormat.countdown(r) : longRemaining(r)
            text = "\(left) left · until \(TimeFormat.endTime(end, now: s.now))"
        case .indefinite:
            text = "Until you say so"
        case .watching(let t):
            text = "While \(t.displayName) runs"
            link = InlineLink(title: "Stop", action: .stopBabysit, accessibilityLabel: "Stop watching \(shortName(t))")
        case .client(let label):
            text = "Held by \(label) (CLI)"
        case .automatic:
            text = "Rule"
            link = InlineLink(title: "edit in Settings", action: .settings(.automations),
                              accessibilityLabel: "Edit rules in Settings")
        case .suspended:
            text = "Plug in to resume"
            tone = .warning
        }
        let more = s.extraHolds > 0 && s.isAwake
            ? InlineLink(title: "\(s.extraHolds) more ›", action: .whyAwake,
                         accessibilityLabel: "\(s.extraHolds) more hold\(s.extraHolds == 1 ? "" : "s"), why awake")
            : nil
        return Subline(text: text, tone: tone, link: link, more: more)
    }

    struct Sublabel: Equatable {
        /// Plain text before the link; may be empty.
        var text: String
        var tone: Tone
        var spinner = false
        var link: InlineLink?

        var joined: String { [text, link?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
    }

    /// H′ wording per `LidStatus` (UX §5). nil = silent (the slot stays, empty).
    static func lidSublabel(_ s: PanelState, nudge: Bool) -> Sublabel? {
        func sec(_ t: String) -> Sublabel { Sublabel(text: t, tone: .secondary) }
        func warn(_ t: String) -> Sublabel { Sublabel(text: t, tone: .warning) }
        let retry = InlineLink(title: "Retry", action: .lidRetry, accessibilityLabel: "Retry lid mode")
        switch s.lid {
        case .off:
            // The switch can't be on without setup (UX §5): say what's missing rather than "Armed".
            if nudge || (s.closedLidMode && s.helper != .installed) {
                return setupSublabel(s.helper)
            }
            guard s.closedLidMode else { return nil }
            if !s.isAwake { return sec("Armed · applies whenever I'm awake") }
            if s.fixedHoldWithoutLid { return sec("Off for this session") }
            return nil
        case .needsSetup:
            return setupSublabel(s.helper)
        case .engaging:
            return Sublabel(text: "Applying…", tone: .secondary, spinner: true)
        case .engaged(let closed):
            return sec(closed ? "Engaged · lid closed" : "Ready · close the lid anytime")
        case .suspended(let g):
            switch g {
            case .thermal: return warn("Paused · running hot")
            case .lowPowerMode: return warn("Paused · Low Power Mode")
            case .batteryFloor, .awakeBatteryFloor: return warn("Paused · battery at \(s.batteryFloor)%")
            case .acRequired: return sec("Waiting for power adapter")
            case .lidBatteryCap: return sec("Paused · \(capText(s.lidBatteryCapMinutes)) limit on battery")
            case .lidACCap: return sec("Paused · \(capText(s.lidACCapMinutes)) limit on power")
            }
        case .latched:
            return sec("Paused · open the lid to resume")
        case .error(.foreignFlag):
            return Sublabel(text: "Another app already turned sleep off", tone: .secondary,
                            link: InlineLink(title: "Why? ›", action: .whyAwake, accessibilityLabel: "Why is sleep off?"))
        case .error(.otherUser):
            return sec("Another user on this Mac is using lid mode")
        case .error(.overridden):
            return Sublabel(text: "Turned off by something else", tone: .danger, link: retry)
        case .error:
            return Sublabel(text: "Couldn't apply · Mac sleeps normally", tone: .danger, link: retry)
        case .stuck:
            return Sublabel(text: "Stuck on · Mac won't sleep", tone: .danger,
                            link: InlineLink(title: "Reset with password…", action: .lidReset,
                                             accessibilityLabel: "Reset sleep with your password"))
        }
    }

    /// H′ while setup is missing, by helper state (UX §5 `.needsSetup` rows).
    private static func setupSublabel(_ helper: HelperStatus) -> Sublabel {
        let fix = InlineLink(title: "Fix ›", action: .settings(.lidSafety), accessibilityLabel: "Fix lid mode in Settings")
        switch helper {
        case .requiresApproval:
            return Sublabel(text: "", tone: .secondary,
                            link: InlineLink(title: "Allow in System Settings ›", action: .lidSetup,
                                             accessibilityLabel: "Allow lid mode in System Settings"))
        case .unreachable, .notFound, .versionMismatch:
            return Sublabel(text: "Helper isn't responding", tone: .secondary, link: fix)
        case .unsafeLocation:
            return Sublabel(text: "Install in Applications to use", tone: .secondary,
                            link: InlineLink(title: "Why? ›", action: .settings(.lidSafety),
                                             accessibilityLabel: "Why lid mode needs Applications"))
        case .leftoverHelper:
            return Sublabel(text: "Old helper still registered", tone: .secondary, link: fix)
        case .daemonDisabled, .partial:
            return Sublabel(text: "Safety daemon is off", tone: .secondary, link: fix)
        case .notInstalled, .installed:
            return Sublabel(text: "", tone: .secondary,
                            link: InlineLink(title: "Setup needed ›", action: .lidSetup, accessibilityLabel: "Set up lid mode"))
        }
    }

    /// The VoiceOver value for the status item (UX §8). Plain in every tier; never per-second.
    static func accessibilityValue(_ s: PanelState) -> String {
        switch s.lid {
        case .stuck: return "Lid mode stuck on, Mac won't sleep"
        case .error(let e) where e.alarms: return "Lid mode failed, sleep works normally"
        default: break
        }
        var v: String
        switch s.status {
        case .asleep: v = s.pausedRuleSummary == nil ? "Sleep allowed" : "Sleep allowed, rules paused"
        case .timed: v = "Awake, \(spokenRemaining(s.remaining ?? 0)) left"
        case .indefinite: v = "Awake until you stop it"
        case .watching(let t): v = "Awake while \(shortName(t)) runs"
        case .client(let label): v = "Awake while \(label) runs"
        case .automatic(let c): v = "Awake, rule: \(c.first?.phrase ?? "active")"
        case .suspended: return "Paused, battery at \(s.batteryFloor) percent"
        }
        switch s.lid {
        case .engaged: v += ", lid mode on"
        case .suspended(let g): v += ", lid mode paused: \(guardPhrase(g, s))"
        case .latched: v += ", lid mode paused: open the lid to resume"
        default: break
        }
        return v
    }

    /// Eyes button value (UX §12): "On, 42 minutes left" / "On, rule: Xcode is running" / "Off".
    static func eyesValue(_ s: PanelState) -> String {
        switch s.status {
        case .asleep, .suspended: return "Off"
        case .timed: return "On, \(spokenRemaining(s.remaining ?? 0)) left"
        case .indefinite: return "On, until you stop it"
        case .watching(let t): return "On, while \(shortName(t)) runs"
        case .client(let label): return "On, held by \(label)"
        case .automatic(let c): return "On, rule: \(c.first?.phrase ?? "active")"
        }
    }

    /// Chip tooltips (Cheeky & Unhinged only; PRODUCT.md §5). nil in Professional.
    static func durationName(_ d: AwakeDuration, _ p: Personality) -> String? {
        guard p != .professional else { return nil }
        switch d {
        case .minutes(30): return "A pomodoro with ambition"
        case .minutes(60): return "A meeting and its follow-up"
        case .minutes(120): return "A Nolan film"
        case .minutes(240): return "Render o'clock"
        case .minutes(480): return "Night shift"
        case .minutes(47): return p == .unhinged ? "One more episode" : nil
        case .indefinite: return "Until the heat death of the universe"
        default: return nil
        }
    }

    /// Chip VoiceOver labels: "30 minutes", "1 hour", "Until I stop".
    static func spokenDuration(_ d: AwakeDuration) -> String {
        switch d {
        case .indefinite: return "Until I stop"
        case .minutes(let m): return spokenRemaining(TimeInterval(m * 60))
        case .until(let date): return "Until \(TimeFormat.endTime(date))"
        }
    }

    static func banner(_ b: Banner, _ s: PanelState) -> PanelBanner {
        switch b {
        case .batteryFloor(let p):
            return PanelBanner(symbol: "battery.25percent", text: "Lid mode off at \(p)% battery", tone: .warning)
        case .guardTripped(let g):
            let symbol = switch g {
            case .thermal: "thermometer.high"
            case .lowPowerMode: "leaf"
            case .acRequired: "powerplug"
            case .lidBatteryCap, .lidACCap: "timer"
            case .batteryFloor, .awakeBatteryFloor: "battery.25percent"
            }
            let text = switch g {
            case .thermal: "Lid mode paused: Mac is hot"
            case .lowPowerMode: "Lid mode paused: Low Power Mode"
            case .acRequired: "Lid mode waits for the power adapter"
            case .lidBatteryCap: "Lid mode paused after \(capText(s.lidBatteryCapMinutes)) closed on battery"
            case .lidACCap: "Lid mode paused after \(capText(s.lidACCapMinutes)) closed"
            case .batteryFloor: "Lid mode off at \(s.batteryFloor)% battery"
            case .awakeBatteryFloor: "Stopped keeping awake at \(s.batteryFloor)% battery"
            }
            return PanelBanner(symbol: symbol, text: text, tone: g.squints ? .warning : .info)
        case .recovered:
            return PanelBanner(symbol: "arrow.counterclockwise", text: "Restored normal sleep after an unexpected quit.", tone: .info)
        case .reopen(let r):
            var parts = ["While you were away: \(TimeFormat.compact(r.closedFor)) closed"]
            if let a = r.batteryStart, let b = r.batteryEnd { parts.append("battery \(a)→\(b)%") }
            let thermal = switch r.worstThermal {
            case .nominal: "stayed cool"
            case .fair: "got warm"
            default: "got hot"
            }
            parts.append(thermal)
            return PanelBanner(symbol: "moon.stars", text: parts.joined(separator: " · "), tone: .info)
        case .lidBatteryCallout:
            let text = s.personality == .professional
                ? "Keep the Mac ventilated while the lid is closed." : "Don't put me in a bag. Seriously."
            return PanelBanner(symbol: "exclamationmark.triangle", text: text, tone: .warning)
        case .setupResult(let text):
            return PanelBanner(symbol: "checkmark.circle", text: text, tone: .success)
        }
    }

    // MARK: Helpers

    static func shortName(_ t: WatchTarget) -> String { FallbackCopy.shortName(t) }

    static func capText(_ minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) h" : (minutes > 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")
    }

    private static func longRemaining(_ r: TimeInterval) -> String {
        let m = Int((r / 60).rounded(.up)), h = m / 60, mm = m % 60
        return mm == 0 ? "\(h) h" : "\(h) h \(mm) min"
    }

    static func spokenRemaining(_ r: TimeInterval) -> String {
        let m = max(1, Int((r / 60).rounded(.up))), h = m / 60, mm = m % 60
        func unit(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        if h == 0 { return unit(mm, "minute") }
        return mm == 0 ? unit(h, "hour") : unit(h, "hour") + " " + unit(mm, "minute")
    }

    private static func guardPhrase(_ g: GuardReason, _ s: PanelState) -> String {
        switch g {
        case .thermal: return "running hot"
        case .lowPowerMode: return "Low Power Mode"
        case .batteryFloor, .awakeBatteryFloor: return "battery at \(s.batteryFloor) percent"
        case .acRequired: return "waiting for power adapter"
        case .lidBatteryCap: return "\(capText(s.lidBatteryCapMinutes)) limit on battery"
        case .lidACCap: return "\(capText(s.lidACCapMinutes)) limit on power"
        }
    }

}

// MARK: - Live adapter (AwakeEngine, Settings, PowerMonitor)

extension PanelModel {
    /// Reads observable sources inside `state`, so SwiftUI re-renders exactly when they change.
    static func live() -> PanelModel {
        PanelModel(provider: { LivePanelState.make() }, clockFreeProvider: { LivePanelState.make(clock: false) },
                   handler: { LivePanelState.perform($0) })
    }
}

@MainActor
enum LivePanelState {
    /// `clock: false` skips every read of the engine's display clock (`now`, `remaining`, `progress`, awake time), so
    /// an observer of the result isn't invalidated by the 1 Hz tick.
    static func make(clock: Bool = true) -> PanelState {
        let engine = AwakeEngine.shared
        let settings = Settings.shared
        let power = PowerMonitor.shared
        var s = PanelState()
        s.status = engine.status
        s.lid = engine.lid
        s.mood = engine.mood
        if clock {
            s.now = engine.now
            s.remaining = engine.remaining
            s.progress = engine.progress
        }
        s.quip = engine.quip
        s.hasLid = power.hasLid
        s.keepScreenOn = settings.keepScreenOn
        s.closedLidMode = settings.closedLidMode
        s.personality = settings.personality
        s.batteryFloor = settings.batteryFloorPercent
        s.lidBatteryCapMinutes = settings.lidMaxOnBatteryMinutes
        s.lidACCapMinutes = settings.lidMaxOnACMinutes
        s.helper = engine.lidController?.helper ?? .notInstalled   // the engine's own fallback (M1: no controller)
        s.canOpenSettings = AppRouter.shared.openSettingsHandler != nil

        let holds = engine.holds
        if let manual = engine.manualHold {
            s.selectedPreset = preset(matching: manual)
            s.fixedHoldWithoutLid = !manual.followsSettings && !manual.options.lid
        }
        s.clientOnly = engine.isHeldOnlyByClients
        s.extraHolds = max(0, holds.count - 1)
        if clock, s.isAwake, let since = engine.awakeSince { s.awakeFor = s.now.timeIntervalSince(since) }
        if !s.isAwake {
            let paused = settings.rules.filter { engine.pausedRuleIDs.contains($0.id) }
            if let first = paused.first { s.pausedRuleSummary = pausedSummary(first.condition) }
        }
        if let b = engine.banner { s.banner = PlainCopy.banner(b, s) }
        if case .reopen(let r)? = engine.banner { s.reopenReport = r }
        return s
    }

    static func perform(_ action: PanelAction) {
        let engine = AwakeEngine.shared
        let settings = Settings.shared
        switch action {
        case .eyes:
            engine.toggle(source: .panel)
            engine.poke()
        case .start(let d): engine.activate(d, source: .panel)
        case .extend: engine.extend(minutes: 15)
        case .setScreen(let on): settings.keepScreenOn = on
        case .setLid(let on): settings.closedLidMode = on
        case .stopBabysit: engine.releaseBabysit()
        case .babysit(let t): engine.babysit(t)
        case .sleepNow: Task { await engine.sleepNow() }
        case .whyAwake: AppRouter.shared.showWhyAwake()
        case .settings(let tab): AppRouter.shared.openSettings(tab)
        case .about:
            AppRouter.shared.closePanel()
            if AppRouter.shared.showAboutHandler != nil { AppRouter.shared.showAbout() } else {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        case .quit: AppRouter.shared.quit()
        case .dismissBanner: engine.dismissBanner()
        case .lidSetup:
            if AppRouter.shared.startLidSetupHandler != nil { AppRouter.shared.startLidSetup() } else { AppRouter.shared.openSettings(.lidSafety) }
        case .lidRetry: ClosedLidController.shared.retry()
        case .lidReset: Task { await ClosedLidController.shared.resetWithPassword() }
        case .closePanel: AppRouter.shared.closePanel()
        }
    }

    private static func preset(matching hold: Hold) -> AwakeDuration? {
        guard let end = hold.end else { return .indefinite }
        let minutes = Int((end.timeIntervalSince(hold.start) / 60).rounded())
        return AwakeDuration.presets.first { $0 == .minutes(minutes) }
    }

    private static func pausedSummary(_ c: RuleCondition) -> String {
        switch c {
        case .app(_, let name), .process(let name): return "\(name) rule paused until \(name) quits"
        case .onAC: return "Power adapter rule paused until you unplug"
        case .externalDisplay: return "Display rule paused until the display disconnects"
        }
    }
}
