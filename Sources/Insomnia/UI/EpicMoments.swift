import AppKit
import Observation
import SwiftUI

// MARK: - The four epic moments (docs/PRODUCT.md §4 rule 10, docs/UX.md §2.4)
//
// | Moment          | Where it lives                                                                                |
// |-----------------|-----------------------------------------------------------------------------------------------|
// | First wake      | `EpicMoments.panelVisibilityChanged` opens the eyes (`eyesMood`, `EyesCues.firstWake`), then  |
// |                 | reveals `WelcomeCard`; "Got it" ends the greeting.                                            |
// | Night vision    | `EpicMoments` detects the first lid engagement each day → `nightVisionCount` (panel sweep via  |
// |                 | `EyesCues.nightVision`) + `.insomniaNightVision` (DockController pulses the tile once).        |
// | Mission report  | `MissionReportCard` replaces row J for `Banner.reopen`; numbers count up over 600 ms.          |
// | Eye bags        | `PanelState.bags` → `EyesView(bags:)` (≥ 24 h bags, ≥ 72 h veins). Static art, no words.       |
//
// Everything respects Reduce Motion: cues don't play (EyesView checks), the card shows final numbers, the Dock skips
// its pulse, and the welcome card appears without waiting for an animation.

extension Notification.Name {
    /// Posted once per day, on the first lid engagement (the Dock tile pulses once).
    static let insomniaNightVision = Notification.Name("InsomniaNightVision")
}

@MainActor
@Observable
final class EpicMoments {
    static let shared = EpicMoments()

    /// The welcome card is showing in the panel (first run only).
    private(set) var welcomeVisible = false
    /// Bumps once per day on the first lid engagement. The panel plays its sweep when this changes while visible.
    private(set) var nightVisionCount = 0

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var wasEngaged = false
    @ObservationIgnored private var firstWakeStarted = false
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// First wake: eyes open (600 ms), blink twice, find the cursor; then the card. Matches `EyesMotion`'s cue.
    static let firstWakeDuration: Duration = .milliseconds(1_900)
    private static let nightVisionDayKey = "epic.nightVisionDay"

    init(settings: Settings = .shared, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
    }

    /// Follows engine state for night vision. Idempotent.
    func start() {
        guard observer == nil else { return }
        wasEngaged = Self.isEngaged(AwakeEngine.shared.lid)
        observer = NotificationCenter.default.addObserver(forName: .insomniaStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stateChanged(lid: AwakeEngine.shared.lid) }
        }
    }

    // MARK: Night vision

    func stateChanged(lid: LidStatus, now: Date = Date()) {
        let engaged = Self.isEngaged(lid)
        defer { wasEngaged = engaged }
        guard engaged, !wasEngaged, claimNightVision(now: now) else { return }
        nightVisionCount += 1
        NotificationCenter.default.post(name: .insomniaNightVision, object: self)
    }

    /// True once per calendar day.
    func claimNightVision(now: Date) -> Bool {
        let today = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        guard defaults.double(forKey: Self.nightVisionDayKey) != today else { return false }
        defaults.set(today, forKey: Self.nightVisionDayKey)
        return true
    }

    private static func isEngaged(_ lid: LidStatus) -> Bool {
        if case .engaged = lid { return true }
        return false
    }

    // MARK: First wake + welcome card

    /// While the mascot greets a new user, the panel eyes are open even though nothing holds the Mac awake (the
    /// headline still says "Sleep allowed"). Ends with "Got it"; the eyes then close with the normal toggle-off motion.
    private(set) var greetingActive = false

    /// The mood the panel eyes should show: `.awake` during the greeting if the Mac is asleep, else `mood`.
    func eyesMood(for mood: EyeMood) -> EyeMood {
        greetingActive && mood == .asleep ? .awake : mood
    }

    /// Call from the panel host's visibility callback. On the first visible panel before onboarding is done: wait for
    /// the first frame (closed eyes), open them slowly with the first-wake cue (600 ms, two blinks, find the cursor),
    /// then reveal the welcome card. Reduce Motion: straight to the card.
    func panelVisibilityChanged(_ visible: Bool, model: PanelModel) {
        guard !settings.hasCompletedOnboarding else { return }
        guard visible else {
            revealTask?.cancel()
            return
        }
        if welcomeVisible { return }
        if firstWakeStarted || Theme.reduceMotion {
            greetingActive = true
            welcomeVisible = true
            return
        }
        firstWakeStarted = true
        revealTask?.cancel()
        revealTask = Task { [weak self, weak model] in
            try? await Task.sleep(for: .milliseconds(180))   // let the panel draw its closed eyes first
            guard !Task.isCancelled, let self else { return }
            self.greetingActive = true
            model?.cues.firstWake += 1
            try? await Task.sleep(for: Self.firstWakeDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.welcomeVisible = true }
        }
    }

    /// "Got it": done for good. Requests notification permission (UX §7.1, §10).
    func completeOnboarding() {
        revealTask?.cancel()
        withAnimation(.easeInOut(duration: Theme.reduceMotion ? 0.15 : 0.25)) { welcomeVisible = false }
        greetingActive = false
        settings.hasCompletedOnboarding = true
        Notifier.requestAuthorization()
    }
}

