import AppKit
import ServiceManagement
import SwiftUI

/// The one-page Settings window. The panel's rows are the same settings, so a change shows in both.
struct SettingsView: View {
    let engine: Engine
    let lid: LidController
    @Bindable var prefs: Preferences
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        let p = engine.powerState
        Form {
            Section {
                Picker("Turn Eyelid off after", selection: $prefs.powerButtonMinutes) {
                    Text("Never").tag(0)
                    ForEach(Preferences.durationChoices, id: \.self) { Text(DurationText.hours(minutes: $0)).tag($0) }
                }
                Toggle("Keep screen on", isOn: $prefs.keepScreenOn)
                Picker(selection: $prefs.clickAction) {
                    ForEach(ClickAction.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Click the menu bar icon to")
                    Text(prefs.clickAction == .openPanel ? "Right-click to turn Eyelid on or off."
                                                         : "Right-click to open the panel.")
                }
            }

            if p.hasLid && lid.setup != .noLid {
                Section {
                    Toggle(isOn: Binding(get: { prefs.closedLidMode && lidUsable }, set: { engine.setLidMode($0) })) {
                        Text("Stay awake with lid closed")
                        Text("While Eyelid is on, Sleep in the Apple menu doesn't work.")
                    }
                    .disabled(!lidUsable)
                    if p.hasBattery { unpluggedPicker(lidMode: prefs.closedLidMode) }
                    if let helperStatus {
                        LabeledContent("Lid helper") {
                            HStack(spacing: 8) {
                                Text(helperStatus).foregroundStyle(.secondary)
                                if lid.state == .stuck {
                                    Button("Reset with Password…") { lid.resetWithPassword() }
                                } else if lid.setup == .notRegistered, !lid.installing {
                                    Button("Set Up…") { lid.install() }
                                } else if lid.setup == .needsApproval {
                                    Button("Open System Settings") { lid.openLoginItems() }
                                }
                            }
                        }
                    }
                }
            } else if p.hasBattery {
                Section { unpluggedPicker(lidMode: false) }
            }

            Section {
                Toggle(isOn: $prefs.overheatProtection) {
                    Text("Turn Eyelid off if your Mac gets hot")
                    Text(overheatNote(p))
                }
                Toggle(isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin)) {
                    Text("Open at login")
                    if let loginError { Text(loginError).foregroundStyle(Theme.dangerText) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(maxHeight: max(400, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        .task { await lid.refreshSetup() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func unpluggedPicker(lidMode: Bool) -> some View {
        Picker(selection: Binding(get: { UnpluggedAction.shown(prefs.whenUnplugged, lidMode: lidMode) },
                                  set: { prefs.whenUnplugged = $0 })) {
            ForEach(UnpluggedAction.choices(lidMode: lidMode)) { Text($0.title).tag($0) }
        } label: {
            Text("When unplugged")
            Text("At \(Engine.lowBatteryPercent)% battery, Eyelid turns off or puts your Mac to sleep.")
        }
    }

    private var lidUsable: Bool {
        ![.notInApplications, .unsigned, .missingFiles].contains(lid.setup)
    }

    /// Only when the lid helper needs something; nothing when it's ready or not wanted.
    private var helperStatus: String? {
        if lid.state == .stuck { return "Couldn't turn sleep back on" }
        switch lid.setup {
        case .notInApplications: return "Works only when installed in Applications"
        case .unsigned: return "Needs a signed build"
        case .missingFiles: return "Missing from this build"
        case .needsApproval: return "Needs your approval"
        case .notRegistered: return prefs.closedLidMode ? (lid.installing ? "Setting up" : "Not set up") : nil
        case .noLid, .ready: return nil
        }
    }

    private func overheatNote(_ p: PowerState) -> String {
        let s = "If no one is using your Mac, Eyelid puts it to sleep instead."
        return p.hasLid ? s + " While it stays awake with the lid closed, this can't be turned off." : s
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let code = (error as NSError).code
            loginError = on ? "Couldn't add Eyelid to Login Items (error \(code))."
                            : "Couldn't remove Eyelid from Login Items (error \(code))."
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
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
            w.title = "Eyelid Settings"
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
