import AppKit
import os

/// Ignores `terminate(_:)` while a quit is already pending (`.terminateLater` while lid mode is released and read
/// back). Otherwise a second ⌘Q, Dock Quit, SIGTERM or quit Apple Event exits at once and skips the verified release.
final class InsomniaApplication: NSApplication {
    var terminationPending = false

    override func terminate(_ sender: Any?) {
        guard !terminationPending else { return }
        super.terminate(sender)
    }
}

/// App lifecycle (ARCHITECTURE.md "App/AppDelegate.swift"). Modules from later milestones are marked where they plug in.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    /// Strongly retained: UNUserNotificationCenter only keeps a weak reference to its delegate.
    private let notificationDelegate = NotificationDelegate()
    /// SIGTERM (`kill`, `pkill`, launchd) quits like ⌘Q: lid mode is released and read back, the socket unlinked.
    private var termSource: DispatchSourceSignal?
    private let log = Logger(subsystem: "com.gdeml.Insomnia", category: "app")
    /// URLs that arrive before everything is wired (a URL that launches the app comes between willFinishLaunching and
    /// didFinishLaunching). They run at the end of applicationDidFinishLaunching.
    private(set) var pendingURLs: [URL] = []
    private var didLaunch = false
    /// Set when another copy is already running (Decision 29): this one forwards its URL, or opens the panel, to that
    /// copy and exits without touching the lid, socket or status item.
    private var handOverTo: NSRunningApplication?
    private var forwardedAURL = false
    private var forwardsInFlight = 0
    private var handOverDone = false

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // First: a URL that launched this copy arrives before didFinishLaunching, and must not be dropped.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        // Single instance (Decision 29): hand over to the running copy before touching lid, socket or status item.
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let other = others.first {
                log.notice("another instance is running (pid \(other.processIdentifier)); handing over")
                handOverTo = other
                return
            }
        }
        Notifier.attach(notificationDelegate)
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = handOverTo {
            finishHandOver(to: other)
            return
        }
        // Launched to serve a command (by the CLI, or by a URL): don't also apply "Start keeping awake at launch".
        // It would turn `insomnia toggle` into "Sleep allowed" and outlive `insomnia run`.
        let launchedForCommand = CLI.wasLaunchedByCLI(ProcessInfo.processInfo.environment) || !pendingURLs.isEmpty
        unsetenv(CLI.launchedByCLIKey)   // not for anything this app starts

        // Initialise the singletons before anything observes their notifications (Settings posts from its init).
        _ = Settings.shared
        let engine = AwakeEngine.shared

        // 1. Notifications, and the engine's personality, notification and stats hooks (M4).
        Notifier.setUp()
        engine.narrator = Narrator.shared
        engine.notifier = Notifier.self
        engine.stats = Stats.shared
        Notifier.retryLidHandler = { ClosedLidController.shared.retry() }
        Notifier.resetLidHandler = { LidResetAction.run() }

        // 2. Power readings.
        PowerMonitor.shared.start()

        // 3. Lid mode (M2) and automations (M3). Every hook is assigned before AwakeEngine.start().
        engine.lidController = ClosedLidController.shared
        engine.eventLog = EventLog.shared
        WatchMonitor.shared.eventLog = EventLog.shared
        WatchMonitor.shared.start()
        engine.watchMonitor = WatchMonitor.shared
        WhyAwakeInput.foreignSleepDisabledProvider = { ClosedLidController.shared.foreignSleepDisabled }

        // 4. Menu bar item.
        let item = StatusItemController()
        item.install()
        statusItem = item

        // 5. Dock: presence, live tile and menu (DockController owns showInDock), then the epic moments.
        DockController.shared.untilHandler = { [weak item] in
            item?.showPanel(floating: true)
            item?.panel.model.showUntil = true
        }
        DockController.shared.openPanelHandler = { [weak item] in item?.showPanel(floating: true) }
        DockController.shared.start()
        EpicMoments.shared.start()

        // 6. Router.
        AppRouter.shared.showAboutHandler = { AboutWindowController.shared.show() }
        AppRouter.shared.openSettingsHandler = { SettingsWindowController.shared.show(tab: $0) }
        AppRouter.shared.startLidSetupHandler = { LidSetupWindow.show(requestedLid: $0) }

        // 7. Global hotkey; HotKeyManager re-registers itself when the hotKey* settings change.
        HotKeyManager.shared.bind(to: .shared) { [weak self] in
            let engine = AwakeEngine.shared
            guard !engine.isHeldOnlyByClients else { return }
            let wasAwake = engine.isAwake
            engine.toggle(source: .hotkey)
            if engine.isAwake != wasAwake { self?.statusItem?.blink() }
        }

        // 8. CLI control socket. It listens now; requests wait for setReady() (lid helper resolved).
        do {
            try ControlServer.shared.start()
        } catch {
            log.error("control socket: \(String(describing: error), privacy: .public)")
            EventLog.shared.log("cli", "control socket unavailable: \(error)")
        }
        EngineControlResponder.shared.foreignProvider = {
            (AssertionInspector.foreignAssertions(), WhyAwakeInput.liveAppPIDs())
        }

        // A plain SIGTERM would skip applicationShouldTerminate; route it through the normal quit instead.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { MainActor.assumeIsolated { AppRouter.shared.quit() } }
        term.resume()
        termSource = term

        // 9. Start the engine (lid recovery, helper status, activate on launch), then answer the CLI.
        Task {
            await AwakeEngine.shared.start(activateOnLaunch: !launchedForCommand)
            ControlServer.shared.setReady()
        }
        // Never keep the CLI waiting past its 15 s timeout (a helper that doesn't answer during start-up): a request
        // it gave up on would still run later.
        Task {
            try? await Task.sleep(for: .seconds(10))
            ControlServer.shared.setReady()
        }

        // First run: open the panel once so the welcome card can greet (UX §7.1).
        if !Settings.shared.hasCompletedOnboarding {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                AppRouter.shared.showPanel()
            }
        }

        // Everything is wired: run the URLs that arrived while launching.
        didLaunch = true
        let urls = pendingURLs
        pendingURLs = []
        for url in urls { URLCommandHandler.handle(url) }
    }

    /// Forwards to the running copy, then exits once LaunchServices has delivered (at most 3 s).
    private func finishHandOver(to other: NSRunningApplication) {
        if !forwardedAURL, let panel = URL(string: "insomnia://panel") { forward(panel, to: other) }
        handOverDone = true
        exitAfterHandOver()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    private func forward(_ url: URL, to other: NSRunningApplication) {
        forwardedAURL = true
        guard let app = other.bundleURL else {
            NSWorkspace.shared.open(url)
            return
        }
        forwardsInFlight += 1
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                if let error { self.log.error("hand-over failed: \(String(describing: error), privacy: .public)") }
                self.forwardsInFlight -= 1
                self.exitAfterHandOver()
            }
        }
    }

    private func exitAfterHandOver() {
        if handOverDone && forwardsInFlight == 0 { exit(0) }
    }

    // MARK: Quit

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // From here until the reply, InsomniaApplication ignores further quits: they would skip the lid release.
        (sender as? InsomniaApplication)?.terminationPending = true
        // Always through the engine: it credits the last stretch of awake time to Stats, records the session end,
        // clears a pending "ending soon" notification and releases the assertions. With lid mode off it returns at
        // once; otherwise lid mode is released (and read back) first: CLOSED_LID.md §4.1 layer 1.
        Task { @MainActor in
            await AwakeEngine.shared.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        ControlServer.shared.stop()
        Stats.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Dock

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Only a reopen sent by the Dock toggles; Spotlight, Finder, `open` and the CLI open the panel (Decision 13).
        let event = NSAppleEventManager.shared().currentAppleEvent
        let senderPID = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        if let senderPID, let dockPID, senderPID == dockPID, Settings.shared.showInDock {
            if DockController.shared.handleDockClick() { statusItem?.blink() }
        } else {
            AppRouter.shared.showPanel()
        }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockController.shared.makeDockMenu()
    }

    // MARK: URL scheme

    /// Internal for the GURL test (R77).
    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        // URLCommand.parse checks the scheme (case-insensitively, `Insomnia://` too) and logs what it rejects.
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        receive(url)
    }

    /// Forwarded (hand-over), run, or queued until launching has finished wiring everything.
    func receive(_ url: URL) {
        if let other = handOverTo {
            forward(url, to: other)
        } else if didLaunch {
            URLCommandHandler.handle(url)
        } else {
            pendingURLs.append(url)
        }
    }

    // MARK: Main menu (so text fields get standard editing keys; UX §2.5)

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Insomnia")
        appMenu.addItem(withTitle: "About Insomnia", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Insomnia", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // ⌘W for every titled window (Settings, About, Lid Mode setup); the panel handles it in its key monitor.
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    @objc private func showAbout(_ sender: Any?) { AppRouter.shared.showAbout() }

    @objc private func showSettings(_ sender: Any?) { AppRouter.shared.openSettings(.general) }
}
