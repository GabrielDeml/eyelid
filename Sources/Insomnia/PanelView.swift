import AppKit
import SwiftUI

/// Everything the panel shows, derived from the engine. A plain value, so snapshots need no engine.
struct PanelState: Equatable {
    struct Caption: Equatable {
        enum Tone: Equatable { case secondary, warning, danger }
        var text: String
        var tone: Tone = .secondary
        var action: PanelAction? = nil
    }

    var mode: Engine.Mode = .off
    var attention = false
    var isOn = false
    var endsAt: Date?
    var keepScreenOn = true
    var showLid = true
    var lidOn = false
    var lidEnabled = true
    var lidCaption: Caption?
    var showUnplugged = true
    var unplugged = UnpluggedAction.sleepWhenLidCloses
    var unpluggedChoices = UnpluggedAction.allCases
    var notice: Engine.Notice?
    /// A release failed: SleepDisabled is still set although we meant to clear it.
    var stuck = false
}

enum PanelAction: Equatable {
    case toggle
    case setScreen(Bool)
    case setLid(Bool)
    case setUnplugged(UnpluggedAction)
    case dismissNotice
    case openLoginItems
    case retryLid
    case resetWithPassword
    case openSettings
    case quit
}

extension PanelState {
    @MainActor
    static func live(engine: Engine, lid: LidController) -> PanelState {
        let prefs = engine.prefs
        let p = engine.powerState
        var s = PanelState()
        s.mode = engine.mode
        s.attention = engine.needsAttention
        s.isOn = engine.isOn
        s.endsAt = engine.endsAt
        s.keepScreenOn = prefs.keepScreenOn
        s.notice = engine.notice
        s.showLid = p.hasLid && lid.setup != .noLid
        s.showUnplugged = p.hasBattery
        s.unpluggedChoices = UnpluggedAction.choices(lidMode: prefs.closedLidMode)
        s.unplugged = UnpluggedAction.shown(prefs.whenUnplugged, lidMode: prefs.closedLidMode)
        s.stuck = lid.isStuck

        switch lid.setup {
        case .notInApplications:
            s.lidEnabled = false
            s.lidCaption = Caption(text: "Needs the copy installed in Applications")
        case .unsigned:
            s.lidEnabled = false
            s.lidCaption = Caption(text: "Needs a signed build")
        case .missingFiles:
            s.lidEnabled = false
            s.lidCaption = Caption(text: "The lid helper is missing from this build", tone: .warning)
        default:
            break
        }
        s.lidOn = prefs.closedLidMode && s.lidEnabled
        if lid.state == .stuck {
            s.lidCaption = Caption(text: "Sleep is still off. Reset with password…", tone: .danger,
                                   action: .resetWithPassword)
        } else if let error = lid.setupError {
            s.lidCaption = Caption(text: error + " Try again", tone: .warning, action: .retryLid)
        } else if s.lidOn {
            s.lidCaption = lidCaption(engine: engine, lid: lid, power: p)
        }
        return s
    }

    @MainActor
    private static func lidCaption(engine: Engine, lid: LidController, power p: PowerState) -> Caption? {
        switch lid.setup {
        case .notRegistered: return Caption(text: "Setting up…")
        case .needsApproval:
            return Caption(text: "Waiting for approval in System Settings ›", tone: .warning, action: .openLoginItems)
        default: break
        }
        if case .failed(let f) = lid.state {
            let text = switch f {
            case .foreignFlag: "Another app has turned sleep off"
            case .otherUser: "Another user is using lid mode"
            case .lowBattery: "Battery too low for lid mode"
            case .setFailed: "Couldn't turn lid mode on. Try again"
            case .lost: "Lost the lid-mode helper. Try again"
            case .overridden: "Something turned sleep back on. Try again"
            }
            let retryable = f != .foreignFlag && f != .otherUser
            return Caption(text: text, tone: .warning, action: retryable ? .retryLid : nil)
        }
        guard engine.isOn else { return nil }
        if engine.hotEpisode { return Caption(text: "Paused: your Mac is hot", tone: .warning) }
        if engine.lowEpisode { return Caption(text: "Paused: battery low", tone: .warning) }
        if p.isOnBattery, engine.prefs.whenUnplugged == .sleepWhenLidCloses {
            return Caption(text: "Paused on battery (When unplugged)")
        }
        return nil
    }
}

/// The menu bar panel: type, spacing and native controls on one 16 pt edge (docs/DESIGN.md, Look).
struct PanelView: View {
    var state: PanelState
    var send: @MainActor (PanelAction) -> Void

