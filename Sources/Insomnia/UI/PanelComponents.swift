import AppKit
import SwiftUI

// MARK: - Building blocks for PanelView (docs/UX.md §2.2)

/// Which kind of panel control has keyboard focus: Return toggles only when the eyes, or nothing, have it (UX §2.5).
enum PanelFocus: Hashable { case eyes, control }

extension View {
    /// Tags a focusable control as `.control` (no-op without a binding, e.g. in previews).
    @ViewBuilder
    func panelFocus(_ binding: FocusState<PanelFocus?>.Binding?) -> some View {
        if let binding { focused(binding, equals: .control) } else { self }
    }
}

/// Plain text followed by inline actions ("While ffmpeg runs · Stop · 2 more ›"). Each action is a real link-style
/// button: in the Tab loop, with its own VoiceOver label. The text truncates in the middle so the actions stay.
struct InlineLinkLine: View {
    let text: String
    let links: [PlainCopy.InlineLink]
    let send: (PanelAction) -> Void
    var focus: FocusState<PanelFocus?>.Binding?

    var body: some View {
        HStack(spacing: 0) {
            if !text.isEmpty {
                Text(links.isEmpty ? text : text + " · ")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                if index > 0 { Text(" · ").accessibilityHidden(true) }
                Button(link.title) { send(link.action) }
                    .buttonStyle(.link)
                    .foregroundStyle(Color.accentColor)   // reads as a link even inside secondary / red text
                    .lineLimit(1)
                    .fixedSize()
                    .panelFocus(focus)
                    .accessibilityLabel(link.accessibilityLabel)
            }
        }
    }
}

/// Hairline separator with the 12 pt rhythm around it.
struct SectionDivider: View {
    var visible = true
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1 / max(1, displayScale))      // 1 px
            .opacity(visible ? 1 : 0)
            .padding(.vertical, Theme.separatorGap)
            .accessibilityHidden(true)
    }
}

/// Capsule chip: presets, Until…, While…. Selected = amber with `onAccent` text.
struct ChipButtonStyle: ButtonStyle {
    var selected = false
    var fillWidth = true
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, selected: selected, fillWidth: fillWidth,
                 highContrast: contrast == .increased, enabled: isEnabled)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let fillWidth: Bool
        let highContrast: Bool
        let enabled: Bool
        @State private var hovering = false
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let base: Color = scheme == .dark ? .white : .black
            let fill: Color = selected ? Theme.accentAwake
                : base.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.09 : (scheme == .dark ? 0.07 : 0.05)))
            configuration.label
                .font(Theme.chip)
                .foregroundStyle(selected ? Theme.onAccent : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, fillWidth ? 4 : 12)
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .frame(height: Theme.chipHeight)
                .background(Capsule(style: .continuous).fill(fill))
                .overlay {
                    if highContrast || (!selected && scheme == .light) {
                        // `.circular`: a continuous capsule's hairline border leaves vertical seams at both ends.
                        Capsule(style: .circular)
                            .strokeBorder(base.opacity(highContrast ? 0.45 : 0.06), lineWidth: highContrast ? 1 : 0.5)
                    }
                }
                .background {
                    // The amber glow only behind the selected chip (no clear shadows rasterising every chip).
                    if selected {
                        Capsule(style: .continuous).fill(Theme.accentAwake)
                            .shadow(color: Theme.accentAwake.opacity(0.35), radius: 4, y: 1)
                    }
                }
                .contentShape(Capsule(style: .continuous))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.18), value: selected)
        }
    }
}

/// The 72 pt eyes button: subtle hover lift (1.03) and press (0.97); no motion under Reduce Motion.
struct EyesButtonStyle: ButtonStyle {
    @Binding var hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let scale: CGFloat = reduceMotion ? 1 : (configuration.isPressed ? 0.97 : (hovering ? 1.03 : 1))
        configuration.label
            .scaleEffect(scale)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: scale)
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

/// "Keep screen on" / "Stay awake with lid closed": 28 pt row, SF Pro 13, trailing mini switch.
struct ToggleRow: View {
    let symbol: String
    let title: String
    let isOn: Bool
    var tint: Color = Theme.accentAwake
    var accessibilityValueOverride: String?
    var accessibilityHintText: String?
    var focus: FocusState<PanelFocus?>.Binding?
    let set: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { isOn }, set: { value in MainActor.assumeIsolated { set(value) } })) {
                Text(title).font(Theme.row).frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(tint)
            .panelFocus(focus)
            .accessibilityValue(accessibilityValueOverride ?? (isOn ? "On" : "Off"))
            .accessibilityHint(accessibilityHintText ?? "")
        }
        .frame(height: Theme.rowHeight)
    }
}

