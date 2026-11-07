import AppKit

/// The menu bar moon (docs/DESIGN.md "Menu bar moon"): one silhouette per mode, plus an optional "!".
/// Template image, never colour. 22 × 16 pt, y-down. A badge slot at the upper right carries the mode:
///   off      outlined crescent, closed eye, "z"
///   awake    outlined crescent, open eye, no badge
///   screenOn outlined crescent, open eye, sparkle (the screen stays lit)
///   lid      solid crescent with the eye knocked out, laptop badge
///   "!"      added under the badge
/// At 1x the geometry snaps to whole pixels. Knock-outs are path subtractions, never a clear blend.
enum MoonGlyph {
    static let size = NSSize(width: 22, height: 16)

    static func image(mode: Engine.Mode, attention: Bool, highContrast: Bool = false) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = abs(ctx.userSpaceToDeviceSpaceTransform.a)
            draw(ctx, mode: mode, attention: attention, stroke: highContrast ? 2.0 : 1.5, pixelScale: scale > 0 ? scale : 2)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Insomnia " + description(mode) + (attention ? ", needs attention" : "")
        return image
    }

    static func description(_ mode: Engine.Mode) -> String {
        switch mode {
        case .off: "off"
        case .awake: "awake"
        case .screenOn: "awake, screen on"
        case .lid: "awake, even with the lid closed"
        }
    }

    static func draw(_ ctx: CGContext, mode: Engine.Mode, attention: Bool, stroke: CGFloat,
                     colour: CGColor = CGColor(gray: 0, alpha: 1), pixelScale: CGFloat = 2) {
        let snap = pixelScale < 1.5
        let lineWidth = snap ? (stroke >= 2 ? 2.0 : 1.5) : stroke * 1.1
        let base = snap ? 1.0 : 1.65
        let crescent = Self.crescent(outset: max(0, lineWidth - base) / 2)
        let outline = crescent.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(colour)
        ctx.setStrokeColor(colour)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Body.
        if mode == .lid {
            var solid = crescent.union(outline)
            if snap {
                solid = solid.subtracting(PixelEye.ring).union(PixelEye.pupil)
            } else {
                let eye = openEye
                solid = solid.subtracting(eye.union(eye.copy(strokingWithWidth: 0.7, lineCap: .round,
                                                             lineJoin: .round, miterLimit: 10)))
                solid = solid.union(disc(eyeCentre, eyeRadius * 0.55))
            }
            ctx.addPath(solid)
            ctx.fillPath()
        } else {
            ctx.addPath(outline)
            ctx.fillPath()
            if mode == .off {
                if snap {
                    ctx.addPath(PixelEye.closed)
                    ctx.fillPath()
                } else {
                    ctx.setLineWidth(base)
                    ctx.addPath(closedEye)
                    ctx.strokePath()
                }
            } else if snap {
                ctx.addPath(PixelEye.open)
                ctx.fillPath(using: .evenOdd)
            } else {
                ctx.addPath(openEye)
                ctx.addPath(disc(CGPoint(x: eyeCentre.x + 0.68, y: eyeCentre.y - 0.68), eyeRadius * 0.34))
                ctx.fillPath(using: .evenOdd)
            }
        }

        // "!" in the lower right, under the mode badge (which stays, so the mode is still readable).
        if attention {
            if snap {
                let w: CGFloat = stroke >= 2 ? 2 : 1
                ctx.fill(CGRect(x: 18, y: 8, width: w, height: 4))
                ctx.fill(CGRect(x: 18, y: 13, width: w, height: 2))
            } else {
                let w = (lineWidth * 1.1 * 2).rounded() / 2
                let x = ((slot.x - w / 2) * 2).rounded() / 2 + w / 2
                ctx.setLineWidth(w)
                ctx.move(to: CGPoint(x: x, y: 8.4))
                ctx.addLine(to: CGPoint(x: x, y: 11.8))
                ctx.strokePath()
                let d = lineWidth * 1.2
                ctx.fillEllipse(in: CGRect(x: x - d / 2, y: 14.2 - d / 2, width: d, height: d))
            }
        }

        // The mode badge, in the upper-right slot.
        switch mode {
        case .off:
            if snap {
                for r in [CGRect(x: 16, y: 1, width: 5, height: 1), CGRect(x: 19, y: 2, width: 1, height: 1),
                          CGRect(x: 18, y: 3, width: 1, height: 1), CGRect(x: 17, y: 4, width: 1, height: 1),
                          CGRect(x: 16, y: 5, width: 5, height: 1)] { ctx.fill(r) }
            } else {
                let zw = (lineWidth * 0.8 * 2).rounded() / 2
                let z = CGRect(x: slot.x - 2.5, y: slot.y - 2.5, width: 5, height: 5).insetBy(dx: zw / 2, dy: zw / 2)
                ctx.setLineWidth(zw)
                ctx.move(to: CGPoint(x: z.minX, y: z.minY))
                ctx.addLine(to: CGPoint(x: z.maxX, y: z.minY))
                ctx.addLine(to: CGPoint(x: z.minX, y: z.maxY))
                ctx.addLine(to: CGPoint(x: z.maxX, y: z.maxY))
                ctx.strokePath()
            }
        case .awake:
            break
        case .screenOn:
            ctx.addPath(sparkle(slot, r: snap ? 2.5 : 3.0, inner: snap ? 0.8 : 0.75))
            ctx.fillPath()
        case .lid:
            ctx.addPath(laptop(snap: snap))
            ctx.fillPath()
        }
    }

    // MARK: Geometry (y-down, 22 × 16 pt)

    static let centre = CGPoint(x: 8, y: 8)
    static let radius: CGFloat = 6.5
    static let biteCentre = CGPoint(x: 8 + cos(-0.36) * 5.0, y: 8 + sin(-0.36) * 5.0)
    static let biteRadius: CGFloat = 4.4
    static let eyeCentre = CGPoint(x: 5.25, y: 9.0)
    static let eyeRadius: CGFloat = 1.9
    /// Badge slot centre, on the device grid at 1x and 2x.
    static let slot = CGPoint(x: 18.5, y: 3.5)

    static func crescent(outset e: CGFloat) -> CGPath {
        disc(centre, radius + e).subtracting(disc(biteCentre, biteRadius - e))
    }

    static func disc(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    static var openEye: CGPath { disc(eyeCentre, eyeRadius) }

    /// The closed "‿" lid.
    static var closedEye: CGPath {
        let p = CGMutablePath()
        let w = eyeRadius * 0.85
        p.move(to: CGPoint(x: eyeCentre.x - w, y: eyeCentre.y + 0.1))
        p.addQuadCurve(to: CGPoint(x: eyeCentre.x + w, y: eyeCentre.y + 0.1),
                       control: CGPoint(x: eyeCentre.x, y: eyeCentre.y + 1.9))
        return p
    }

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

    /// An open laptop from the front: a screen outline on a wider base.
    static func laptop(snap: Bool) -> CGPath {
        let p = CGMutablePath()
        if snap {
            for r in [CGRect(x: 16, y: 1, width: 5, height: 1), CGRect(x: 16, y: 2, width: 1, height: 3),
                      CGRect(x: 20, y: 2, width: 1, height: 3), CGRect(x: 15, y: 5, width: 7, height: 1)] { p.addRect(r) }
        } else {
            let screen = CGPath(roundedRect: CGRect(x: 16.1, y: 0.9, width: 4.8, height: 3.7), cornerWidth: 0.6,
                                cornerHeight: 0.6, transform: nil)
            p.addPath(screen.copy(strokingWithWidth: 1.1, lineCap: .round, lineJoin: .round, miterLimit: 10))
            p.addRoundedRect(in: CGRect(x: 14.9, y: 5.0, width: 7.2, height: 1.2), cornerWidth: 0.6, cornerHeight: 0.6)
        }
        return p
    }

    /// The 1x eye on whole pixels (columns 3…6).
    enum PixelEye {
        nonisolated(unsafe) static let open: CGPath = {
            let p = CGMutablePath()
            p.addPath(rounded(CGRect(x: 3, y: 7, width: 4, height: 4)))
            p.addRect(CGRect(x: 5, y: 8, width: 1, height: 1))   // catch-light, knocked out by even-odd
            return p
        }()
        nonisolated(unsafe) static let closed: CGPath = {
            let p = CGMutablePath()
            p.addRect(CGRect(x: 3, y: 8, width: 1, height: 1))
            p.addRect(CGRect(x: 6, y: 8, width: 1, height: 1))
            p.addRect(CGRect(x: 4, y: 9, width: 2, height: 1))
            return p
        }()
        nonisolated(unsafe) static let ring = rounded(CGRect(x: 3, y: 7, width: 4, height: 4))
        nonisolated(unsafe) static let pupil = CGPath(rect: CGRect(x: 4, y: 8, width: 2, height: 2), transform: nil)

        static func rounded(_ b: CGRect) -> CGPath {
            let p = CGMutablePath()
            p.addRect(CGRect(x: b.minX + 1, y: b.minY, width: b.width - 2, height: b.height))
            p.addRect(CGRect(x: b.minX, y: b.minY + 1, width: b.width, height: b.height - 2))
            return p.normalized()
        }
    }
}