    #if DEBUG
    /// Width the content asked for, before the fixed frame. `make snapshot` fails if it is wider than the panel.
    @MainActor static var contentWidth: CGFloat = 0
    #endif

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let notice = state.notice { noticeView(notice).padding(.top, 10) }
                Divider().padding(.top, Theme.gap)
                rows.padding(.top, 4)
            }
            #if DEBUG
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { PanelView.contentWidth = $0 }
            #endif
            .padding(.horizontal, Theme.inset)
            .padding(.top, Theme.top)
            .padding(.bottom, 6)
            Divider()
            footer
        }
        .frame(width: Theme.panelWidth)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Text(state.isOn ? "Awake" : "Off").font(Theme.title)
                Spacer(minLength: 8)
                Toggle("Keep awake", isOn: binding(state.isOn) { _ in send(.toggle) })
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)   // .regular is oversized on the macOS 26+ glass switch
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)   // Return toggles
                    .help(state.isOn ? "Turn off" : "Keep awake")
            }
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(subtitle(now: context.date))
                    .font(Theme.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            if state.isOn { modeLine.padding(.top, 1) }
        }
        .accessibilityElement(children: .contain)
    }

    private func subtitle(now: Date) -> String {
        guard state.isOn else { return state.stuck ? "Sleep is still turned off (see below)" : "Your Mac sleeps normally" }
        guard let end = state.endsAt else { return "Until you turn it off" }
        return DurationText.left(until: end, now: now) + " · until " + DurationText.clock(end)
    }

    /// The mode in words: the menu bar moon right above shows it in shape.
    private var modeLine: some View {
        var parts: [Text] = []
        if state.mode == .screenOn || (state.mode == .lid && state.keepScreenOn) { parts.append(Text("Screen on")) }
        if state.mode == .lid { parts.append(Text("Lid can close").foregroundStyle(Theme.lidText)) }
        if state.mode == .awake { parts.append(Text("Screen may sleep")) }
        let line = parts.dropFirst().reduce(parts.first ?? Text("")) { Text("\($0) · \($1)") }
        return line
            .font(Theme.mode)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: Rows

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Keep screen on") {
                Toggle("Keep screen on", isOn: binding(state.keepScreenOn) { send(.setScreen($0)) })
                    .tint(Theme.accent)
            }
            if state.showLid {
                row("Stay awake with lid closed", dimmed: !state.lidEnabled) {
                    Toggle("Stay awake with lid closed", isOn: binding(state.lidOn) { send(.setLid($0)) })
                        .tint(Theme.lid)
                        .disabled(!state.lidEnabled)
                }
                if let caption = state.lidCaption { captionView(caption) }
            }
            if state.showUnplugged {
                row("When unplugged") { unpluggedMenu }
            }
        }
    }

    private func row<Control: View>(_ title: String, dimmed: Bool = false,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(Theme.row)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            Spacer(minLength: 12)
            control()
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.rowHeight)
    }

    /// The native pop-up (a SwiftUI `Menu` with a custom label didn't open in the real popover). Borderless so it reads
    /// as a value; no fixedSize, so it can never widen the panel.
    private var unpluggedMenu: some View {
        Picker("When unplugged", selection: binding(state.unplugged) { send(.setUnplugged($0)) }) {
            ForEach(state.unpluggedChoices) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .buttonStyle(.borderless)
        .help("What Insomnia does when you unplug the power adapter")
    }

    private func captionView(_ caption: PanelState.Caption) -> some View {
        let colour: Color = switch caption.tone {
        case .secondary: .secondary
        case .warning: Theme.warningText
        case .danger: Theme.dangerText
        }
        let symbol: String? = switch caption.tone {
        case .secondary: nil
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "exclamationmark.octagon.fill"
        }
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10)).accessibilityHidden(true) }
            if let action = caption.action {
                Button { send(action) } label: { captionText(caption.text) }
                    .buttonStyle(.plain)
                    .linkPointer()
            } else {
                captionText(caption.text)
            }
        }
        .font(Theme.caption)
        .foregroundStyle(colour)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, -4)
        .padding(.bottom, 6)
    }

    private func captionText(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Notice and footer

    private func noticeView(_ notice: Engine.Notice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(notice.isWarning ? Theme.warning : .secondary)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(Theme.notice)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { send(.dismissNotice) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(QuietButtonStyle())
            .padding(.trailing, -Theme.quietPadding)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button("Settings…") { send(.openSettings) }
                .help("Open Insomnia settings")
            Spacer(minLength: 8)
            Button("Quit Insomnia") { send(.quit) }
        }
        .font(Theme.footer)
        .buttonStyle(QuietButtonStyle())
        .padding(.horizontal, Theme.inset - Theme.quietPadding)
        .frame(height: Theme.footerHeight)
    }

    private func binding<T: Sendable>(_ value: T, _ set: @escaping @MainActor (T) -> Void) -> Binding<T> {
        Binding(get: { value }, set: set)
    }
}

private extension View {
    /// The pointing hand over an actionable caption, where the OS has it.
    @ViewBuilder func linkPointer() -> some View {
        if #available(macOS 15, *) { pointerStyle(.link) } else { self }
    }
}

/// The live panel: re-derives `PanelState` whenever anything it reads changes (Observation).
struct LivePanel: View {
    let engine: Engine
    let lid: LidController
    let send: @MainActor (PanelAction) -> Void

    var body: some View {
        PanelView(state: .live(engine: engine, lid: lid), send: send)
    }
}
