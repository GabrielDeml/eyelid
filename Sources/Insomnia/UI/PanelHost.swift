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

/// A counter that lets a deferred completion check it is still the latest request (a stale fade-out must not order out
/// a panel that was shown again; a superseded settling window must not end a newer one).
struct Generation: Equatable {
    private(set) var current = 0

    /// Starts a new generation and returns its token.
    mutating func advance() -> Int {
        current &+= 1
        return current
    }

    func isCurrent(_ token: Int) -> Bool { token == current }
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

    /// What `show` does, given what is open now.
    enum ShowPlan: Equatable {
        /// Nothing is open: present it.
        case present
        /// The same kind of host is already open: move it and make it key again (no close, no `onClose`).
        case refocus
        /// The other kind is open (popover ↔ window): close it, then present.
        case replace
    }

    static func showPlan(isOpen: Bool, openInWindow: Bool, wantsWindow: Bool) -> ShowPlan {
        guard isOpen else { return .present }
        return openInWindow == wantsWindow ? .refocus : .replace
    }

    /// Whether a finished fade-out orders the window out. Not if it was shown again during the fade (R34): the newer
    /// fade-in owns it then. A popover that replaced the window (`.replace`) doesn't count as the window being open:
    /// otherwise the window would stay ordered in at alpha 0.
    static func fadeOutOrdersOut(tokenIsCurrent: Bool, windowIsOpen: Bool) -> Bool {
        tokenIsCurrent && !windowIsOpen
    }

    /// The window frame for content of `size`: the top edge stays put, kept inside `visible` (UX §2.1: the panel grows
    /// for the welcome card and row J banners).
    static func resizedFrame(_ frame: NSRect, to size: CGSize, within visible: NSRect?) -> NSRect {
        var r = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        if let v = visible {
            if r.minY < v.minY { r.origin.y = v.minY }
            if r.maxY > v.maxY { r.origin.y = v.maxY - r.height }
        }
        return r
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
    private var hosting: PanelHostingView?
    private var keyMonitor: Any?
    private var closing = false
    /// Shown and not closing. A window still fading out is not open.
    private var isOpen = false
    /// Bumped by every fade: a fade-out's completion orders the window out only if no fade started since.
    private var fades = Generation()
    private var resizeScheduled = false

    init(model: PanelModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { isOpen }

    func show(anchor: Anchor) {
        let wantsWindow: Bool
        if case .statusItem = anchor, !usesWindowForStatusItem { wantsWindow = false } else { wantsWindow = true }
        let plan = Self.showPlan(isOpen: isOpen, openInWindow: popover == nil, wantsWindow: wantsWindow)
        if plan == .replace { close() }
        let refocus = plan == .refocus
        NSApp.activate(ignoringOtherApps: true)
        switch anchor {
        case .statusItem(let button) where !usesWindowForStatusItem:
            if refocus { popover?.contentViewController?.view.window?.makeKey() } else { showPopover(from: button) }
        case .statusItem(let button):
            showWindow(at: .belowButton(button), refocus: refocus)
        case .floating:
            showWindow(at: .floating, refocus: refocus)
        }
        guard !refocus else { return }
        isOpen = true
        installKeyMonitor()
        setVisible(true)
    }

    func close() {
        guard !closing, isOpen else { return }
        closing = true
        defer { closing = false }
        isOpen = false
        model.showUntil = false
        if let popover, popover.isShown {
            popover.delegate = nil          // this path reports the close itself
            popover.performClose(nil)
        }
        if let window, window.isVisible { fadeOut(window) }
        popover = nil
        removeKeyMonitor()
        setVisible(false)
        onClose?()
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

    /// `refocus`: the window is already open; move it to `placement` and make it key without fading or rebuilding.
    private func showWindow(at placement: Placement, refocus: Bool) {
        if refocus, let w = window, let hosting {
            _ = fades.advance()
            let size = hosting.fittingSize
            w.alphaValue = 1
            w.setFrame(NSRect(origin: origin(for: placement, size: size), size: size), display: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = PanelHostingView(rootView: PanelView(model: model, opaqueBackground: Theme.reduceTransparency))
        hosting.sizingOptions = [.intrinsicContentSize]
        // The welcome card, its dismissal and row J banners change the content height after the window is up (R6).
        hosting.onIntrinsicSizeChange = { [weak self] in self?.scheduleResize() }
        let size = hosting.fittingSize
        let w = window ?? PanelWindow(contentRect: NSRect(origin: .zero, size: size))
        w.delegate = self
        w.contentView = makeMaterial(around: hosting, size: size)
        w.setContentSize(size)
        window = w
        self.hosting = hosting
        fadeIn(w, to: NSRect(origin: origin(for: placement, size: size), size: size))
    }

    private func origin(for placement: Placement, size: CGSize) -> NSPoint {
        switch placement {
        case .belowButton(let button):
            guard let bw = button.window else { return origin(for: .floating, size: size) }
            let r = bw.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = bw.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? r
            let x = min(max(visible.minX + 8, r.midX - size.width / 2), visible.maxX - size.width - 8)
            return NSPoint(x: x, y: r.minY - 6 - size.height)
        case .floating:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - 80 - size.height)
        }
    }

    /// Coalesces a burst of content-size invalidations into one resize on the next main-loop turn.
    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.resizeScheduled = false
                self?.fitWindowToContent()
            }
        }
    }

    /// Resizes the open window to its SwiftUI content, top edge pinned (R6). The popover follows `preferredContentSize`.
    private func fitWindowToContent() {
        guard isOpen, popover == nil, let w = window, let hosting else { return }
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0,
              abs(w.frame.height - size.height) > 0.5 || abs(w.frame.width - size.width) > 0.5 else { return }
        let target = Self.resizedFrame(w.frame, to: size, within: w.screen?.visibleFrame)
        if Theme.reduceMotion {
            w.setFrame(target, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                w.animator().setFrame(target, display: true)
            }
        }
    }

    /// Liquid Glass on macOS 26+ (cornerRadius 12), a popover material before; solid under Reduce Transparency.
    /// The content follows the window's size in every branch, so a resize only has to set the window frame.
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
            content.autoresizingMask = [.width, .height]
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
        _ = fades.advance()   // a fade-out still running must not order this window out when it completes (R34)
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
        let token = fades.advance()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.reduceMotion ? 0.1 : 0.12
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, Self.fadeOutOrdersOut(tokenIsCurrent: self.fades.isCurrent(token),
                                                       windowIsOpen: self.isOpen && self.popover == nil) else { return }
                w.orderOut(nil)
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
    /// A Dock presence switch deactivates the app for a moment (R33): the transient popover stays open through it.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        !DockController.shared.isSwitchingPresence
    }

    func popoverDidClose(_ notification: Notification) {
        guard !closing, isOpen else { return }
        isOpen = false
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
                guard let self, self.isOpen, self.popover == nil, let w = self.window, !w.isKeyWindow else { return }
                // Our own Dock presence switch deactivates the app for a moment (R33); DockController re-keys the panel.
                guard !DockController.shared.isSwitchingPresence else { return }
                if let key = NSApp.keyWindow, self.ownsWindow(key) { return }
                self.close()
            }
        }
    }
}

/// Reports content-size changes so the panel window can follow its SwiftUI content (R6).
final class PanelHostingView: NSHostingView<PanelView> {
    var onIntrinsicSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }
}
