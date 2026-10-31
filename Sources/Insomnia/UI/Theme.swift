import AppKit
import SwiftUI

/// Colour tokens, type and metrics (docs/UX.md §2.2, §2.3). Defined once; every surface reads from here.
/// Colour is never the only signal: every coloured state also changes text and shape.
@MainActor
enum Theme {
    // MARK: Colour tokens (NSColor, dynamic for light/dark)

    /// Ring, selected chip fill, irises. Amber.
    static let accentAwakeNS = dynamic(light: 0xE8940C, dark: 0xFFB547, name: "accentAwake")
    /// Text drawn on amber (white on amber fails 4.5:1).
    static let onAccentNS = NSColor(srgb: 0x1A1206)
    /// Lid toggle tint, night-vision glow.
    static let accentLidNS = NSColor.systemIndigo
    /// Closed eyes, the "z".
    static let sleepToneNS = NSColor.secondaryLabelColor
    /// Icons and banner tints. Small text uses `warningText` / `dangerText` (systemOrange is ~1.9:1 on a light panel).
    static let warningNS = NSColor.systemOrange
    static let dangerNS = NSColor.systemRed
    /// 11–12 pt warning / error text: ≥ 4.5:1 on the panel in light and dark.
    static let warningTextNS = dynamic(light: 0xA84A00, dark: 0xFF9F0A, name: "warningText")
    static let dangerTextNS = dynamic(light: 0xC0201A, dark: 0xFF453A, name: "dangerText")
    /// Panel eye whites (the menu bar glyph is a template and never uses colour).
    static let scleraNS = dynamic(light: 0xFFFFFF, dark: 0xF4F1EA, name: "sclera")

    // Mascot palette (panel eyes, Dock tile, app icon). Not UX tokens; shared art constants.
    /// The "night sky" face behind open eyes: deep indigo, slightly violet at the bottom.
    static let faceTopNS = dynamic(light: 0x2E3170, dark: 0x262A63, name: "faceTop")
    static let faceBottomNS = dynamic(light: 0x4A3A9E, dark: 0x3D3189, name: "faceBottom")
    /// The face while asleep: a quiet, neutral disc that lets the closed eyes read as secondary.
    static let faceAsleepNS = dynamic(light: 0xE9E8EF, dark: 0x2C2B33, name: "faceAsleep")
    static let pupilNS = NSColor(srgb: 0x17132B)
    static let irisDeepNS = NSColor(srgb: 0xC9700A)

    // MARK: SwiftUI mirrors

    static let accentAwake = Color(nsColor: accentAwakeNS)
    static let onAccent = Color(nsColor: onAccentNS)
    static let accentLid = Color(nsColor: accentLidNS)
    static let sleepTone = Color(nsColor: sleepToneNS)
    static let warning = Color(nsColor: warningNS)
    static let danger = Color(nsColor: dangerNS)
    static let warningText = Color(nsColor: warningTextNS)
    static let dangerText = Color(nsColor: dangerTextNS)
    static let sclera = Color(nsColor: scleraNS)

    // MARK: Type (SF Pro for words, SF Pro Rounded for numerals)

    static let headline = Font.system(size: 17, weight: .semibold)
    static let subline = Font.system(size: 12, weight: .regular, design: .rounded).monospacedDigit()
    static let chip = Font.system(size: 12, weight: .medium, design: .rounded).monospacedDigit()
    static let row = Font.system(size: 13)
    static let sublabel = Font.system(size: 11)
    static let quip = Font.system(size: 12)
    /// Menu bar timer text: SF Pro 11, monospaced digits (UX §1.3).
    static let menuBarTimerFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    // MARK: Metrics (UX §2.1, §2.2)

    static let panelWidth: CGFloat = 320
    static let padding: CGFloat = 14
    static let separatorGap: CGFloat = 12
    static let chipHeight: CGFloat = 28
    static let chipGap: CGFloat = 8
    static let rowHeight: CGFloat = 28
    static let sublabelHeight: CGFloat = 14
    static let quipHeight: CGFloat = 34
    static let eyesButton: CGFloat = 72
    static let cornerRadius: CGFloat = 12

    // MARK: Accessibility environment (read live; AppKit posts changes via NSWorkspace)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    // MARK: Helpers

    private static func dynamic(light: UInt32, dark: UInt32, name: String) -> NSColor {
        let l = NSColor(srgb: light), d = NSColor(srgb: dark)
        return NSColor(name: NSColor.Name("Insomnia." + name)) { appearance in
            appearance.isDark ? d : l
        }
    }
}

extension NSColor {
    /// 0xRRGGBB in sRGB.
    convenience init(srgb hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// Resolves a dynamic/catalog colour to a concrete CGColor under `appearance`.
    func resolvedCGColor(for appearance: NSAppearance) -> CGColor {
        var result = CGColor(gray: 0, alpha: 1)
        appearance.performAsCurrentDrawingAppearance {
            result = (self.usingColorSpace(.sRGB) ?? self).cgColor
        }
        return result
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]).map {
        [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0)
    } ?? false }
}