// MARK: - App icon

enum AppIcon {
    /// Deep indigo squircle with a warm amber, wide-awake moon.
    static func draw(_ ctx: CGContext, size s: CGFloat) {
        let rect = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
        let shape = squircle(in: rect)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colours = [NSColor(srgb: 0x2E3170).cgColor, NSColor(srgb: 0x4A3A9E).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        }
        ctx.restoreGState()

        // The moon: the menu bar geometry (13 pt across) scaled to ~56% of the icon, centred.
        let k = s * 0.56 / 13
        var tf = CGAffineTransform(translationX: s / 2 - MoonGlyph.centre.x * k + s * 0.02, y: s / 2 - MoonGlyph.centre.y * k)
            .scaledBy(x: k, y: k)
        let moon = MoonGlyph.crescent(outset: 0)
        let eye = MoonGlyph.openEye
        guard let moonPath = moon.copy(using: &tf), let eyePath = eye.copy(using: &tf) else { return }
        ctx.setFillColor(NSColor(srgb: 0xFFB547).cgColor)
        ctx.addPath(moonPath.subtracting(eyePath))
        ctx.fillPath()
        ctx.setFillColor(NSColor(srgb: 0x17132B).cgColor)
        ctx.addPath(eyePath)
        ctx.fillPath()
        var gtf = tf
        if let glint = MoonGlyph.disc(CGPoint(x: MoonGlyph.eyeCentre.x + 0.62, y: MoonGlyph.eyeCentre.y - 0.62),
                                      MoonGlyph.eyeRadius * 0.32).copy(using: &gtf) {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(glint)
            ctx.fillPath()
        }
    }

