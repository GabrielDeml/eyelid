import AppKit
import SwiftUI

/// Colour, type and metrics, defined once. Colour is never the only signal: every state also changes text and shape.
enum Theme {
    /// Amber: the master switch and the screen switch.
    static let accent = Color(nsColor: dynamic(light: 0xE8940C, dark: 0xFFB547))
    /// Lid mode: the lid switch.
    static let lid = Color(nsColor: .systemIndigo)
    /// Lid mode as 11 pt text (system indigo fails 4.5:1 on dark glass).
    static let lidText = Color(nsColor: dynamic(light: 0x3F3CBB, dark: 0xA5A3FF))
    /// 11–12 pt warning / error text, ≥ 4.5:1 in light and dark.
    static let warningText = Color(nsColor: dynamic(light: 0xA84A00, dark: 0xFF9F0A))
    static let dangerText = Color(nsColor: dynamic(light: 0xC0201A, dark: 0xFF453A))
    static let warning = Color(nsColor: .systemOrange)
    /// Quiet-button backgrounds. Primary opacities, so they read on glass and on the opaque fallback alike.
    static let hover = Color.primary.opacity(0.07)
    static let pressed = Color.primary.opacity(0.11)

    static let title = Font.system(size: 20, weight: .semibold)
    static let subtitle = Font.system(size: 12, design: .rounded).monospacedDigit()
    static let mode = Font.system(size: 11, weight: .medium)
    static let row = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let notice = Font.system(size: 12)
    static let footer = Font.system(size: 12)

    static let panelWidth: CGFloat = 300
    /// Every text, control and inset hairline starts and ends on this edge.
    static let inset: CGFloat = 16
    static let top: CGFloat = 14
    static let gap: CGFloat = 12
    static let rowHeight: CGFloat = 32
    static let footerHeight: CGFloat = 36
    /// Quiet buttons pad their text by this much, so callers pull them out by it to keep the text on the edge.
    static let quietPadding: CGFloat = 6

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        let l = NSColor(srgb: light), d = NSColor(srgb: dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        }
    }
}

/// Text that looks like a label until you point at it: secondary, turning primary on a faint capsule on hover.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    /// A ButtonStyle can't hold state, so the hover lives here.
    private struct QuietButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(hovering || configuration.isPressed ? .primary : .secondary)
                .padding(.horizontal, Theme.quietPadding)
                .padding(.vertical, 3)
                .background(Capsule().fill(configuration.isPressed ? Theme.pressed
                                           : hovering ? Theme.hover : Color.clear))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 && isEnabled }
        }
    }
}
