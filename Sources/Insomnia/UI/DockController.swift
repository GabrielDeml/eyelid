import AppKit
import os

/// The live Dock tile, Dock menu and Dock click (docs/UX.md §3; ARCHITECTURE.md "UI/DockController.swift").
///
/// - Presence follows `Settings.showInDock`: `.regular` with a tile, `.accessory` without. Switching never closes windows.
/// - The tile draws `EyesRenderer.appIcon(size: 128, mood:, pill:)` with the time **inside** the tile. `badgeLabel` is
///   used only for a lid error or stuck flag ("!" = needs attention).
/// - Redraws only when (mood, pill, badge) changes: at most once a minute under 1 h, once a second in the final minute.
///   No timers of its own while idle; it rides on the engine's `.insomniaStateDidChange` ticks.
/// - Two one-shot animations (skipped under Reduce Motion): a blink on a Dock-click toggle, and the night-vision pulse on
///   the first lid engagement each day (`EpicMoments`).
@MainActor
final class DockController {
    static let shared = DockController()

    /// "Until…" in the Dock menu. AppDelegate wires it to open the panel with the Until… popover; without it the panel
    /// opens plainly.
    var untilHandler: (() -> Void)?

    private struct Render: Equatable {
        var mood: EyeMood
        var pill: String?
        var badge: String?
    }

    private let tileView = DockTileView()
    private var lastRender: Render?
    private var observers: [NSObjectProtocol] = []
    private var animation: Timer?
    private var frameIndex = 0
    private var frameCount = 0
    private var frameHandler: (@MainActor (Int) -> Void)?
    private var started = false
    private let log = Logger(subsystem: "com.gdeml.Insomnia", category: "dock")

    // MARK: Lifecycle

