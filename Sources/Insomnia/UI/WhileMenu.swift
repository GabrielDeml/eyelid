import AppKit
import SwiftUI

// MARK: - While… (babysit) menu and prompts (UX.md §2.2 F)
//
//   Stop watching ffmpeg (4411)      (only while babysitting)
//   ───────────
//   Running apps ▸   (regular apps, with icons)
//   Suggested ▸      (claude, codex, xcodebuild, ffmpeg, rsync, make, cargo, npm, python3 that the matcher finds, with pid)
//   ───────────
//   Process name…    (small popover: name field, live "Running · pid 4411", Start)
//   PID…             (small popover: number field, live process name, Start)
//
// Wire it with `model.whileMenuProvider = WhileMenu.provider(for: model)`. Choices go through
// `model.send(.babysit(target))` → `AwakeEngine.babysit`, so the panel stays the only path to the engine.

@MainActor
enum WhileMenu {
    /// The `PanelModel.whileMenuProvider` closure. Holds the model weakly.
    static func provider(for model: PanelModel, monitor: WatchMonitor = .shared) -> () -> NSMenu {
        { [weak model] in
            let current: WatchTarget? = {
                if case .babysit(let t)? = AwakeEngine.shared.babysitHold?.owner { return t }
                return nil
            }()
            return make(monitor: monitor, current: current, anchor: model?.whileAnchor,
                        choose: { model?.send(.babysit($0)) },
                        stop: { model?.send(.stopBabysit) })
        }
    }

    static func make(monitor: WatchMonitor, current: WatchTarget?, anchor: NSView?,
                     choose: @escaping @MainActor (WatchTarget) -> Void,
                     stop: @escaping @MainActor () -> Void) -> NSMenu {
        let menu = NSMenu(title: "While…")
        menu.autoenablesItems = false

        if let current {
            menu.addItem(item("Stop watching \(monitor.displayNameWithPID(current))", action: stop))
            menu.addItem(.separator())
        }

        // Running apps ▸
        let appsItem = NSMenuItem(title: "Running apps", action: nil, keyEquivalent: "")
        let appsMenu = NSMenu(title: "Running apps")
        appsMenu.autoenablesItems = false
        let apps = monitor.runningApps()
        if apps.isEmpty {
            appsMenu.addItem(disabled("No apps running"))
        }
        for app in apps {
            let target = WatchTarget.app(bundleID: app.bundleID, name: app.name)
            let entry = item(app.name) { choose(target) }
            let icon = app.icon.copy() as? NSImage ?? app.icon
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            if case .app(let id, _)? = current, id == app.bundleID { entry.state = .on }
            entry.setAccessibilityLabel("While \(app.name) runs")
            appsMenu.addItem(entry)
        }
        appsItem.submenu = appsMenu
        menu.addItem(appsItem)

        // Suggested ▸ (the process scan runs off the main thread; the menu opens with the last result, then updates)
        let suggestedItem = NSMenuItem(title: "Suggested", action: nil, keyEquivalent: "")
        let suggestedMenu = NSMenu(title: "Suggested")
        suggestedMenu.autoenablesItems = false
        fillSuggested(suggestedMenu, monitor.lastSuggested, current: current, choose: choose)
        Task { @MainActor [weak suggestedMenu] in
            let fresh = await monitor.runningSuggestedProcesses()
            guard let suggestedMenu else { return }
            fillSuggested(suggestedMenu, fresh, current: current, choose: choose)
        }
        suggestedItem.submenu = suggestedMenu
        menu.addItem(suggestedItem)

        menu.addItem(.separator())
        menu.addItem(item("Process name…") { WhilePrompt.show(.processName, from: anchor, start: choose) })
        menu.addItem(item("PID…") { WhilePrompt.show(.pid, from: anchor, start: choose) })
        return menu
    }

    /// nil = no scan finished yet.
    private static func fillSuggested(_ menu: NSMenu, _ suggested: [(name: String, pid: Int32)]?, current: WatchTarget?,
                                      choose: @escaping @MainActor (WatchTarget) -> Void) {
        menu.removeAllItems()
        guard let suggested else {
            menu.addItem(disabled("Looking…"))
            return
        }
        if suggested.isEmpty {
            menu.addItem(disabled("None running right now"))
            menu.addItem(disabled("Looks for " + WatchMonitor.suggestedNames.joined(separator: ", ")))
        }
        for p in suggested {
            let target = WatchTarget.pid(p.pid, name: p.name)
            let entry = item("\(p.name) (\(p.pid))") { choose(target) }
            if current == target { entry.state = .on }
            entry.setAccessibilityLabel("While \(p.name), process \(p.pid), runs")
            menu.addItem(entry)
        }
    }

    private static func item(_ title: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        ActionMenuItem(title, handler: action)
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }
}

// MARK: - Process name… / PID… prompt (a small popover on the While… chip; never a modal)

@MainActor
final class WhilePrompt: NSObject, NSPopoverDelegate {
    enum Kind: Equatable, Sendable { case processName, pid }

    /// What the field currently resolves to.
    enum Lookup: Equatable, Sendable {
        case empty
        /// Can't start: shown in secondary text.
        case unavailable(String)
        /// Can start: `summary` like "Running · pid 4411" / "3 running · pid 4411, 4420, 4502".
        case found(WatchTarget, summary: String)

