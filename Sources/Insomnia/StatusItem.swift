import AppKit
import Observation
import SwiftUI

/// The menu bar moon and its panel (an NSPopover: Liquid Glass on macOS 26+, closes on outside clicks).
/// Never assigns `statusItem.menu` (macOS 27 drops clicks on multi-display setups with it), and stays narrow: no
/// timer text.
@MainActor
final class StatusItem: NSObject, NSPopoverDelegate {
    private let engine: Engine
    private let lid: LidController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var observers: [NSObjectProtocol] = []
    private var lastGlyph: (Engine.Mode, Bool, Bool)?
    /// Refreshes the tooltip's countdown while a timer runs (nothing observable changes as time passes).
    private var tooltipTimer: Timer?

    init(engine: Engine, lid: LidController) {
        self.engine = engine
        self.lid = lid
        super.init()
        item.autosaveName = "InsomniaEyes"
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Insomnia")
        }
        let host = NSHostingController(rootView: LivePanel(engine: engine, lid: lid) { [weak self] in self?.perform($0) })
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // Never leave the panel up across sleep.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.popover.performClose(nil) }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.lastGlyph = nil; self?.refresh() }
            })
        refresh()
    }

    /// Redraws the glyph and tooltip, then waits for the next change to anything they read.
    private func refresh() {
        withObservationTracking {
            let mode = engine.mode
            let attention = engine.needsAttention
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            if lastGlyph.map({ $0 != (mode, attention, contrast) }) ?? true {
                lastGlyph = (mode, attention, contrast)
                item.button?.image = MoonGlyph.image(mode: mode, attention: attention, highContrast: contrast)
            }
            let text = tooltip()
            item.button?.toolTip = text
            item.button?.setAccessibilityValue(text)
            scheduleTooltipRefresh(timed: engine.endsAt != nil)
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func scheduleTooltipRefresh(timed: Bool) {
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        guard timed else { return }
        let timer = Timer(timeInterval: 30, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        tooltipTimer = timer
    }

    private func tooltip() -> String {
        var parts = [engine.isOn ? "Awake" : (lid.isStuck ? "Sleep is still turned off" : "Off")]
        if let end = engine.endsAt { parts.append(DurationText.left(until: end, now: Date())) }
        if engine.mode == .screenOn || (engine.mode == .lid && engine.prefs.keepScreenOn) { parts.append("screen on") }
        if engine.mode == .lid { parts.append("lid can close") }
        if let notice = engine.notice { parts.append(notice.text) }
        if engine.needsAttention, engine.notice == nil, !lid.isStuck { parts.append("lid mode needs a look") }
        return "Insomnia · " + parts.joined(separator: " · ")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        let toggles = (engine.prefs.clickAction == .toggle) != secondary
        if toggles {
            popover.performClose(nil)
            engine.toggle()
        } else {
            togglePanel()
        }
    }

    func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        engine.panelOpened()
        Task { await lid.refreshSetup() }
        NSApp.activate(ignoringOtherApps: true)   // an accessory app gets no key focus otherwise
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func perform(_ action: PanelAction) {
        switch action {
        case .toggle: engine.toggle()
        case .start(let minutes): engine.start(minutes: minutes)
        case .setScreen(let on): engine.prefs.keepScreenOn = on
        case .setLid(let on): engine.setLidMode(on)
        case .setUnplugged(let choice): engine.prefs.whenUnplugged = choice
        case .dismissNotice: engine.dismissNotice()
        case .openLoginItems: lid.openLoginItems()
        case .retryLid:
            if lid.needsSetup || lid.setupError != nil { lid.install() } else { lid.userActed() }
        case .resetWithPassword: lid.resetWithPassword()
        case .openSettings:
            popover.performClose(nil)
            SettingsWindow.shared.show()
        case .quit: NSApp.terminate(nil)
        }
    }
}