    /// Applies `showInDock` and starts following engine state. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .insomniaSettingsDidChange, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            MainActor.assumeIsolated {
                if key == "showInDock" { self?.applyPresence() }
            }
        })
        observers.append(center.addObserver(forName: .insomniaStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: .insomniaNightVision, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pulse() }
        })
        applyPresence()
    }

    private var isShown: Bool { Settings.shared.showInDock }

    private func applyPresence() {
        let policy: NSApplication.ActivationPolicy = isShown ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            // Keep whatever is frontmost frontmost: `.accessory` can deactivate the app, which would close the panel.
            NSApp.setActivationPolicy(policy)
            log.info("dock presence: \(self.isShown ? "shown" : "hidden", privacy: .public)")
        }
        if isShown {
            if NSApp.dockTile.contentView !== tileView {
                NSApp.dockTile.contentView = tileView
            }
            lastRender = nil
            refresh()
        } else {
            stopAnimation()
            NSApp.dockTile.badgeLabel = nil
        }
    }

    // MARK: Tile

    /// Redraws when (mood, pill, badge) changed.
    func refresh() {
        guard isShown, animation == nil else { return }
        let engine = AwakeEngine.shared
        let render = Render(mood: engine.mood, pill: Self.pill(status: engine.status, remaining: engine.remaining),
                            badge: Self.badge(engine.lid))
        guard render != lastRender else { return }
        let badgeChanged = render.badge != lastRender?.badge
        lastRender = render
        draw(mood: render.mood, pill: render.pill)
        if badgeChanged { NSApp.dockTile.badgeLabel = render.badge }
    }

    private func draw(mood: EyeMood, pill: String?, pose: EyePose? = nil, glow: CGFloat = 0) {
        tileView.content = DockTileView.Content(mood: mood, pill: pill, pose: pose, glow: glow)
        NSApp.dockTile.display()
    }

    /// The text drawn into the tile (UX §3 "Time"): "42m", "1h 5m", "0:42" in the final minute, "∞", the first four
    /// letters of a watched/CLI label ("ffmp…"), or nil (asleep, rules, suspended).
    static func pill(status: AwakeStatus, remaining: TimeInterval?) -> String? {
        switch status {
        case .timed(let end):
            let r = remaining ?? max(0, end.timeIntervalSinceNow)
            return r <= 60 ? TimeFormat.countdown(r) : TimeFormat.compact(r)
        case .indefinite: return "∞"
        case .watching(let target): return abbreviate(FallbackCopy.shortName(target))
        case .client(let label): return abbreviate(label)
        case .asleep, .automatic, .suspended: return nil
        }
    }

    static func abbreviate(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= 4 ? trimmed : String(trimmed.prefix(4)) + "…"
    }

    /// "!" only for a lid error that alarms, or a stuck flag (UX §3 "Badge").
    static func badge(_ lid: LidStatus) -> String? {
        switch lid {
        case .stuck: return "!"
        case .error(let e) where e.alarms: return "!"
        default: return nil
        }
    }

    // MARK: Click

    /// A reopen sent by the Dock (AppDelegate checks the sender pid and `showInDock`): eyes-button semantics with one
    /// tile blink. Never bounces.
    /// Returns true when the state actually changed (AppDelegate then blinks the menu bar glyph too, UX §1.2).
    @discardableResult
    func handleDockClick() -> Bool {
        let engine = AwakeEngine.shared
        guard !engine.isHeldOnlyByClients else { return false }   // a CLI hold can't be released from here either
        let wasAwake = engine.isAwake
        engine.toggle(source: .dock)
        guard engine.isAwake != wasAwake else { return false }
        blink()
        return true
    }

    /// One ~180 ms blink: half, closed, half (skipped under Reduce Motion).
    func blink() {
        guard isShown, !Theme.reduceMotion else { return refresh() }
        let mood = AwakeEngine.shared.mood
        let pill = lastRender?.pill
        // Falling asleep blinks the open eyes shut; waking blinks the new, open eyes.
        let blinkMood: EyeMood = mood == .asleep || mood == .squint ? .awake : mood
        let frames: [CGFloat] = [0.5, 1, 0.5]
        runFrames(count: frames.count, interval: 0.06) { [weak self] i in
            var pose = EyePose.resting(for: blinkMood)
            pose.openLeft *= 1 - frames[i]
            pose.openRight = pose.rightCross ? 0 : pose.openRight * (1 - frames[i])
            self?.draw(mood: blinkMood, pill: pill, pose: pose)
        }
    }

    /// Night vision (PRODUCT.md §4 rule 10): the tile pulses once with an indigo glow (~400 ms).
    func pulse() {
        guard isShown, !Theme.reduceMotion else { return }
        let mood = AwakeEngine.shared.mood
        let pill = lastRender?.pill
        let steps = 10
        runFrames(count: steps, interval: 0.04) { [weak self] i in
            let t = CGFloat(i + 1) / CGFloat(steps)
            self?.draw(mood: mood, pill: pill, glow: sin(.pi * t))
        }
    }

    private func runFrames(count: Int, interval: TimeInterval, frame: @escaping @MainActor (Int) -> Void) {
        stopAnimation()
        frameIndex = 0
        frameCount = count
        frameHandler = frame
        frame(0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    private func advanceFrame() {
        frameIndex += 1
        if frameIndex < frameCount {
            frameHandler?(frameIndex)
        } else {
            stopAnimation()
            lastRender = nil
            refresh()   // back to the live tile
        }
    }

    private func stopAnimation() {
        animation?.invalidate()
        animation = nil
        frameHandler = nil
    }

    // MARK: Dock menu (UX §3)

    func makeDockMenu() -> NSMenu {
        let engine = AwakeEngine.shared
        let settings = Settings.shared
        let menu = NSMenu()
        menu.autoenablesItems = false

        let headline = Narrator.shared.headline(status: engine.status, lid: engine.lid)
        let sub = Narrator.shared.subline(status: engine.status, lid: engine.lid, remaining: engine.remaining, now: engine.now)
        let header = NSMenuItem(title: Self.dockHeader(headline: headline, subline: sub, status: engine.status),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let keepAwake = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        let durations = NSMenu()
        durations.autoenablesItems = false
        for d in AwakeDuration.presets {
            durations.addItem(ActionMenuItem(d.shortLabel, accessibility: PlainCopy.spokenDuration(d)) {
                AwakeEngine.shared.activate(d, source: .dock)
            })
        }
        durations.addItem(ActionMenuItem("Until…") { [weak self] in
            if let handler = self?.untilHandler { handler() } else { AppRouter.shared.showPanel() }
        })
        keepAwake.submenu = durations
        menu.addItem(keepAwake)

        if case .timed = engine.status, engine.manualHold?.end != nil {
            menu.addItem(ActionMenuItem("Extend +15m", accessibility: "Extend 15 minutes") {
                AwakeEngine.shared.extend(minutes: 15, source: .dock)
            })
        }
        if engine.isAwake {
            let stop = ActionMenuItem("Allow Sleep") { AwakeEngine.shared.toggle(source: .dock) }
            stop.isEnabled = !engine.isHeldOnlyByClients
            if engine.isHeldOnlyByClients { stop.toolTip = "Held by a command" }
            menu.addItem(stop)
        }

        menu.addItem(.separator())
        let screen = ActionMenuItem("Keep Screen On") { Settings.shared.keepScreenOn.toggle() }
        screen.state = settings.keepScreenOn ? .on : .off
        menu.addItem(screen)
        if PowerMonitor.shared.hasLid {
            let helperReady = (engine.lidController?.helper ?? .notInstalled) == .installed
            if helperReady {
                let lid = ActionMenuItem("Stay Awake With Lid Closed") { Settings.shared.closedLidMode.toggle() }
                lid.state = settings.closedLidMode ? .on : .off
                menu.addItem(lid)
            } else {
                menu.addItem(ActionMenuItem("Stay Awake With Lid Closed: Set Up…") {
                    if AppRouter.shared.startLidSetupHandler != nil { AppRouter.shared.startLidSetup() } else {
                        AppRouter.shared.openSettings(.lidSafety)
                    }
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Open Panel") { AppRouter.shared.showPanel() })
        menu.addItem(ActionMenuItem("Why Awake?") { AppRouter.shared.showWhyAwake() })
        let settingsItem = ActionMenuItem("Settings…") { AppRouter.shared.openSettings(.general) }
        settingsItem.isEnabled = AppRouter.shared.openSettingsHandler != nil
        menu.addItem(settingsItem)
        return menu
    }

    /// "Wide awake · 42 min left". The subline's inline links ("Stop", "edit in Settings") are panel-only.
    static func dockHeader(headline: String, subline: String, status: AwakeStatus) -> String {
        let cleaned = subline
            .replacingOccurrences(of: " · Stop", with: "")
            .replacingOccurrences(of: " · edit in Settings", with: "")
        if case .asleep = status { return headline }
        return cleaned.isEmpty ? headline : "\(headline) · \(cleaned)"
    }
}

/// The Dock tile's content view: the app icon with the time drawn in, plus an optional pulse glow.
final class DockTileView: NSView {
    struct Content: Equatable {
        var mood: EyeMood
        var pill: String?
        var pose: EyePose?
        /// 0…1 night-vision pulse.
        var glow: CGFloat
    }

    var content = Content(mood: .asleep, pill: nil, pose: nil, glow: 0)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
        Self.draw(ctx, side: side, content: content)
        ctx.restoreGState()
    }

    /// Draws one tile into a y-down context (also used by `--snapshot`).
    static func draw(_ ctx: CGContext, side: CGFloat, content: Content) {
        EyesRenderer.drawAppIcon(ctx, size: side, mood: content.mood, pill: content.pill, pose: content.pose)
        guard content.glow > 0.01 else { return }
        // Night-vision pulse: an indigo bloom over the eyes, clipped to the icon body.
        let inset = side * 100 / 1024
        let body = CGRect(x: inset, y: inset * 0.9, width: side - inset * 2, height: side - inset * 2)
        ctx.saveGState()
        ctx.addPath(EyesRenderer.squircle(in: body))
        ctx.clip()
        let colours = [NSColor(srgb: 0x8B8CFF, alpha: 0.65 * content.glow).cgColor,
                       NSColor(srgb: 0x8B8CFF, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1]) {
            // Centred on the eyes (they sit higher when a pill is drawn) and kept clear of the pill.
            let hasPill = !(content.pill?.isEmpty ?? true)
            let c = CGPoint(x: body.midX, y: body.minY + body.height * (hasPill ? 0.4 : 0.5))
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                                   endRadius: body.width * ((hasPill ? 0.2 : 0.3) + 0.1 * content.glow), options: [])
        }
        ctx.restoreGState()
    }
}

/// An NSMenuItem that runs a closure (the Dock menu has no responder chain to send to). Menus fire on the main thread.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, accessibility: String? = nil, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
        if let accessibility { setAccessibilityLabel(accessibility) }
    }

    required init(coder: NSCoder) {
        handler = {}
        super.init(coder: coder)
    }

    @objc private func run(_ sender: Any?) {
        handler()
    }
}
