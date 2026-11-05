#if DEBUG
import AppKit
import SwiftUI

/// `make snapshot`: renders panel states (light and dark) and the menu bar glyphs to PNGs. Never touches power.
@MainActor
enum Snapshot {
    static func run(to dir: URL) -> Bool {
        _ = NSApplication.shared
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return false }
        let now = Date()
        var off = PanelState()
        off.notice = nil
        var timed = PanelState()
        timed.mode = .screenOn
        timed.isOn = true
        timed.runMinutes = 120
        timed.endsAt = now.addingTimeInterval(102 * 60)
        var lidOn = PanelState()
        lidOn.mode = .lid
        lidOn.isOn = true
        lidOn.lidOn = true
        var approval = lidOn
        approval.mode = .screenOn
        approval.attention = true
        approval.lidCaption = .init(text: "Waiting for approval in System Settings ›", tone: .warning, action: .openLoginItems)
        var hot = PanelState()
        hot.attention = true
        hot.notice = Engine.Notice(text: "Slept because your Mac got hot", isWarning: true)
        var stuck = PanelState()
        stuck.attention = true
        stuck.stuck = true
        stuck.lidOn = true
        stuck.lidCaption = .init(text: "Sleep is still off. Reset with password…", tone: .danger, action: .resetWithPassword)
        var desktop = PanelState()
        desktop.mode = .awake
        desktop.isOn = true
        desktop.keepScreenOn = false
        desktop.showLid = false
        desktop.showUnplugged = false
        var notInstalled = PanelState()
        notInstalled.lidEnabled = false
        notInstalled.lidCaption = .init(text: "Needs the copy installed in Applications")
        notInstalled.unpluggedChoices = [.keepGoing, .turnOff]
        notInstalled.unplugged = .keepGoing

        let states: [(String, PanelState)] = [("off", off), ("timed", timed), ("lid", lidOn), ("approval", approval),
                                              ("hot", hot), ("stuck", stuck), ("desktop", desktop),
                                              ("not-installed", notInstalled)]
        var ok = true
        for (name, state) in states {
            for dark in [false, true] {
                let view = PanelView(state: state, send: { _ in })
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
                guard let rep = render(view, dark: dark) else { ok = false; continue }
                ok = write(rep, to: dir.appendingPathComponent("panel-\(name)-\(dark ? "dark" : "light").png")) && ok
            }
        }
        // Glyphs at 1x and 2x, in a row: off, awake, screen on, lid, and each with "!".
        let modes: [Engine.Mode] = [.off, .awake, .screenOn, .lid]
        for scale in [1, 2, 8] {
            let cell = MoonGlyph.size
            let pointSize = NSSize(width: cell.width * 8 + 8 * 6, height: cell.height + 8)
            let rep = AppIcon.bitmap(width: Int(pointSize.width) * scale, height: Int(pointSize.height) * scale,
                                     pointSize: pointSize) { ctx in
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(origin: .zero, size: pointSize))
                for (i, (mode, attention)) in (modes.map { ($0, false) } + modes.map { ($0, true) }).enumerated() {
                    ctx.saveGState()
                    ctx.translateBy(x: 4 + CGFloat(i) * (cell.width + 6), y: 4)
                    MoonGlyph.draw(ctx, mode: mode, attention: attention, stroke: 1.5, pixelScale: CGFloat(scale))
                    ctx.restoreGState()
                }
            }
            if let rep { ok = write(rep, to: dir.appendingPathComponent("glyphs@\(scale)x.png")) && ok } else { ok = false }
        }
        if let rep = AppIcon.bitmap(width: 512, height: 512, pointSize: NSSize(width: 512, height: 512), draw: {
            AppIcon.draw($0, size: 512)
        }) { ok = write(rep, to: dir.appendingPathComponent("app-icon.png")) && ok }
        print("Wrote snapshots to \(dir.path)")
        return ok
    }

    private static func render<V: View>(_ view: V, dark: Bool) -> NSBitmapImageRep? {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return nil }
        let root = view.environment(\.colorScheme, dark ? .dark : .light).padding(20)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = dark ? NSColor(srgb: 0x1B1B1F) : NSColor(srgb: 0xD9D9DE)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))   // let AppKit-backed switches draw
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        appearance.performAsCurrentDrawingAppearance {
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                (window.backgroundColor ?? .gray).setFill()
                NSRect(origin: .zero, size: rep.size).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        window.contentView = nil
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) -> Bool {
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }
}
#endif
