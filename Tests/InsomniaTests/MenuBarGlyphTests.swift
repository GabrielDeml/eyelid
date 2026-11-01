import AppKit
import CoreGraphics
import Testing
@testable import Insomnia

/// The menu bar glyph: the wide-awake moon (docs/UX.md §1.1, ARCHITECTURE.md decision 45). Rendered headless into
/// plain bitmaps and checked by pixel: every mood draws, the canvas never changes size, lid is the boldest state but
/// never a plain filled crescent (macOS Focus), and the blink closes onto the asleep eye.
@Suite("Menu bar glyph")
struct MenuBarGlyphTests {
    static let moods: [EyeMood] = [.asleep, .awake, .watching, .lid, .squint, .alarmed]

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

    @Test(arguments: [1, 2])
    func everyMoodDrawsInsideTheCanvas(scale: Int) {
        for mood in Self.moods {
            for stroke in [1.5, 2.0] as [CGFloat] {
                let g = Self.glyph(mood, scale: scale, stroke: stroke)
                #expect(g.ink > 40 * 255 * scale * scale, "\(mood) @\(scale)x stroke \(stroke) is nearly empty")
                // The moon is always in the same place: its left edge sits at x = 1.5 pt for every mood.
                #expect(g.at(pt: 1.6, 8) > 128, "\(mood) @\(scale)x: moon's left edge moved")
                if stroke == 1.5 { #expect(g.at(pt: 0.4, 8) == 0) }
            }
        }
    }

    @Test @MainActor func statusItemImageNeverChangesSize() {
        for mood in Self.moods {
            for hc in [false, true] {
                for blink in [0, 0.5, 1] as [CGFloat] {
                    let image = EyesRenderer.menuBarImage(mood: mood, blink: blink, highContrast: hc)
                    #expect(image.size == EyesRenderer.menuBarSize)
                    #expect(image.isTemplate)
                }
            }
        }
        #expect(EyesRenderer.menuBarSize == NSSize(width: 22, height: 16))
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
    func lidIsBoldestButNotAPlainFilledCrescent(scale: Int) {
        let lid = Self.glyph(.lid, scale: scale)
        for mood in Self.moods where mood != .lid {
            #expect(lid.ink > Self.glyph(mood, scale: scale).ink, "lid should out-ink \(mood) @\(scale)x")
        }
        // macOS Focus shows SF `moon.fill`: the same crescent, filled, alone. Lid must differ by shape.
        let lw: CGFloat = scale == 1 ? 1 : 1.65
        let plain = Self.render(scale: scale) { ctx in
            let moon = MenuBarMoon.crescent
            ctx.addPath(moon.union(moon.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 10)))
            ctx.fillPath()
        }
        // 1. A knocked-out eye: clear pixels inside the crescent, around a solid pupil.
        let e = MenuBarMoon.eyeCentre
        let pupil = scale == 1 ? lid.at(4, 8) : lid.at(pt: e.x, e.y)
        #expect(pupil > 200)
        let ringPoint = scale == 1 ? (3, 9) : (Int((e.x - 1.6) * 2), Int(e.y * 2))
        #expect(plain.at(ringPoint.0, ringPoint.1) > 200)
        #expect(lid.at(ringPoint.0, ringPoint.1) < 60)
        // 2. A badge beside the moon (the closed laptop) where the plain crescent has nothing.
        #expect(plain.ink(xFrom: 15.5, to: 22) == 0)
        #expect(lid.ink(xFrom: 15.5, to: 22) > 10 * 255 * scale * scale)
        // Every other mood with a badge keeps its badge in the same slot.
        for mood in [EyeMood.asleep, .watching, .squint, .alarmed] {
            #expect(Self.glyph(mood, scale: scale).ink(xFrom: 15.5, to: 22) > 0, "\(mood) badge")
        }
        #expect(Self.glyph(.awake, scale: scale).ink(xFrom: 15.5, to: 22) == 0)
    }

    @Test(arguments: [1, 2])
    func blinkClosesOntoTheAsleepEye(scale: Int) {
        // The moon part (x < 15 pt; the asleep "z" is in the badge slot) must match pixel for pixel.
        let closed = Self.glyph(.awake, blink: 1, scale: scale)
        let asleep = Self.glyph(.asleep, scale: scale)
        let limit = 15 * scale
        var diff = 0
        for y in 0..<closed.height { for x in 0..<limit where closed.at(x, y) != asleep.at(x, y) { diff += 1 } }
        #expect(diff == 0)
        // Mid-blink is between open and closed, not a jump.
        let open = Self.glyph(.awake, scale: scale).ink(xFrom: 0, to: 15)
        let half = Self.glyph(.awake, blink: 0.5, scale: scale).ink(xFrom: 0, to: 15)
        #expect(open != half && closed.ink(xFrom: 0, to: 15) != half)
        // Lid mode blinks too, and its closed eye is still knocked out of the solid moon.
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

    @Test func increaseContrastIsHeavier() {
        for scale in [1, 2] {
            #expect(Self.glyph(.awake, scale: scale, stroke: 2).ink > Self.glyph(.awake, scale: scale).ink)
        }
    }
}
