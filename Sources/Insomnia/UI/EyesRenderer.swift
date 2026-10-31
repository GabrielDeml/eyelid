import AppKit
import CoreGraphics

// MARK: - The mascot, drawn in code (docs/UX.md §1.1, §2.4, §3; ARCHITECTURE.md UI/EyesRenderer)
//
// Everything here is plain Core Graphics in a y-down coordinate space, so the same artist serves the SwiftUI panel
// eyes (Canvas.withCGContext), the Dock tile, and headless icon export (NSBitmapImageRep, no window server needed).

/// One frame of the panel/icon eyes. Pure value; EyesView animates it, EyesRenderer draws it.
struct EyePose: Equatable, Sendable {
    /// 0 = closed (a downward arc), 1 = fully open. Per eye so a wink or "×" is possible.
    var openLeft: CGFloat = 1
    var openRight: CGFloat = 1
    /// Pupil offset as a fraction of the eye's half-width (−1…1 each axis).
    var gaze: CGPoint = .zero
    /// 1 = normal; 1.2 = dilated.
    var pupilScale: CGFloat = 1
    /// 0…1: pupils drift toward the nose (poke egg, UX §9).
    var crossEyed: CGFloat = 0
    /// Flat slits (heat, low power, battery floor).
    var squint: Bool = false
    /// The right eye is an "×" (lid error / stuck).
    var rightCross: Bool = false
    /// 0…1 indigo glow under the lower lids (lid engaged: 0.35).
    var glow: CGFloat = 0
    /// Night-vision sweep progress 0…1, or nil when not sweeping.
    var sweep: CGFloat? = nil
    /// 0 none, 1 bags (≥ 24 h awake), 2 bags + thin veins (≥ 72 h).
    var bags: Int = 0
    /// Night-vision eyes: luminous sclera, knocked-out pupils (app icon `.lid`).
    var nightVision: Bool = false
    /// Sweat drop progress 0…1 (squint, slides once), or nil.
    var sweat: CGFloat? = nil

    static func resting(for mood: EyeMood) -> EyePose {
        var p = EyePose()
        switch mood {
        case .asleep: p.openLeft = 0; p.openRight = 0
        case .awake: break
        case .watching: p.gaze = CGPoint(x: 0.55, y: 0)
        case .lid: p.glow = 0.35
        case .squint: p.squint = true; p.openLeft = 0.34; p.openRight = 0.34
        case .alarmed: p.rightCross = true; p.openRight = 0
        }
        return p
    }
}

/// Resolved colours for one drawing pass.
struct EyePalette: Sendable {
    var sclera: CGColor
    var iris: CGColor
    var irisDeep: CGColor
    var pupil: CGColor
    /// Closed-lid arc colour.
    var closedStroke: CGColor
    var glow: CGColor
    var cross: CGColor
    var bag: CGColor
    var vein: CGColor

    @MainActor static func panel(appearance: NSAppearance) -> EyePalette {
        EyePalette(
            sclera: Theme.scleraNS.resolvedCGColor(for: appearance),
            iris: Theme.accentAwakeNS.resolvedCGColor(for: appearance),
            irisDeep: Theme.irisDeepNS.resolvedCGColor(for: appearance),
            pupil: Theme.pupilNS.resolvedCGColor(for: appearance),
            closedStroke: Theme.scleraNS.resolvedCGColor(for: appearance),
            glow: NSColor(srgb: 0x8E8CFF).cgColor,   // systemIndigo lifted so it reads on the indigo face
            cross: NSColor(srgb: 0xFF6B5E).cgColor,
            bag: NSColor(srgb: 0x8C7BD6, alpha: 0.85).cgColor,
            vein: NSColor(srgb: 0xE8940C, alpha: 0.75).cgColor)
    }

