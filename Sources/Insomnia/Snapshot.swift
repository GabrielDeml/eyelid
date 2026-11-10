#if DEBUG
import AppKit
import SwiftUI

/// `make snapshot`: renders panel states, the Settings window (light and dark) and the menu bar glyphs to PNGs. Never
/// touches power.
@MainActor
enum Snapshot {
    static func run(to dir: URL) -> Bool {
        _ = NSApplication.shared
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return false }
        let now = Date()
        let off = PanelState()
        var timed = PanelState()
        timed.isOn = true
        timed.endsAt = now.addingTimeInterval(102 * 60)
        var lidOn = PanelState()
        lidOn.isOn = true
        lidOn.lidOn = true
        lidOn.unpluggedChoices = UnpluggedAction.allCases
        lidOn.unplugged = .sleepWhenLidCloses
        var approval = lidOn
        approval.lidCaption = PanelState.needsApprovalCaption
        var hot = PanelState()
        hot.notice = Engine.notice(for: .hot, slept: true)
        var stuck = PanelState()
        stuck.stuck = true
        stuck.lidOn = true
        stuck.lidCaption = PanelState.stuckCaption
        var desktop = PanelState()
        desktop.isOn = true
        desktop.keepScreenOn = false
        desktop.showLid = false
        desktop.showUnplugged = false
        var notInstalled = PanelState()
        notInstalled.lidEnabled = false
        notInstalled.lidCaption = PanelState.notInApplicationsCaption
        var timedLid = lidOn
        timedLid.endsAt = now.addingTimeInterval(230 * 60)
        var lidFailed = lidOn
        lidFailed.lidCaption = PanelState.setupErrorCaption(HelperClient.registerError(code: 1))
        var paused = lidOn
        paused.lidCaption = PanelState.pausedOnBatteryCaption
        var unpluggedOff = PanelState()
        unpluggedOff.unplugged = .turnOff
        unpluggedOff.notice = Engine.unpluggedNotice

        let states: [(String, PanelState)] = [("off", off), ("timed", timed), ("lid", lidOn), ("timed-lid", timedLid),
                                              ("approval", approval), ("lid-failed", lidFailed), ("hot", hot),
                                              ("stuck", stuck), ("desktop", desktop), ("not-installed", notInstalled),
                                              ("paused", paused), ("unplugged-off", unpluggedOff)]
        let maxContent = Theme.panelWidth - 2 * Theme.inset + 0.5
        var ok = true
        for (name, state) in states {
            for dark in [false, true] {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                let view = PanelView(state: state, send: { _ in })
                    .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                    .clipShape(shape)
                PanelView.contentWidth = 0
                guard let rep = render(view, dark: dark) else { ok = false; continue }
                if PanelView.contentWidth > maxContent {
                    print("panel \(name) content is \(PanelView.contentWidth)pt (max \(maxContent - 0.5))")
                    ok = false
                }
                ok = write(rep, to: dir.appendingPathComponent("panel-\(name)-\(dark ? "dark" : "light").png")) && ok
            }
        }
        // The Settings window on a MacBook, with scratch preferences. The engine gets inert stand-ins, and the lid
        // controller is only read.
        if let defaults = UserDefaults(suiteName: "com.gdeml.Insomnia.snapshot") {
            defaults.removePersistentDomain(forName: "com.gdeml.Insomnia.snapshot")
            let prefs = Preferences(defaults: defaults)
            let lid = LidController(client: ReadyClient(), prefs: prefs, hasLid: true, runsTimers: false)
            let engine = Engine(prefs: prefs, power: StillPower(), lid: StillLid(), assertions: NoAssertions(),
                                armsTimers: false)
            engine.reconcile()
            for dark in [false, true] {
                let view = SettingsView(engine: engine, lid: lid, prefs: prefs).fixedSize(horizontal: false, vertical: true)
                if let rep = render(view, dark: dark) {
                    ok = write(rep, to: dir.appendingPathComponent("settings-\(dark ? "dark" : "light").png")) && ok
                } else { ok = false }
            }
            defaults.removePersistentDomain(forName: "com.gdeml.Insomnia.snapshot")
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))   // let AppKit-backed switches draw
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

/// `make snapshot`'s stand-ins: a MacBook on AC, a lid helper that is set up but never engages, assertions that do
/// nothing.
private final class ReadyClient: HelperClienting {
    func setup(hasLid: Bool) async -> LidSetup { .ready }
    func install() async -> (setup: LidSetup, error: String?) { (.ready, nil) }
    func upgradeIfNeeded(savedCDHash: String?) async -> String? { nil }
    func bundledCDHash() async -> String? { nil }
    func engage(onLost: @escaping @Sendable () -> Void) async -> Int32 { -1 }
    func release() async -> Int32 { -1 }
    func abandon() async {}
    func heartbeat() async -> Int32 { -1 }
    func query() async -> HelperAnswer? { nil }
    func flag() async -> Bool? { nil }
    func isUnattendedNow() async -> Bool { false }
    func pmset(_ verb: String) async {}
    func resetWithPassword() async -> Bool { false }
}

@MainActor private final class StillPower: PowerSource {
    let state = PowerState(hasBattery: true, batteryPercent: 80, isOnAC: true, hasLid: true)
    var onChange: (() -> Void)?
    let idleSeconds: TimeInterval = 0
    func refreshLid() {}
}

@MainActor private final class StillLid: LidControlling {
    let isReady = false, needsSetup = false, isEngaged = false, isStuck = false, needsAttention = false
    var onChange: (() -> Void)?
    func setDesired(_ on: Bool) {}
    func update(closedWithoutDisplay: Bool) {}
    func sleepNow() {}
    func userActed() {}
    func install() {}
    func releaseForQuit() async {}
}

private final class NoAssertions: AssertionApplying {
    func update(system: Bool, display: Bool, reason: String) {}
    func releaseAll() {}
    let hasSystemAssertion = false, hasDisplayAssertion = false
}
#endif
