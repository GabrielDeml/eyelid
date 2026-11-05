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
    var runMinutes: Int?
    var presets = Preferences.defaultPresets
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
    case start(minutes: Int)
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
        s.runMinutes = engine.runMinutes
        s.presets = prefs.timerPresets
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

/// The menu bar panel.
struct PanelView: View {
    var state: PanelState
    var send: @MainActor (PanelAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 8) {
                ForEach(Array(state.presets.enumerated()), id: \.offset) { _, minutes in
                    let selected = state.isOn && state.runMinutes == minutes
                    Button(DurationText.short(minutes: minutes)) { send(.start(minutes: minutes)) }
                        .buttonStyle(ChipStyle(selected: selected))
                        .help("Keep awake for \(DurationText.short(minutes: minutes)), from now")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Divider()
            VStack(spacing: 2) {
                row(symbol: "display", title: "Keep screen on") {
                    Toggle("", isOn: binding(state.keepScreenOn) { send(.setScreen($0)) })
                }
                if state.showLid {
                    row(symbol: "laptopcomputer", title: "Stay awake with lid closed", tint: Theme.lid) {
                        Toggle("", isOn: binding(state.lidOn) { send(.setLid($0)) })
                            .disabled(!state.lidEnabled)
                    }
                    if let caption = state.lidCaption { captionView(caption) }
                }
                if state.showUnplugged {
                    row(symbol: "powerplug", title: "When unplugged") {
                        Picker("", selection: binding(state.unplugged) { send(.setUnplugged($0)) }) {
                            ForEach(state.unpluggedChoices) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
            }
            if let notice = state.notice { noticeView(notice) }
            HStack {
                Spacer()
                Menu {
                    Button("Settings…") { send(.openSettings) }
                    Divider()
                    Button("Quit Insomnia") { send(.quit) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
            .padding(.top, -6)
        }
        .padding(Theme.padding)
        .frame(width: Theme.panelWidth)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: MoonGlyph.image(mode: state.mode, attention: state.attention))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 30)
                .foregroundStyle(state.isOn ? (state.mode == .lid ? Theme.lid : Theme.accent) : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.isOn ? "Awake" : "Off").font(Theme.title)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(subtitle(now: context.date))
                        .font(Theme.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                if state.isOn { modeTags }
            }
            Spacer(minLength: 0)
            Button { send(.toggle) } label: {
                Image(systemName: "power")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(state.isOn ? Theme.onAccent : Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(state.isOn ? Theme.accent : Color.primary.opacity(0.09)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .help(state.isOn ? "Turn off" : "Keep awake until you turn it off")
            .accessibilityLabel(state.isOn ? "Turn off" : "Turn on")
        }
        .accessibilityElement(children: .contain)
    }

    private func subtitle(now: Date) -> String {
        guard state.isOn else { return state.stuck ? "Sleep is still turned off (see below)" : "Your Mac sleeps normally" }
        guard let end = state.endsAt else { return "Until you turn it off" }
        return DurationText.left(until: end, now: now) + " · until " + DurationText.clock(end)
    }

    /// The mode in words, next to the moon that shows it in shape.
    private var modeTags: some View {
        HStack(spacing: 4) {
            if state.mode == .screenOn || (state.mode == .lid && state.keepScreenOn) { tag("Screen on", symbol: "sparkle") }
            if state.mode == .lid { tag("Lid can close", symbol: "laptopcomputer", tint: Theme.lid) }
            if state.mode == .awake { tag("Screen may sleep", symbol: "moon.zzz") }
        }
    }

    private func tag(_ text: String, symbol: String, tint: Color = .secondary) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    // MARK: Rows

    private func row<Control: View>(symbol: String, title: String, tint: Color = .secondary,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(title).font(Theme.row).lineLimit(1).fixedSize().layoutPriority(1)
            Spacer(minLength: 8)
            control()
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(minHeight: Theme.rowHeight)
    }

    private func captionView(_ caption: PanelState.Caption) -> some View {
        let colour: Color = switch caption.tone {
        case .secondary: .secondary
        case .warning: Theme.warningText
        case .danger: Theme.dangerText
        }
        return Group {
            if let action = caption.action {
                Button(caption.text) { send(action) }.buttonStyle(.plain)
            } else {
                Text(caption.text)
            }
        }
        .font(Theme.caption)
        .foregroundStyle(colour)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 30)
        .padding(.top, -6)
        .padding(.bottom, 2)
    }

    private func noticeView(_ notice: Engine.Notice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.isWarning ? Theme.warning : .secondary)
            Text(notice.text).font(.system(size: 12))
            Spacer(minLength: 4)
            Button { send(.dismissNotice) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill((notice.isWarning ? Theme.warning : Color.secondary).opacity(0.12)))
    }

    private func binding<T: Sendable>(_ value: T, _ set: @escaping @MainActor (T) -> Void) -> Binding<T> {
        Binding(get: { value }, set: set)
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
