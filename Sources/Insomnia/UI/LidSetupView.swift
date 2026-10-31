import AppKit
import SwiftUI

// MARK: - Lid mode setup (docs/UX.md §6)
//
//   1 · Explain  → Set Up… (helper: SMAppService register(), no password; sudoers: one admin prompt)
//   2 · Approve  → System Settings ▸ General ▸ Login Items & Extensions (helper only; re-checked every 1 s)
//   3 · Done     → "Ready. Close the lid whenever." + a 10 s test drive
//
// One sheet, never a modal alert. Not Now (or Esc, or the close button) at any step leaves the setup as it is: a
// registered-but-unapproved helper stays that way, and H′ / Lid & Safety reopen step 2 directly. The lid switch
// reverts (UX §6), so it can be turned off again while the helper isn't ready.

struct LidSetupView: View {
    enum Step: Equatable { case explain, approve, done }

    /// The lid switch asked for lid mode: switch the setting on once setup completes. Every other entry point
    /// (welcome card, Dock, Lid & Safety) only sets up: finishing never starts a session the user didn't ask for.
    let requestedLid: Bool
    /// This view's token for ClosedLidController.watchApproval (one per window or sheet).
    let approvalWatcher: UUID
    let onClose: () -> Void

    @State private var step: Step
    @State private var busy = false
    @State private var problem: SetupProblem?
    @State private var drive: TestDrive = .idle
    @State private var closedAt: Date?
    /// The test drive's own short hold, if it started one (ended when the drive ends).
    @State private var driveHold: UUID?

