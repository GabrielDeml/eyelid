import Darwin
import Foundation
import Testing
@testable import Insomnia
import InsomniaShared

// Regression tests for the verification follow-ups to the 2026-10-31 review fixes. Each test names its finding.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - R46: the Settings sheet keeps one approval token across re-renders

@Suite("Follow-ups: lid setup", .serialized)
@MainActor
struct FollowUpLidSetupTests {
    @Test func rebuiltSheetViewStopsThePollItStarted() async throws {
        let sheet = LidSafetyTab.SetupSheet(startAt: .approve)
        let appeared = LidSafetyTab.setupView(for: sheet) {}
        let rebuilt = LidSafetyTab.setupView(for: sheet) {}   // LidSafetyTab's body ran again (lid.helper changed)
        #expect(appeared.approvalWatcher == rebuilt.approvalWatcher)
        #expect(appeared.approvalWatcher == sheet.id)

        let rig = await LidRig()
        rig.backend.configure { $0.status = .requiresApproval }
        await rig.controller.refreshHelper()
        rig.controller.watchApproval(true, by: appeared.approvalWatcher)    // .onAppear
        rig.controller.watchApproval(false, by: rebuilt.approvalWatcher)    // .onDisappear / Not Now, newer value
        try await Task.sleep(for: .milliseconds(50))
        let stopped = rig.backend.statusCalls
        try await Task.sleep(for: .milliseconds(1300))
        #expect(rig.backend.statusCalls == stopped)
    }

    // MARK: R42: a failed reset from the panel, Dock or notification is not silent

    @Test func failedResetPostsTheStuckNotificationAgain() async {
        let posted = Box<[(NotificationID, String, String)]>([])
        await LidResetAction.run(reset: { .scriptFailed(code: 1, detail: "nope") },
                                 post: { posted.value.append(($0, $1, $2)) }).value
        #expect(posted.value.count == 1)
        #expect(posted.value.first?.0 == .lidStuck)
        #expect(posted.value.first?.1 == "Lid mode is still stuck on")
        #expect(posted.value.first?.2.contains(LidSetupCopy.problem(for: .scriptFailed(code: 1, detail: "nope")).message) == true)

        // Success, a cancelled prompt (nil from resetWithPassword) or a reset already running: nothing posted.
        await LidResetAction.run(reset: { nil }, post: { posted.value.append(($0, $1, $2)) }).value
        #expect(posted.value.count == 1)
    }

    // MARK: R90: the sudoers watchdog's recovery still gives the banner at the next launch

    @Test func watchdogBreadcrumbGivesTheBannerAndNeverMakesTheFlagOurs() async throws {
        let rig = await LidRig(kind: .sudoers)
        try FileManager.default.createDirectory(at: rig.dir, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: rig.marker.breadcrumb.path, contents: Data()))
        rig.system.flag = true   // set by something else since the watchdog's reset
        #expect(await rig.controller.recoverIfNeeded())
        #expect(!FileManager.default.fileExists(atPath: rig.marker.breadcrumb.path))
        #expect(rig.system.flag == true)
        #expect(!rig.backend.calls.contains("release"))
        #expect(await rig.controller.recoverIfNeeded() == false)   // once
    }

    @Test func writingOrDeletingTheMarkerClearsTheBreadcrumb() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("insomnia-crumb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = LidMarker(url: dir.appendingPathComponent("lid-engaged"))
        #expect(marker.breadcrumb.lastPathComponent == "lid-engaged.recovered")
        #expect(Watchdog.script.contains(#"/bin/mv -f "$M" "$M.recovered""#))

        FileManager.default.createFile(atPath: marker.breadcrumb.path, contents: Data())
        #expect(marker.write())   // a new engagement while still running
        #expect(!FileManager.default.fileExists(atPath: marker.breadcrumb.path))

        FileManager.default.createFile(atPath: marker.breadcrumb.path, contents: Data())
        marker.delete()           // a clean release while still running
        #expect(!marker.exists)
        #expect(!FileManager.default.fileExists(atPath: marker.breadcrumb.path))
    }
}

