#if DEBUG   // the --snapshot review renderer ships only in debug builds (make snapshot)
import AppKit
import SwiftUI

/// `--snapshot` additions for the lid setup sheet (all three steps) and the Automations, Lid & Safety and Diagnostics
/// Settings tabs, light and dark. Read-only like the rest of `Snapshot`: PowerMonitor is started only to read this
/// Mac's real lid/battery (so Lid & Safety shows the MacBook layout); the lid controller is never started, so the lid
/// views show the pre-launch state (backend unresolved, helper not installed) and nothing is registered or written.
extension Snapshot {
    static func integrationSheets(to dir: URL) -> Bool {
        var ok = true
        PowerMonitor.shared.start()
        let shots: [(String, AnyView)] = [
            ("lid-setup-explain", AnyView(sheet(LidSetupView(requestedLid: true, startAt: .explain, approvalWatcher: UUID(), onClose: {})))),
            ("lid-setup-approve", AnyView(sheet(LidSetupView(requestedLid: true, startAt: .approve, approvalWatcher: UUID(), onClose: {})))),
            ("lid-setup-done", AnyView(sheet(LidSetupView(requestedLid: true, startAt: .done, approvalWatcher: UUID(), onClose: {})))),
            ("settings-automations", AnyView(tab(.automations))),
            ("settings-lid-safety", AnyView(tab(.lidSafety))),
            ("settings-diagnostics", AnyView(tab(.diagnostics))),
        ]
        for (name, view) in shots {
            for dark in [false, true] {
                guard let rep = renderPolish(view, dark: dark),
                      let png = rep.representation(using: .png, properties: [:]) else { ok = false; continue }
                do { try png.write(to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")) } catch { ok = false }
            }
        }
        return ok
    }

    private static func sheet(_ view: some View) -> some View {
        view.background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Color(nsColor: .windowBackgroundColor)))
    }

    private static func tab(_ tab: SettingsTab) -> some View {
        SettingsTabContent(tab: tab).background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
