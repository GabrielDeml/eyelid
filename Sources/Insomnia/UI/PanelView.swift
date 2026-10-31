import AppKit
import SwiftUI

/// The panel (docs/UX.md §2): 320 wide, ≤ 340 tall, fixed regions, nothing scrolls.
///
/// ```
///  A eyes  B headline          C ⋯
///          D subline
///  ───────────────────────────────
///  E 30m 1h 2h 4h 8h ∞
///  F Until… While…
///  ───────────────────────────────
///  G Keep screen on            [ ]
///  H Stay awake with lid closed[ ]   (MacBooks only)
///  H′ sublabel (fixed 14 pt slot)
///  ───────────────────────────────
///  J quip or banner (fixed 34 pt; collapsed in Professional unless a banner shows)
/// ```
///
/// Renders only from `model.state`; talks back only through `model.send(_:)`. The host window supplies the material
/// (Liquid Glass on macOS 26+, a popover material before); `opaqueBackground` is for snapshots and Reduce Transparency.
struct PanelView: View {
    @Bindable var model: PanelModel
    var opaqueBackground = false

    @FocusState private var focus: PanelFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Clock-free: the 1 Hz display tick invalidates only `PanelHeader` (eyes ring, countdown), not the whole panel.
        let s = model.layoutState
        // Professional has no quips: row J collapses unless a safety banner or report needs it (UX §2.1).
        let showRowJ = s.personality != .professional || s.banner != nil || s.reopenReport != nil
        VStack(spacing: 0) {
            PanelHeader(model: model, focus: $focus)
            SectionDivider()
            if EpicMoments.shared.welcomeVisible {
                LiveWelcomeCard()
                    .padding(.bottom, Theme.separatorGap)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            presets(s)
            untilWhile(s)
                .padding(.top, Theme.chipGap)
            SectionDivider()
            toggles(s)
            if showRowJ {
                SectionDivider(visible: s.quip != nil || s.banner != nil || s.reopenReport != nil)
                if let report = s.reopenReport {
                    MissionReportCard(report: report, line: s.personality == .professional ? nil : s.quip,
                                      focus: $focus) {
                        model.send(.dismissBanner)
                    }
                } else {
                    QuipOrBannerRow(quip: s.personality == .professional ? nil : s.quip, banner: s.banner,
                                    focus: $focus) {
                        model.send(.dismissBanner)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.padding)
        .padding(.top, Theme.padding)
        .padding(.bottom, Theme.padding - 2)
        .frame(width: Theme.panelWidth)
        .background {
            if opaqueBackground {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            }
        }
        .onChange(of: focus) { _, new in model.focus = new }
        .onChange(of: EpicMoments.shared.nightVisionCount) { _, _ in
            if model.isVisible { model.cues.nightVision += 1 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Insomnia")
    }

    // MARK: E

    private func presets(_ s: PanelState) -> some View {
        HStack(spacing: Theme.chipGap) {
            ForEach(Array(AwakeDuration.presets.enumerated()), id: \.offset) { index, d in
                let selected = s.isAwake && s.selectedPreset == d
                let name = PlainCopy.durationName(d, s.personality)
                Button(d.shortLabel) { model.send(.start(d)) }
                    .buttonStyle(ChipButtonStyle(selected: selected))
                    .focused($focus, equals: .control)
                    .help(name ?? "Keep awake: \(PlainCopy.spokenDuration(d).lowercased()) · \(index + 1)")
                    .accessibilityLabel(PlainCopy.spokenDuration(d))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint(name ?? "")
            }
        }
    }

    // MARK: F

    private func untilWhile(_ s: PanelState) -> some View {
        HStack(spacing: Theme.chipGap) {
            Button { model.showUntil.toggle() } label: { chipLabel("Until…", symbol: "clock") }
                .buttonStyle(ChipButtonStyle(fillWidth: false))
                .focused($focus, equals: .control)
                .popover(isPresented: $model.showUntil, arrowEdge: .bottom) {
                    UntilPicker { d in
                        model.showUntil = false
                        model.send(.start(d))
                    }
                }
                .help("Keep awake until a time · U")
                .accessibilityLabel("Until a time")
            Button { model.presentWhileMenu() } label: { chipLabel("While…", symbol: "hourglass") }
                .buttonStyle(ChipButtonStyle(fillWidth: false))
                .focused($focus, equals: .control)
                .background(MenuAnchor { model.whileAnchor = $0 })
                .help("Keep awake while an app or process runs · W")
                .accessibilityLabel("While an app runs")
            Spacer(minLength: 0)
        }
    }

    private func chipLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(title)
        }
    }

    // MARK: G H H′

    private func toggles(_ s: PanelState) -> some View {
        VStack(spacing: 0) {
            ToggleRow(symbol: "display", title: "Keep screen on", isOn: s.keepScreenOn, focus: $focus) {
                model.send(.setScreen($0))
            }
            if s.hasLid {
                let needsSetup = s.helper != .installed
                ToggleRow(symbol: "laptopcomputer", title: "Stay awake with lid closed", isOn: s.lidToggleOn,
                          tint: Theme.accentLid,
                          accessibilityValueOverride: needsSetup ? "Off" : nil,
                          accessibilityHintText: needsSetup ? "Requires one-time setup. Opens setup." : nil,
                          focus: $focus) {
                    model.send(.setLid($0))
                }
                LidSublabelView(sublabel: PlainCopy.lidSublabel(s), send: model.send, focus: $focus)
            }
        }
    }
}

/// Rows A–D. The only part of the panel that reads the display clock (`model.state`: countdown, ring, heavy lids,
/// eye bags), so the 1 Hz tick re-renders this header and nothing else.
private struct PanelHeader: View {
    @Bindable var model: PanelModel
    var focus: FocusState<PanelFocus?>.Binding

    @State private var eyesHover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View { header(model.state) }

    // MARK: A B C D

    private func header(_ s: PanelState) -> some View {
        let sub = PlainCopy.subline(s)
        return HStack(alignment: .center, spacing: 12) {
            Button { model.send(.eyes) } label: {
                EyesView(mood: EpicMoments.shared.eyesMood(for: s.mood), progress: s.isTimed ? s.progress : nil, isLive: model.isVisible,
                         heavyLids: s.heavyLids, bags: s.bags, cues: model.cues)
            }
            .buttonStyle(EyesButtonStyle(hovering: $eyesHover))
            .focused(focus, equals: .eyes)
            .disabled(s.clientOnly)
            .help(s.clientOnly ? "Held by a command" : (s.isAwake ? "Allow sleep" : "Keep awake"))
            .accessibilityLabel("Keep awake")
            .accessibilityValue(PlainCopy.eyesValue(s))
            .accessibilityAddTraits(.isToggle)
            .accessibilityHint(s.clientOnly ? "Held by a command" : "")
            .accessibilityAction(named: "Extend 15 minutes") { model.send(.extend) }
            .accessibilityAction(named: "Allow sleep") { if s.isAwake && !s.clientOnly { model.send(.eyes) } }

            VStack(alignment: .leading, spacing: 3) {
                // B and C share a row (UX §2.1 "Wide awake ⋯").
                HStack(alignment: .center, spacing: 4) {
                    Text(PlainCopy.headline(s))
                        .font(Theme.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.opacity)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    MoreMenuButton(send: model.send)
                        .focused(focus, equals: .control)
                        .offset(x: 4)
                }
                subline(sub)
                    .font(Theme.subline)
                    .foregroundStyle(subTone(sub.tone))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.2), value: PlainCopy.headline(s))
        }
        .frame(height: Theme.eyesButton)
    }

    /// D: one line when it fits. Otherwise "· 2 more ›" gets its own line (never a dangling "·"), and a long watched
    /// name truncates in the middle so the trailing "Stop" link stays visible.
    @ViewBuilder
    private func subline(_ sub: PlainCopy.Subline) -> some View {
        if let more = sub.more {
            ViewThatFits(in: .horizontal) {
                InlineLinkLine(text: sub.text, links: [sub.link, more].compactMap { $0 }, send: model.send, focus: focus)
                VStack(alignment: .leading, spacing: 2) {
                    InlineLinkLine(text: sub.text, links: [sub.link].compactMap { $0 }, send: model.send, focus: focus)
                    InlineLinkLine(text: "", links: [more], send: model.send, focus: focus)
                }
            }
        } else if let link = sub.link {
            InlineLinkLine(text: sub.text, links: [link], send: model.send, focus: focus)
        } else {
            Text(sub.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
        }
    }

    // MARK: Helpers

    private func subTone(_ tone: PlainCopy.Tone) -> Color {
        switch tone {
        case .secondary: return .secondary
        case .warning: return Theme.warningText
        case .danger: return Theme.dangerText
        }
    }
}