// MARK: - R1: scripts/quit-running.sh fails closed and quits every copy

@Suite("Follow-ups: quit-running.sh", .serialized)
@MainActor
struct FollowUpQuitScriptTests {
    /// Never the real app: a bundle id nobody has and a pattern only our own `sleep` children match.
    private static let fakeID = "com.example.insomnia-quit-test.nonexistent"
    private static let sleepArg = "47.4183"
    private static let pattern = "^/bin/sleep 47\\.4183$"

    private func runScript(pattern: String) -> Spawn.Result {
        let script = repoRoot.appendingPathComponent("scripts/quit-running.sh").path
        return Spawn.run("/bin/bash", [script, "3"],
                         environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                       "INSOMNIA_QUIT_TEST_ID": Self.fakeID,
                                       "INSOMNIA_QUIT_TEST_PATTERN": pattern],
                         timeout: 15, captureStderr: true)
    }

    @Test func theOverridesAreTheOnlyWayToRetarget() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("scripts/quit-running.sh"), encoding: .utf8)
        #expect(text.contains("ID=${INSOMNIA_QUIT_TEST_ID:-com.gdeml.Insomnia}"))
        #expect(text.contains("PATTERN=${INSOMNIA_QUIT_TEST_PATTERN:-'/Contents/MacOS/Insomnia$'}"))
    }

    @Test func nothingRunningExitsZero() {
        #expect(runScript(pattern: Self.pattern).status == 0)
    }

    @Test func cantTellCountsAsRunning() {
        let r = runScript(pattern: "[")   // pgrep fails (exit 2)
        #expect(r.status == 1)
        #expect(r.stderr.contains("Can't tell"))
    }

    @Test func everyRunningCopyGetsOneQuit() async throws {
        var pids: [pid_t] = []
        for _ in 0..<2 {
            guard case .success(let pid) = CLIRunner.spawn(["/bin/sleep", Self.sleepArg], inheritedIgnored: []) else {
                Issue.record("spawn failed")
                return
            }
            pids.append(pid)
        }
        // Reap at once, so a quit copy doesn't linger as a zombie.
        let reaped = pids.map { pid in
            Task.detached { () -> Int32 in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                return status
            }
        }
        let r = runScript(pattern: Self.pattern)
        for pid in pids { kill(pid, SIGKILL) }   // only if the script failed to quit them
        #expect(r.status == 3, "\(r.stderr)")
        for task in reaped {
            #expect(WaitStatus(await task.value) == .signaled(SIGTERM))
        }
    }
}

// MARK: - R34, R95: panel presentation

@Suite("Follow-ups: panel presentation", .serialized)
@MainActor
struct FollowUpPanelTests {
    @Test func aPopoverThatReplacedTheWindowDoesNotKeepItOrderedIn() {
        // The `.replace` path: the window fades out, then the popover opens (isOpen, but not the window).
        #expect(PanelHost.fadeOutOrdersOut(tokenIsCurrent: true, windowIsOpen: false))
        // Shown again in the window during the fade: the newer fade-in owns it.
        #expect(!PanelHost.fadeOutOrdersOut(tokenIsCurrent: false, windowIsOpen: true))
        #expect(!PanelHost.fadeOutOrdersOut(tokenIsCurrent: true, windowIsOpen: true))
        #expect(!PanelHost.fadeOutOrdersOut(tokenIsCurrent: false, windowIsOpen: false))
    }

    @Test func heldBackCardWaitsAgainWhenThePanelReopenedInTheSameTurn() async {
        let settings = Settings(defaults: ScratchDefaults.make("FollowUpR95"))
        let card = HiddenItemCardController(settings: settings)
        card.showIfNeeded(panelOpen: true)
        #expect(card.isPending)
        // popover → window: close() (onClose) and the new host opening happen in one turn.
        card.panelDidClose(itemStillHidden: true) { true }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        #expect(card.isPending)                      // held back again, not shown over the panel
        #expect(!settings.hiddenItemCardShown)
    }
}

