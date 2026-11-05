import AppKit
import SwiftUI

/// Colour, type and metrics, defined once. Colour is never the only signal: every state also changes text and shape.
enum Theme {
    /// Amber: the power button, selected chips, the moon while awake.
    static let accent = Color(nsColor: dynamic(light: 0xE8940C, dark: 0xFFB547))
    /// Text and symbols drawn on amber (white on amber fails 4.5:1).
    static let onAccent = Color(nsColor: NSColor(srgb: 0x1A1206))
    /// Lid mode.
    static let lid = Color(nsColor: .systemIndigo)
    /// 11–12 pt warning / error text, ≥ 4.5:1 in light and dark.
    static let warningText = Color(nsColor: dynamic(light: 0xA84A00, dark: 0xFF9F0A))
    static let dangerText = Color(nsColor: dynamic(light: 0xC0201A, dark: 0xFF453A))
    static let warning = Color(nsColor: .systemOrange)

    static let title = Font.system(size: 17, weight: .semibold)
    static let subtitle = Font.system(size: 12, design: .rounded).monospacedDigit()
    static let chip = Font.system(size: 12, weight: .medium, design: .rounded).monospacedDigit()
    static let row = Font.system(size: 13)
    static let caption = Font.system(size: 11)

    static let panelWidth: CGFloat = 324
    static let padding: CGFloat = 14
    static let chipHeight: CGFloat = 28
    static let rowHeight: CGFloat = 30

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        let l = NSColor(srgb: light), d = NSColor(srgb: dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        }
    }
}

/// A rounded, pill-ish button: filled amber when selected.
struct ChipStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.chip)
            .foregroundStyle(selected ? Theme.onAccent : Color.primary)
            .frame(maxWidth: .infinity, minHeight: Theme.chipHeight)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.accent : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
