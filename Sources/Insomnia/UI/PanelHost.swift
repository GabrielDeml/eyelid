import AppKit
import SwiftUI

/// Borderless key-capable panel: macOS 27 expanded status-item session, and the floating fallback on any version
/// (docs/UX.md §2.2 Window, §2.6).
final class PanelWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows `PanelView` either in an `NSPopover` (macOS 14–26 from the menu bar) or a `PanelWindow` (macOS 27 expanded
/// session, floating mode). Calls `NSApp.activate()` first so an accessory app gets keyboard focus. Closes on Esc and
/// on focus loss. Tells the engine when it appears/disappears (1 Hz ticks only while visible).
@MainActor
final class PanelHost: NSObject {
    enum Anchor {
        case statusItem(NSStatusBarButton)
        case floating
    }

    let model: PanelModel
    /// Called once each time the panel closes (any path).
    var onClose: (() -> Void)?
    /// Called on every visibility change. Wired to `AwakeEngine.setPanelVisible`.
    var onVisibilityChange: ((Bool) -> Void)?
    /// macOS 27 expanded-interface sessions present the window below the button instead of a popover.
    var usesWindowForStatusItem = false

    private var popover: NSPopover?
    private var window: PanelWindow?
    private var keyMonitor: Any?
    private var closing = false

    init(model: PanelModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { (popover?.isShown ?? false) || (window?.isVisible ?? false) }

    func show(anchor: Anchor) {
        if isVisible { close() }
        NSApp.activate(ignoringOtherApps: true)
        switch anchor {
        case .statusItem(let button) where !usesWindowForStatusItem:
            showPopover(from: button)
        case .statusItem(let button):
            showWindow(at: .belowButton(button))
        case .floating:
            showWindow(at: .floating)
        }
        installKeyMonitor()
        setVisible(true)
    }

    func close() {
        guard !closing else { return }
        closing = true
        defer { closing = false }
        let wasVisible = isVisible
        model.showUntil = false
        if let popover, popover.isShown {
            popover.delegate = nil          // this path reports the close itself
            popover.performClose(nil)
        }
        if let window, window.isVisible { fadeOut(window) }
        popover = nil
        removeKeyMonitor()
        if wasVisible {
            setVisible(false)
            onClose?()
        }
    }

    // MARK: Popover (14–26)

    private func showPopover(from button: NSStatusBarButton) {
        let controller = NSHostingController(rootView: PanelView(model: model, opaqueBackground: Theme.reduceTransparency))
        controller.sizingOptions = [.preferredContentSize]
        let p = NSPopover()
        p.behavior = .transient
        p.animates = !Theme.reduceMotion
        p.contentViewController = controller
        p.delegate = self
        popover = p
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    // MARK: Window (27 expanded session, floating)

    private enum Placement {
        case belowButton(NSStatusBarButton)
        case floating
    }

    private func showWindow(at placement: Placement) {
        let hosting = NSHostingView(rootView: PanelView(model: model, opaqueBackground: Theme.reduceTransparency))
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        let w = window ?? PanelWindow(contentRect: NSRect(origin: .zero, size: size))
        w.delegate = self
        w.contentView = makeMaterial(around: hosting, size: size)
        w.setContentSize(size)

        let origin: NSPoint
        switch placement {
        case .belowButton(let button):
            guard let bw = button.window else { return showWindow(at: .floating) }
            let r = bw.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = bw.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? r
            let x = min(max(visible.minX + 8, r.midX - size.width / 2), visible.maxX - size.width - 8)
            origin = NSPoint(x: x, y: r.minY - 6 - size.height)
        case .floating:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - 80 - size.height)
        }
        window = w
        fadeIn(w, to: NSRect(origin: origin, size: size))
    }

    /// Liquid Glass on macOS 26+ (cornerRadius 12), a popover material before; solid under Reduce Transparency.
    private func makeMaterial(around content: NSView, size: CGSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        if Theme.reduceTransparency {
            let plain = NSView(frame: frame)
            plain.wantsLayer = true
            plain.layer?.cornerRadius = Theme.cornerRadius
            plain.layer?.cornerCurve = .continuous
            plain.layer?.masksToBounds = true
            embed(content, in: plain)
            return plain
        }
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = Theme.cornerRadius
            content.frame = frame
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        embed(content, in: effect)
        return effect
    }

    private func embed(_ content: NSView, in container: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func fadeIn(_ w: NSWindow, to frame: NSRect) {
        if Theme.reduceMotion {
            w.setFrame(frame, display: false)
            w.alphaValue = 0
            w.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; w.animator().alphaValue = 1 }
            return
        }
        w.setFrame(frame.offsetBy(dx: 0, dy: 6), display: false)
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
            w.animator().setFrame(frame, display: true)
        }
    }

    private func fadeOut(_ w: NSWindow) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.reduceMotion ? 0.1 : 0.12
            w.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if w.alphaValue < 0.01 { w.orderOut(nil) }
            }
        })
    }

    // MARK: Keyboard (UX §2.5)

    private func installKeyMonitor() {
        removeKeyMonitor()
        // Local monitors run on the main thread (the event loop).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, let ew = event.window, self.ownsWindow(ew) else { return event }
            // Child popovers (Until…, the While… name / PID prompts) handle their own keys: Return starts, and Esc
            // closes just that popover rather than the whole panel.
            if ew !== self.window, ew !== self.popover?.contentViewController?.view.window { return event }
            // Single-key shortcuts are off while a text field (field editor) is first responder.
            if ew.firstResponder is NSText, event.keyCode != 53 { return event }
            return self.model.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func ownsWindow(_ w: NSWindow) -> Bool {
        if w === window || w === popover?.contentViewController?.view.window { return true }
        var parent = w.parent
        while let p = parent {
            if p === window || p === popover?.contentViewController?.view.window { return true }
            parent = p.parent
        }
        return false
    }

    private func setVisible(_ visible: Bool) {
        model.isVisible = visible
        onVisibilityChange?(visible)
    }
}

extension PanelHost: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        guard !closing else { return }
        popover = nil
        removeKeyMonitor()
        setVisible(false)
        onClose?()
    }
}

extension PanelHost: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // A child popover (Until…) taking key focus is still "inside" the panel.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let w = self.window, w.isVisible, !w.isKeyWindow else { return }
                if let key = NSApp.keyWindow, self.ownsWindow(key) { return }
                self.close()
            }
        }
    }
}
