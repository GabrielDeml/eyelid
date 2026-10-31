import AppKit
import os

/// The menu bar item (docs/UX.md §1): a template glyph that never encodes state in colour, optional timer text,
/// the click model (panel / toggle / ⌥ Why awake), tooltip and VoiceOver value, the one-blink toggle feedback, and the
/// "hidden by macOS" heuristic.
///
/// Never assigns `statusItem.menu` (27.0.1 drops clicks on multi-display setups with it).
@MainActor
final class StatusItemController: NSObject {
    let panel: PanelHost

    private var statusItem: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var lastRender: Render?
    private var lastAccessibilityValue: String?
    private var blinkFrames: [Timer] = []
    private var finalMinuteTimer: Timer?
    private var hiddenCheck: Timer?
    private var lastSecondaryClick = Date.distantPast
    private(set) var isHidden = false
    private let log = Logger(subsystem: "com.gdeml.Insomnia", category: "statusItem")

    private struct Render: Equatable {
        var mood: EyeMood
        var text: String?
        var highContrast: Bool
    }

    override init() {
        panel = PanelHost(model: .live())
        super.init()
        panel.model.whileMenuProvider = WhileMenu.provider(for: panel.model)
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "InsomniaEyes"
        statusItem = item
        guard let button = item.button else { return }
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.setAccessibilityLabel("Insomnia")
        button.setAccessibilityHelp("Click: panel. Right-click: toggle. Option-click: why awake.")

        if #available(macOS 27, *), !UserDefaults.standard.bool(forKey: "legacyStatusItemClicks") {
            // Expanded-interface session: the item takes part in menu bar keyboard navigation and tracking.
            // The delegate property is weak; this controller lives for the whole app (AppDelegate owns it).
            item.expandedInterfaceDelegate = self
            panel.usesWindowForStatusItem = true
            // Safety net in case secondary clicks bypass the session (spike pending, UX §1.4): de-duplicated below.
            button.target = self
            button.action = #selector(secondaryFallback(_:))
            button.sendAction(on: [.rightMouseUp])
        } else {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panel.onVisibilityChange = { [weak self] visible in
            AwakeEngine.shared.setPanelVisible(visible)
            if let model = self?.panel.model { EpicMoments.shared.panelVisibilityChanged(visible, model: model) }
        }
        panel.onClose = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.highlight(false)
            if #available(macOS 27, *) { self.statusItem?.expandedInterfaceSession?.cancel() }
            // A hidden-item card held back while the panel was up (R95).
            HiddenItemCardController.shared.panelDidClose(itemStillHidden: self.isHidden) { [weak self] in
                self?.panel.isVisible ?? false
            }
        }

