import AppKit
import SwiftUI

// MARK: - Lid mode setup (docs/UX.md §6)
//
//   1 · Explain  → Set Up… (helper: SMAppService register(), no password; sudoers: one admin prompt)
//   2 · Approve  → System Settings ▸ General ▸ Login Items & Extensions (helper only; re-checked every 1 s)
//   3 · Done     → "Ready. Close the lid whenever." + a 10 s test drive
//
// One sheet, never a modal alert. Not Now (or Esc, or the close button) at any step leaves things as they are:
// a registered-but-unapproved helper stays that way, and H′ / Lid & Safety reopen step 2 directly.

struct LidSetupView: View {
    enum Step: Equatable { case explain, approve, done }

    /// The lid switch (or a hold) asked for lid mode: switch the setting on once setup completes.
    let requestedLid: Bool
    let onClose: () -> Void

    @State private var step: Step
    @State private var busy = false
    @State private var problem: SetupProblem?
    @State private var drive: TestDrive = .idle
    @State private var closedAt: Date?

    private var lid: ClosedLidController { ClosedLidController.shared }
    private var settings: Settings { Settings.shared }
    private var power: PowerMonitor { PowerMonitor.shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(requestedLid: Bool, startAt: Step? = nil, onClose: @escaping () -> Void) {
        self.requestedLid = requestedLid
        self.onClose = onClose
        _step = State(initialValue: startAt ?? Self.initialStep(ClosedLidController.shared.helper))
    }

    static func initialStep(_ helper: HelperStatus) -> Step {
        switch helper {
        case .requiresApproval: return .approve
        case .installed: return .done
        default: return .explain
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepIndicator(step: step, showsApproval: lid.backendKind != .sudoers)
            Group {
                switch step {
                case .explain: explain
                case .approve: approve
                case .done: done
                }
            }
            .transition(reduceMotion ? .identity : .opacity)
        }
        .padding(22)
        .frame(width: 460, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
        .onChange(of: lid.helper) { _, new in helperChanged(new) }
        .onChange(of: power.isLidClosed) { _, closed in lidMoved(closed: closed) }
        .onChange(of: step) { _, new in announce(new) }
        .task { await lid.refreshHelper() }
    }

    // MARK: 1 · Explain

    private var explain: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stay awake with the lid closed")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { Bullet(text: $0.element) }
            }
            if let blocker {
                ProblemText(problem: blocker)
            } else if let problem {
                ProblemText(problem: problem)
            }
            HStack {
                Spacer()
                Button("Not Now", action: notNow)
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await setUp() }
                } label: {
                    if busy {
                        ProgressView().controlSize(.small).accessibilityLabel("Setting up")
                    } else {
                        Text("Set Up…")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || blocker != nil || lid.backendKind == nil)
            }
        }
    }

    private var bullets: [LocalizedStringKey] {
        let cap = LidSetupCopy.capText(settings.lidMaxOnBatteryMinutes)
        let floor = settings.batteryFloorPercent
        var b: [LocalizedStringKey] = ["Your Mac won't sleep when you close the lid. The screen turns off."]
        if lid.backendKind == .sudoers {
            b.append("You'll type your password once. Insomnia adds a rule that allows exactly two commands (sleep off / sleep on), **usable by any app running as you**, and a tiny safety daemon that restores sleep after a restart and at 10% battery.")
        } else {
            b.append("Insomnia adds a small helper that does exactly one thing: turn sleep off and back on. Only this Insomnia can talk to it.")
            b.append("If Insomnia quits, crashes or freezes, the helper turns sleep back on. It also restores sleep after a restart and at 10% battery.")
        }
        b.append("Keep it out of bags. On battery it stops after \(cap), pauses when hot or in Low Power Mode, and turns off at \(floor)%.")
        b.append("Apple menu ▸ Sleep is blocked while engaged. Use ⋯ ▸ Sleep Now.")
        return b
    }

    /// Conditions under which Set Up… can't work from this copy (UX §4.3).
    private var blocker: SetupProblem? {
        switch lid.helper {
        case .unsafeLocation:
            return SetupProblem(message: "Install Insomnia with make install to use lid mode.",
                                info: LidSetupCopy.unsafeLocationInfo)
        case .notFound:
            return SetupProblem(message: "Helper missing from the app. Reinstall Insomnia.")
        case .leftoverHelper:
            return SetupProblem(message: "A helper from a signed build is still registered. Remove it in Settings ▸ Lid & Safety first.")
        default:
            return nil
        }
    }

    // MARK: 2 · Approve

    private var approve: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One more step: allow Insomnia in System Settings")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                Text("General ▸ Login Items & Extensions ▸ turn on Insomnia.")
                Text("macOS asks for Touch ID or your password there.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your OK…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .opacity(problem == nil ? 1 : 0)
            if let problem { ProblemText(problem: problem, repair: { Task { await repair() } }) }
            HStack {
                Spacer()
                Button("Not Now", action: notNow)
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings") { lid.openApprovalSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { lid.watchApproval(true) }
        .onDisappear { lid.watchApproval(false) }
    }

    // MARK: 3 · Done

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready. Close the lid whenever.")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            driveText
            HStack {
                Button(drive == .waiting ? "Waiting for the lid…" : "Try it: close the lid for 10 s", action: startDrive)
                    .disabled(drive == .waiting || !power.hasLid)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var driveText: some View {
        switch drive {
        case .idle:
            Text("Lid mode turns on whenever Insomnia keeps your Mac awake and the lid switch is on.")
                .foregroundStyle(.secondary)
        case .waiting:
            Text("Close the lid, wait 10 seconds, then open it again.")
        case .survived:
            Label(settings.personality == .professional ? "Verified." : "Survived. Welcome to the night shift.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .tooShort:
            Text("That was quick. Keep it closed for at least 10 seconds.").foregroundStyle(.secondary)
        case .notEngaged:
            Label("Lid mode wasn't on when the lid closed. Check the lid switch in the panel.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warningText)
        }
    }

    // MARK: Actions

    private func setUp() async {
        busy = true
        problem = nil
        defer { busy = false }
        do throws(LidSetupError) {
            try await lid.install()
            advance(for: lid.helper)
        } catch .cancelled {
            notNow()   // cancelled password prompt == Not Now (UX §6)
        } catch {
            problem = LidSetupCopy.problem(for: error)
        }
    }

    private func repair() async {
        problem = nil
        do throws(LidSetupError) {
            try await lid.install()
            advance(for: lid.helper)
        } catch {
            problem = LidSetupCopy.problem(for: error)
        }
    }

    private func advance(for helper: HelperStatus) {
        switch helper {
        case .installed: finish()
        case .requiresApproval: step = .approve
        case .unreachable, .versionMismatch:
            step = .approve
            problem = SetupProblem(message: "The helper isn't responding.", canRepair: true)
        default: break
        }
    }

    private func helperChanged(_ helper: HelperStatus) {
        guard step == .approve else { return }
        switch helper {
        case .installed: finish()
        case .unreachable: problem = SetupProblem(message: "The helper isn't responding.", canRepair: true)
        default: break
        }
    }

    private func finish() {
        problem = nil
        guard step != .done else { return }
        step = .done
        Notifier.requestAuthorization()   // UX §10: asked at setup success, so the first safety notification lands
        AwakeEngine.shared.narrate(.setupDone)
        if requestedLid && !settings.closedLidMode { settings.closedLidMode = true }   // engages if something's awake
    }

    private func notNow() {
        lid.watchApproval(false)
        AwakeEngine.shared.narrate(.setupCancelled)   // UX §6: a quip, no error tone
        onClose()
    }

    private func startDrive() {
        drive = .waiting
        closedAt = nil
        if !settings.closedLidMode {
            settings.closedLidMode = true   // the engine starts a default hold if nothing is awake
        } else if !AwakeEngine.shared.isAwake {
            AwakeEngine.shared.activate(settings.defaultDuration, source: .panel)
        }
    }

    private func lidMoved(closed: Bool) {
        guard drive == .waiting || closedAt != nil else { return }
        if closed {
            if case .engaged = AwakeEngine.shared.lid { closedAt = Date() } else { drive = .notEngaged }
            return
        }
        guard let start = closedAt else { return }
        closedAt = nil
        drive = Date().timeIntervalSince(start) >= 10 ? .survived : .tooShort
    }

    private func announce(_ step: Step) {
        let text: String
        switch step {
        case .explain: return
        case .approve: text = "One more step: allow Insomnia in System Settings."
        case .done: text = "Ready. Close the lid whenever."
        }
        AccessibilityNotification.Announcement(text).post()
    }

    private enum TestDrive: Equatable { case idle, waiting, survived, tooShort, notEngaged }
}

// MARK: - Pieces

private struct StepIndicator: View {
    let step: LidSetupView.Step
    let showsApproval: Bool

    var body: some View {
        let steps: [(LidSetupView.Step, String)] = showsApproval
            ? [(.explain, "Explain"), (.approve, "Approve"), (.done, "Done")]
            : [(.explain, "Explain"), (.done, "Done")]
        let current = steps.firstIndex { $0.0 == step } ?? 0
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                Text("\(i + 1) · \(s.1)")
                    .font(.caption.weight(i == current ? .semibold : .regular))
                    .foregroundStyle(i == current ? Theme.accentLid : Color.secondary)
                if i < steps.count - 1 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(steps.count): \(steps[current].1)")
    }
}

private struct Bullet: View {
    let text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An inline red problem with optional ⓘ, [Copy details] and [Repair…].
struct SetupProblem: Equatable {
    var message: String
    var detail: String?
    var info: String?
    var canRepair = false
}

struct ProblemText: View {
    let problem: SetupProblem
    var repair: (() -> Void)?
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                Text(problem.message).fixedSize(horizontal: false, vertical: true)
                if let info = problem.info {
                    Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Why?")
                        .popover(isPresented: $showInfo) {
                            Text(info).padding(12).frame(width: 280).fixedSize(horizontal: false, vertical: true)
                        }
                }
            }
            .foregroundStyle(Theme.dangerText)
            if problem.detail != nil || (problem.canRepair && repair != nil) {
                HStack(spacing: 8) {
                    if let detail = problem.detail {
                        Button("Copy details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(detail, forType: .string)
                        }
                    }
                    if problem.canRepair, let repair { Button("Repair…", action: repair) }
                }
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Plain copy shared by the setup sheet and Lid & Safety. No jokes in errors.
enum LidSetupCopy {
    static let unsafeLocationInfo = "The helper runs as root, so it only runs from /Applications/Insomnia.app owned by the system. make install puts it there."

    static func capText(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : (minutes == 60 ? "1 hour" : "\(minutes / 60) hours")
    }

    static func problem(for error: LidSetupError) -> SetupProblem {
        switch error {
        case .cancelled:
            return SetupProblem(message: "Cancelled.")
        case .invalidUser:
            return SetupProblem(message: "Your user name can't be used in a sudoers rule.")
        case .includedirMissing:
            return SetupProblem(message: "/etc/sudoers doesn't include /etc/sudoers.d, so the rule can't be added. Nothing was changed.")
        case .scriptFailed(let code, let detail):
            return SetupProblem(message: "Setup didn't finish (code \(code)).", detail: detail.isEmpty ? "exit \(code)" : detail)
        case .registrationFailed(let code, let detail):
            return SetupProblem(message: "Couldn't add the helper (code \(code)).", detail: detail)
        case .helperUnreachable:
            return SetupProblem(message: "The helper isn't responding.", canRepair: true)
        case .unsafeLocation:
            return SetupProblem(message: "Install Insomnia with make install to use lid mode.", info: unsafeLocationInfo)
        case .unregisterIncomplete:
            return SetupProblem(message: "macOS didn't remove the helper. Switch Insomnia off in System Settings ▸ General ▸ Login Items & Extensions, or run make uninstall.")
        }
    }
}

// MARK: - Window presenter (the panel is transient, so setup gets its own small window)

@MainActor
enum LidSetupWindow {
    private static var window: NSWindow?
    private static var delegate: CloseObserver?

    /// `AppRouter.shared.startLidSetupHandler = { LidSetupWindow.show(requestedLid: true) }`.
    static func show(requestedLid: Bool, startAt: LidSetupView.Step? = nil) {
        AppRouter.shared.closePanel()
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = LidSetupView(requestedLid: requestedLid, startAt: startAt) { LidSetupWindow.close() }
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = "Lid Mode"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let observer = CloseObserver()
        w.delegate = observer
        delegate = observer
        window = w
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    fileprivate static func didClose() {
        ClosedLidController.shared.watchApproval(false)
        window?.delegate = nil
        window = nil
        delegate = nil
    }

    private final class CloseObserver: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { LidSetupWindow.didClose() }
        }
    }
}