/// H′: fixed 14 pt slot under the lid switch (empty when silent).
struct LidSublabelView: View {
    let sublabel: PlainCopy.Sublabel?
    var send: (PanelAction) -> Void = { _ in }
    var focus: FocusState<PanelFocus?>.Binding?

    var body: some View {
        HStack(spacing: 5) {
            if let sublabel {
                if sublabel.spinner {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                }
                InlineLinkLine(text: sublabel.text, links: [sublabel.link].compactMap { $0 }, send: send, focus: focus)
                    .font(Theme.sublabel)
                    .foregroundStyle(colour(sublabel.tone))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
        .frame(height: Theme.sublabelHeight)
        .animation(.easeInOut(duration: 0.2), value: sublabel)
    }

    private func colour(_ tone: PlainCopy.Tone) -> Color {
        switch tone {
        case .secondary: return .secondary
        case .warning: return Theme.warningText
        case .danger: return Theme.dangerText
        }
    }
}

/// Row J: the quip, or a safety/report banner that replaces it. Fixed 34 pt.
struct QuipOrBannerRow: View {
    let quip: String?
    let banner: PanelBanner?
    var focus: FocusState<PanelFocus?>.Binding?
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let banner {
                BannerView(banner: banner, focus: focus, dismiss: dismiss)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
            } else if let quip {
                Text("\u{201C}\(quip)\u{201D}")
                    .font(Theme.quip)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(quip)
                    .transition(.opacity)
            }
        }
        .frame(height: Theme.quipHeight)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.2), value: quip)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: banner)
    }
}

struct BannerView: View {
    let banner: PanelBanner
    var focus: FocusState<PanelFocus?>.Binding?
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = tone
        HStack(spacing: 8) {
            Image(systemName: banner.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(banner.text)
                .font(.system(size: 12, weight: .medium, design: .default).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .panelFocus(focus)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(scheme == .dark ? 0.18 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private var tone: Color {
        switch banner.tone {
        case .info: return Theme.accentLid
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        case .success: return Color(nsColor: .systemGreen)
        }
    }
}

/// `⋯` (C): Sleep Now, Why awake?…, Settings… ⌘,, About Insomnia, Quit ⌘Q.
struct MoreMenuButton: View {
    let send: (PanelAction) -> Void
    var body: some View {
        Menu {
            Button("Sleep Now") { send(.sleepNow) }
            Button("Why Awake?…") { send(.whyAwake) }
            Divider()
            Button("Settings…") { send(.settings(.general)) }
                .keyboardShortcut(",", modifiers: .command)
            Button("About Insomnia") { send(.about) }
            Divider()
            Button("Quit Insomnia") { send(.quit) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .help("More")
        .accessibilityLabel("More")
    }
}

/// Until… (F): hour:minute picker, step 5 min; a past time means tomorrow.
struct UntilPicker: View {
    let start: (AwakeDuration) -> Void
    @State private var time: Date = UntilPicker.defaultTime()

    var body: some View {
        let target = target(for: time)
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep awake until")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .font(.system(size: 20, weight: .medium, design: .rounded).monospacedDigit())
            HStack {
                Text(label(for: target))
                    .font(Theme.subline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start") { start(target) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 210)
    }

    private func target(for t: Date) -> AwakeDuration { Self.target(for: t) }

    /// The picked time rounded to 5 minutes, next occurrence after `now`. 23:58 rounds to 00:00, not to an hour 24 that
    /// `Calendar.nextDate` can't match (which fell back to "24 h from now", R37).
    static func target(for t: Date, now: Date = Date(), calendar: Calendar = .current) -> AwakeDuration {
        let c = calendar.dateComponents([.hour, .minute], from: t)
        let total = ((c.hour ?? 0) * 60 + ((c.minute ?? 0) + 2) / 5 * 5) % 1440
        return AwakeDuration.nextOccurrence(hour: total / 60, minute: total % 60, after: now, calendar: calendar)
    }

    private func label(for d: AwakeDuration) -> String {
        guard case .until(let date) = d else { return "" }
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(date) ? "today \(time)" : "tomorrow \(time)"
    }

    private static func defaultTime() -> Date {
        // Next whole hour + 1: a sensible first guess.
        let now = Date()
        let c = Calendar.current.dateComponents([.hour], from: now)
        return Calendar.current.date(bySettingHour: ((c.hour ?? 0) + 2) % 24, minute: 0, second: 0, of: now) ?? now
    }
}

/// Hands an NSView to the model so AppKit menus can pop up from a SwiftUI control.
struct MenuAnchor: NSViewRepresentable {
    let register: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        register(v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