    /// Fixed palette for the app icon and Dock tile (they live on an indigo squircle in both appearances).
    static let icon = EyePalette(
        sclera: NSColor(srgb: 0xF7F4EE).cgColor,
        iris: NSColor(srgb: 0xFFB547).cgColor,
        irisDeep: NSColor(srgb: 0xD9780A).cgColor,
        pupil: NSColor(srgb: 0x17132B).cgColor,
        closedStroke: NSColor(srgb: 0xF7F4EE).cgColor,
        glow: NSColor(srgb: 0x8B8CFF).cgColor,
        cross: NSColor(srgb: 0xFF6B5E).cgColor,
        bag: NSColor(srgb: 0x9A8CE0, alpha: 0.85).cgColor,
        vein: NSColor(srgb: 0xE8940C, alpha: 0.75).cgColor)
}

enum EyeArtist {
    /// Draws the pair of eyes centred in `rect` (y-down). `rect.width` is the pair's width.
    static func draw(in ctx: CGContext, rect: CGRect, pose: EyePose, palette: EyePalette) {
        let w = rect.width * 0.43
        let a = w / 2
        let cy = rect.midY
        let centres = [CGPoint(x: rect.minX + a, y: cy), CGPoint(x: rect.maxX - a, y: cy)]

        for (i, c) in centres.enumerated() {
            let isRight = i == 1
            var open = isRight ? pose.openRight : pose.openLeft
            if pose.squint { open = min(open, 0.34) }

            if pose.glow > 0.001 { drawGlow(ctx, centre: c, a: a, strength: pose.glow, palette: palette) }

            if isRight && pose.rightCross {
                drawCross(ctx, centre: c, a: a, palette: palette)
                continue
            }

            // Cross-eyed: pupils toward the nose.
            let inward: CGFloat = isRight ? -1 : 1
            let gaze = CGPoint(x: pose.gaze.x + pose.crossEyed * 0.55 * inward, y: pose.gaze.y)
            drawEye(ctx, centre: c, a: a, open: open, squint: pose.squint, gaze: gaze, pose: pose,
                    palette: palette, isRight: isRight)
            if pose.bags > 0 { drawBag(ctx, centre: c, a: a, palette: palette, isRight: isRight) }
        }

        if let sweat = pose.sweat, sweat > 0, sweat < 1 {
            drawSweat(ctx, near: centres[1], a: a, progress: sweat, palette: palette)
        }
    }

    // MARK: Pieces

    /// Almond with a moving upper lid. When open == 0 both curves coincide: the closed "‿" arc.
    static func almond(centre c: CGPoint, a: CGFloat, open: CGFloat, squint: Bool) -> CGPath {
        let lower = a * (squint ? 0.30 : 0.80)      // lower lid depth (peak of curve)
        let upper = a * (squint ? 0.42 : 1.14)      // upper lid height when fully open
        let k: CGFloat = 1 / 0.75                   // cubic with both controls at h peaks at 0.75 h
        let lowY = c.y + lower * k
        let upY = lowY - (lower + upper) * k * max(0, min(1, open))
        let p = CGMutablePath()
        let l = CGPoint(x: c.x - a, y: c.y), r = CGPoint(x: c.x + a, y: c.y)
        p.move(to: l)
        p.addCurve(to: r, control1: CGPoint(x: c.x - a * 0.52, y: upY), control2: CGPoint(x: c.x + a * 0.52, y: upY))
        p.addCurve(to: l, control1: CGPoint(x: c.x + a * 0.52, y: lowY), control2: CGPoint(x: c.x - a * 0.52, y: lowY))
        p.closeSubpath()
        return p
    }

