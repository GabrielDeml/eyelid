import AppKit
import os

/// Ignores `terminate(_:)` while a quit is already pending (`.terminateLater` while lid mode is released and read
/// back). Otherwise a second ⌘Q, SIGTERM or quit Apple Event would exit at once and skip the release.
final class InsomniaApplication: NSApplication {
    var terminationPending = false

    override func terminate(_ sender: Any?) {
        guard !terminationPending else { return }
        super.terminate(sender)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine?
    private var lid: LidController?
    private var statusItem: StatusItem?
    private var termSource: DispatchSourceSignal?
    private let log = Logger(subsystem: "com.gdeml.Insomnia", category: "app")
    private var handingOver = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One copy only: two would both drive the lid helper and both show a moon. The younger copy (ties: higher
        // pid) asks the older one to show its panel (a reopen event) and exits before touching anything.
        if let id = Bundle.main.bundleIdentifier {
            let me = NSRunningApplication.current
            let myKey = (me.launchDate ?? .distantFuture, me.processIdentifier)
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
                $0.processIdentifier != me.processIdentifier
                    && (($0.launchDate ?? .distantPast), $0.processIdentifier) < myKey
            }) {
                log.notice("another copy is running (pid \(other.processIdentifier)); handing over")
                if let url = other.bundleURL {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                        exit(0)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(0) }
                handingOver = true
                return
            }
        }
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !handingOver else { return }
        let prefs = Preferences.shared
        let power = Power.shared
        power.start()
        let lid = LidController(client: HelperClient(), prefs: prefs, hasLid: power.state.hasLid)
        let engine = Engine(prefs: prefs, power: power, lid: lid, assertions: PowerAssertions())
        self.lid = lid
        self.engine = engine
        statusItem = StatusItem(engine: engine, lid: lid)
        SettingsWindow.shared.make = { SettingsView(engine: engine, lid: lid, prefs: prefs) }

        // A plain SIGTERM would skip applicationShouldTerminate; route it through the normal quit.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            // Terminate from the run loop, never from inside this main-queue block: the reply to
            // applicationShouldTerminate comes from a main-actor Task that can't run while we are on the stack.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { NSApp.terminate(nil) }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        term.resume()
        termSource = term

        // The engine is wired at once; the lid controller holds any engage until its launch recovery is done.
        engine.start()
        Task { await lid.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (sender as? InsomniaApplication)?.terminationPending = true
        guard let engine else { return .terminateNow }
        Task { @MainActor in
            await engine.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opened again from Finder / Spotlight: show the panel.
        statusItem?.togglePanel()
        return false
    }

    /// App menu (⌘, ⌘Q) and ⌘W for the Settings window.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Insomnia")
        app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Insomnia", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        main.addItem(fileItem)
        return main
    }

    @objc private func showSettings(_ sender: Any?) { SettingsWindow.shared.show() }
}