        let nc = NotificationCenter.default
        for name in [Notification.Name.insomniaStateDidChange, .insomniaSettingsDidChange] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsRefresh() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(force: true) }
            })
        // Hidden-by-macOS heuristic inputs (UX §1.7).
        if let window = button.window {
            observers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleHiddenCheck() }
            })
        }
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleHiddenCheck() }
        })
        // Never leave the panel open across sleep (R96): it would still be up, and the engine ticking, on wake.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePanel() }
            })
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleHiddenCheck() }
        }

        AppRouter.shared.showPanelHandler = { [weak self] in self?.showPanel() }
        AppRouter.shared.closePanelHandler = { [weak self] in self?.closePanel() }
        AppRouter.shared.showWhyAwakeHandler = { [weak self] in self?.showWhyAwakeMenu() }

        refresh(force: true)
    }

    // MARK: Panel

    /// `floating`: the top-centre panel (UX §2.6) even when the menu bar item is visible (Dock menu "Open Panel", "Until…").
    func showPanel(floating: Bool = false) {
        guard !floating, let button = statusItem?.button, isItemVisible else {
            panel.show(anchor: .floating)
            return
        }
        if !panel.usesWindowForStatusItem { button.highlight(true) }
        panel.show(anchor: .statusItem(button))
    }

    func closePanel() { panel.close() }

    func togglePanel() { panel.isVisible ? closePanel() : showPanel() }

    // MARK: Clicks (macOS 14–26 path)

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.modifierFlags.contains(.option) == true { showWhyAwakeMenu(); return }
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        perform(secondary ? secondaryAction : primaryAction)
    }

    /// macOS 27: right-click arriving as a button action rather than an expanded session.
    @objc private func secondaryFallback(_ sender: NSStatusBarButton) {
        guard Date().timeIntervalSince(lastSecondaryClick) > 0.6 else { return }
        lastSecondaryClick = Date()
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { showWhyAwakeMenu(); return }
        perform(secondaryAction)
    }

    /// What a macOS 27 expanded-interface session does when it begins.
    enum SessionResponse: Equatable { case whyAwake, secondary, toggleAwake, closePanel, showPanel }

    /// ⌥: Why awake. Right/⌃: the secondary action. A click with "click toggles": toggle. A click while the panel is
    /// already open without a session (Dock, Spotlight, URL) closes it, like the 14–26 toggle (R92). Else the panel.
    static func sessionResponse(option: Bool, secondary: Bool, primaryToggles: Bool, keyboard: Bool,
                                panelOpen: Bool) -> SessionResponse {
        if option { return .whyAwake }
        if secondary { return .secondary }
        if primaryToggles && !keyboard { return .toggleAwake }
        return panelOpen ? .closePanel : .showPanel
    }

    private var primaryAction: ClickAction { Settings.shared.leftClickAction }
    private var secondaryAction: ClickAction { primaryAction == .openPanel ? .toggle : .openPanel }

    private func perform(_ action: ClickAction) {
        switch action {
        case .openPanel: togglePanel()
        case .toggle: toggleAwake()
        }
    }

    private func toggleAwake() {
        let wasAwake = AwakeEngine.shared.isAwake
        AwakeEngine.shared.toggle(source: .menuBar)
        if AwakeEngine.shared.isAwake != wasAwake { blink() }
    }

    // MARK: Rendering

    private var refreshScheduled = false

    /// Coalesces bursts of notifications into one redraw on the next main-loop turn. Never re-enters the engine or
    /// Settings synchronously from inside their own posts (a post can arrive while a singleton is still initialising).
    private func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    /// Redraws only when (mood, text, contrast) changes. Tooltip and VoiceOver value follow state changes.
    func refresh(force: Bool = false) {
        guard let button = statusItem?.button else { return }
        let engine = AwakeEngine.shared
        let render = Render(mood: engine.mood, text: timerText(), highContrast: Theme.increaseContrast)
        if (force || render != lastRender) && blinkFrames.isEmpty {
            button.image = EyesRenderer.menuBarImage(mood: render.mood, highContrast: render.highContrast)
            if let text = render.text {
                button.attributedTitle = NSAttributedString(string: "\u{2009}" + text, attributes: [
                    .font: Theme.menuBarTimerFont, .baselineOffset: 0.5, .kern: 0,
                ])
            } else {
                button.title = ""
            }
            lastRender = render
        }
        let state = LivePanelState.make()
        let value = PlainCopy.accessibilityValue(state)
        if value != lastAccessibilityValue {
            button.setAccessibilityValue(value)
            lastAccessibilityValue = value
        }
        let sub = PlainCopy.subline(state).joined
        button.toolTip = "\(PlainCopy.headline(state)) · \(sub)\nClick: \(primaryAction == .openPanel ? "panel" : "toggle") · Right-click: \(secondaryAction == .openPanel ? "panel" : "toggle") · ⌥-click: why awake"
        updateFinalMinuteBlink()
    }

    /// UX §1.3: timed holds only; never for ∞ or rule holds.
    private func timerText() -> String? {
        let engine = AwakeEngine.shared
        guard case .timed = engine.status, let r = engine.remaining else { return nil }
        switch Settings.shared.menuBarTimer {
        case .off: return nil
        case .lastTenMinutes: return r <= 600 ? TimeFormat.compact(r) : nil
        case .always: return TimeFormat.compact(r)
        }
    }

    // MARK: Blink (the only menu bar motion: UX §1.2)

    /// One ~180 ms blink: half, closed, half. Skipped under Reduce Motion.
    func blink() {
        guard let button = statusItem?.button, !Theme.reduceMotion else { refresh(force: true); return }
        blinkFrames.forEach { $0.invalidate() }
        blinkFrames = []
        let mood = AwakeEngine.shared.mood
        // Falling asleep blinks the open eyes shut; waking blinks the new eyes.
        let blinkMood: EyeMood = mood == .asleep ? .awake : (mood == .squint ? .awake : mood)
        let hc = Theme.increaseContrast
        let frames: [CGFloat] = [0.5, 1, 0.5]
        for (i, b) in frames.enumerated() {
            let t = Timer(timeInterval: 0.06 * Double(i), repeats: false) { _ in
                MainActor.assumeIsolated {
                    button.image = EyesRenderer.menuBarImage(mood: blinkMood, blink: b, highContrast: hc)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            blinkFrames.append(t)
        }
        let end = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.blinkFrames = []
                self?.refresh(force: true)
            }
        }
        RunLoop.main.add(end, forMode: .common)
        blinkFrames.append(end)
    }

    /// Final 60 s of a timed hold: one slow blink every 10 s. No timer otherwise.
    private func updateFinalMinuteBlink() {
        let engine = AwakeEngine.shared
        let inFinalMinute: Bool = {
            guard case .timed = engine.status, let r = engine.remaining else { return false }
            return r > 0 && r <= 60
        }()
        if inFinalMinute, finalMinuteTimer == nil {
            let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.blink() }
            }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            finalMinuteTimer = t
        } else if !inFinalMinute, let t = finalMinuteTimer {
            t.invalidate()
            finalMinuteTimer = nil
        }
    }

    // MARK: Why awake? (⌥-click)

    func showWhyAwakeMenu() {
        let menu = WhyAwakeMenu.make()
        if let button = statusItem?.button, isItemVisible {
            let y = button.isFlipped ? button.bounds.maxY + 4 : -4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: button)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // MARK: Hidden by macOS (UX §1.7)

    /// Heuristic: the button's window isn't visible, has no screen, or the button sits behind the notch.
    var isItemVisible: Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        guard window.occlusionState.contains(.visible), let screen = window.screen else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The notch is the gap between the two unobscured top areas.
            let notch = NSRect(x: left.maxX, y: min(left.minY, right.minY), width: max(0, right.minX - left.maxX),
                               height: max(left.height, right.height))
            let global = notch.minX < screen.frame.minX || notch.maxX > screen.frame.maxX
                ? notch.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) : notch
            if global.width > 0, frame.intersects(global) { return false }
        }
        return true
    }

    private func scheduleHiddenCheck() {
        hiddenCheck?.invalidate()
        guard !isItemVisible else {
            if isHidden { log.info("status item visible again") }
            isHidden = false
            hiddenCheck = nil
            return
        }
        // Hidden for more than 3 s counts as hidden.
        let t = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isItemVisible, !self.isHidden else { return }
                self.isHidden = true
                self.log.notice("status item appears hidden by macOS")
                // The card takes key focus, which would close an open panel (the first-run welcome, R95): it waits.
                HiddenItemCardController.shared.showIfNeeded(panelOpen: self.panel.isVisible)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        hiddenCheck = t
    }
}

// MARK: - macOS 27 expanded interface session

@available(macOS 27, *)
extension StatusItemController: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        let isRight = event?.type == .rightMouseDown || event?.type == .rightMouseUp || flags.contains(.control)
        switch Self.sessionResponse(option: flags.contains(.option), secondary: isRight,
                                    primaryToggles: primaryAction == .toggle, keyboard: event?.type == .keyDown,
                                    panelOpen: panel.isVisible) {
        case .whyAwake:
            session.cancel()
            lastSecondaryClick = Date()
            showWhyAwakeMenu()
        case .secondary:
            session.cancel()
            lastSecondaryClick = Date()
            perform(secondaryAction)
        case .toggleAwake:
            session.cancel()
            toggleAwake()
        case .closePanel:
            session.cancel()
            panel.close()
        case .showPanel:
            if let button = statusItem.button { panel.show(anchor: .statusItem(button)) }
        }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        // Our own Dock presence switch deactivates the app for a moment (R33): keep the panel through it.
        guard !DockController.shared.isSwitchingPresence else { return }
        panel.close()
    }
}