    /// Superellipse (n = 5) approximating Apple's continuous-corner icon shape.
    static func squircle(in r: CGRect, n: CGFloat = 5) -> CGPath {
        let p = CGMutablePath()
        let a = r.width / 2, b = r.height / 2, c = CGPoint(x: r.midX, y: r.midY)
        for i in 0...256 {
            let t = CGFloat(i) / 256 * 2 * .pi
            let x = c.x + a * copysign(pow(abs(cos(t)), 2 / n), cos(t))
            let y = c.y + b * copysign(pow(abs(sin(t)), 2 / n), sin(t))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }

    /// Renders a y-down drawing into an sRGB bitmap.
    static func bitmap(width: Int, height: Int, pointSize: NSSize, draw: (CGContext) -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = pointSize
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / pointSize.width, y: -CGFloat(height) / pointSize.height)
        draw(ctx)
        gc.flushGraphics()
        NSGraphicsContext.current = previous
        return rep.retagging(with: .sRGB)
    }

    /// AppIcon.iconset PNGs (16…512 @1x and @2x) for scripts/build.sh.
    static func exportIconset(to directory: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return false }
        var ok = true
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                guard let rep = bitmap(width: px, height: px, pointSize: NSSize(width: base, height: base), draw: {
                    draw($0, size: CGFloat(base))
                }), let png = rep.representation(using: .png, properties: [:]) else { ok = false; continue }
                do { try png.write(to: directory.appendingPathComponent(name)) } catch { ok = false }
            }
        }
        return ok
    }
}

extension NSColor {
    /// 0xRRGGBB in sRGB.
    convenience init(srgb hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
