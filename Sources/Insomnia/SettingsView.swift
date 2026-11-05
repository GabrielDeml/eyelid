import AppKit
import ServiceManagement
import SwiftUI

/// The one-page Settings window. Everything is optional: the panel's three rows are the same settings.
struct SettingsView: View {
    let engine: Engine
    let lid: LidController
    @Bindable var prefs: Preferences
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        let p = engine.powerState
        Form {
            Section("Keep awake") {
                Picker("Power button keeps awake", selection: $prefs.powerButtonMinutes) {
                    Text("Until turned off").tag(0)
                    ForEach([60, 120, 240, 480], id: \.self) { Text(DurationText.short(minutes: $0)).tag($0) }
                }
                LabeledContent("Timer buttons") {
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { i in
                            Picker("", selection: presetBinding(i)) {
                                ForEach(Preferences.presetChoices, id: \.self) {
                                    Text(DurationText.short(minutes: $0)).tag($0)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                Toggle("Keep screen on", isOn: $prefs.keepScreenOn)
                Picker("Clicking the moon", selection: $prefs.clickAction) {
                    ForEach(ClickAction.allCases) { Text($0.title).tag($0) }
                }
                Text(prefs.clickAction == .openPanel ? "Right-click turns Insomnia on or off."
                                                     : "Right-click opens the panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if p.hasLid && lid.setup != .noLid {
                Section("Lid closed") {
                    Toggle("Stay awake with lid closed", isOn: Binding(
                        get: { prefs.closedLidMode && lidUsable },
                        set: { engine.setLidMode($0) }))
                        .disabled(!lidUsable)
                    LabeledContent("Lid-mode helper") {
                        HStack(spacing: 8) {
                            Text(helperStatus).foregroundStyle(.secondary)
                            if lid.setup == .notRegistered { Button("Set Up…") { lid.install() } }
                            if lid.setup == .needsApproval { Button("Open System Settings") { lid.openLoginItems() } }
                            if lid.state == .stuck { Button("Reset with Password…") { lid.resetWithPassword() } }
                        }
                    }
                    if p.hasBattery {
                        Picker("When unplugged", selection: unplugged) {
                            ForEach(UnpluggedAction.choices(lidMode: prefs.closedLidMode)) { Text($0.title).tag($0) }
                        }
                    }
                    Text("While lid mode is on, the Apple menu's Sleep is blocked by macOS: turn Insomnia off first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if p.hasBattery {
                Section("Power") {
                    Picker("When unplugged", selection: unplugged) {
                        ForEach(UnpluggedAction.choices(lidMode: false)) { Text($0.title).tag($0) }
                    }
                }
            }

            Section("Safety") {
                Toggle("Overheat protection", isOn: $prefs.overheatProtection)
                if !prefs.overheatProtection {
                    Text("Insomnia won't step in if your Mac gets hot. With the lid closed, macOS may not either.")
                        .font(.caption).foregroundStyle(Theme.warningText)
                }
                if p.hasBattery {
                    Toggle("Low battery protection", isOn: $prefs.lowBatteryProtection)
                    Stepper(value: $prefs.lowBatteryPercent, in: Preferences.lowBatteryRange) {
                        LabeledContent("At or below", value: "\(prefs.lowBatteryPercent)%")
                    }
                    .disabled(!prefs.lowBatteryProtection)
                }
                Picker("With the lid open", selection: $prefs.tripAction) {
                    ForEach(TripAction.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.overheatProtection && !(p.hasBattery && prefs.lowBatteryProtection))
                Text(safetyFootnote(hasBattery: p.hasBattery))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(Theme.dangerText) }
                LabeledContent("Menu bar") { legend }
                HStack {
                    Spacer()
                    Button("Quit Insomnia") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(idealHeight: 760, maxHeight: max(400, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        .task { await lid.refreshSetup() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var unplugged: Binding<UnpluggedAction> {
        Binding(get: { UnpluggedAction.shown(prefs.whenUnplugged, lidMode: prefs.closedLidMode) },
                set: { prefs.whenUnplugged = $0 })
    }

    private var lidUsable: Bool {
        ![.notInApplications, .unsigned, .missingFiles].contains(lid.setup)
    }

    private var helperStatus: String {
        if lid.state == .stuck { return "Sleep is stuck off" }
        switch lid.setup {
        case .noLid: return "Not available"
        case .notInApplications: return "Needs the copy in Applications (make install)"
        case .unsigned: return "Needs a signed build"
        case .missingFiles: return "Missing from this build"
        case .notRegistered: return "Not set up"
        case .needsApproval: return "Waiting for approval"
        case .ready: return lid.isEngaged ? "Ready · holding sleep off" : "Ready"
        }
    }

    private func safetyFootnote(hasBattery: Bool) -> String {
        let what = hasBattery ? "When your Mac gets hot or the battery runs low" : "When your Mac gets hot"
        return what + " while Insomnia keeps it awake, it lets go. With the lid closed it always sleeps the Mac."
            + (hasBattery ? " The lid helper also sleeps the Mac at 10% battery, whatever these say." : "")
    }

    private func presetBinding(_ i: Int) -> Binding<Int> {
        Binding(get: { prefs.timerPresets[i] },
                set: { v in var all = prefs.timerPresets; all[i] = v; prefs.timerPresets = all })
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Couldn't change this (\((error as NSError).code))."
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([(Engine.Mode.off, "Off"), (.awake, "Awake"), (.screenOn, "Screen on"), (.lid, "Lid")], id: \.1) { m, name in
                VStack(spacing: 3) {
                    Image(nsImage: MoonGlyph.image(mode: m, attention: false))
                    Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 3) {
                Image(nsImage: MoonGlyph.image(mode: .awake, attention: true))
                Text("Attention").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    var make: (() -> SettingsView)?

    func show() {
        if window == nil, let make {
            let host = NSHostingController(rootView: make())
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "Insomnia Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            host.view.layoutSubtreeIfNeeded()
            w.setContentSize(host.view.fittingSize)   // size first, so center() keeps it on screen
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