// MARK: - R23: an app's PID only hides the app's own names

@Suite("Follow-ups: app PIDs and process names")
struct FollowUpAppNameTests {
    @Test func guiPythonStillMatchesItsScriptAndAliases() {
        let apps = [
            RunningAppInfo(bundleID: "com.anthropic.claudefordesktop", name: "Claude", pid: 10, isRegular: true,
                           executable: "Claude"),
            RunningAppInfo(bundleID: "org.python.python", name: "Python", pid: 20, isRegular: true, executable: "Python"),
            RunningAppInfo(bundleID: "com.example.agent", name: "agent", pid: 30, isRegular: false, hasUI: false),
        ]
        let names = WatchMonitor.appNames(apps)
        #expect(names == [10: ["claude"]])
        let hits: [String: [ProcessHit]] = [
            "claude": [ProcessHit(pid: 10, uid: 501), ProcessHit(pid: 11, uid: 501)],
            "python3": [ProcessHit(pid: 20, uid: 501)],
            "train.py": [ProcessHit(pid: 20, uid: 501)],
            "agent": [ProcessHit(pid: 30, uid: 501)],
            "other": [ProcessHit(pid: 10, uid: 501)],   // the app's PID under a name that isn't the app's
        ]
        let kept = ProcessMatcher.excludingApps(hits, apps: names)
        #expect(kept["claude"]?.map(\.pid) == [11])
        #expect(kept["python3"]?.map(\.pid) == [20])
        #expect(kept["train.py"]?.map(\.pid) == [20])
        #expect(kept["agent"]?.map(\.pid) == [30])
        #expect(kept["other"]?.map(\.pid) == [10])
    }
}

// MARK: - R12: the mission report survives lid mode re-engaging after a guard released it

@MainActor
private final class ReopenNarrator: Narrating {
    func line(_ m: Moment, _ p: Personality, now: Date) -> String? {
        if case .lidReopened = m { return "welcome back" }
        return nil
    }
    func dateLine(_ p: Personality, now: Date) -> String? { nil }
    func notification(_ id: NotificationID, _ p: Personality, context: [String: String]) -> (title: String, body: String) {
        FallbackCopy.notification(id, context: context)
    }
}

@Suite("Follow-ups: engine", .serialized)
@MainActor
struct FollowUpEngineTests {
    @Test func reopenReportSurvivesReEngagementAfterTheCapTripped() {
        let h = Harness()
        let narrator = ReopenNarrator()
        h.engine.narrator = narrator
        h.settings.lidBatteryCalloutShown = true
        h.settings.closedLidMode = true
        h.settings.lidMaxOnBatteryMinutes = 15
        h.engine.activate(.indefinite, source: .panel)
        h.power.isLidClosed = true
        h.lid.converge(lidClosed: true)
        h.clock.advance(16 * 60)
        h.engine.reevaluate()
        #expect(h.engine.latched)
        h.lid.converge(lidClosed: true)              // the cap released lid mode while closed

        // Lid opens: the report arrives with the controller still off, then lid mode comes back on.
        h.power.isLidClosed = false
        let report = ReopenReport(closedFor: 16 * 60, batteryStart: 80, batteryEnd: 70, worstThermal: .nominal)
        h.lid.reopenReport = report
        h.lid.onChange?()
        #expect(h.engine.banner == .reopen(report))
        #expect(h.engine.quip == "welcome back")
        for status in [LidStatus.engaging, .engaged(lidClosed: false)] {
            h.lid.status = status
            h.lid.onChange?()
            #expect(h.engine.lid == status)
            #expect(h.engine.banner == .reopen(report), "after \(status)")
            #expect(h.engine.quip == "welcome back", "after \(status)")
        }

        // A lid problem or an awake-status change still clears it.
        h.lid.status = .error(.readbackMismatch)
        h.lid.onChange?()
        #expect(h.engine.banner == nil)
    }
}