    private var lid: ClosedLidController { ClosedLidController.shared }
    private var settings: Settings { Settings.shared }
    private var power: PowerMonitor { PowerMonitor.shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(requestedLid: Bool, startAt: Step? = nil, approvalWatcher: UUID = UUID(), onClose: @escaping () -> Void) {
        self.requestedLid = requestedLid
        self.approvalWatcher = approvalWatcher
        self.onClose = onClose
        _step = State(initialValue: startAt ?? Self.initialStep(ClosedLidController.shared.helper))
    }

    static func initialStep(_ helper: HelperStatus) -> Step {
        switch helper {
        case .requiresApproval, .daemonDisabled: return .approve
        case .installed: return .done
        default: return .explain
        }
    }

    /// Where Set Up… / Repair… lead, by the status they ended in (pure, unit-tested).
    enum Advance: Equatable {
        case finish
        case approve(SetupProblem?)
        case problem(SetupProblem)
    }

    static func advance(after helper: HelperStatus) -> Advance {
        switch helper {
        case .installed: return .finish
        // Sudoers: the safety daemon is off in Login Items: the same System Settings step, re-checked every second.
        case .requiresApproval, .daemonDisabled: return .approve(nil)
        case .unreachable, .versionMismatch:
            return .approve(SetupProblem(message: "The helper isn't responding.", canRepair: true))
        case .partial:
            return .problem(SetupProblem(message: "Setup didn't finish: part of it is missing or not working.", canRepair: true))
        case .notInstalled, .notFound, .unsafeLocation, .leftoverHelper:
            return .problem(SetupProblem(message: "Setup didn't finish. Check Settings ▸ Lid & Safety.", canRepair: true))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepIndicator(step: step, showsApproval: lid.backendKind != .sudoers || step == .approve)
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
                ProblemText(problem: problem, repair: { Task { await repair() } })
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
        let cap = PlainCopy.capLong(settings.lidMaxOnBatteryMinutes)
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
                Text(lid.backendKind == .sudoers
                     ? "General ▸ Login Items & Extensions ▸ turn on Insomnia's safety daemon (com.gdeml.insomnia.safety)."
                     : "General ▸ Login Items & Extensions ▸ turn on Insomnia.")
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
        .onAppear { lid.watchApproval(true, by: approvalWatcher) }
        .onDisappear { lid.watchApproval(false, by: approvalWatcher) }
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
                Button("Done") {
                    endDrive()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onDisappear { endDrive() }
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
        switch Self.advance(after: helper) {
        case .finish: finish()
        case .approve(let p):
            step = .approve
            problem = p
        case .problem(let p): problem = p
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
        LidSetupActions.finish(requestedLid: requestedLid, settings: settings)
    }

    private func notNow() {
        lid.watchApproval(false, by: approvalWatcher)
        LidSetupActions.revertSwitchIfUnfinished(helper: lid.helper, settings: settings)
        AwakeEngine.shared.narrate(.setupCancelled)   // UX §6: a quip, no error tone
        onClose()
    }

    private func startDrive() {
        drive = .waiting
        closedAt = nil
        endDrive()
        driveHold = LidSetupActions.beginTestDrive(engine: AwakeEngine.shared, settings: settings)
    }

    private func endDrive() {
        LidSetupActions.endTestDrive(driveHold, engine: AwakeEngine.shared)
        driveHold = nil
    }

    private func lidMoved(closed: Bool) {
        guard drive == .waiting || closedAt != nil else { return }
        if closed {
            if case .engaged = AwakeEngine.shared.lid {
                closedAt = Date()
            } else {
                drive = .notEngaged
                endDrive()
            }
            return
        }
        guard let start = closedAt else { return }
        closedAt = nil
        drive = Date().timeIntervalSince(start) >= 10 ? .survived : .tooShort
        endDrive()
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

/// What setup does to Settings and the engine, kept out of the view so it is unit-tested. Setup never writes the lid
/// switch except when the switch itself asked (`requestedLid`), and never starts an open-ended session.
@MainActor
enum LidSetupActions {
    /// Long enough to close the lid for 10 s and open it again; ends by itself if the sheet goes away mid-drive.
    static let testDriveDuration = AwakeDuration.minutes(2)

    /// Setup finished. Only the lid switch's own request turns lid mode on (with nothing awake, the engine then starts
    /// its usual hold, UX §2.2 H); the welcome card, the Dock and Lid & Safety leave the switch alone.
    static func finish(requestedLid: Bool, settings: Settings) {
        if requestedLid && !settings.closedLidMode { settings.closedLidMode = true }
    }

    /// Not Now, a cancelled prompt, or the window closed before Done: the switch reverts while the helper isn't ready,
    /// so it can't be left on with no way to turn it off (UX §6).
    static func revertSwitchIfUnfinished(helper: HelperStatus, settings: Settings) {
        if helper != .installed && settings.closedLidMode { settings.closedLidMode = false }
    }

    /// "Try it": a short manual hold with lid mode, never the lid switch. Never replaces the user's own manual hold
    /// (then the drive only works if that hold already has lid mode). Returns the hold to end afterwards, or nil.
    static func beginTestDrive(engine: AwakeEngine, settings: Settings) -> UUID? {
        guard engine.manualHold == nil else { return nil }
        engine.activate(testDriveDuration, source: .panel, options: AwakeOptions(screen: settings.keepScreenOn, lid: true))
        return engine.manualHold?.id
    }

    /// Ends the drive's hold if it is still the drive's own (the user may have replaced it meanwhile). With a While…
    /// hold running it's left to expire, since ending the manual hold would end that one too.
    static func endTestDrive(_ hold: UUID?, engine: AwakeEngine) {
        guard let hold, engine.manualHold?.id == hold, engine.babysitHold == nil else { return }
        engine.deactivate(.replaced)
    }
}

/// Plain copy shared by the setup sheet and Lid & Safety. No jokes in errors.
enum LidSetupCopy {
    static let unsafeLocationInfo = "The helper runs as root, so it only runs from /Applications/Insomnia.app owned by the system. make install puts it there."

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
    private static var watcher = UUID()

    /// `AppRouter.shared.startLidSetupHandler = { LidSetupWindow.show(requestedLid: $0) }`.
    static func show(requestedLid: Bool, startAt: LidSetupView.Step? = nil) {
        AppRouter.shared.closePanel()
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        watcher = UUID()
        let view = LidSetupView(requestedLid: requestedLid, startAt: startAt, approvalWatcher: watcher) {
            LidSetupWindow.close()
        }
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
        ClosedLidController.shared.watchApproval(false, by: watcher)
        LidSetupActions.revertSwitchIfUnfinished(helper: ClosedLidController.shared.helper, settings: Settings.shared)
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
