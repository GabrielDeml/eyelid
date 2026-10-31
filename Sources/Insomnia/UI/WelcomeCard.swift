import SwiftUI

/// First-run card (docs/UX.md §7.1), shown in the panel above row E once, after the first-wake animation.
///
/// ```
/// Hi. I'm Insomnia. I keep your Mac awake.
/// • Click my eyes (or right-click me in the menu bar) to toggle. ⌥-click: why awake.
/// Where should I live?       [ Menu bar | Menu bar + Dock ]
/// Awake with the lid closed? [Set up later]  [Set up now]     (MacBooks only)
///                                                      [Got it]
/// ```
/// Labels are plain in every tier (PRODUCT.md §4 rule 8). "Got it" finishes onboarding and asks for notification
/// permission. The panel grows for this card only (UX §2.1).
struct WelcomeCard: View {
    /// `PowerMonitor.hasLid`: the lid row is MacBooks only.
    var hasLid: Bool
    /// The menu bar click model, so the hint describes what the clicks really do.
    var leftClickAction: ClickAction
    @Binding var showInDock: Bool
    var setUpLid: () -> Void
    var done: () -> Void

    @State private var lidDeferred = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hi. I'm Insomnia. I keep your Mac awake.")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Label {
                Text(clickHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            row("Where should I live?") {
                Picker("Where should I live?", selection: $showInDock) {
                    Text("Menu bar").tag(false)
                    Text("Menu bar + Dock").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            if hasLid && !lidDeferred {
                row("Awake with the lid closed?") {
                    HStack(spacing: 6) {
                        Button("Set up later") { withAnimation(.easeInOut(duration: 0.2)) { lidDeferred = true } }
                        Button("Set up now", action: setUpLid)
                    }
                    .controlSize(.small)
                }
                .transition(.opacity)
            }

            HStack {
                Spacer()
                Button("Got it", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.accentAwake.opacity(scheme == .dark ? 0.12 : 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.accentAwake.opacity(0.28), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome")
    }

    private var clickHint: String {
        let menuBar = leftClickAction == .toggle
            ? "click me in the menu bar; right-click opens this panel"
            : "right-click me in the menu bar"
        return "Click my eyes (or \(menuBar)) to toggle. ⌥-click: why awake."
    }

    private func row<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                trailing()
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12))
                trailing()
            }
        }
    }
}

/// The live welcome card: reads Settings and PowerMonitor, finishes through `EpicMoments`.
struct LiveWelcomeCard: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        WelcomeCard(hasLid: PowerMonitor.shared.hasLid, leftClickAction: settings.leftClickAction,
                    showInDock: $settings.showInDock,
                    setUpLid: { AppRouter.shared.startLidSetup() },
                    done: { EpicMoments.shared.completeOnboarding() })
    }
}
