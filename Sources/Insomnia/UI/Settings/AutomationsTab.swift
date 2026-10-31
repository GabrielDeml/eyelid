import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings ▸ Automations (UX.md §4.2)
//
//   Rules: keep awake automatically
//     [●] While [Xcode ▾] is running        ☐ screen  ☐ lid   ●  [−]
//     [●] While process [ffmpeg     ] runs  ☑ screen  ☐ lid   ○  [−]
//     [+ Add rule ▾]
//   Command line            (SettingsTabContent passes `AutomationsTab { CLIInstallView() }`)
//   URL scheme              recipes with copy buttons
//
// Rules are sentence-shaped rows, never a modal form. Edits write `Settings.rules` (key "rules.v1"); WatchMonitor and
// the engine pick them up from the settings notification.

struct AutomationsTab<CommandLine: View>: View {
    private let commandLine: CommandLine
    private let hasCommandLine: Bool

    /// - Parameter commandLine: the "Command line" section's rows (CLI install status, Reinstall / Remove, PATH hint).
    init(@ViewBuilder commandLine: () -> CommandLine) {
        self.commandLine = commandLine()
        self.hasCommandLine = CommandLine.self != EmptyView.self
    }

    var body: some View {
        Form {
            RulesSection()
            if hasCommandLine {
                Section("Command line") { commandLine }
            }
            URLSchemeSection()
        }
        .formStyle(.grouped)
    }
}

extension AutomationsTab where CommandLine == EmptyView {
    /// Without a Command line section (snapshots, previews).
    init() { self.init { EmptyView() } }
}

// MARK: - Rules

private struct RulesSection: View {
    @State private var focusRuleID: Rule.ID?
    private let settings = Settings.shared
    private let monitor = WatchMonitor.shared
    private let engine = AwakeEngine.shared
    private let power = PowerMonitor.shared

    var body: some View {
        Section {
            if settings.rules.isEmpty {
                Text("No rules yet. Add one and Insomnia keeps your Mac awake on its own while it applies.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.rules) { rule in
                RuleRow(rule: rule,
                        state: state(of: rule),
                        hasLid: power.hasLid,
                        focusName: focusRuleID == rule.id,
                        update: { replace($0) },
                        remove: { remove(rule.id) })
            }
            AddRuleMenu(hasBattery: power.hasBattery, existing: settings.rules) { add($0) }
        } header: {
            Text("Rules: keep awake automatically")
        } footer: {
            Text(power.hasLid
                 ? "Rules never override a guard. The panel's lid switch applies to rules too; \u{201C}lid\u{201D} here means \u{201C}even when the switch is off\u{201D}. It still needs lid mode set up."
                 : "Rules never override a guard. Clicking the open eyes pauses a rule until its condition ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func state(of rule: Rule) -> RuleRow.State {
        guard rule.enabled else { return .off }
        guard monitor.satisfiedRules.contains(where: { $0.id == rule.id }) else { return .inactive }
        return engine.pausedRuleIDs.contains(rule.id) ? .paused : .active
    }

    private func add(_ condition: RuleCondition) {
        let rule = Rule(condition: condition)   // screen and lid default to off (UX.md §4.2)
        settings.rules.append(rule)
        if case .process(let name) = condition, name.isEmpty { focusRuleID = rule.id }
    }

    private func replace(_ rule: Rule) {
        guard let i = settings.rules.firstIndex(where: { $0.id == rule.id }), settings.rules[i] != rule else { return }
        settings.rules[i] = rule
    }

    private func remove(_ id: Rule.ID) {
        settings.rules.removeAll { $0.id == id }
    }
}

private struct RuleRow: View {
    enum State { case off, inactive, active, paused }

    let rule: Rule
    let state: State
    let hasLid: Bool
    let focusName: Bool
    let update: (Rule) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Rule on", isOn: binding(\.enabled))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Rule: \(sentence)")
            RuleSentence(rule: rule, focusName: focusName, update: update)
                .foregroundStyle(rule.enabled ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("screen", isOn: binding(\.keepScreenOn))
                .toggleStyle(.checkbox)
                .help("Also keep the screen on while this rule applies")
                .accessibilityLabel("Keep screen on for this rule")
            if hasLid {
                Toggle("lid", isOn: binding(\.allowLid))
                    .toggleStyle(.checkbox)
                    .help("Stay awake with the lid closed for this rule, even when the panel's switch is off. Needs lid mode set up.")
                    .accessibilityLabel("Lid mode for this rule")
            }
            StateDot(state: state)
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove rule")
            .accessibilityLabel("Remove rule: \(sentence)")
        }
        .font(.system(size: 13))
    }

    private var sentence: String {
        switch rule.condition {
        case .app(_, let name): return "While \(name) is running"
        case .process(let name): return "While process \(name.isEmpty ? "(unnamed)" : name) runs"
        case .onAC: return "While on power adapter"
        case .externalDisplay: return "While an external display is connected"
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Rule, Bool>) -> Binding<Bool> {
        Binding(get: { rule[keyPath: keyPath] }, set: { new in
            var copy = rule
            copy[keyPath: keyPath] = new
            update(copy)
        })
    }
}

/// "While [Xcode ▾] is running" / "While process [ffmpeg] runs" / "While on power adapter" / "While an external
/// display is connected".
private struct RuleSentence: View {
    let rule: Rule
    let focusName: Bool
    let update: (Rule) -> Void

    var body: some View {
        switch rule.condition {
        case .app(let bundleID, let name):
            HStack(spacing: 5) {
                Text("While")
                AppPickerMenu(title: name, selectedBundleID: bundleID) { id, newName in
                    var copy = rule
                    copy.condition = .app(bundleID: id, name: newName)
                    update(copy)
                }
                Text("is running")
            }
        case .process(let name):
            HStack(spacing: 5) {
                Text("While process")
                ProcessNameField(name: name, focusOnAppear: focusName) { newName in
                    var copy = rule
                    copy.condition = .process(name: newName)
                    update(copy)
                }
                Text("runs")
            }
        case .onAC:
            Text("While on power adapter")
        case .externalDisplay:
            Text("While an external display is connected")
        }
    }
}

/// Inline name field: commits on Return or when it loses focus (never on every keystroke).
private struct ProcessNameField: View {
    let name: String
    let focusOnAppear: Bool
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Process name", text: $text, prompt: Text("name"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .frame(width: 110)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onAppear {
                text = name
                if focusOnAppear { focused = true }
            }
            .onChange(of: name) { _, new in if !focused { text = new } }
            .help("Matches the app, tool or script name, e.g. ffmpeg, claude, make")
            .accessibilityLabel("Process name")
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != text { text = trimmed }
        if trimmed != name { commit(trimmed) }
    }
}

