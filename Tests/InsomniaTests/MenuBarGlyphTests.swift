import AppKit
import CoreGraphics
import Testing
@testable import Insomnia

/// The menu bar glyph: the wide-awake moon (docs/UX.md §1.1, ARCHITECTURE.md decision 45). Rendered headless into
/// plain bitmaps and checked by pixel: every mood draws, the status item image draws at the backing scale, the eye
/// never touches the outline (every mood, blink and weight), lid is the boldest state but never a plain filled
/// crescent (macOS Focus), and the blink closes onto the asleep eye.
@Suite("Menu bar glyph")
struct MenuBarGlyphTests {
    static let moods: [EyeMood] = [.asleep, .awake, .watching, .lid, .squint, .alarmed]
    static let strokes: [CGFloat] = [1.5, 2.0]          // normal, Increase Contrast
    static let blinks: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]

    /// Alpha plane of one glyph at `scale` px per pt (22 × 16 pt, y-down rows).
    struct Plane {
        let width: Int, height: Int, scale: Int
        let alpha: [UInt8]
        func at(_ x: Int, _ y: Int) -> UInt8 { alpha[y * width + x] }
        /// Alpha at the pixel covering point (x, y).
        func at(pt x: CGFloat, _ y: CGFloat) -> UInt8 { at(Int(x * CGFloat(scale)), Int(y * CGFloat(scale))) }
        var ink: Int { alpha.reduce(0) { $0 + Int($1) } }
        func ink(xFrom: CGFloat, to xTo: CGFloat) -> Int {
            var sum = 0
            for y in 0..<height {
                for x in Int(xFrom * CGFloat(scale))..<min(width, Int(xTo * CGFloat(scale))) { sum += Int(at(x, y)) }
            }
            return sum
        }
    }

    static func render(scale: Int, background: CGColor? = nil, _ draw: (CGContext) -> Void) -> Plane {
        let w = 22 * scale, h = 16 * scale
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let background { ctx.setFillColor(background); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        draw(ctx)
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // Bitmap memory is top row first, which matches the y-down drawing space.
        let alpha = (0..<(w * h)).map { p[$0 * 4 + 3] }
        return Plane(width: w, height: h, scale: scale, alpha: alpha)
    }

    static func glyph(_ mood: EyeMood, blink: CGFloat = 0, scale: Int, stroke: CGFloat = 1.5) -> Plane {
        render(scale: scale) { ctx in
            EyesRenderer.drawMenuBarGlyph(ctx, mood: mood, blink: blink, stroke: stroke, pixelScale: CGFloat(scale))
        }
    }

    /// The outline alone (no eye, no badge), exactly as the glyph draws it.
    static func outline(scale: Int, stroke: CGFloat) -> Plane {
        render(scale: scale) { ctx in
            ctx.addPath(MenuBarMoon.outline(stroke: stroke, snap: scale == 1).stroke)
            ctx.fillPath()
        }
    }

    /// Smallest distance (px, between pixel centres) from an eye pixel to an outline pixel, counting only pixels with
    /// alpha > `ink`. Eye pixels are the glyph's ink left of the badge slot that the outline doesn't touch at all.
    static func eyeGap(_ mood: EyeMood, blink: CGFloat, scale: Int, stroke: CGFloat, ink: UInt8) -> Double {
        let g = glyph(mood, blink: blink, scale: scale, stroke: stroke)
        let o = outline(scale: scale, stroke: stroke)
        var eye: [(Int, Int)] = [], line: [(Int, Int)] = []
        for y in 0..<g.height {
            for x in 0..<(15 * scale) {
                if o.at(x, y) > ink { line.append((x, y)) } else if o.at(x, y) == 0 && g.at(x, y) > ink { eye.append((x, y)) }
            }
        }
        var best = Double.infinity
        for e in eye { for l in line { best = min(best, hypot(Double(e.0 - l.0), Double(e.1 - l.1))) } }
        return best
    }

    @Test(arguments: [1, 2])
    func everyMoodDrawsInsideTheCanvas(scale: Int) {
        for mood in Self.moods {
            for stroke in Self.strokes {
                let g = Self.glyph(mood, scale: scale, stroke: stroke)
                #expect(g.ink > 40 * 255 * scale * scale, "\(mood) @\(scale)x stroke \(stroke) is nearly empty")
                // The moon is always in the same place: its left edge covers x = 1.6 pt for every mood and weight.
                #expect(g.at(pt: 1.6, 8) > 128, "\(mood) @\(scale)x: moon's left edge moved")
                // At 2x the normal outline leaves the left column clear (extra weight grows outward from there).
                if stroke == 1.5 && scale == 2 { #expect(g.at(pt: 0.4, 8) == 0) }
            }
        }
    }

    /// The status item image picks the 1x pixel-snapped glyph or the 2x one from the context it is drawn into, and
    /// draws exactly what `drawMenuBarGlyph` draws at that scale.
    @Test @MainActor func statusItemImageDrawsAtTheBackingScale() {
        for scale in [1, 2] {
            for mood in Self.moods {
                let image = EyesRenderer.menuBarImage(mood: mood)
                #expect(image.isTemplate)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 22 * scale, pixelsHigh: 16 * scale,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 22 * scale * 4, bitsPerPixel: 32)!
                rep.size = EyesRenderer.menuBarSize
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(origin: .zero, size: EyesRenderer.menuBarSize))
                NSGraphicsContext.restoreGraphicsState()
                let drawn = (0..<(22 * scale * 16 * scale)).map { rep.bitmapData![$0 * 4 + 3] }
                let expected = Self.glyph(mood, scale: scale)
                let off = zip(drawn, expected.alpha).filter { abs(Int($0) - Int($1)) > 8 }.count
                #expect(off == 0, "\(mood) @\(scale)x: \(off) px differ from the \(scale)x glyph")
            }
        }
    }

    @Test(arguments: [1, 2])
    func awakeEyeIsAnOpenEyeNotASpeck(scale: Int) {
        let g = Self.glyph(.awake, scale: scale)
        // The longest opaque run through the eye's middle row, inside the belly (x 2.5…8 pt): the old eye was a
        // 2.2 pt dot (4 px at 2x); the eye is now 3.8 pt across (7 solid px at 2x, a 4 px block at 1x).
        let row = 9 * scale
        var best = 0, run = 0
        for x in Int(2.5 * CGFloat(scale))..<(8 * scale) {
            if g.at(x, row) > 160 { run += 1; best = max(best, run) } else { run = 0 }
        }
        #expect(best >= (scale == 1 ? 4 : 7), "eye run \(best) px @\(scale)x")
        // A clear pixel between the outline and the eye on the left, so they never merge.
        #expect((scale == 1 ? g.at(2, 9) : g.at(5, 18)) < 128)
    }

    @Test(arguments: [1, 2])
    func openEyesHaveAClearCatchLight(scale: Int) {
        // The catch-light is a real hole (even-odd), not just a lighter pixel; the eye around it is solid.
        for mood in [EyeMood.awake, .watching, .alarmed] {
            let g = Self.glyph(mood, scale: scale)
            if scale == 1 {
                let y = mood == .awake ? 8 : 7         // watching glances 1 px up; alarmed is 1 px taller
                #expect(g.at(5, y) == 0, "\(mood) @1x catch-light")
                #expect(g.at(4, y) == 255 && g.at(4, y + 1) == 255, "\(mood) @1x eye")
            } else {
                let shape = MenuBarMoon.EyeShape(mood, t: 0)
                #expect(g.at(pt: shape.glintCentre.x, shape.glintCentre.y) < 16, "\(mood) @2x catch-light")
                #expect(g.at(pt: shape.centre.x - 0.6, shape.centre.y + 0.6) > 240, "\(mood) @2x eye")
            }
        }
    }

    /// The eye never merges into the moon: for every mood, blink frame and weight (normal and Increase Contrast),
    /// eye and outline pixels are kept apart. At 2x (≥ 0.8 pt = 1.6 px of clearance) a clear pixel separates anything
    /// over a third opaque; at 1x they never share an edge, and solid pixels never touch even at a corner.
    @Test(arguments: [1, 2])
    func eyeNeverTouchesTheOutline(scale: Int) {
        for mood in Self.moods where mood != .lid {
            for stroke in Self.strokes {
                for blink in Self.blinks {
                    let what = "\(mood) @\(scale)x stroke \(stroke) blink \(blink)"
                    if scale == 2 {
                        #expect(Self.eyeGap(mood, blink: blink, scale: 2, stroke: stroke, ink: 80) >= 2, "\(what)")
                    } else {
                        #expect(Self.eyeGap(mood, blink: blink, scale: 1, stroke: stroke, ink: 80) > 1.1, "\(what)")
                        #expect(Self.eyeGap(mood, blink: blink, scale: 1, stroke: stroke, ink: 160) >= 2, "\(what)")
                    }
                }
            }
        }
    }

    @Test(arguments: [1, 2])
    func lidIsBoldestButNotAPlainFilledCrescent(scale: Int) {
        let lid = Self.glyph(.lid, scale: scale)
        for mood in Self.moods where mood != .lid {
            #expect(lid.ink > Self.glyph(mood, scale: scale).ink, "lid should out-ink \(mood) @\(scale)x")
        }
        // macOS Focus shows SF `moon.fill`: the same crescent, filled, alone. Lid must differ by shape.
        let plain = Self.render(scale: scale) { ctx in
            ctx.addPath(MenuBarMoon.outline(stroke: 1.5, snap: scale == 1).solid)
            ctx.fillPath()
        }
        // 1. A knocked-out eye: clear pixels inside the crescent, around a solid pupil.
        let e = MenuBarMoon.eyeCentre
        let pupil = scale == 1 ? lid.at(4, 8) : lid.at(pt: e.x, e.y)
        #expect(pupil > 200)
        let ringPoint = scale == 1 ? (3, 9) : (Int((e.x - 1.6) * 2), Int(e.y * 2))
        #expect(plain.at(ringPoint.0, ringPoint.1) > 200)
        #expect(lid.at(ringPoint.0, ringPoint.1) < 60)
        if scale == 1 {
            // The 1x ring is the round eye's block (corners left solid), not a square "stop button".
            for corner in [(3, 7), (6, 7), (3, 10), (6, 10)] { #expect(lid.at(corner.0, corner.1) == 255) }
        }
        // 2. A badge beside the moon (the closed laptop) where the plain crescent has nothing.
        #expect(plain.ink(xFrom: 16, to: 22) == 0)
        #expect(lid.ink(xFrom: 16, to: 22) > 10 * 255 * scale * scale)
        // Every other mood with a badge keeps its badge in the same slot.
        for mood in [EyeMood.asleep, .watching, .squint, .alarmed] {
            #expect(Self.glyph(mood, scale: scale).ink(xFrom: 16, to: 22) > 0, "\(mood) badge")
        }
        #expect(Self.glyph(.awake, scale: scale).ink(xFrom: 16, to: 22) == 0)
    }

    @Test(arguments: [1, 2])
    func laptopBadgeIsALidOnALongerThickerBase(scale: Int) {
        // Ink per row of the badge (x ≥ 15.5 pt): two bars, the lower one (the base) wider and taller than the lid.
        let lid = Self.glyph(.lid, scale: scale)
        var bars: [(rows: Int, width: Int)] = []
        var inBar = false
        for y in 0..<lid.height {
            let width = (Int(15.5 * Double(scale))..<lid.width).filter { lid.at($0, y) > 128 }.count
            if width > 0 {
                if inBar { bars[bars.count - 1].rows += 1; bars[bars.count - 1].width = max(bars[bars.count - 1].width, width) }
                else { bars.append((1, width)) }
            }
            inBar = width > 0
        }
        #expect(bars.count == 2, "laptop @\(scale)x: \(bars)")
        if bars.count == 2 {
            #expect(bars[1].width > bars[0].width && bars[1].rows > bars[0].rows, "laptop @\(scale)x: \(bars)")
        }
    }

    @Test(arguments: [1, 2])
    func blinkClosesOntoTheAsleepEye(scale: Int) {
        // The moon part (x < 15 pt; the asleep "z" is in the badge slot) must match pixel for pixel, for every
        // open-eyed mood: the glance and the alarmed oval ease back into the round eye as it closes.
        let asleep = Self.glyph(.asleep, scale: scale)
        let limit = 15 * scale
        for mood in [EyeMood.awake, .watching, .alarmed] {
            let closed = Self.glyph(mood, blink: 1, scale: scale)
            var diff = 0
            for y in 0..<closed.height { for x in 0..<limit where closed.at(x, y) != asleep.at(x, y) { diff += 1 } }
            #expect(diff == 0, "\(mood) @\(scale)x: \(diff) px")
        }
        // Mid-blink is between open and closed, not a jump.
        let closed = Self.glyph(.awake, blink: 1, scale: scale)
        let open = Self.glyph(.awake, scale: scale).ink(xFrom: 0, to: 15)
        let half = Self.glyph(.awake, blink: 0.5, scale: scale).ink(xFrom: 0, to: 15)
        #expect(open != half && closed.ink(xFrom: 0, to: 15) != half)
        // Lid mode blinks too: its closed eye is knocked out of the solid moon wherever the asleep eye has ink.
        let lidClosed = Self.glyph(.lid, blink: 1, scale: scale)
        let line = Self.outline(scale: scale, stroke: 1.5)
        var eyePixels = 0
        for y in 0..<asleep.height {
            for x in 0..<limit where asleep.at(x, y) > 200 && line.at(x, y) == 0 {
                eyePixels += 1
                #expect(lidClosed.at(x, y) < 60, "lid blink 1 @\(scale)x: (\(x), \(y)) not knocked out")
            }
        }
        #expect(eyePixels > 3 * scale * scale)
        #expect(Self.glyph(.lid, blink: 1, scale: scale).ink != Self.glyph(.lid, scale: scale).ink)
    }

    @Test(arguments: [1, 2])
    func knockOutsNeverPunchThroughWhatIsUnderneath(scale: Int) {
        // Template drawing is alpha-only in the given colour: drawing over an opaque background leaves it opaque.
        for mood in Self.moods {
            let g = Self.render(scale: scale, background: CGColor(gray: 0.5, alpha: 1)) { ctx in
                EyesRenderer.drawMenuBarGlyph(ctx, mood: mood, blink: 0, stroke: 1.5, colour: CGColor(gray: 1, alpha: 1),
                                              pixelScale: CGFloat(scale))
            }
            #expect(g.alpha.allSatisfy { $0 == 255 }, "\(mood) @\(scale)x cleared pixels")
        }
    }

    /// Increase Contrast thickens the outline outward only: the heavier outline covers the normal one, its inner edge
    /// doesn't move, and the eye inside is untouched.
    @Test(arguments: [1, 2])
    func increaseContrastGrowsTheOutlineOutward(scale: Int) {
        let normal = Self.outline(scale: scale, stroke: 1.5), heavy = Self.outline(scale: scale, stroke: 2)
        #expect(heavy.ink > normal.ink + 20 * 255 * scale)
        #expect(zip(heavy.alpha, normal.alpha).allSatisfy { Int($0) >= Int($1) - 8 })   // AA at the horn tips
        // Inside the outline (where the heavy one has no ink at all) only anti-aliasing dust may differ.
        for mood in Self.moods where mood != .lid {
            let a = Self.glyph(mood, scale: scale), b = Self.glyph(mood, scale: scale, stroke: 2)
            var diff = 0
            for y in 0..<a.height {
                for x in 0..<(15 * scale) where heavy.at(x, y) == 0 && abs(Int(a.at(x, y)) - Int(b.at(x, y))) > 4 { diff += 1 }
            }
            #expect(diff == 0, "\(mood) @\(scale)x: the eye changed under Increase Contrast (\(diff) px)")
        }
    }
}
