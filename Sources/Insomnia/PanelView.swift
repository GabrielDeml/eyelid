import AppKit
import SwiftUI

/// Everything the panel shows, derived from the engine. A plain value, so snapshots need no engine.
struct PanelState: Equatable {
    /// A line under the lid switch. `text` is a fragment with no period, unless a link follows; then it ends with one.
    struct Caption: Equatable {
        enum Tone: Equatable { case secondary, warning, danger }
        struct Link: Equatable {
            var title: String
            var action: PanelAction
        }
        var text: String
        var tone: Tone = .secondary
        var link: Link? = nil
    }

    var isOn = false
    var endsAt: Date?
    var keepScreenOn = true
    var showLid = true
    var lidOn = false
    var lidEnabled = true
    var lidCaption: Caption?
    var showUnplugged = true
    var unplugged = UnpluggedAction.keepGoing
    var unpluggedChoices = UnpluggedAction.choices(lidMode: false)
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
        case .notInApplications: s.lidEnabled = false; s.lidCaption = notInApplicationsCaption
        case .unsigned: s.lidEnabled = false; s.lidCaption = unsignedCaption
        case .missingFiles: s.lidEnabled = false; s.lidCaption = missingFilesCaption
        default: break
        }
        s.lidOn = prefs.closedLidMode && s.lidEnabled
        if lid.state == .stuck {
            s.lidCaption = stuckCaption
        } else if let error = lid.setupError {
            s.lidCaption = setupErrorCaption(error)
        } else if s.lidOn {
            s.lidCaption = lidCaption(engine: engine, lid: lid, power: p)
        }
        return s
    }

    @MainActor
    private static func lidCaption(engine: Engine, lid: LidController, power p: PowerState) -> Caption? {
        switch lid.setup {
        case .notRegistered: return lid.installing ? settingUpCaption : notSetUpCaption
        case .needsApproval: return needsApprovalCaption
        default: break
        }
        if case .failed(let f) = lid.state { return failureCaption(f) }
        guard engine.isOn else { return nil }
        if engine.hotEpisode { return hotCaption }
        if engine.lowEpisode { return lowBatteryCaption }
        if p.isOnBattery, engine.prefs.whenUnplugged == .sleepWhenLidCloses { return pausedOnBatteryCaption }
        return nil
    }

    // The captions, shared with `make snapshot` so its pictures show the app's real text.
    static let notInApplicationsCaption = Caption(text: "Works only when installed in Applications")
    static let unsignedCaption = Caption(text: "Needs a signed build")
    static let missingFilesCaption = Caption(text: "This build is missing the lid helper", tone: .warning)
    static let stuckCaption = Caption(text: "Couldn't turn sleep back on.", tone: .danger,
                                      link: .init(title: "Reset with Password…", action: .resetWithPassword))
    static let settingUpCaption = Caption(text: "Setting up the lid helper")
    static let notSetUpCaption = Caption(text: "The lid helper isn't set up.",
                                         link: .init(title: "Set Up…", action: .retryLid))
    static let needsApprovalCaption = Caption(text: "Needs your approval.", tone: .warning,
                                              link: .init(title: "Open System Settings", action: .openLoginItems))
    static let hotCaption = Caption(text: "Paused while your Mac is hot", tone: .warning)
    static let lowBatteryCaption = Caption(text: "Paused while the battery is low", tone: .warning)
    static let pausedOnBatteryCaption = Caption(text: "Paused while on battery")

    static func setupErrorCaption(_ error: String) -> Caption {
        Caption(text: error, tone: .warning, link: tryAgain)
    }

    static func failureCaption(_ f: LidController.Failure) -> Caption {
        switch f {
        case .foreignFlag: Caption(text: "Another app has already turned off sleep", tone: .warning)
        case .otherUser: Caption(text: "In use by another user on this Mac", tone: .warning)
        case .lowBattery: Caption(text: "Battery too low. Plug in your Mac.", tone: .warning, link: tryAgain)
        case .setFailed: Caption(text: "Couldn't turn off sleep.", tone: .warning, link: tryAgain)
        case .lost: Caption(text: "Lost contact with the lid helper.", tone: .warning, link: tryAgain)
        case .overridden: Caption(text: "Something else turned sleep back on.", tone: .warning, link: tryAgain)
        }
    }

    private static let tryAgain = Caption.Link(title: "Try Again", action: .retryLid)
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
                    .help(state.isOn ? "Let your Mac sleep" : "Keep your Mac awake")
            }
            if let subtitle {
                Text(subtitle)
                    .font(Theme.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Only what the state word doesn't say: when a timed session ends, or that sleep is still off.
    private var subtitle: String? {
        if state.isOn { return state.endsAt.map { "Until " + DurationText.clock($0) } }
        return state.stuck ? "Your Mac still can't sleep" : nil
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
            if let link = caption.link {
                // One text, so the link wraps with the message; non-breaking spaces keep the link itself whole.
                let title = Text(link.title.replacingOccurrences(of: " ", with: "\u{00A0}"))
                    .foregroundStyle(Color(nsColor: .linkColor))
                Button { send(link.action) } label: { captionText(Text("\(Text(caption.text)) \(title)")) }
                    .buttonStyle(.plain)
                    .linkPointer()
                    .accessibilityLabel(caption.text + " " + link.title)
            } else {
                captionText(Text(caption.text))
            }
        }
        .font(Theme.caption)
        .foregroundStyle(colour)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, -4)
        .padding(.bottom, 6)
    }

    private func captionText(_ text: Text) -> some View {
        text
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Notice and footer

    private func noticeView(_ notice: Engine.Notice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(notice.isWarning ? Theme.warningText : .secondary)
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