    private static func closedArc(centre c: CGPoint, a: CGFloat) -> CGPath {
        let k: CGFloat = 1 / 0.75
        let lowY = c.y + a * 0.62 * k * 0.72
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x - a * 0.92, y: c.y))
        p.addCurve(to: CGPoint(x: c.x + a * 0.92, y: c.y),
                   control1: CGPoint(x: c.x - a * 0.48, y: lowY), control2: CGPoint(x: c.x + a * 0.48, y: lowY))
        return p
    }

    private static func drawEye(_ ctx: CGContext, centre c: CGPoint, a: CGFloat, open: CGFloat, squint: Bool,
                                gaze: CGPoint, pose: EyePose, palette: EyePalette, isRight: Bool) {
        // Closed (or nearly): the downward arc, with a little lash at the outer corner.
        let closedness = max(0, min(1, (0.14 - open) / 0.14))
        if closedness > 0 {
            ctx.saveGState()
            ctx.setAlpha(closedness)
            ctx.setStrokeColor(palette.closedStroke)
            ctx.setLineWidth(max(1, a * 0.2))
            ctx.setLineCap(.round)
            ctx.addPath(closedArc(centre: c, a: a))
            ctx.strokePath()
            ctx.restoreGState()
        }
        guard open > 0.02 else { return }

        let shape = almond(centre: c, a: a, open: open, squint: squint)
        ctx.saveGState()
        ctx.setAlpha(1 - closedness)

        // Sclera.
        ctx.addPath(shape)
        if pose.nightVision {
            ctx.saveGState()
            ctx.clip()
            let colours = [NSColor(srgb: 0xFFFFFF).cgColor, NSColor(srgb: 0xC9C6FF).cgColor, NSColor(srgb: 0x8E8BF5).cgColor]
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours as CFArray,
                                  locations: [0, 0.55, 1]) {
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x, y: c.y - a * 0.1), startRadius: 0,
                                       endCenter: c, endRadius: a * 1.1, options: [.drawsAfterEndLocation])
            }
            ctx.restoreGState()
        } else {
            ctx.setFillColor(palette.sclera)
            ctx.fillPath()
        }

        // Iris + pupil, clipped to the almond.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let irisR = a * (squint ? 0.5 : 0.64)
        let maxShift = a - irisR * 0.9
        let ic = CGPoint(x: c.x + max(-1, min(1, gaze.x)) * maxShift,
                         y: c.y + a * 0.04 + max(-1, min(1, gaze.y)) * a * 0.22)
        if pose.nightVision {
            // Knocked-out pupil: a dark vertical slit.
            let pr = irisR * 0.42 * pose.pupilScale
            ctx.setFillColor(palette.pupil)
            ctx.fillEllipse(in: CGRect(x: ic.x - pr * 0.75, y: ic.y - pr * 1.25, width: pr * 1.5, height: pr * 2.5))
        } else {
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [palette.iris, palette.irisDeep] as CFArray, locations: [0.35, 1]) {
                ctx.saveGState()
                ctx.addEllipse(in: CGRect(x: ic.x - irisR, y: ic.y - irisR, width: irisR * 2, height: irisR * 2))
                ctx.clip()
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: ic.x, y: ic.y - irisR * 0.2), startRadius: 0,
                                       endCenter: ic, endRadius: irisR, options: [.drawsAfterEndLocation])
                ctx.restoreGState()
            }
            let pr = irisR * 0.5 * pose.pupilScale
            ctx.setFillColor(palette.pupil)
            ctx.fillEllipse(in: CGRect(x: ic.x - pr, y: ic.y - pr, width: pr * 2, height: pr * 2))
            // Catch-light.
            let hr = irisR * 0.24
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
            ctx.fillEllipse(in: CGRect(x: ic.x + irisR * 0.22 - hr, y: ic.y - irisR * 0.42 - hr, width: hr * 2, height: hr * 2))
        }
        // Thin veins (≥ 72 h awake): from the outer corner.
        if pose.bags >= 2 && !pose.nightVision {
            ctx.setStrokeColor(palette.vein)
            ctx.setLineWidth(max(0.5, a * 0.045))
            ctx.setLineCap(.round)
            let dir: CGFloat = isRight ? 1 : -1
            let corner = CGPoint(x: c.x + dir * a * 0.98, y: c.y)
            for (dy, len) in [(-0.16, 0.42), (0.05, 0.5), (0.2, 0.36)] as [(CGFloat, CGFloat)] {
                let end = CGPoint(x: corner.x - dir * a * len, y: corner.y + a * dy * 1.4)
                ctx.move(to: corner)
                ctx.addQuadCurve(to: end, control: CGPoint(x: (corner.x + end.x) / 2, y: corner.y + a * dy * 0.2))
            }
            ctx.strokePath()
        }
        // Night-vision sweep: a soft indigo band crossing the eyes.
        if let s = pose.sweep {
            let x = c.x - a * 1.6 + (a * 3.2) * s
            let colours = [palette.glow.copy(alpha: 0) ?? palette.glow, palette.glow.copy(alpha: 0.85) ?? palette.glow,
                           palette.glow.copy(alpha: 0) ?? palette.glow]
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours as CFArray,
                                  locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: x - a * 0.5, y: c.y - a * 0.3),
                                       end: CGPoint(x: x + a * 0.5, y: c.y + a * 0.3), options: [])
            }
        }
        ctx.restoreGState()
        ctx.restoreGState()
    }

    private static func drawGlow(_ ctx: CGContext, centre c: CGPoint, a: CGFloat, strength: CGFloat, palette: EyePalette) {
        let colours = [palette.glow.copy(alpha: min(1, strength * 1.6)) ?? palette.glow, palette.glow.copy(alpha: 0) ?? palette.glow]
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.saveGState()
        // Squash vertically: the glow pools under the lower lid.
        let centre = CGPoint(x: c.x, y: c.y + a * 0.55)
        ctx.translateBy(x: centre.x, y: centre.y)
        ctx.scaleBy(x: 1, y: 0.55)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: a * 1.45, options: [])
        ctx.restoreGState()
    }

    private static func drawCross(_ ctx: CGContext, centre c: CGPoint, a: CGFloat, palette: EyePalette) {
        let s = a * 0.62
        ctx.saveGState()
        ctx.setStrokeColor(palette.cross)
        ctx.setLineWidth(max(1.2, a * 0.24))
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x - s, y: c.y - s)); ctx.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
        ctx.move(to: CGPoint(x: c.x + s, y: c.y - s)); ctx.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawBag(_ ctx: CGContext, centre c: CGPoint, a: CGFloat, palette: EyePalette, isRight: Bool) {
        let y = c.y + a * 0.78
        ctx.saveGState()
        ctx.setStrokeColor(palette.bag)
        ctx.setLineWidth(max(0.8, a * 0.1))
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x - a * 0.62, y: y))
        ctx.addQuadCurve(to: CGPoint(x: c.x + a * 0.62, y: y), control: CGPoint(x: c.x, y: y + a * 0.34))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawSweat(_ ctx: CGContext, near c: CGPoint, a: CGFloat, progress: CGFloat, palette: EyePalette) {
        let t = progress
        let x = c.x + a * 1.25
        let y = c.y - a * 0.9 + a * 1.4 * t
        let r = a * 0.2
        let alpha = t < 0.15 ? t / 0.15 : (t > 0.8 ? (1 - t) / 0.2 : 1)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x, y: y - r * 1.8))
        p.addCurve(to: CGPoint(x: x, y: y + r), control1: CGPoint(x: x + r * 1.3, y: y - r * 0.2),
                   control2: CGPoint(x: x + r, y: y + r))
        p.addCurve(to: CGPoint(x: x, y: y - r * 1.8), control1: CGPoint(x: x - r, y: y + r),
                   control2: CGPoint(x: x - r * 1.3, y: y - r * 0.2))
        ctx.addPath(p)
        ctx.setFillColor(NSColor(srgb: 0x9FD4FF).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: - Public renderer

enum EyesRenderer {
    static let menuBarSize = NSSize(width: 22, height: 16)

    /// 22 × 16 pt template image. `blink` 0 (open) … 1 (closed). Shapes per UX.md §1.1; stroke 1.5 (2.0 if highContrast).
    /// Resolution-independent (drawn at the backing scale on demand); at 1x the geometry snaps to the pixel grid.
    static func menuBarImage(mood: EyeMood, blink: CGFloat = 0, highContrast: Bool = false) -> NSImage {
        let image = NSImage(size: menuBarSize, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = abs(ctx.userSpaceToDeviceSpaceTransform.a)
            drawMenuBarGlyph(ctx, mood: mood, blink: blink, stroke: highContrast ? 2.0 : 1.5,
                             pixelScale: scale > 0 ? scale : 2)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Insomnia"
        return image
    }

    /// Glyph geometry (y-down, 22 × 16). Eyes are 7.8 × ~6 pt almonds with a clear 3 pt gap so they never merge
    /// into one shape at 1x; the asleep "z" sits up and to the right. `pixelScale` < 1.5 (a 1x display): a 1 pt
    /// stroke (2 under Increase Contrast) on half-pixel centres, so edges land on pixels instead of smearing.
    static func drawMenuBarGlyph(_ ctx: CGContext, mood: EyeMood, blink: CGFloat, stroke: CGFloat,
                                 colour: CGColor = CGColor(gray: 0, alpha: 1), pixelScale: CGFloat = 2) {
        let snap = pixelScale < 1.5
        let lineWidth = snap ? (stroke >= 2 ? 2.0 : 1.0) : stroke
        ctx.setStrokeColor(colour)
        ctx.setFillColor(colour)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let a: CGFloat = 3.9                                // eye half-width
        let cy: CGFloat = snap ? 8.5 : 8.4
        let pair: [CGFloat] = snap ? [5.5, 16.5] : [5.4, 16.6]
        let open = max(0, min(1, 1 - blink))
        switch mood {
        case .asleep:
            // Two downward arcs (closed lids) where the open eyes sit, so the toggle-off blink closes into them
            // without a jump, + a small "z" up and right, clear of the right arc.
            for cx in pair { strokeClosed(ctx, cx: cx, cy: 9.2, a: 3.3) }
            let z = CGRect(x: 17.4, y: 0.9, width: 3.8, height: 4.2)
            ctx.setLineWidth(snap ? 1.0 : max(1.1, stroke - 0.25))
            ctx.move(to: CGPoint(x: z.minX, y: z.minY))
            ctx.addLine(to: CGPoint(x: z.maxX, y: z.minY))
            ctx.addLine(to: CGPoint(x: z.minX, y: z.maxY))
            ctx.addLine(to: CGPoint(x: z.maxX, y: z.maxY))
            ctx.strokePath()

        case .awake, .watching, .lid:
            // Watching: eyes nudge left to make room for the trailing dot; pupils glance right.
            let centres: [CGFloat] = mood == .watching ? [4.5, 14.3] : pair
            for cx in centres {
                let c = CGPoint(x: cx, y: cy)
                if open < 0.12 { strokeClosed(ctx, cx: cx, cy: cy, a: a); continue }
                let shape = glyphAlmond(c: c, a: a, top: 3.4 * open, bottom: 2.7)
                let r: CGFloat = 1.65
                let pupil = CGRect(x: c.x - r + (mood == .watching ? 1.9 : 0), y: c.y - r + 0.1, width: r * 2, height: r * 2)
                if mood == .lid {
                    // Night vision: a solid silhouette (the same outer size as the stroked moods, so the glyph
                    // doesn't shrink when lid mode engages) with knocked-out pupils.
                    let outline = shape.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round,
                                             miterLimit: 10)
                    let solid = shape.union(outline).subtracting(CGPath(ellipseIn: pupil.insetBy(dx: 0.15, dy: 0.15),
                                                                        transform: nil))
                    ctx.addPath(solid)
                    ctx.fillPath()
                } else {
                    ctx.addPath(shape)
                    ctx.strokePath()
                    ctx.saveGState()
                    ctx.addPath(shape)
                    ctx.clip()
                    ctx.fillEllipse(in: pupil)
                    ctx.restoreGState()
                }
            }
            if mood == .watching {
                // A 2 pt dot after the right eye: "…".
                ctx.fillEllipse(in: CGRect(x: 19.6, y: cy + 1.2, width: 2, height: 2))
            }

        case .squint:
            // Flat slits, 3 pt tall, no pupils.
            for cx in pair {
                ctx.addPath(glyphAlmond(c: CGPoint(x: cx, y: cy), a: a + 0.2, top: 1.5, bottom: 1.5))
                ctx.strokePath()
            }

        case .alarmed:
            let c = CGPoint(x: pair[0], y: cy)
            let shape = glyphAlmond(c: c, a: a, top: 3.4, bottom: 2.7)
            ctx.addPath(shape)
            ctx.strokePath()
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.fillEllipse(in: CGRect(x: c.x - 1.65, y: c.y - 1.55, width: 3.3, height: 3.3))
            ctx.restoreGState()
            let x = CGPoint(x: pair[1], y: cy), s: CGFloat = 2.7
            ctx.move(to: CGPoint(x: x.x - s, y: x.y - s)); ctx.addLine(to: CGPoint(x: x.x + s, y: x.y + s))
            ctx.move(to: CGPoint(x: x.x + s, y: x.y - s)); ctx.addLine(to: CGPoint(x: x.x - s, y: x.y + s))
            ctx.strokePath()
        }
    }

    /// Almond whose upper/lower lid peaks sit `top` / `bottom` pt from the corner line (cubic peaks at 0.75 × control).
    private static func glyphAlmond(c: CGPoint, a: CGFloat, top: CGFloat, bottom: CGFloat) -> CGPath {
        let upY = c.y - top / 0.75, lowY = c.y + bottom / 0.75
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x - a, y: c.y))
        p.addCurve(to: CGPoint(x: c.x + a, y: c.y), control1: CGPoint(x: c.x - a * 0.45, y: upY),
                   control2: CGPoint(x: c.x + a * 0.45, y: upY))
        p.addCurve(to: CGPoint(x: c.x - a, y: c.y), control1: CGPoint(x: c.x + a * 0.45, y: lowY),
                   control2: CGPoint(x: c.x - a * 0.45, y: lowY))
        p.closeSubpath()
        return p
    }

    private static func strokeClosed(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, a: CGFloat) {
        ctx.move(to: CGPoint(x: cx - a, y: cy - 1.0))
        ctx.addCurve(to: CGPoint(x: cx + a, y: cy - 1.0), control1: CGPoint(x: cx - a * 0.45, y: cy + 2.4),
                     control2: CGPoint(x: cx + a * 0.45, y: cy + 2.4))
        ctx.strokePath()
    }

    // MARK: App icon / Dock tile

    /// Full-colour squircle icon (Dock tile + exported .icns). `pill`: optional time text drawn bottom-centre,
    /// inside the tile (never `badgeLabel`, which means "needs attention").
    static func appIcon(size: CGFloat, mood: EyeMood, pill: String? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawAppIcon(ctx, size: size, mood: mood, pill: pill)
            return true
        }
        image.accessibilityDescription = "Insomnia"
        return image
    }

    /// Draws the icon into a y-down context of `size` × `size` points.
    static func drawAppIcon(_ ctx: CGContext, size s: CGFloat, mood: EyeMood, pill: String?, pose: EyePose? = nil) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        // macOS icon grid: 824 pt body inside a 1024 pt canvas, with a soft drop shadow.
        let inset = s * 100 / 1024
        let body = CGRect(x: inset, y: inset * 0.9, width: s - inset * 2, height: s - inset * 2)
        let shape = squircle(in: body)

        // Shadow + base fill.
        let (top, bottom): (UInt32, UInt32) = switch mood {
        case .asleep: (0x2B2E72, 0x4B3490)
        case .lid: (0x1E1C55, 0x3A2A86)
        case .alarmed: (0x3A2C78, 0x6A3290)
        default: (0x4C4FDB, 0x7B42D6)
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: s * 10 / 1024), blur: s * 22 / 1024,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(NSColor(srgb: bottom).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        if let g = CGGradient(colorsSpace: space, colors: [NSColor(srgb: top).cgColor, NSColor(srgb: bottom).cgColor] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: body.midX, y: body.minY), end: CGPoint(x: body.midX, y: body.maxY), options: [])
        }
        // Top sheen.
        if let g = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray,
                              locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: body.midX, y: body.minY - body.height * 0.15), startRadius: 0,
                                   endCenter: CGPoint(x: body.midX, y: body.minY - body.height * 0.15),
                                   endRadius: body.width * 0.85, options: [])
        }
        // A few stars on the night sky (subtle; skipped at tiny sizes).
        if s >= 64 {
            let stars: [(CGFloat, CGFloat, CGFloat)] = [(0.18, 0.2, 0.012), (0.8, 0.16, 0.009), (0.3, 0.12, 0.007),
                                                       (0.86, 0.36, 0.007), (0.12, 0.42, 0.006)]
            // While asleep the "z z" occupies the top right; keep that sky clear so the small "z" stays crisp.
            for (x, y, r) in stars where !(mood == .asleep && x > 0.6 && y < 0.3) {
                ctx.setFillColor(CGColor(gray: 1, alpha: mood == .asleep ? 0.55 : 0.32))
                ctx.fillEllipse(in: CGRect(x: body.minX + body.width * x, y: body.minY + body.height * y,
                                           width: body.width * r * 2, height: body.width * r * 2))
            }
        }
        // Lid mode: indigo glow + the closed-lid bar.
        if mood == .lid {
            if let g = CGGradient(colorsSpace: space, colors: [NSColor(srgb: 0x7A7BFF, alpha: 0.55).cgColor,
                                                                NSColor(srgb: 0x7A7BFF, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 1]) {
                let c = CGPoint(x: body.midX, y: body.minY + body.height * 0.5)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: body.width * 0.55, options: [])
            }
            // The closed-lid bar sits where the time pill goes; with a pill the night-vision eyes and glow carry it.
            if pill?.isEmpty ?? true {
                let barW = body.width * 0.56, barH = max(1.5, body.height * 0.035)
                let bar = CGRect(x: body.midX - barW / 2, y: body.minY + body.height * 0.74, width: barW, height: barH)
                ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
                ctx.setFillColor(NSColor(srgb: 0xC9C6FF, alpha: 0.75).cgColor)
                ctx.fillPath()
            }
        }
        // Inner hairline.
        ctx.addPath(shape)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
        ctx.setLineWidth(max(0.5, s / 256))
        ctx.strokePath()
        ctx.restoreGState()

        // Eyes.
        let pairW = body.width * 0.68
        let eyesCY = body.minY + body.height * (pill == nil ? 0.5 : 0.4)
        let eyesRect = CGRect(x: body.midX - pairW / 2, y: eyesCY - pairW * 0.2, width: pairW, height: pairW * 0.4)
        var p = pose ?? EyePose.resting(for: mood)
        if mood == .lid { p.nightVision = true; p.glow = 0.5 }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: s * 6 / 1024), blur: s * 14 / 1024, color: CGColor(gray: 0, alpha: 0.28))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        var palette = EyePalette.icon
        if mood == .asleep { palette.closedStroke = NSColor(srgb: 0xE9E4F7).cgColor }
        EyeArtist.draw(in: ctx, rect: eyesRect, pose: p, palette: palette)
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // "z z" while asleep.
        if mood == .asleep {
            let base = body.width
            drawText(ctx, "z", size: base * 0.13, at: CGPoint(x: body.minX + body.width * 0.70, y: body.minY + body.height * 0.22),
                     colour: NSColor(srgb: 0xF7F4EE, alpha: 0.95), weight: .heavy)
            drawText(ctx, "z", size: base * 0.09, at: CGPoint(x: body.minX + body.width * 0.81, y: body.minY + body.height * 0.13),
                     colour: NSColor(srgb: 0xF7F4EE, alpha: 0.6), weight: .heavy)
        }

        // Time pill.
        if let pill, !pill.isEmpty {
            var fontSize = s * 22 / 128
            func make(_ size: CGFloat) -> NSAttributedString {
                NSAttributedString(string: pill, attributes: [.font: roundedFont(size: size, weight: .bold),
                                                              .foregroundColor: NSColor(srgb: 0x2A2570)])
            }
            var text = make(fontSize)
            let maxText = body.width * 0.78
            if text.size().width > maxText {
                fontSize *= maxText / text.size().width
                text = make(fontSize)
            }
            let ts = text.size()
            let fullSize = s * 22 / 128
            let h = fullSize * 1.42, w = min(body.width * 0.94, max(h * 1.6, ts.width + fullSize * 0.9))
            let rect = CGRect(x: body.midX - w / 2, y: body.maxY - h - body.height * 0.07, width: w, height: h)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: s / 128), blur: s * 3 / 128, color: CGColor(gray: 0, alpha: 0.25))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.97))
            ctx.fillPath()
            ctx.restoreGState()
            drawAttributed(ctx, text, centre: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    /// Superellipse (n = 5) approximating Apple's continuous-corner icon shape.
    static func squircle(in r: CGRect, n: CGFloat = 5) -> CGPath {
        let p = CGMutablePath()
        let a = r.width / 2, b = r.height / 2, c = CGPoint(x: r.midX, y: r.midY)
        let steps = 256
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let x = c.x + a * copysign(pow(abs(ct), 2 / n), ct)
            let y = c.y + b * copysign(pow(abs(st), 2 / n), st)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }

    static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    private static func drawText(_ ctx: CGContext, _ s: String, size: CGFloat, at centre: CGPoint, colour: NSColor,
                                 weight: NSFont.Weight) {
        let text = NSAttributedString(string: s, attributes: [.font: roundedFont(size: size, weight: weight), .foregroundColor: colour])
        drawAttributed(ctx, text, centre: centre)
    }

    /// Draws text centred at `centre` in a y-down CGContext (works headless).
    private static func drawAttributed(_ ctx: CGContext, _ text: NSAttributedString, centre: CGPoint) {
        let size = text.size()
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        text.draw(at: NSPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2))
        NSGraphicsContext.current = previous
    }

    // MARK: Headless bitmap rendering (--export-icon, --snapshot)

    /// Renders a y-down drawing into an sRGB bitmap of `pixels` × `pixels` (or w × h) pixels.
    static func bitmap(width: Int, height: Int, pointSize: NSSize,
                       draw: (CGContext) -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = pointSize
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // Scale points → pixels and flip to y-down.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / pointSize.width, y: -CGFloat(height) / pointSize.height)
        draw(ctx)
        gc.flushGraphics()
        NSGraphicsContext.current = previous
        return rep.retagging(with: .sRGB)
    }

    /// Writes AppIcon.iconset PNGs (16…512 @1x and @2x) into `directory`. Returns false on any write failure.
    static func exportIconset(to directory: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return false }
        var ok = true
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                guard let rep = bitmap(width: px, height: px, pointSize: NSSize(width: base, height: base), draw: { ctx in
                    drawAppIcon(ctx, size: CGFloat(base), mood: .awake, pill: nil)
                }), let png = rep.representation(using: .png, properties: [:]) else { ok = false; continue }
                do { try png.write(to: directory.appendingPathComponent(name)) } catch { ok = false }
            }
        }
        return ok
    }
}
