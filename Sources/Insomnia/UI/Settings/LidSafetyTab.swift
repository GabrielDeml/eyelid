import AppKit
import SwiftUI

// MARK: - Settings ▸ Lid & Safety (docs/UX.md §4.3)
//
// "Safety" on a Mac without a lid (only the opt-in awake battery floor), hidden by SettingsLayout when there's
// neither lid nor battery. The lid guards are always on; only their thresholds are configurable (Decision 9).

struct LidSafetyTab: View {
    @Bindable private var settings = Settings.shared
    private let lid = ClosedLidController.shared
    private let power = PowerMonitor.shared
    private let engine = AwakeEngine.shared

    @State private var setup: SetupSheet?
    @State private var confirmRemove = false
    @State private var confirmLegacy = false
    @State private var busy = false
    @State private var problem: SetupProblem?

    var body: some View {
        Form {
            if power.hasLid {
                helperSection
                lidSection
                guardsSection
            } else {
                safetyOnlySection
            }
        }
        .formStyle(.grouped)
        .task { await lid.refreshHelper() }
        .sheet(item: $setup) { sheet in
            LidSetupView(requestedLid: false, startAt: sheet.startAt) { setup = nil }
        }
        .confirmationDialog("Remove lid mode?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { run(.remove) }
        } message: {
            Text(lid.backendKind == .sudoers
                 ? "Lid mode turns off and Insomnia removes its sudoers rule and safety daemon. You'll be asked for your password."
                 : "Lid mode turns off and the helper is removed. Your Mac sleeps normally when the lid closes. You can set it up again anytime.")
        }
        .confirmationDialog("Remove the old password-based setup?", isPresented: $confirmLegacy) {
            Button("Remove old setup", role: .destructive) { run(.removeLegacy) }
        } message: {
            Text("An earlier unsigned build left a sudoers rule and a safety daemon. The helper doesn't use them. You'll be asked for your password.")
        }
    }

    // MARK: Status

