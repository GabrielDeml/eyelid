import AppKit
import SwiftUI

/// One-shot animation triggers for the panel eyes. Bump a counter to play the cue once (docs/UX.md §2.4).
struct EyesCues: Equatable, Sendable {
    /// Double-take: two quick blinks (Extend).
    var extend = 0
    /// Indigo glow sweeps across the eyes (first lid engagement each day).
    var nightVision = 0
    /// Eyes cross for 2 s (poke egg, 20 clicks).
    var crossEyes = 0
    /// First launch: eyes open slowly (600 ms), blink twice, find the cursor.
    var firstWake = 0
}

/// The panel eyes: a 72 pt face with a progress ring. Animates with `TimelineView(.animation)` **only while
/// `isLive`** (the panel is visible) and Reduce Motion is off; otherwise it renders a static pose and swaps with a
/// ≤ 150 ms crossfade. Decorative: hidden from VoiceOver (the headline carries the meaning).
struct EyesView: View {
    var mood: EyeMood
    /// 0…1 elapsed of a timed hold; nil hides the ring.
    var progress: Double?
    var isLive: Bool
    /// Final 60 s of a timed hold: lids 40% closed.
    var heavyLids: Bool = false
    /// 0 none, 1 bags (≥ 24 h awake), 2 bags + veins (≥ 72 h).
    var bags: Int = 0
    var cues = EyesCues()
    var size: CGFloat = Theme.eyesButton

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var motion = EyesMotion()

    var body: some View {
        let animating = isLive && !reduceMotion
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        let palette = EyePalette.panel(appearance: appearance)
        let faceAsleep = Theme.faceAsleepNS.resolvedCGColor(for: appearance)
        let faceTop = Theme.faceTopNS.resolvedCGColor(for: appearance)
        let faceBottom = Theme.faceBottomNS.resolvedCGColor(for: appearance)
        let sleepTone = Theme.sleepToneNS.resolvedCGColor(for: appearance)
        let ringTrack = NSColor.labelColor.withAlphaComponent(colorScheme == .dark ? 0.14 : 0.09).resolvedCGColor(for: appearance)
        let ringColour = palette.iris
        let ringWidth: CGFloat = contrast == .increased ? 4 : 3
        let zColour = Color(nsColor: Theme.sleepToneNS)

        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating)) { context in
            let frame = animating
                ? motion.frame(at: context.date, mood: mood, heavyLids: heavyLids, bags: bags, progress: progress)
                : EyesMotion.staticFrame(mood: mood, heavyLids: heavyLids, bags: bags, progress: progress)
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { gc, canvasSize in
                let s = min(canvasSize.width, canvasSize.height)
                let bounds = CGRect(x: (canvasSize.width - s) / 2, y: (canvasSize.height - s) / 2, width: s, height: s)
                var eyePalette = palette
                eyePalette.closedStroke = EyesView.blend(sleepTone, palette.sclera, frame.lights)
                gc.withCGContext { ctx in
                    EyesView.drawFace(ctx, bounds: bounds, frame: frame, palette: eyePalette,
                                      faceAsleep: faceAsleep, faceTop: faceTop, faceBottom: faceBottom,
                                      ringTrack: ringTrack, ringColour: ringColour, ringWidth: ringWidth)
                }
                if frame.zAlpha > 0.01 {
                    let zSize = s * 0.2
                    gc.opacity = frame.zAlpha
                    gc.draw(Text("z").font(.system(size: zSize, weight: .heavy, design: .rounded)).foregroundStyle(zColour),
                            at: CGPoint(x: bounds.minX + s * frame.zPosition.x, y: bounds.minY + s * frame.zPosition.y))
                }
            }
        }
        .frame(width: size, height: size)
        .background(ScreenAnchor(motion: motion))
        .id(animating ? AnyHashable("live") : AnyHashable(mood))      // static: crossfade between moods
        .transition(.opacity)
        .animation(animating ? nil : .easeInOut(duration: 0.15), value: mood)
        .onChange(of: mood) { old, new in motion.moodChanged(from: old, to: new, animate: animating) }
        .onChange(of: cues.extend) { _, _ in if animating { motion.start(.doubleTake) } }
        .onChange(of: cues.nightVision) { _, _ in if animating { motion.start(.sweep) } }
        .onChange(of: cues.crossEyes) { _, _ in if animating { motion.start(.cross) } }
        .onChange(of: cues.firstWake) { _, _ in if animating { motion.start(.firstWake) } }
        .onChange(of: isLive) { _, live in if live { motion.reset(mood: mood) } }
        .accessibilityHidden(true)
    }

    /// Face disc, ring and eyes, y-down.
    nonisolated static func drawFace(_ ctx: CGContext, bounds: CGRect, frame: EyesFrame, palette: EyePalette,
                                     faceAsleep: CGColor, faceTop: CGColor, faceBottom: CGColor,
                                     ringTrack: CGColor, ringColour: CGColor, ringWidth: CGFloat) {
        let s = bounds.width
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)

        // Ring (3 pt, inset 2). The track shows only while a timed hold runs.
        if frame.ringAlpha > 0.01, let progress = frame.progress {
            let r = s / 2 - 2 - ringWidth / 2
            ctx.saveGState()
            ctx.setAlpha(frame.ringAlpha)
            ctx.setLineWidth(ringWidth)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(ringTrack)
            ctx.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            ctx.strokePath()
            let p = max(0, min(1, progress))
            if p > 0.001 {
                ctx.setStrokeColor(ringColour)
                // Start at 12 o'clock, clockwise on screen (y-down → increasing angle is clockwise).
                ctx.addArc(center: centre, radius: r, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * p, clockwise: false)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        // Face disc: neutral when asleep, night sky when awake ("lights on").
        let faceInset: CGFloat = 8
        let face = bounds.insetBy(dx: faceInset, dy: faceInset)
        ctx.saveGState()
        ctx.addEllipse(in: face)
        ctx.clip()
        ctx.setFillColor(faceAsleep)
        ctx.fill(face)
        if frame.lights > 0.001 {
            ctx.setAlpha(frame.lights)
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [faceTop, faceBottom] as CFArray,
                                  locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: face.midX, y: face.minY), end: CGPoint(x: face.midX, y: face.maxY), options: [])
            }
            // Soft sheen at the top.
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1]) {
                let c = CGPoint(x: face.midX, y: face.minY)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: face.width * 0.7, options: [])
            }
            ctx.setAlpha(1)
        }
        ctx.restoreGState()
        // Hairline edge so the asleep disc holds its shape on light backgrounds.
        ctx.saveGState()
        ctx.addEllipse(in: face.insetBy(dx: 0.25, dy: 0.25))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08 * (1 - frame.lights)))
        ctx.setLineWidth(0.5)
        ctx.strokePath()
        ctx.restoreGState()

        // Eyes: 44 pt wide, slightly above centre.
        let pairW = s * (Theme.eyesWidthRatio)
        let eyes = CGRect(x: centre.x - pairW / 2, y: centre.y - pairW * 0.2 - s * 0.01, width: pairW, height: pairW * 0.4)
        EyeArtist.draw(in: ctx, rect: eyes, pose: frame.pose, palette: palette)
    }

    nonisolated static func blend(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ca = a.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              let cb = b.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              ca.count >= 4, cb.count >= 4 else { return t > 0.5 ? b : a }
        let t = max(0, min(1, t))
        return CGColor(srgbRed: ca[0] + (cb[0] - ca[0]) * t, green: ca[1] + (cb[1] - ca[1]) * t,
                       blue: ca[2] + (cb[2] - ca[2]) * t, alpha: ca[3] + (cb[3] - ca[3]) * t)
    }
}

