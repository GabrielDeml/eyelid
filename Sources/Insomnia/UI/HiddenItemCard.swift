import AppKit
import SwiftUI

/// "macOS hid me from the menu bar" (docs/UX.md §1.7, §7.2). Shown once, in a floating panel window, when the
/// status item's hidden heuristic fires. Afterwards the hotkey, Spotlight/Finder (floating panel) and the Dock menu
/// keep working.
struct HiddenItemCard: View {
    var showInDock: Bool
    var showMeInDock: () -> Void
    var openPanel: () -> Void
    var openMenuBarSettings: () -> Void
    var keepHidden: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                EyesView(mood: .watching, progress: nil, isLive: false, size: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS hid me from the menu bar. I'm still here.")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Open Insomnia from Spotlight to see this panel.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Full-width buttons in spec order (UX §7.2): three side by side don't fit in 320 pt.
            VStack(spacing: 8) {
                primary
                    .buttonStyle(.borderedProminent)
                Button(action: openMenuBarSettings) { Text("Open Menu Bar Settings").frame(maxWidth: .infinity) }
                Button(action: keepHidden) { Text("Keep Hidden").frame(maxWidth: .infinity) }
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: Theme.panelWidth)
    }

    /// "Show Me in the Dock", or "Open Panel" when the Dock icon is already on.
    @ViewBuilder private var primary: some View {
        if showInDock {
            Button(action: openPanel) { Text("Open Panel").frame(maxWidth: .infinity) }.keyboardShortcut(.defaultAction)
        } else {
            Button(action: showMeInDock) { Text("Show Me in the Dock").frame(maxWidth: .infinity) }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Presents `HiddenItemCard` in a floating `PanelWindow` (top-centre of the screen under the mouse, 80 pt below the
/// menu bar; UX §2.6). Closes on Esc, on losing key status, or on any button. Marks `hiddenItemCardShown` when shown.
@MainActor
final class HiddenItemCardController: NSObject, NSWindowDelegate {
    static let shared = HiddenItemCardController()

    private var window: PanelWindow?
    private var keyMonitor: Any?
    /// The item went hidden while the panel was open; the card waits for the panel to close (R95).
    private var pending = false

    enum Decision: Equatable { case skip, waitForPanel, show }

    /// Once ever; never over an open panel, whose focus loss would close it (the first-run welcome panel).
    static func decide(alreadyShown: Bool, force: Bool, panelOpen: Bool) -> Decision {
        if force { return .show }
        if alreadyShown { return .skip }
        return panelOpen ? .waitForPanel : .show
    }

    /// Shows the card once ever (`Settings.hiddenItemCardShown`). `force` ignores the flag (debug / snapshots).
    /// With the panel open it is held back, unmarked, until `panelDidClose`.
    func showIfNeeded(force: Bool = false, panelOpen: Bool = false) {
        let settings = Settings.shared
        switch Self.decide(alreadyShown: settings.hiddenItemCardShown, force: force, panelOpen: panelOpen) {
        case .skip:
            return
        case .waitForPanel:
            pending = true
        case .show:
            pending = false
            settings.hiddenItemCardShown = true
            show()
        }
    }

    /// The panel closed: show a held-back card if the item is still hidden. On the next turn, so the card doesn't take
    /// focus in the middle of the panel's own close.
    func panelDidClose(itemStillHidden: Bool) {
        guard pending else { return }
        pending = false
        guard itemStillHidden else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.showIfNeeded() }
        }
    }

    private func show() {
        close()
        let settings = Settings.shared
        let card = HiddenItemCard(
            showInDock: settings.showInDock,
            showMeInDock: { [weak self] in
                Settings.shared.showInDock = true
                self?.close()
            },
            openPanel: { [weak self] in
                self?.close()
                AppRouter.shared.showPanel()
            },
            openMenuBarSettings: { [weak self] in
                Self.openMenuBarSettings()
                self?.close()
            },
            keepHidden: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: card)
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size))
        w.delegate = self
        w.contentView = Self.material(around: hosting, size: size)
        w.setAccessibilityLabel("Insomnia")

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        w.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - 80 - size.height,
                          width: size.width, height: size.height), display: false)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.reduceMotion ? 0.15 : 0.2
            w.animator().alphaValue = 1
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.window === self?.window else { return event }   // Esc
            self?.close()
            return nil
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let w = window else { return }
        window = nil
        w.delegate = nil
        w.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// System Settings ▸ Menu Bar (best effort), else the System Settings app.
    static func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Liquid Glass on macOS 26+, a popover material before, solid under Reduce Transparency (matches PanelHost).
    private static func material(around content: NSView, size: CGSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        content.frame = frame
        if !Theme.reduceTransparency, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = Theme.cornerRadius
            glass.contentView = content
            return glass
        }
        let container: NSView
        if Theme.reduceTransparency {
            container = NSView(frame: frame)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            container = effect
        }
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        return container
    }
}