    private var helperSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 8) {
                    StatusDot(kind: statusRow.dot)
                    Text(statusRow.text)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    if let info = statusRow.info { InfoButton(text: info) }
                    if busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                    statusButtons
                }
            }
            .accessibilityElement(children: .contain)
            if engine.lid == .stuck {
                LabeledContent {
                    Button("Reset with password…") { Task { await lid.resetWithPassword() } }
                } label: {
                    Label("Stuck on · your Mac won't sleep", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(Theme.dangerText)
                }
            }
            if let problem {
                ProblemText(problem: problem, repair: { run(.install) })
            }
            if lid.backendKind == .helper && lid.hasLegacySudoers {
                // The password prompt can stay up for minutes and lid mode's heartbeats would queue behind it.
                let lidActive = engine.lid == .engaging || { if case .engaged = engine.lid { true } else { false } }()
                LabeledContent("Old password-based setup found") {
                    Button("Remove old setup…") { confirmLegacy = true }
                        .disabled(busy || lidActive)
                        .help(lidActive ? "Turn lid mode off first" : "")
                }
            }
        } header: {
            Text("Stay awake with lid closed")
        }
    }

    @ViewBuilder private var statusButtons: some View {
        switch (lid.backendKind, lid.helper) {
        case (_, .installed):
            Button("Test…") { setup = SetupSheet(startAt: .done) }
            Button("Remove…") { confirmRemove = true }.disabled(busy)
        case (_, .notInstalled):
            Button("Set Up…") { setup = SetupSheet(startAt: .explain) }.disabled(lid.backendKind == nil)
        case (_, .requiresApproval):
            Button("Open System Settings") { setup = SetupSheet(startAt: .approve) }
        case (_, .unreachable), (_, .versionMismatch), (.sudoers, .partial):
            Button("Repair…") { run(.install) }.disabled(busy)
        case (_, .daemonDisabled):
            Button("Open Login Items") { lid.openApprovalSettings() }
        case (_, .leftoverHelper):
            Button("Remove…") { confirmRemove = true }.disabled(busy)
        default:
            EmptyView()
        }
    }

    private var statusRow: (dot: StatusDot.Kind, text: String, info: String?) {
        let sudoers = lid.backendKind == .sudoers
        switch lid.helper {
        case .installed:
            return (.ready, sudoers ? "Ready (sudoers rule ✓ · safety daemon ✓)" : "Ready · helper allowed", nil)
        case .notInstalled: return (.off, "Not set up", nil)
        case .requiresApproval: return (.pending, "Waiting for your OK in System Settings", nil)
        case .unreachable, .versionMismatch: return (.pending, "Helper isn't responding", nil)
        case .unsafeLocation:
            return (.warning, "Install Insomnia with make install to use lid mode", LidSetupCopy.unsafeLocationInfo)
        case .notFound: return (.warning, "Helper missing from the app. Reinstall Insomnia.", nil)
        case .leftoverHelper: return (.pending, "A helper from a signed build is still registered", nil)
        case .partial(let rule, let daemon):
            let missing = !daemon ? "safety daemon missing" : (!rule ? "sudoers rule missing or not working" : "incomplete")
            return (.pending, "Partly installed: \(missing)", nil)
        case .daemonDisabled: return (.pending, "Safety daemon is off in Login Items", nil)
        }
    }

    // MARK: Lid behaviour

    private var lidSection: some View {
        Section {
            LabeledContent("Turn the screen off when the lid closes") {
                HStack(spacing: 4) {
                    Text("always on").foregroundStyle(.secondary)
                    InfoButton(text: "With no external display attached, Insomnia turns the built-in screen off when the lid closes. With one attached it never does, so your external display stays on.")
                }
            }
            Toggle("Only on power adapter", isOn: $settings.lidRequiresAC)
            LabeledContent("Time limit with the lid closed") { EmptyView() }
            Picker("On battery", selection: $settings.lidMaxOnBatteryMinutes) {
                ForEach(Settings.lidBatteryCapChoices, id: \.self) { Text(Self.duration($0)).tag($0) }
            }
            .padding(.leading, 14)
            LabeledContent {
                HStack(spacing: 8) {
                    Toggle("Limit on power adapter", isOn: $settings.lidCapOnACEnabled).labelsHidden()
                    Picker("Limit on power adapter", selection: $settings.lidMaxOnACMinutes) {
                        ForEach(Settings.lidACCapChoices, id: \.self) { Text(Self.duration($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!settings.lidCapOnACEnabled)
                }
            } label: {
                Text("On power adapter")
            }
            .padding(.leading, 14)
            Footnote("On battery there's always a limit; on power, lid mode runs until you stop it unless you set one.")
        }
    }

    // MARK: Guards

    private var guardsSection: some View {
        Section("Guards") {
            floorSlider(label: "Turn off lid mode at battery")
            if power.hasBattery {
                Toggle("Also stop keeping awake at that level", isOn: $settings.awakeBatteryFloorEnabled)
            }
            LabeledContent("Pause lid mode when your Mac runs hot") {
                HStack(spacing: 4) {
                    Text("always on").foregroundStyle(.secondary)
                    InfoButton(text: "Pauses when macOS reports serious heat, or after 5 minutes of moderate heat with the lid closed on battery. Resumes after it has cooled for a minute.")
                }
            }
            LabeledContent("Pause lid mode in Low Power Mode") {
                HStack(spacing: 4) {
                    Text("always on").foregroundStyle(.secondary)
                    InfoButton(text: "Low Power Mode means you want the battery to last. Lid mode waits until it's off.")
                }
            }
            Footnote("Lid mode disables macOS's own low-battery sleep, so its guards can't be switched off.",
                     symbol: "info.circle")
        }
    }

    /// No lid: the opt-in awake floor only.
    private var safetyOnlySection: some View {
        Section("Battery") {
            Toggle("Stop keeping awake at low battery", isOn: $settings.awakeBatteryFloorEnabled)
            floorSlider(label: "Stop at battery")
                .disabled(!settings.awakeBatteryFloorEnabled)
            Footnote("Ends a timer or ∞ session and pauses rules until you plug in.")
        }
    }

    private func floorSlider(label: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { Double(settings.batteryFloorPercent) },
                                      set: { settings.batteryFloorPercent = Int($0.rounded()) }),
                       in: 10...50)
                    .frame(width: 180)
                    .accessibilityLabel(label)
                    .accessibilityValue("\(settings.batteryFloorPercent) percent")
                Text("\(settings.batteryFloorPercent)%")
                    .font(.body.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Helpers

    private enum Operation { case install, remove, removeLegacy }

    private func run(_ op: Operation) {
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do throws(LidSetupError) {
                switch op {
                case .install: try await lid.install()
                case .remove: try await lid.uninstall()
                case .removeLegacy: try await lid.removeLegacySudoers()
                }
            } catch .cancelled {
                // A cancelled password prompt changes nothing and says nothing.
            } catch {
                problem = LidSetupCopy.problem(for: error)
            }
        }
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let h = minutes / 60
        return h == 1 ? "1 hour" : "\(h) hours"
    }

    private struct SetupSheet: Identifiable {
        let id = UUID()
        let startAt: LidSetupView.Step
    }
}

// MARK: - Small pieces

private struct StatusDot: View {
    enum Kind { case ready, off, pending, warning }
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .ready: Image(systemName: "circle.fill").foregroundStyle(.green)
            case .off: Image(systemName: "circle").foregroundStyle(.secondary)
            case .pending: Image(systemName: "circle.lefthalf.filled").foregroundStyle(Theme.warning)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
        }
        .font(.caption)
        .accessibilityHidden(true)   // the text next to it carries the meaning
    }
}

private struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help(text)
            .accessibilityLabel("More info")
            .accessibilityHint(text)
            .popover(isPresented: $shown) {
                Text(text).padding(12).frame(width: 280).fixedSize(horizontal: false, vertical: true)
            }
    }
}

private struct Footnote: View {
    let text: String
    var symbol: String?
    init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
