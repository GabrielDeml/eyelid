import AppKit
import InsomniaShared
import SwiftUI

// MARK: - Settings ▸ Diagnostics (UX.md §4.4)
//
//   Live          SleepDisabled · Lid · Thermal / Power · Low Power Mode / Lid mode · Helper (three lines)
//   Why awake?    the ⌥-click report as a table (Who · What · Since; System is the Live section)   [Refresh]
//   Event log     last 200                                                       [Copy] [Clear]
//   About                                                                        [About Insomnia…]
//
// No timers: the live rows are observable (PowerMonitor, AwakeEngine); the report and the SleepDisabled readback
// refresh on appear, on state/power/rule changes and on Refresh. Never per second.

struct DiagnosticsTab: View {
    private let engine = AwakeEngine.shared
    private let power = PowerMonitor.shared

    @State private var report: WhyAwakeReport?
    @State private var reportDate = Date()
    @State private var sleepDisabled: Bool?
    @State private var teamID: String?

    var body: some View {
        Form {
            liveSection
            whySection
            EventLogSection()
            Section("About") {
                HStack {
                    Text("Version \(Self.versionText)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("About Insomnia…") { AppRouter.shared.showAbout() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: trigger) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .insomniaRulesDidChange)) { _ in refresh() }
        .task { teamID = await Self.loadTeamID() }
    }

    // MARK: Live

    /// Three compact lines (UX §4.4), so Event log and About stay in view.
    private var liveSection: some View {
        Section("Live") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 18) {
                    livePair("SleepDisabled", sleepDisabledText)
                    if power.hasLid { livePair("Lid", power.isLidClosed ? "Closed" : "Open") }
                    livePair("Thermal", WhyAwakeReport.thermalText(power.thermalState).capitalized)
                }
                HStack(spacing: 18) {
                    livePair("Power", powerText)
                    livePair("Low Power Mode", power.isLowPowerMode ? "On" : "Off")
                }
                if power.hasLid {
                    (Text("Lid mode ").foregroundStyle(.secondary) + Text(lidModeText)
                        + Text("   Helper ").foregroundStyle(.secondary) + Text(helperText))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel("Lid mode \(lidModeText). Helper: \(helperText)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func livePair(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var lidModeText: String {
        WhyAwakeReport.lidText(engine.lid).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Off"
    }

    private var sleepDisabledText: String {
        switch sleepDisabled {
        case nil: return "Unknown"
        case false?: return "No"
        case true?:
            let flag = report?.section(.system)?.rows.first { $0.id == "sys-flag" }?.what
            return flag ?? "Yes"
        }
    }

    private var powerText: String {
        guard power.hasBattery else { return "AC" }
        var parts = [power.isOnAC ? "AC" : "Battery"]
        if let p = power.batteryPercent { parts.append("\(p)%") }
        if power.isOnAC { parts.append(power.isCharging ? "charging" : "not charging") }
        return parts.joined(separator: " · ")
    }

    /// "privileged helper 1.0.0 · team ABCDE12345 · ready · idle" / "sudoers fallback · ready · engaged".
    private var helperText: String {
        guard let lc = engine.lidController else { return "Not available in this build yet" }
        let activity: String = switch lc.status {
        case .engaged: "engaged"
        case .engaging: "applying"
        case .error: "error"
        case .stuck: "stuck on"
        default: "idle"
        }
        let state = HelperStatusText.short(lc.helper)
        switch lc.backendKind {
        case .helper?:
            return "privileged helper \(HelperInfo.version) · team \(teamID ?? "…") · \(state) · \(activity)"
        case .sudoers?:
            return "sudoers fallback · \(state) · \(activity)"
        case nil:
            return "resolving…"
        }
    }

    // MARK: Why awake?

    private var whySection: some View {
        Section {
            if let report {
                WhyAwakeTable(report: report, now: reportDate)
            } else {
                ProgressView().controlSize(.small)
            }
        } header: {
            HStack {
                Text("Why awake?")
                Spacer()
                Button("Copy Report") {
                    if let report { WhyAwakeMenu.copyToPasteboard(report.text(generatedAt: reportDate)) }
                }
                .controlSize(.small)
                .disabled(report == nil)
                Button("Refresh", action: refresh)
                    .controlSize(.small)
            }
        }
    }

    private func refresh() {
        let now = Date()
        reportDate = now
        report = WhyAwakeReport.build(.live())
        sleepDisabled = RootDomain.sleepDisabled()
    }

    /// Changes that should refresh the report (never the 1 Hz display tick).
    private var trigger: Trigger {
        Trigger(holds: engine.holds, guards: engine.guards, lid: engine.lid, paused: engine.pausedRuleIDs,
                onAC: power.isOnAC, percent: power.batteryPercent, thermal: power.thermalState,
                lidClosed: power.isLidClosed, lowPower: power.isLowPowerMode, displays: power.externalDisplayCount)
    }

    private struct Trigger: Equatable {
        var holds: [Hold]
        var guards: Set<GuardReason>
        var lid: LidStatus
        var paused: Set<Rule.ID>
        var onAC: Bool
        var percent: Int?
        var thermal: ProcessInfo.ThermalState
        var lidClosed: Bool
        var lowPower: Bool
        var displays: Int
    }

    // MARK: Helpers

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return "\(version) (\(build))"
    }

    /// Our own Team ID, read once off the main thread (certificate reads). nil for ad-hoc builds.
    private static func loadTeamID() async -> String? {
        await Task.detached(priority: .utility) { CodeSignature.currentTeamID() }.value
    }
}

// MARK: - Why awake table

private struct WhyAwakeTable: View {
    let report: WhyAwakeReport
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if report.isNothing {
                Text(WhyAwakeReport.nothingText)
                    .foregroundStyle(.secondary)
            } else {
                table.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var table: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Who")
                Text("What")
                Text("Since").gridColumnAlignment(.trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            // System readback is the Live section above; the table lists who is holding the Mac awake.
            ForEach(report.sections.filter { $0.kind != .system }) { section in
                GridRow {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                        .gridCellColumns(3)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(section.rows) { row in
                    GridRow {
                        Text(row.who)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 200, alignment: .leading)
                        Text(row.what)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(row.detail ?? "")
                        Text(row.since.map { WhyAwakeReport.sinceText($0, now: now) } ?? "")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText(row, section: section))
                }
            }
        }
    }

    private func accessibilityText(_ row: WhyAwakeReport.Row, section: WhyAwakeReport.Section) -> String {
        var parts = [row.who, row.what]
        if let since = row.since { parts.append("since \(WhyAwakeReport.sinceText(since, now: now))") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Event log

private struct EventLogSection: View {
    private let log = EventLog.shared

    var body: some View {
        Section {
            if log.entries.isEmpty {
                Text("No events yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(log.entries) { entry in
                                Text(EventLog.line(entry))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(entry.kind == "guard" || entry.kind == "lid" ? .primary : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                    }
                    .frame(height: 180)
                    .onAppear { proxy.scrollTo(log.entries.last?.id, anchor: .bottom) }
                    .onChange(of: log.entries.last?.id) { _, last in
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .accessibilityLabel("Event log, \(log.entries.count) entries")
            }
        } header: {
            HStack {
                Text("Event log (last \(log.capacity))")
                Spacer()
                Button("Copy") { WhyAwakeMenu.copyToPasteboard(log.text()) }
                    .controlSize(.small)
                    .disabled(log.entries.isEmpty)
                Button("Clear") { log.clear() }
                    .controlSize(.small)
                    .disabled(log.entries.isEmpty)
            }
        }
    }
}
