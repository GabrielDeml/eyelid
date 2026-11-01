#if DEBUG   // the --snapshot review renderer ships only in debug builds (make snapshot)
import AppKit
import SwiftUI

/// `Insomnia --snapshot <dir>`: renders PanelView in representative states, light and dark, plus the six menu bar
/// glyphs (1x / 2x, light / dark bar) and the app icon moods, so reviewers can SEE the UI without running the app.
/// Uses fixed `PanelModel`s only: never touches AwakeEngine, PowerMonitor, Settings writes or power assertions.
@MainActor
enum Snapshot {
    static func run(to dir: URL) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            FileHandle.standardError.write(Data("cannot create \(dir.path)\n".utf8))
            return false
        }

        var ok = true
        var sheet: [(String, NSBitmapImageRep, NSBitmapImageRep)] = []
        for (name, state) in states() {
            var reps: [NSBitmapImageRep] = []
            for dark in [false, true] {
                guard let rep = render(PanelView(model: .fixed(state), opaqueBackground: true), dark: dark) else {
                    ok = false; continue
                }
                ok = write(rep, to: dir.appendingPathComponent("panel-\(name)-\(dark ? "dark" : "light").png")) && ok
                reps.append(rep)
            }
            if reps.count == 2 { sheet.append((name, reps[0], reps[1])) }
        }
        if let rep = contactSheet(sheet) { ok = write(rep, to: dir.appendingPathComponent("panel-sheet.png")) && ok }
        if let rep = glyphSheet() { ok = write(rep, to: dir.appendingPathComponent("menubar-glyphs.png")) && ok }
        if let rep = iconSheet() { ok = write(rep, to: dir.appendingPathComponent("app-icons.png")) && ok }
        ok = polishSheets(to: dir) && ok
        ok = integrationSheets(to: dir) && ok
        print("Wrote snapshots to \(dir.path)")
        return ok
    }

    // MARK: States

    private static func states() -> [(String, PanelState)] {
        let now = Date()
        var base = PanelState()
        base.now = now
        base.hasLid = true
        base.keepScreenOn = true

        var asleep = base
        asleep.quip = "Off duty. One eye open. Metaphorically."

        var timed = base
        let remaining: TimeInterval = 42 * 60 + 7
        timed.status = .timed(end: now.addingTimeInterval(remaining))
        timed.mood = .awake
        timed.remaining = remaining
        timed.progress = 1 - remaining / 3600
        timed.selectedPreset = .minutes(60)
        timed.quip = "Eyes open. Blinking is for quitters."
        timed.awakeFor = 3600 - remaining

        var indefinite = base
        indefinite.status = .indefinite
        indefinite.mood = .awake
        indefinite.selectedPreset = .indefinite
        indefinite.quip = "Wide awake. Coffee optional."

        var lid = base
        let lidLeft: TimeInterval = 2 * 3600 + 14 * 60
        lid.status = .timed(end: now.addingTimeInterval(lidLeft))
        lid.remaining = lidLeft
        lid.progress = 1 - lidLeft / (4 * 3600)
        lid.selectedPreset = .minutes(240)
        lid.lid = .engaged(lidClosed: false)
        lid.mood = .lid
        lid.closedLidMode = true
        lid.helper = .installed
        lid.quip = "Lid mode on. I'll watch through the lid. Don't ask."

        var suspended = base
        suspended.status = .suspended(.awakeBatteryFloor)
        suspended.mood = .squint
        suspended.banner = PlainCopy.banner(.guardTripped(.awakeBatteryFloor), suspended)

        var watching = base
        watching.status = .watching(.pid(4411, name: "ffmpeg"))
        watching.mood = .watching
        watching.extraHolds = 1
        watching.quip = "Watching ffmpeg like a hawk. A sleepy hawk."

        var hot = base
        hot.status = .indefinite
        hot.selectedPreset = .indefinite
        hot.lid = .suspended(.thermal)
        hot.mood = .squint
        hot.closedLidMode = true
        hot.helper = .installed
        hot.banner = PlainCopy.banner(.guardTripped(.thermal), hot)

        var error = base
        error.status = .indefinite
        error.selectedPreset = .indefinite
        error.lid = .error(.readbackMismatch)
        error.mood = .alarmed
        error.closedLidMode = true
        error.helper = .installed

        // What an M1 MacBook shows: the lid switch is on in Settings, but lid mode isn't set up (no helper yet).
        var setup = base
        setup.status = .timed(end: now.addingTimeInterval(8 * 60 + 30))
        setup.mood = .awake
        setup.remaining = 8 * 60 + 30
        setup.progress = 1 - (8 * 60 + 30) / 1800
        setup.selectedPreset = .minutes(30)
        setup.closedLidMode = true
        setup.lid = .needsSetup
        setup.helper = .notInstalled

        var bags = base
        bags.status = .indefinite
        bags.selectedPreset = .indefinite
        bags.mood = .awake
        bags.awakeFor = 80 * 3600
        bags.personality = .professional
        bags.hasLid = false

        return [("asleep", asleep), ("timed", timed), ("indefinite", indefinite), ("lid-engaged", lid),
                ("suspended", suspended), ("watching", watching), ("lid-hot", hot), ("lid-error", error),
                ("lid-needs-setup", setup), ("72h-desktop-professional", bags)]
    }

    // MARK: Rendering

    private static func render<V: View>(_ view: V, dark: Bool) -> NSBitmapImageRep? {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return nil }
        let root = view.environment(\.colorScheme, dark ? .dark : .light).padding(24)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = dark ? NSColor(srgb: 0x1B1B1F) : NSColor(srgb: 0xD9D9DE)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI and AppKit controls (switches, menus) finish their first pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        // Paint the "desktop" behind the panel so the drop shadow-free card reads on both appearances.
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

    /// All states, light | dark, in one image.
    private static func contactSheet(_ rows: [(String, NSBitmapImageRep, NSBitmapImageRep)]) -> NSBitmapImageRep? {
        guard let first = rows.first else { return nil }
        let cellW = first.1.pixelsWide, scale = CGFloat(first.1.pixelsWide) / first.1.size.width
        let cols = 4
        let cellH = rows.map { max($0.1.pixelsHigh, $0.2.pixelsHigh) }.max() ?? first.1.pixelsHigh
        let labelH = Int(28 * scale)
        let gridRows = Int((Double(rows.count) / Double(cols) * 1).rounded(.up))
        let width = cellW * 2 * cols, height = (cellH + labelH) * gridRows
        let pointSize = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        return EyesRenderer.bitmap(width: width, height: height, pointSize: pointSize) { ctx in
            ctx.setFillColor(NSColor(srgb: 0x2A2A30).cgColor)
            ctx.fill(CGRect(origin: .zero, size: pointSize))
            for (i, row) in rows.enumerated() {
                let col = i % cols, line = i / cols
                let x = CGFloat(col * cellW * 2) / scale, y = CGFloat(line * (cellH + labelH)) / scale
                drawLabel(ctx, row.0, at: CGPoint(x: x + 12, y: y + 6))
                for (j, rep) in [row.1, row.2].enumerated() {
                    let r = CGRect(x: x + CGFloat(j * cellW) / scale, y: y + CGFloat(labelH) / scale,
                                   width: rep.size.width, height: rep.size.height)
                    drawRep(ctx, rep, in: r)
                }
            }
        }
    }

    /// The six moods side by side, at 1x and 2x, on a light and a dark menu bar (magnified ×4 so pixels are visible).
    private static func glyphSheet() -> NSBitmapImageRep? {
        let moods: [EyeMood] = [.asleep, .awake, .watching, .lid, .squint, .alarmed]
        let names = ["asleep", "awake", "watching", "lid", "squint", "alarmed"]
        let mag: CGFloat = 4
        let cell = CGSize(width: 22 * mag + 24, height: 16 * mag + 22)
        let light = (NSColor(srgb: 0xF2F2F4), NSColor.black), dark = (NSColor(srgb: 0x232327), NSColor.white)
        // Light and dark bars at both scales; then Increase Contrast (stroke 2.0) and the blink frames, which are
        // where the eye is likeliest to touch the outline.
        let rows: [(label: String, bar: (NSColor, NSColor), px: Int, stroke: CGFloat, blink: CGFloat)] = [
            ("light @1x", light, 1, 1.5, 0), ("light @2x", light, 2, 1.5, 0),
            ("dark @1x", dark, 1, 1.5, 0), ("dark @2x", dark, 2, 1.5, 0),
            ("contrast @1x", light, 1, 2.0, 0), ("contrast @2x", light, 2, 2.0, 0),
            ("blink ½ @1x", light, 1, 1.5, 0.5), ("blink ½ @2x", light, 2, 1.5, 0.5),
            ("blink 1 @2x", light, 2, 1.5, 1),
        ]
        let size = CGSize(width: 130 + cell.width * CGFloat(moods.count), height: 30 + cell.height * CGFloat(rows.count))
        let scale: CGFloat = 2
        return EyesRenderer.bitmap(width: Int(size.width * scale), height: Int(size.height * scale), pointSize: size) { ctx in
            ctx.setFillColor(NSColor(srgb: 0x2A2A30).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, n) in names.enumerated() { drawLabel(ctx, n, at: CGPoint(x: 130 + CGFloat(i) * cell.width + 8, y: 8)) }
            for (rowIndex, row) in rows.enumerated() {
                let (bg, fg) = row.bar
                let y = 30 + CGFloat(rowIndex) * cell.height
                drawLabel(ctx, row.label, at: CGPoint(x: 10, y: y + cell.height / 2 - 8))
                for (i, mood) in moods.enumerated() {
                    let x = 130 + CGFloat(i) * cell.width
                    let tile = CGRect(x: x + 4, y: y + 4, width: cell.width - 8, height: cell.height - 8)
                    ctx.setFillColor(bg.cgColor)
                    ctx.fill(tile)
                    guard let glyph = EyesRenderer.bitmap(width: 22 * row.px, height: 16 * row.px, pointSize: EyesRenderer.menuBarSize, draw: { g in
                        EyesRenderer.drawMenuBarGlyph(g, mood: mood, blink: row.blink, stroke: row.stroke, colour: fg.cgColor,
                                                      pixelScale: CGFloat(row.px))
                    }), let cg = glyph.cgImage else { continue }
                    ctx.saveGState()
                    ctx.interpolationQuality = .none
                    let r = CGRect(x: tile.midX - 11 * mag, y: tile.midY - 8 * mag, width: 22 * mag, height: 16 * mag)
                    ctx.translateBy(x: r.minX, y: r.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(cg, in: CGRect(origin: .zero, size: r.size))
                    ctx.restoreGState()
                }
            }
        }
    }

    /// App icon in every mood, plus Dock pills.
    private static func iconSheet() -> NSBitmapImageRep? {
        let items: [(String, EyeMood, String?)] = [
            ("awake", .awake, nil), ("asleep", .asleep, nil), ("lid", .lid, nil), ("squint", .squint, nil),
            ("alarmed", .alarmed, nil), ("watching", .watching, "ffmp…"), ("timed", .awake, "42m"), ("∞ lid", .lid, "∞"),
        ]
        let icon: CGFloat = 200, gap: CGFloat = 24
        let size = CGSize(width: gap + (icon + gap) * 4, height: (icon + gap + 24) * 2 + gap)
        return EyesRenderer.bitmap(width: Int(size.width * 2), height: Int(size.height * 2), pointSize: size) { ctx in
            ctx.setFillColor(NSColor(srgb: 0xE6E6EB).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, item) in items.enumerated() {
                let x = gap + CGFloat(i % 4) * (icon + gap), y = gap + CGFloat(i / 4) * (icon + gap + 24)
                ctx.saveGState()
                ctx.translateBy(x: x, y: y)
                EyesRenderer.drawAppIcon(ctx, size: icon, mood: item.1, pill: item.2)
                ctx.restoreGState()
                drawLabel(ctx, item.0, at: CGPoint(x: x + icon / 2 - 24, y: y + icon + 2), colour: NSColor(srgb: 0x333338))
            }
        }
    }

    private static func drawRep(_ ctx: CGContext, _ rep: NSBitmapImageRep, in r: CGRect) {
        guard let cg = rep.cgImage else { return }
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    private static func drawLabel(_ ctx: CGContext, _ text: String, at p: CGPoint, colour: NSColor = NSColor(white: 0.85, alpha: 1)) {
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: colour])
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        s.draw(at: p)
        NSGraphicsContext.current = previous
    }
}
#endif