/// "[Xcode ▾]": running apps plus Choose… (any app in /Applications).
private struct AppPickerMenu: View {
    let title: String
    let selectedBundleID: String
    let choose: (_ bundleID: String, _ name: String) -> Void

    var body: some View {
        Menu {
            RunningAppItems(selectedBundleID: selectedBundleID, choose: choose)
            Divider()
            Button("Choose…") {
                if let app = AppChooser.chooseApp() { choose(app.bundleID, app.name) }
            }
        } label: {
            Text(title)
        }
        .fixedSize()
        .accessibilityLabel("App: \(title)")
    }
}

private struct RunningAppItems: View {
    var selectedBundleID: String?
    let choose: (_ bundleID: String, _ name: String) -> Void

    var body: some View {
        let apps = WatchMonitor.shared.runningApps()
        if apps.isEmpty {
            Text("No apps running")
        }
        ForEach(apps, id: \.bundleID) { app in
            Button {
                choose(app.bundleID, app.name)
            } label: {
                if app.bundleID == selectedBundleID {
                    Label(app.name, systemImage: "checkmark")
                } else {
                    Text(app.name)
                }
            }
        }
    }
}

private struct AddRuleMenu: View {
    let hasBattery: Bool
    let existing: [Rule]
    let add: (RuleCondition) -> Void

    var body: some View {
        Menu {
            Button("App…") {
                if let app = AppChooser.chooseApp() { add(.app(bundleID: app.bundleID, name: app.name)) }
            }
            Menu("Running app") {
                RunningAppItems { id, name in add(.app(bundleID: id, name: name)) }
            }
            Button("Process name…") { add(.process(name: "")) }
            Divider()
            if hasBattery {
                Button("On power adapter") { add(.onAC) }
                    .disabled(existing.contains { $0.condition == .onAC })
            }
            Button("External display connected") { add(.externalDisplay) }
                .disabled(existing.contains { $0.condition == .externalDisplay })
        } label: {
            Label("Add rule", systemImage: "plus")
        }
        .fixedSize()
        .accessibilityLabel("Add rule")
    }
}

private struct StateDot: View {
    let state: RuleRow.State

    var body: some View {
        let (symbol, color, label): (String, Color, String) = switch state {
        case .active: ("circle.fill", Theme.accentAwake, "Active now")
        case .paused: ("circle.lefthalf.filled", Color.secondary, "Paused from the eyes until it stops")
        case .inactive: ("circle", Color.secondary, "Not active")
        case .off: ("circle.dashed", Color.secondary.opacity(0.6), "Rule off")
        }
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 12)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// NSOpenPanel for an .app bundle. Returns nil when cancelled or the bundle has no identifier.
@MainActor
private enum AppChooser {
    static func chooseApp() -> (bundleID: String, name: String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Choose"
        panel.message = "Keep your Mac awake while this app is running"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (id, name)
    }
}

// MARK: - URL scheme

private struct URLSchemeSection: View {
    private static let recipes = [
        "insomnia://on?for=45m",
        "insomnia://on?until=17:30&screen=1",
        "insomnia://off",
        "insomnia://extend?by=15m",
        "insomnia://toggle",
        "insomnia://panel",
        "insomnia://sleep",
    ]

    var body: some View {
        Section {
            ForEach(Self.recipes, id: \.self) { CopyableRow(text: $0) }
        } header: {
            Text("URL scheme")
        } footer: {
            Text("Works from Shortcuts \u{2192} \u{201C}Open URLs\u{201D} or Terminal \u{2192} open \u{201C}\u{2026}\u{201D}. Links can't turn lid mode on, so use the command line for that.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Monospaced text with a copy button that briefly confirms.
private struct CopyableRow: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy \(text)")
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}