extension Theme {
    /// 44 pt of eyes inside the 72 pt button.
    nonisolated static let eyesWidthRatio: CGFloat = 44.0 / 72.0
}

/// Everything one rendered frame needs. Pure value.
struct EyesFrame: Sendable {
    var pose: EyePose
    /// 0 asleep disc … 1 awake (night-sky) disc.
    var lights: CGFloat
    var ringAlpha: CGFloat
    var progress: Double?
    var zAlpha: CGFloat
    /// Unit position of the "z" within the button (0…1).
    var zPosition: CGPoint
}

/// The animation integrator: time-based, so frames are pure functions of the clock plus a few start times.
/// Mutated only from the main actor (view body / onChange).
@MainActor
final class EyesMotion {
    enum Cue { case doubleTake, sweep, cross, firstWake }

    private struct Transition { var from: CGFloat; var to: CGFloat; var start: Date; var duration: TimeInterval; var opening: Bool }

    private var lid: Transition?
    private var lights: Transition?
    private var dilateStart: Date?
    private var doubleTakeStart: Date?
    private var sweepStart: Date?
    private var crossStart: Date?
    private var firstWakeStart: Date?
    private var sweatStart: Date?
    private var zAnchor = Date()
    private var blinkAnchor = Date()
    private var lastFrame: Date?
    private var gaze = CGPoint.zero
    private var currentOpen: CGFloat = 1
    private var currentLights: CGFloat = 1
    /// The anchor view, for cursor tracking (window + screen position).
    weak var anchorView: NSView?

