import AppKit
import SwiftUI

/// The Settings window: a toolbar `NSTabViewController` (the native Settings look on macOS 14+) hosting one SwiftUI tab
/// per `SettingsTab`, 540 wide (docs/UX.md §4). Created once, on first use; closing only hides it.
///
/// Wiring (AppDelegate): `AppRouter.shared.openSettingsHandler = { SettingsWindowController.shared.show(tab: $0) }`.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow?
    private var tabController: SettingsTabViewController?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Creates the window once, activates the app, brings the window front and selects `tab` (a tab this Mac doesn't
    /// have falls back to General).
    func show(tab: SettingsTab = .general) {
        let (window, tabs) = makeIfNeeded()
        tabs.select(tab)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.performClose(nil) }

    private func makeIfNeeded() -> (NSWindow, SettingsTabViewController) {
        if let window, let tabController { return (window, tabController) }
        let power = PowerMonitor.shared
        let tabs = SettingsTabViewController(hasLid: power.hasLid, hasBattery: power.hasBattery)
        let w = SettingsWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("InsomniaSettings")
        w.collectionBehavior.insert(.fullScreenNone)
        window = w
        tabController = tabs
        tabs.fitWindow(animated: false)
        return (w, tabs)
    }
}

/// ⌘W closes (the app's main menu has no Window menu, so the window handles it itself).
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Toolbar tabs; resizes the window to the selected tab's fixed height, keeping the top edge in place.
final class SettingsTabViewController: NSTabViewController {
    private(set) var tabs: [SettingsTab] = []
    private let hasLid: Bool

    init(hasLid: Bool, hasBattery: Bool) {
        self.hasLid = hasLid
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = Theme.reduceMotion ? [] : [.crossfade, .allowUserInteraction]
        canPropagateSelectedChildViewControllerTitle = true
        tabs = SettingsLayout.visibleTabs(hasLid: hasLid, hasBattery: hasBattery)
        for tab in tabs {
            let hosting = NSHostingController(rootView: SettingsTabContent(tab: tab))
            hosting.sizingOptions = []
            hosting.preferredContentSize = NSSize(width: SettingsLayout.width, height: SettingsLayout.height(tab))
            hosting.title = SettingsLayout.title(tab, hasLid: hasLid)
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = tab.rawValue
            item.label = SettingsLayout.title(tab, hasLid: hasLid)
            item.image = NSImage(systemSymbolName: SettingsLayout.symbol(tab, hasLid: hasLid),
                                 accessibilityDescription: item.label)
            addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) {
        hasLid = true
        super.init(coder: coder)
    }

    func select(_ tab: SettingsTab) {
        let resolved = SettingsLayout.resolve(tab, visible: tabs)
        guard let index = tabs.firstIndex(of: resolved), selectedTabViewItemIndex != index else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animated: view.window?.isVisible ?? false)
    }

    func fitWindow(animated: Bool) {
        guard let window = view.window, tabs.indices.contains(selectedTabViewItemIndex) else { return }
        let tab = tabs[selectedTabViewItemIndex]
        let content = NSSize(width: SettingsLayout.width, height: SettingsLayout.height(tab))
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        var frame = window.frame
        frame.origin.y += frame.height - target.height   // keep the top edge
        frame.size = target.size
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animated && !Theme.reduceMotion)
    }
}
