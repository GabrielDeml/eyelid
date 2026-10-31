import AppKit
import ServiceManagement
import SwiftUI

/// Settings ▸ General (docs/UX.md §4.1).
///
/// ```
/// Startup      Launch at login · Start keeping awake at launch
/// Behaviour    Default duration · menu bar click · timer text · Dock · notifications · global hotkey
/// Personality  [ Professional | Cheeky | Unhinged ]  + a live sample that reshuffles on change
/// ```
/// Every label is plain in every tier; only the sample line has personality.
struct GeneralTab: View {
    @Bindable private var settings = Settings.shared
    @State private var login = LaunchAtLogin()
    @State private var sample = ""
    private let hotKeys = HotKeyManager.shared

    private static let durations: [(minutes: Int, title: String)] = [
        (30, "30 minutes"), (60, "1 hour"), (120, "2 hours"), (240, "4 hours"), (480, "8 hours"), (0, "Until I stop"),
    ]

    var body: some View {
        Form {
            startup
            behaviour
            personality
        }
        .formStyle(.grouped)
        .onAppear {
            login.refresh()
            reshuffle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()   // the user may have changed Login Items in System Settings
        }
    }

    // MARK: Startup

    private var startup: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
            if let note = login.note {
                SettingsFootnote(text: note.text, symbol: note.isError ? "exclamationmark.triangle.fill" : "info.circle",
                                 tint: note.isError ? Theme.warning : .secondary)
                if note.offersSettings {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Toggle("Start keeping awake at launch", isOn: $settings.activateOnLaunch)
        }
    }

    // MARK: Behaviour

    private var behaviour: some View {
        Section("Behaviour") {
            Picker("Default duration", selection: $settings.defaultDurationMinutes) {
                ForEach(durationChoices, id: \.minutes) { choice in
                    Text(choice.title).tag(choice.minutes)
                }
            }

            Picker("Clicking the eyes in the menu bar", selection: $settings.leftClickAction) {
                ForEach(ClickAction.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()

            Picker("Show timer in menu bar", selection: $settings.menuBarTimer) {
                ForEach(MenuBarTimerStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Show in Dock", isOn: $settings.showInDock)

            Toggle("Notify before a timer ends and when it ends", isOn: Binding(
                get: { settings.sessionNotifications },
                set: { on in
                    settings.sessionNotifications = on
                    if on { Notifier.requestAuthorization() }
                }))

            LabeledContent("Global hotkey (toggle)") {
                HStack(spacing: 8) {
                    HotKeyRecorder(keyCode: $settings.hotKeyCode, modifiers: $settings.hotKeyModifiers,
                                   isEnabled: $settings.hotKeyEnabled)
                    Button("Clear") { settings.hotKeyEnabled = false }
                        .disabled(!settings.hotKeyEnabled)
                        .accessibilityLabel("Clear global hotkey")
                }
            }
            if settings.hotKeyEnabled, let failure = hotKeys.failureMessage {
                SettingsFootnote(text: failure, symbol: "exclamationmark.triangle.fill", tint: Theme.warning)
            } else {
                SettingsFootnote(text: "Include ⌘ or ⌃.")
            }
        }
    }

    /// The presets, plus the stored value if it isn't one (e.g. set with `defaults write`), so the picker never lies.
    private var durationChoices: [(minutes: Int, title: String)] {
        let stored = settings.defaultDurationMinutes
        guard !Self.durations.contains(where: { $0.minutes == stored }) else { return Self.durations }
        return Self.durations + [(stored, PlainCopy.spokenDuration(.minutes(stored)))]
    }

    // MARK: Personality

    private var personality: some View {
        Section {
            Picker("Personality", selection: $settings.personality) {
                ForEach(Personality.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Personality")

            Button(action: reshuffle) {
                Text("\u{201C}\(sample)\u{201D}")
                    .italic()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.plain)
            .help("Another sample")
            .accessibilityLabel("Sample line")
            .accessibilityValue(sample)
            .accessibilityHint("Shows another sample")
        } header: {
            Text("Personality")
        } footer: {
            Text(Self.blurb(settings.personality))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: settings.personality) { _, _ in reshuffle() }
    }

    private func reshuffle() {
        withAnimation(.easeInOut(duration: Theme.reduceMotion ? 0 : 0.2)) {
            sample = Narrator.shared.sample(settings.personality)
        }
    }

    private static func blurb(_ p: Personality) -> String {
        switch p {
        case .professional: return "Plain words only. No jokes anywhere; safety messages are always plain."
        case .cheeky: return "Dry and warm. A line now and then, never on every click."
        case .unhinged: return "Over-caffeinated theatre. Still kind. Still rare."
        }
    }
}

/// `SMAppService.mainApp` state for the "Launch at login" row. Reflects `.status`; shows the error when a change fails.
@MainActor
@Observable
final class LaunchAtLogin {
    struct Note: Equatable {
        var text: String
        var isError: Bool
        var offersSettings: Bool
    }

    private(set) var isOn = false
    private(set) var note: Note?
    /// What the user last asked for. An error note stays until the status matches it (R45); `.enabled` alone isn't
    /// enough, because a failed unregister also stays `.enabled`.
    @ObservationIgnored private var requested: Bool?

    func refresh() {
        apply(SMAppService.mainApp.status)
    }

    func apply(_ status: SMAppService.Status) {
        isOn = status == .enabled || status == .requiresApproval
        switch status {
        case .requiresApproval:
            note = Note(text: "Allow Insomnia in System Settings ▸ General ▸ Login Items.", isError: false,
                        offersSettings: true)
        case .enabled, .notRegistered, .notFound:
            if note?.isError != true || requested == isOn { note = nil }
        @unknown default:
            note = nil
        }
    }

    /// A register/unregister call failed.
    func recordFailure(_ on: Bool, code: Int) {
        requested = on
        note = Note(text: "Couldn't \(on ? "turn on" : "turn off") launch at login (code \(code)).", isError: true,
                    offersSettings: true)
    }

    func set(_ on: Bool) {
        requested = on
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            note = nil
        } catch {
            recordFailure(on, code: (error as NSError).code)
        }
        let previousError = note
        refresh()
        if previousError?.isError == true { note = previousError }
    }
}