    static func staticFrame(mood: EyeMood, heavyLids: Bool, bags: Int, progress: Double?) -> EyesFrame {
        var pose = EyePose.resting(for: mood)
        pose.bags = mood == .asleep ? 0 : bags
        if heavyLids && mood != .asleep {
            pose.openLeft = min(pose.openLeft, 0.6)
            if !pose.rightCross { pose.openRight = min(pose.openRight, 0.6) }
        }
        let awake = mood != .asleep
        return EyesFrame(pose: pose, lights: awake ? 1 : 0, ringAlpha: progress == nil ? 0 : 1, progress: progress,
                         zAlpha: awake ? 0 : 0.9, zPosition: CGPoint(x: 0.76, y: 0.24))
    }

    func reset(mood: EyeMood) {
        let now = Date()
        lid = nil; lights = nil; dilateStart = nil; doubleTakeStart = nil; sweepStart = nil; crossStart = nil
        sweatStart = mood == .squint ? now : nil
        zAnchor = now; blinkAnchor = now; lastFrame = nil
        currentOpen = mood == .asleep ? 0 : 1
        currentLights = mood == .asleep ? 0 : 1
    }

    func moodChanged(from old: EyeMood, to new: EyeMood, animate: Bool) {
        guard animate else { reset(mood: new); return }
        let now = Date()
        let wasAwake = old != .asleep, isAwake = new != .asleep
        if !wasAwake && isAwake {
            // Toggle on: lids snap open (120 ms spring), pupils dilate once, ring + lights fade in.
            lid = Transition(from: currentOpen, to: 1, start: now, duration: 0.22, opening: true)
            lights = Transition(from: currentLights, to: 1, start: now, duration: 0.25, opening: true)
            dilateStart = now.addingTimeInterval(0.08)
            blinkAnchor = now
        } else if wasAwake && !isAwake {
            // Toggle off: lids lower (350 ms ease-in), then the "z" fades in.
            lid = Transition(from: currentOpen, to: 0, start: now, duration: 0.35, opening: false)
            lights = Transition(from: currentLights, to: 0, start: now.addingTimeInterval(0.15), duration: 0.4, opening: false)
            zAnchor = now.addingTimeInterval(0.35)
        }
        if new == .squint && old != .squint { sweatStart = now }
    }

    func start(_ cue: Cue) {
        let now = Date()
        switch cue {
        case .doubleTake: doubleTakeStart = now
        case .sweep: sweepStart = now
        case .cross: crossStart = now
        case .firstWake:
            firstWakeStart = now
            lid = Transition(from: 0, to: 1, start: now, duration: 0.6, opening: false)
            lights = Transition(from: 0, to: 1, start: now, duration: 0.6, opening: false)
        }
    }

    func frame(at date: Date, mood: EyeMood, heavyLids: Bool, bags: Int, progress: Double?) -> EyesFrame {
        let dt = lastFrame.map { min(0.1, max(0, date.timeIntervalSince($0))) } ?? 0
        lastFrame = date
        let awake = mood != .asleep
        var pose = EyePose.resting(for: mood)
        pose.bags = awake ? bags : 0

        // Lid openness: transition, then rest.
        let restOpen: CGFloat = awake ? (heavyLids ? 0.6 : (mood == .squint ? 0.34 : 1)) : 0
        var open = restOpen
        if let t = lid {
            let x = progressOf(t, at: date)
            if x >= 1 { lid = nil } else {
                let eased = t.opening ? easeOutBack(x) : (t.to < t.from ? easeIn(x) : easeInOut(x))
                let target = t.to == 0 ? 0 : restOpen
                open = max(0, t.from + (target - t.from) * eased)
            }
        }
        currentOpen = open

        var lightsValue: CGFloat = awake ? 1 : 0
        if let t = lights {
            let x = progressOf(t, at: date)
            if x >= 1 { lights = nil } else { lightsValue = t.from + (t.to - t.from) * easeInOut(max(0, x)) }
        }
        currentLights = lightsValue

        // Idle blink every 4–9 s (awake only), plus the extend double-take and first-wake double blink.
        var blink: CGFloat = 0
        if awake && lid == nil {
            blink = max(blink, Self.idleBlink(elapsed: date.timeIntervalSince(blinkAnchor)))
        }
        if let s = doubleTakeStart {
            let e = date.timeIntervalSince(s)
            if e > 0.6 { doubleTakeStart = nil } else { blink = max(blink, quickBlink(e), quickBlink(e - 0.26)) }
        }
        if let s = firstWakeStart {
            let e = date.timeIntervalSince(s) - 0.75
            if e > 1.2 { firstWakeStart = nil } else { blink = max(blink, quickBlink(e), quickBlink(e - 0.3)) }
        }
        let leftOpen = open * (1 - blink)
        pose.openLeft = leftOpen
        pose.openRight = pose.rightCross ? 0 : leftOpen

        // Pupils: dilate once on toggle-on (+20 %, 200 ms).
        if let s = dilateStart {
            let e = date.timeIntervalSince(s)
            if e > 0.2 { dilateStart = nil } else if e > 0 { pose.pupilScale = 1 + 0.2 * sin(.pi * e / 0.2) }
        }

        // Cursor tracking (±2 pt, eased). Watching keeps a slight sideways glance.
        let target = awake ? cursorGaze(bias: mood == .watching ? 0.3 : 0) : .zero
        let k = 1 - exp(-dt * 9)
        gaze.x += (target.x - gaze.x) * k
        gaze.y += (target.y - gaze.y) * k
        pose.gaze = gaze

        // Cross-eyes for 2 s.
        if let s = crossStart {
            let e = date.timeIntervalSince(s)
            if e > 2.3 { crossStart = nil } else {
                pose.crossEyed = e < 0.25 ? e / 0.25 : (e > 2.05 ? max(0, (2.3 - e) / 0.25) : 1)
            }
        }
        // Night-vision sweep (400 ms).
        if let s = sweepStart {
            let e = date.timeIntervalSince(s)
            if e > 0.4 { sweepStart = nil } else { pose.sweep = CGFloat(e / 0.4) }
        }
        // Sweat drop slides once.
        if let s = sweatStart {
            let e = date.timeIntervalSince(s)
            if e > 1.6 || mood != .squint { sweatStart = nil } else { pose.sweat = CGFloat(e / 1.6) }
        }

        // Ring fades in with the lights.
        let ringAlpha: CGFloat = progress == nil ? 0 : (lights == nil ? 1 : lightsValue)

        // The "z": drifts up and fades every 6 s while asleep.
        var zAlpha: CGFloat = 0
        var zPos = CGPoint(x: 0.74, y: 0.3)
        if !awake {
            let e = date.timeIntervalSince(zAnchor)
            if e >= 0 {
                let phase = e.truncatingRemainder(dividingBy: 6) / 6
                let rise = CGFloat(min(1, phase / 0.75))
                zPos = CGPoint(x: 0.7 + 0.08 * rise, y: 0.34 - 0.2 * rise)
                zAlpha = phase < 0.15 ? CGFloat(phase / 0.15) : (phase < 0.75 ? CGFloat(1 - (phase - 0.15) / 0.6) : 0)
            }
        }
        return EyesFrame(pose: pose, lights: lightsValue, ringAlpha: ringAlpha, progress: progress, zAlpha: zAlpha, zPosition: zPos)
    }

