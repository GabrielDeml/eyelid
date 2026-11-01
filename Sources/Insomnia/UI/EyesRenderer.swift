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

    /// The wide-awake moon (UX.md §1.1), y-down in a 22 × 16 pt canvas: a fat outlined crescent opening up and to
    /// the right with one eye in its belly, plus a badge in a fixed slot at the upper right for every mood but
    /// `.awake`. Lid mode is a solid moon with a knocked-out night-vision eye and a closed-laptop badge (never a plain
    /// filled crescent, which is macOS Focus). Alpha-only in `colour`: knock-outs are path subtractions or even-odd
    /// fills, never a clear blend, so nothing underneath is punched through.
    /// `pixelScale` < 1.5 (a 1x display): a 1 pt stroke (2 under Increase Contrast), eye and badges on whole pixels.
    /// `blink` 0…1 closes the eye into the asleep eye (the same lens), so the toggle-off blink lands without a jump.
    static func drawMenuBarGlyph(_ ctx: CGContext, mood: EyeMood, blink: CGFloat, stroke: CGFloat,
                                 colour: CGColor = CGColor(gray: 0, alpha: 1), pixelScale: CGFloat = 2) {
        typealias M = MenuBarMoon
        let snap = pixelScale < 1.5
        // Optical weight: 10% over the spec stroke so the moon sits with SF Symbols (wifi) at 2x.
        let lineWidth = snap ? (stroke >= 2 ? 2.0 : 1.0) : stroke * 1.1
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(colour)
        ctx.setFillColor(colour)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let moon = M.crescent
        let outline = moon.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let t = max(0, min(1, mood == .asleep ? 1 : blink))
        let centre = mood == .watching ? M.glanceCentre : M.eyeCentre
        let radius = mood == .alarmed ? M.eyeRadius + 0.35 : M.eyeRadius

        if mood == .lid {
            // Solid moon (the outlined moods' outer size, so the glyph doesn't grow) with the eye knocked out and a
            // solid pupil left inside it; the closed-laptop badge breaks the plain crescent silhouette.
            var solid = moon.union(outline)
            if snap {
                solid = t < 0.25 ? solid.subtracting(M.PixelEye.lidHole).union(M.PixelEye.lidPupil)
                                 : solid.subtracting(M.PixelEye.path(t: t))
            } else {
                let eye = M.eye(centre, radius, t: t)
                let hole = eye.union(eye.copy(strokingWithWidth: 0.7 + lineWidth * t, lineCap: .round,
                                              lineJoin: .round, miterLimit: 10))
                solid = solid.subtracting(hole)
                if t < 0.75 { solid = solid.union(M.disc(centre, radius * 0.55).intersection(eye)) }
            }
            ctx.addPath(solid)
            ctx.addPath(M.laptop(snap: snap))
            ctx.fillPath()
            return
        }

        ctx.addPath(outline)
        ctx.fillPath()

        switch mood {
        case .squint:
            // Heavy-lidded: the lower half of the eye under a lid tilted up at the outer (left) corner.
            if snap {
                ctx.fill(CGRect(x: 3, y: 9, width: 4, height: 1))
                ctx.fill(CGRect(x: 4, y: 10, width: 2, height: 1))
            } else {
                ctx.saveGState()
                ctx.translateBy(x: centre.x, y: centre.y - 0.15)
                ctx.rotate(by: 0.3)
                ctx.addArc(center: .zero, radius: radius, startAngle: 0, endAngle: .pi, clockwise: false)
                ctx.closePath()
                ctx.fillPath()
                ctx.setLineWidth(lineWidth * 0.8)   // the heavy upper lid
                ctx.move(to: CGPoint(x: -radius, y: 0))
                ctx.addLine(to: CGPoint(x: radius, y: 0))
                ctx.strokePath()
                ctx.restoreGState()
            }
        default:
            if snap {
                // 1x: hand-placed pixels (open, half-closed, closed), so nothing smears into the outline.
                ctx.addPath(M.PixelEye.path(t: t, dy: mood == .watching ? -1 : 0, tall: mood == .alarmed))
                ctx.fillPath(using: .evenOdd)
            } else {
                let eye = M.eye(centre, radius, t: t)
                if t < 0.01 {
                    // Open: a solid round eye with a knocked-out catch-light up and to the right.
                    ctx.addPath(eye)
                    let glint = CGPoint(x: centre.x + radius * 0.36, y: centre.y - radius * 0.36)
                    ctx.addPath(M.disc(glint, radius * 0.34))
                    ctx.fillPath(using: .evenOdd)
                } else {
                    // Closing: the lens flattens into the closed "‿" lid, stroked to moon weight as it shuts.
                    ctx.addPath(eye)
                    ctx.fillPath()
                    ctx.setLineWidth(lineWidth * t)
                    ctx.addPath(eye)
                    ctx.strokePath()
                    ctx.setLineWidth(lineWidth)
                }
            }
        }

        // The badge (same slot for every mood).
        let slot = snap ? CGPoint(x: 18.5, y: 3.5) : M.slot
        switch mood {
        case .asleep:
            let z = snap ? CGRect(x: 16, y: 1, width: 4, height: 4)
                         : CGRect(x: slot.x - 2.1, y: slot.y - 2.2, width: 4.2, height: 4.4)
            let zw = snap ? 1.0 : lineWidth * 0.8
            let inset = zw / 2
            ctx.setLineWidth(zw)
            ctx.move(to: CGPoint(x: z.minX + inset, y: z.minY + inset))
            ctx.addLine(to: CGPoint(x: z.maxX - inset, y: z.minY + inset))
            ctx.addLine(to: CGPoint(x: z.minX + inset, y: z.maxY - inset))
            ctx.addLine(to: CGPoint(x: z.maxX - inset, y: z.maxY - inset))
            ctx.strokePath()
        case .watching:
            // The eye glances up and to the right at a sparkle: something automatic is keeping me up.
            ctx.addPath(M.sparkle(slot, r: snap ? 2.0 : 2.6, inner: 0.7))
            ctx.fillPath()
        case .squint:
            ctx.addPath(M.drop(CGPoint(x: slot.x, y: slot.y + 1.3), r: snap ? 1.5 : 1.6))
            ctx.fillPath()
        case .alarmed:
            // A full-height "!" beside a wider eye.
            let x = snap ? 18.5 : slot.x
            ctx.setLineWidth(snap ? 1.0 : lineWidth * 1.1)
            ctx.setLineCap(snap ? .butt : .round)
            ctx.move(to: CGPoint(x: x, y: snap ? 1.0 : 1.9))
            ctx.addLine(to: CGPoint(x: x, y: snap ? 10.0 : 9.6))
            ctx.strokePath()
            if snap {
                ctx.fill(CGRect(x: 18, y: 12, width: 1, height: 2))
            } else {
                let d = lineWidth * 1.35
                ctx.fillEllipse(in: CGRect(x: x - d / 2, y: 12.9 - d / 2, width: d, height: d))
            }
        case .awake, .lid:
            break
        }
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

// MARK: - Menu bar moon geometry (UX.md §1.1)

/// Geometry of the wide-awake moon, y-down in the 22 × 16 pt menu bar canvas.
enum MenuBarMoon {
    /// Outer disc: extremes on half points (1.5 … 14.5), so 1x edges land on pixels.
    static let centre = CGPoint(x: 8, y: 8)
    static let radius: CGFloat = 6.5
    /// The bite: a disc offset up and to the right (≈ 20°). Belly thickness = radius + biteOffset − biteRadius = 7.1.
    static let axis = CGVector(dx: cos(-0.36), dy: sin(-0.36))
    static let biteOffset: CGFloat = 5.0
    static let biteRadius: CGFloat = 4.4
    /// The eye: centred in the belly, ≥ 0.8 pt clear of the outline's inner edge at the 1.65 pt stroke.
    static let eyeCentre = CGPoint(x: 5.25, y: 9.0)
    static let eyeRadius: CGFloat = 1.9
    /// `.watching`: the eye glances up and to the right, toward the sparkle.
    static let glanceCentre = CGPoint(x: 5.65, y: 8.7)
    /// Badge slot centre (z, sparkle, drop, "!", laptop).
    static let slot = CGPoint(x: 18.6, y: 3.6)

    static var crescent: CGPath {
        let bite = CGPoint(x: centre.x + axis.dx * biteOffset, y: centre.y + axis.dy * biteOffset)
        return disc(centre, radius).subtracting(disc(bite, biteRadius))
    }

    static func disc(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    /// The eye at blink `t`: 0 a round disc … 1 the closed "‿" lid (a thin downward lens). Mid-blink is a level,
    /// symmetric lens, so no blink frame looks like the tilted squint.
    static func eye(_ c: CGPoint, _ r: CGFloat, t: CGFloat) -> CGPath {
        let w = r - 0.2 * r * t
        let top = r - 1.53 * r * t          // the upper lid falls past the corner line onto the lower one
        let bottom = r - 0.47 * r * t
        // Closing drifts a little down and right, where the belly is widest, so the lid line clears the outline.
        let c = CGPoint(x: c.x + 0.25 * t, y: c.y + 0.25 * t), y = c.y
        let k: CGFloat = 4.0 / 3.0          // a cubic with both controls at h peaks at 0.75 h
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x - w, y: y))
        p.addCurve(to: CGPoint(x: c.x + w, y: y), control1: CGPoint(x: c.x - w, y: y - top * k),
                   control2: CGPoint(x: c.x + w, y: y - top * k))
        p.addCurve(to: CGPoint(x: c.x - w, y: y), control1: CGPoint(x: c.x + w, y: y + bottom * k),
                   control2: CGPoint(x: c.x - w, y: y + bottom * k))
        p.closeSubpath()
        return p
    }

    /// The 1x eye on whole pixels: columns 3…6, one clear pixel inside the 1 px outline at rows 6…10.
    enum PixelEye {
        /// Blink `t` < 0.25: a 4 × 4 px disc (corners off; 4 × 5 if `tall`) with a 1 px catch-light, for an even-odd
        /// fill. < 0.75: a level 4 × 2 px slit. Otherwise the closed "‿" (the asleep eye).
        static func path(t: CGFloat, dy: CGFloat = 0, tall: Bool = false) -> CGPath {
            let p = CGMutablePath()
            if t < 0.25 {
                let b = CGRect(x: 3, y: 7 + dy - (tall ? 1 : 0), width: 4, height: tall ? 5 : 4)
                p.addRect(CGRect(x: b.minX + 1, y: b.minY, width: 2, height: b.height))
                p.addRect(CGRect(x: b.minX, y: b.minY + 1, width: 4, height: b.height - 2))
                let out = CGMutablePath()
                out.addPath(p.normalized())
                out.addRect(CGRect(x: 5, y: b.minY + 1, width: 1, height: 1))
                return out
            }
            if t < 0.75 {
                p.addRect(CGRect(x: 3, y: 8, width: 4, height: 2))
            } else {
                p.addRect(CGRect(x: 3, y: 8, width: 1, height: 1))
                p.addRect(CGRect(x: 6, y: 8, width: 1, height: 1))
                p.addRect(CGRect(x: 4, y: 9, width: 2, height: 1))
            }
            return p
        }
        /// Lid mode at 1x: a 4 × 4 px hole around a 2 × 2 px pupil.
        static var lidHole: CGPath { CGPath(rect: CGRect(x: 3, y: 7, width: 4, height: 4), transform: nil) }
        static var lidPupil: CGPath { CGPath(rect: CGRect(x: 4, y: 8, width: 2, height: 2), transform: nil) }
    }

    /// Lid mode's badge: a closed laptop seen from the side (lid and base joined by a rounded hinge on the left,
    /// open at the front).
    static func laptop(snap: Bool) -> CGPath {
        let body = snap ? CGRect(x: 16, y: 2, width: 6, height: 4) : CGRect(x: 15.6, y: 1.9, width: 6.0, height: 3.9)
        let corner: CGFloat = snap ? 1.0 : 1.2
        let slit = snap ? CGRect(x: 18, y: 3, width: 4, height: 1)
                        : CGRect(x: body.minX + 1.6, y: body.minY + 1.25, width: body.width, height: 0.9)
        return CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)
            .subtracting(CGPath(rect: slit, transform: nil))
    }

    /// Four-point sparkle.
    static func sparkle(_ c: CGPoint, r: CGFloat, inner: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4 - .pi / 2
            let rr = i.isMultiple(of: 2) ? r : inner
            let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    /// Sweat drop: round bottom centred on `c`, pointed top.
    static func drop(_ c: CGPoint, r: CGFloat) -> CGPath {
        let tip = CGPoint(x: c.x, y: c.y - r - 2.6)
        let p = CGMutablePath()
        p.move(to: tip)
        p.addCurve(to: CGPoint(x: c.x + r, y: c.y), control1: CGPoint(x: c.x + 0.4, y: c.y - r - 1.4),
                   control2: CGPoint(x: c.x + r, y: c.y - 1.2))
        p.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi, clockwise: false)
        p.addCurve(to: tip, control1: CGPoint(x: c.x - r, y: c.y - 1.2), control2: CGPoint(x: c.x - 0.4, y: c.y - r - 1.4))
        p.closeSubpath()
        return p
    }
}
