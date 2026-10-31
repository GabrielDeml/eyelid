import AppKit
import InsomniaShared
import SwiftUI

/// About Insomnia (docs/UX.md §4.4): big panel eyes, the version, lifetime stats, milestones earned, Reset Stats and
/// the GitHub link. A sheet on the Settings window when that's frontmost, otherwise a small window of its own.
struct AboutView: View {
    var isSheet = false
    var close: () -> Void = {}

    private let stats = Stats.shared
    @State private var visible = false
    @State private var confirmReset = false

    static let repository = URL(string: "https://github.com/GabrielDeml/insomnia")

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                EyesView(mood: .awake, progress: nil, isLive: visible, size: 104)
                Text("Insomnia")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text("Version \(Self.versionText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("A pair of eyes in your menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            statsGrid
            milestones

            HStack {
                if let url = Self.repository {
                    Link("GitHub", destination: url)
                }
                Spacer()
                Button("Reset Stats…") { confirmReset = true }
                if isSheet {
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)

            // The joke is about the app, never the reader, and Professional has none (PRODUCT.md §4).
            Text(Settings.shared.personality == .professional
                 ? "© 2026 Gabriel Deml."
                 : "© 2026 Gabriel Deml. Built by an app that has never slept.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .confirmationDialog("Reset all stats?", isPresented: $confirmReset) {
            Button("Reset Stats", role: .destructive) { stats.reset() }
        } message: {
            Text("Total time, sessions and badges go back to zero. Milestones already shown won't repeat.")
        }
    }

    // MARK: Stats

    private var statsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            row("Total awake", stats.totalAwakeSeconds > 0 ? TimeFormat.humanLong(stats.totalAwakeSeconds) : "Not yet")
            row("Sessions", stats.sessionCount.formatted())
            row("Longest session", stats.longestSessionSeconds > 0 ? TimeFormat.humanLong(stats.longestSessionSeconds) : "–")
            if PowerMonitor.shared.hasLid {
                row("Lid closed", stats.lidClosedSeconds > 0 ? TimeFormat.humanLong(stats.lidClosedSeconds) : "–")
            }
            row("Coffee equivalent", Self.cups(stats.cupsOfCoffeeEquivalent))
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    static func cups(_ n: Int) -> String {
        n == 0 ? "Less than a cup" : "≈ \(n.formatted()) cup\(n == 1 ? "" : "s") of coffee"
    }

    // MARK: Milestones

    private var milestones: some View {
        let earned = Self.badges(stats)
        return VStack(spacing: 6) {
            Text("Milestones")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if earned.isEmpty {
                Text("None yet. Give it time.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    ForEach(earned, id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.accentAwake))
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Earned badges, in order: hours milestones, the poke badge, lid survivals.
    static func badges(_ s: Stats) -> [String] {
        var out = Stats.milestoneHours.filter { s.milestonesShown.contains($0) && Double($0) * 3600 <= s.totalAwakeSeconds }
            .map { "\($0.formatted()) h" }
        if s.pokeBadge { out.append("Poked 50×") }
        if s.lidCloseSurvivals > 0 { out.append("Lid closed \(s.lidCloseSurvivals.formatted())×") }
        return out
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? HelperInfo.version
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// Presents `AboutView`: as a sheet on the Settings window when it's the key window, otherwise in its own small window.
/// Wiring: `AppRouter.shared.showAboutHandler = { AboutWindowController.shared.show() }`.
@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()

    private var window: NSWindow?
    private var sheet: NSWindow?

    func show() {
        AppRouter.shared.closePanel()
        NSApp.activate(ignoringOtherApps: true)
        if let parent = SettingsWindowController.shared.window, parent.isVisible, parent.isKeyWindow || parent.isMainWindow {
            presentSheet(on: parent)
            return
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: AboutView())
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable]
        w.title = "About Insomnia"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    private func presentSheet(on parent: NSWindow) {
        guard sheet == nil else { return }
        let hosting = NSHostingController(rootView: AboutView(isSheet: true) { [weak self] in self?.endSheet() })
        let s = NSWindow(contentViewController: hosting)
        s.styleMask = [.titled]
        sheet = s
        parent.beginSheet(s) { [weak self] _ in
            MainActor.assumeIsolated { self?.sheet = nil }
        }
    }

    private func endSheet() {
        guard let sheet, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil   // the next show() builds a fresh one (and the eyes stop animating)
    }
}