    // MARK: Helpers

    private func progressOf(_ t: Transition, at date: Date) -> CGFloat {
        let e = date.timeIntervalSince(t.start)
        if e <= 0 { return 0 }
        return CGFloat(min(1, e / t.duration))
    }

    /// Deterministic 4–9 s blink schedule (no stored RNG state): a fixed cycle of pseudo-random gaps.
    private static let blinkGaps: [Double] = (0..<16).map { i in
        let r = abs(sin(Double(i) * 12.9898 + 4.1414) * 43758.5453)
        return 4 + 5 * (r - r.rounded(.down))
    }
    private static let blinkCycle = blinkGaps.reduce(0, +)

    private static func idleBlink(elapsed: Double) -> CGFloat {
        var t = elapsed.truncatingRemainder(dividingBy: blinkCycle)
        for gap in blinkGaps {
            if t < gap { return blinkShape(gap - t < 0.16 ? 0.16 - (gap - t) : -1) }
            t -= gap
        }
        return 0
    }

    /// 160 ms blink curve: 0 → 1 → 0.
    private static func blinkShape(_ e: Double) -> CGFloat {
        guard e >= 0, e <= 0.16 else { return 0 }
        return CGFloat(sin(.pi * e / 0.16))
    }

    private func quickBlink(_ e: Double) -> CGFloat {
        guard e >= 0, e <= 0.14 else { return 0 }
        return CGFloat(sin(.pi * e / 0.14))
    }

    private func cursorGaze(bias: CGFloat) -> CGPoint {
        guard let view = anchorView, let window = view.window else { return CGPoint(x: bias, y: 0) }
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - onScreen.midX, dy = onScreen.midY - mouse.y   // y-down
        let dist = max(1, hypot(dx, dy))
        let reach = min(1, dist / 160)
        // ±2 pt: x is a fraction of the eye's free travel (~4.7 pt), y of ~2.1 pt.
        return CGPoint(x: max(-1, min(1, dx / dist * reach * 0.42 + bias)), y: dy / dist * reach * 0.95)
    }

    private func easeIn(_ x: CGFloat) -> CGFloat { x * x * x }
    private func easeInOut(_ x: CGFloat) -> CGFloat { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// Springy snap with a small overshoot.
    private func easeOutBack(_ x: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.4, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

/// Zero-size AppKit view that hands EyesMotion its window position for cursor tracking.
private struct ScreenAnchor: NSViewRepresentable {
    let motion: EyesMotion
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        motion.anchorView = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { motion.anchorView = nsView }
}