        var target: WatchTarget? { if case .found(let t, _) = self { return t } else { return nil } }
    }

    private static var current: WhilePrompt?
    private let popover = NSPopover()
    private var closeObserver: NSObjectProtocol?

    /// Shows the prompt below `anchor` (the While… chip). Without an anchor (panel gone) it does nothing.
    static func show(_ kind: Kind, from anchor: NSView?, start: @escaping @MainActor (WatchTarget) -> Void) {
        current?.close()
        guard let anchor, anchor.window != nil else { return }
        let prompt = WhilePrompt()
        current = prompt
        prompt.present(kind, from: anchor, start: start)
    }

    private func present(_ kind: Kind, from anchor: NSView, start: @escaping @MainActor (WatchTarget) -> Void) {
        let view = WhilePromptView(kind: kind, lookup: { await Self.lookup(kind, $0) }) { [weak self] target in
            self?.close()
            start(target)
        }
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = !Theme.reduceMotion
        popover.delegate = self
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        // The panel closing takes the prompt with it.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: anchor.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
        finish()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { finish() }
    }

    private func finish() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if Self.current === self { Self.current = nil }
    }

    // MARK: Lookups (off the main thread for the process scan)

    static func lookup(_ kind: Kind, _ text: String) async -> Lookup {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        switch kind {
        case .processName:
            let key = trimmed.lowercased()
            let raw = await Task.detached(priority: .userInitiated) { ProcessTable.scan([key]) }.value
            // The same app filter as rules and watches: Claude.app is not the `claude` CLI.
            let appPIDs = WatchMonitor.appPIDs(LiveWatchSystem().runningApps())
            let pids = (ProcessMatcher.excludingApps(raw, appPIDs: appPIDs)[key] ?? []).map(\.pid)
            return processLookup(name: trimmed, pids: pids, appMatched: pids.isEmpty && !(raw[key] ?? []).isEmpty)
        case .pid:
            guard let pid = Int32(trimmed), pid > 0 else { return .unavailable("Enter a process number") }
            if pid == getpid() { return .unavailable("That's Insomnia itself") }
            let alive = ProcessTable.isAlive(pid)
            let name = alive ? ProcessTable.displayName(pid: pid) : nil
            return pidLookup(pid: pid, alive: alive, name: name)
        }
    }

    /// Pure: the result for a process name and the PIDs that match it. `appMatched`: only running apps matched.
    static func processLookup(name: String, pids: [Int32], appMatched: Bool = false) -> Lookup {
        let sorted = pids.sorted()
        if sorted.isEmpty, appMatched { return .unavailable("That's an app: use Running apps") }
        guard let first = sorted.first else { return .unavailable("No running process named \u{201C}\(name)\u{201D}") }
        let summary: String
        if sorted.count == 1 {
            summary = "Running · pid \(first)"
        } else {
            let shown = sorted.prefix(3).map(String.init).joined(separator: ", ")
            summary = "\(sorted.count) running · pid \(shown)\(sorted.count > 3 ? ", …" : "")"
        }
        return .found(.process(name: name), summary: summary)
    }

    /// Pure: the result for a PID. `name` comes from `ProcessTable.displayName(pid:)`; unresolved → "pid N" (which
    /// `WatchTarget.displayName` shows once, not as "pid N (N)").
    static func pidLookup(pid: Int32, alive: Bool, name: String?) -> Lookup {
        guard alive else { return .unavailable("No process with PID \(pid)") }
        let resolved = (name?.isEmpty == false ? name : nil) ?? "pid \(pid)"
        return .found(.pid(pid, name: resolved), summary: resolved)
    }
}

/// The prompt's content. Live lookup (debounced 200 ms) so Start is enabled only for something that runs.
struct WhilePromptView: View {
    let kind: WhilePrompt.Kind
    let lookup: @MainActor (String) async -> WhilePrompt.Lookup
    let start: @MainActor (WatchTarget) -> Void

    @State private var text = ""
    @State private var result: WhilePrompt.Lookup = .empty
    /// The text `result` was computed for: Start never acts on a stale lookup.
    @State private var resolvedText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep awake while")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(kind == .processName ? "Process name" : "PID", text: $text,
                      prompt: Text(kind == .processName ? "e.g. ffmpeg" : "e.g. 4411"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 13, design: kind == .pid ? .monospaced : .default))
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel(kind == .processName ? "Process name" : "Process ID")
            HStack(alignment: .firstTextBaseline) {
                Text(statusText)
                    .font(Theme.subline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(statusText.isEmpty ? "" : statusText)
                Spacer(minLength: 8)
                Button("Start", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                    .disabled(readyTarget == nil)
            }
        }
        .padding(14)
        .frame(width: 250)
        .onAppear { focused = true }
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let r = await lookup(text)
            guard !Task.isCancelled else { return }
            result = r
            resolvedText = text
        }
    }

    private var statusText: String {
        switch result {
        case .empty: return kind == .processName ? "Matches app, tool or script names" : "Find it in Activity Monitor"
        case .unavailable(let why): return why
        case .found(_, let summary): return summary
        }
    }

    private var readyTarget: WatchTarget? { resolvedText == text ? result.target : nil }

    private func submit() {
        guard let target = readyTarget else { return }
        start(target)
    }
}
