#if DEBUG   // the --snapshot review renderer ships only in debug builds (make snapshot)
import AppKit
import SwiftUI

/// `--snapshot` additions for the M4 surfaces: welcome card, hidden-item card, mission report, Settings ▸ General,
/// About, and the Dock tile (live, blink frame, night-vision pulse). Light and dark. Read-only: renders fixed values,
/// never writes Settings, never touches power management.
///
/// Wiring: add `ok = polishSheets(to: dir) && ok` to `Snapshot.run` before the final print.
extension Snapshot {
    static func polishSheets(to dir: URL) -> Bool {
        var ok = true
        let report = ReopenReport(closedFor: 72 * 60, batteryStart: 82, batteryEnd: 61, worstThermal: .nominal)
        let width = Theme.panelWidth - Theme.padding * 2
        let shots: [(String, AnyView)] = [
            ("welcome-card", AnyView(
                WelcomeCard(hasLid: true, leftClickAction: .openPanel, showInDock: .constant(true), setUpLid: {}, done: {})
                    .frame(width: width))),
            ("welcome-card-desktop", AnyView(
                WelcomeCard(hasLid: false, leftClickAction: .toggle, showInDock: .constant(false), setUpLid: {}, done: {})
                    .frame(width: width))),
            ("mission-report", AnyView(
                MissionReportCard(report: report, line: "Welcome back. I kept the lights on in here.")
                    .frame(width: width))),
            ("mission-report-professional", AnyView(
                MissionReportCard(report: ReopenReport(closedFor: 3 * 3600 + 5 * 60, batteryStart: nil, batteryEnd: nil,
                                                       worstThermal: .serious), line: nil)
                    .frame(width: width))),
            ("hidden-card", AnyView(
                HiddenItemCard(showInDock: false, showMeInDock: {}, openPanel: {}, openMenuBarSettings: {}, keepHidden: {})
                    .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Color(nsColor: .windowBackgroundColor))))),
            ("settings-general", AnyView(
                GeneralTab().frame(width: SettingsLayout.width, height: SettingsLayout.height(.general))
                    .background(Color(nsColor: .windowBackgroundColor)))),
            ("about", AnyView(
                AboutView().background(Color(nsColor: .windowBackgroundColor)))),
        ]
        for (name, view) in shots {
            for dark in [false, true] {
                guard let rep = renderPolish(view, dark: dark),
                      let png = rep.representation(using: .png, properties: [:]) else { ok = false; continue }
                do { try png.write(to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")) } catch { ok = false }
            }
        }
        if let rep = dockSheet(), let png = rep.representation(using: .png, properties: [:]) {
            do { try png.write(to: dir.appendingPathComponent("dock-tiles.png")) } catch { ok = false }
        } else {
            ok = false
        }
        return ok
    }

    static func renderPolish(_ view: AnyView, dark: Bool) -> NSBitmapImageRep? {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return nil }
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).padding(20))
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))   // let count-ups and first passes settle
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        appearance.performAsCurrentDrawingAppearance {
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                (dark ? NSColor(srgb: 0x1B1B1F) : NSColor(srgb: 0xD9D9DE)).setFill()
                NSRect(origin: .zero, size: rep.size).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        window.contentView = nil
        return rep
    }

    /// Dock tiles: the live states with pills, a mid-blink frame and the night-vision pulse peak.
    private static func dockSheet() -> NSBitmapImageRep? {
        var blink = EyePose.resting(for: .awake)
        blink.openLeft = 0.15
        blink.openRight = 0.15
        let items: [DockTileView.Content] = [
            .init(mood: .awake, pill: "42m", pose: nil, glow: 0), .init(mood: .awake, pill: "0:42", pose: nil, glow: 0),
            .init(mood: .lid, pill: "∞", pose: nil, glow: 0), .init(mood: .watching, pill: "ffmp…", pose: nil, glow: 0),
            .init(mood: .asleep, pill: nil, pose: nil, glow: 0), .init(mood: .alarmed, pill: "1h 5m", pose: nil, glow: 0),
            .init(mood: .awake, pill: "42m", pose: blink, glow: 0), .init(mood: .lid, pill: "2h", pose: nil, glow: 1),
        ]
        let tile: CGFloat = 128, gap: CGFloat = 20
        let size = CGSize(width: gap + (tile + gap) * 4, height: gap + (tile + gap) * 2)
        return EyesRenderer.bitmap(width: Int(size.width * 2), height: Int(size.height * 2), pointSize: size) { ctx in
            ctx.setFillColor(NSColor(srgb: 0xE6E6EB).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, item) in items.enumerated() {
                ctx.saveGState()
                ctx.translateBy(x: gap + CGFloat(i % 4) * (tile + gap), y: gap + CGFloat(i / 4) * (tile + gap))
                DockTileView.draw(ctx, side: tile, content: item)
                ctx.restoreGState()
            }
        }
    }
}
#endif