// MARK: - Mission report (UX §6 "Lid reopens", §2.4)

/// Row J grown into a card: "While you were away" + three numbers that count up (600 ms) + one line (Cheeky/Unhinged).
/// Plain facts in every tier; the line is optional. Reduce Motion shows the final numbers.
struct MissionReportCard: View {
    let report: ReopenReport
    /// The `lidReopened` line; nil in Professional (and when the Narrator has none).
    var line: String?
    var focus: FocusState<PanelFocus?>.Binding?
    var dismiss: () -> Void = {}

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accentLid)
                    .accessibilityHidden(true)
                Text("While you were away")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .panelFocus(focus)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            CountUp(duration: 0.6) { t in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    stat(TimeFormat.compact(report.closedFor * t), "closed")
                    if let start = report.batteryStart, let end = report.batteryEnd {
                        let shown = Int((Double(start) + Double(end - start) * t).rounded())
                        stat("\(start)→\(shown)%", "battery")
                    }
                    stat(Self.thermalWord(report.worstThermal), "temperature")
                }
            }
            if let line, !line.isEmpty {
                Text(line)
                    .font(Theme.quip)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.accentLid.opacity(scheme == .dark ? 0.2 : 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.accentLid.opacity(0.25), lineWidth: 0.5))
        .transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenSummary(report))
        .accessibilityAction(named: "Dismiss", dismiss)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The same three words as the plain banner (UX §6): stayed cool / got warm / got hot.
    static func thermalWord(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "Stayed cool"
        case .fair: return "Got warm"
        default: return "Got hot"
        }
    }

    static func spokenSummary(_ r: ReopenReport) -> String {
        var parts = ["While you were away: \(PlainCopy.spokenRemaining(r.closedFor)) closed"]
        if let a = r.batteryStart, let b = r.batteryEnd { parts.append("battery \(a) to \(b) percent") }
        parts.append(thermalWord(r.worstThermal).lowercased())
        return parts.joined(separator: ", ")
    }
}

/// Drives a 0…1 eased fraction over `duration` once, then rests at 1. Animates only while on screen; Reduce Motion
/// renders the final value immediately. No timer survives the animation.
struct CountUp<Content: View>: View {
    var duration: TimeInterval = 0.6
    @ViewBuilder var content: (Double) -> Content

    @State private var start = Date()
    @State private var done = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || done {
            content(1)
        } else {
            TimelineView(.animation) { context in
                let t = min(1, max(0, context.date.timeIntervalSince(start) / duration))
                content(1 - pow(1 - t, 3))   // ease-out cubic
            }
            .task {
                try? await Task.sleep(for: .seconds(duration + 0.05))
                done = true
            }
        }
    }
}

// MARK: - Eye bags

enum EyeBags {
    /// 0 none, 1 bags (≥ 24 h continuously awake), 2 bags + veins (≥ 72 h). `PanelState.bags` gates it on awake.
    static func level(awakeFor: TimeInterval) -> Int {
        awakeFor >= 72 * 3600 ? 2 : (awakeFor >= 24 * 3600 ? 1 : 0)
    }
}
