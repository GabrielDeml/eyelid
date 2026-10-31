import Darwin
import Foundation
import InsomniaShared
import Testing
@testable import Insomnia

// Regression tests for the 2026-10-31 review, group A (lid safety): docs/reviews/2026-10-31-code-review.md. Nothing
// here runs sudo, pmset, osascript or make: scripts run only with harmless stand-ins substituted for every privileged
// command, inside a temp directory that each test removes.

/// A temp directory removed when the test is done.
final class FixATempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("insomnia-fixa-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func write(_ name: String, _ text: String, executable: Bool = false) {
        FileManager.default.createFile(atPath: path(name), contents: Data(text.utf8),
                                       attributes: executable ? [.posixPermissions: 0o755] : nil)
    }
    func read(_ name: String) -> String { (try? String(contentsOfFile: path(name), encoding: .utf8)) ?? "" }
    func lines(_ name: String) -> [String] { read(name).split(separator: "\n").map(String.init) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }
}

/// Replaces `old` with `new`, failing the test if `old` isn't there (the script changed under the test).
private func substitute(_ script: String, _ old: String, _ new: String,
                        sourceLocation: SourceLocation = #_sourceLocation) -> String {
    #expect(script.contains(old), "missing \(old)", sourceLocation: sourceLocation)
    return script.replacingOccurrences(of: old, with: new)
}

/// Polls `condition` for up to `timeout` seconds (in the caller's isolation), then expects it.
private func expectEventually(_ timeout: TimeInterval = 5, isolation: isolated (any Actor)? = #isolation,
                              sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), sourceLocation: sourceLocation)
}

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

private func repoFile(_ path: String) -> String {
    (try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// Text of one Makefile target's recipe (up to the next blank line).
private func recipe(_ target: String) -> String {
    let make = repoFile("Makefile")
    guard let start = make.range(of: "\n\(target):") else { return "" }
    let rest = make[start.upperBound...]
    let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
}

private func offset(_ needle: String, in text: String) -> Int? {
    text.range(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
}

// MARK: - R1 / R76: make install / make uninstall

@Suite("Fix A: Makefile install and uninstall")
struct FixAMakefileTests {
    @Test func uninstallQuitsAndResetsBeforeRemovingTheSafetyNets() throws {
        let r = recipe("uninstall")
        let quit = try #require(offset("scripts/quit-running.sh", in: r))
        let unregister = try #require(offset("--unregister-helper", in: r))
        let reset = try #require(offset("sudo /usr/bin/pmset -a disablesleep 0", in: r))
        let verified = try #require(offset("SleepDisabled is still set; nothing removed", in: r))
        let markerGone = try #require(offset(#"rm -f "$$M""#, in: r))
        let bootout = try #require(offset("launchctl bootout system/com.gdeml.insomnia.safety", in: r))
        let rule = try #require(offset("/etc/sudoers.d/zz_insomnia /Library", in: r))
        let app = try #require(offset(#"sudo rm -rf "$(DEST)""#, in: r))
        #expect(quit < unregister && unregister < reset)
        #expect(reset < verified && verified < markerGone)
        #expect(markerGone < bootout && bootout < rule && rule < app)
        // The reset only runs when our marker exists (a foreign flag is never touched, Decision 23).
        #expect(r.contains(#"if [ -e "$$M" ]"#))
        // Same leftovers as SudoersBackend.uninstallScript.
        #expect(r.contains(SudoersBackend.bootMarker))
        #expect(r.contains("/etc/sudoers.d/.insomnia.*"))
        #expect(r.contains("/Library/LaunchDaemons/.insomnia.*"))
    }

    @Test func installQuitsTheRunningCopyBeforeTheSwapAndReopensIt() throws {
        let r = recipe("install")
        let verify = try #require(offset("scripts/lid-verify.sh --staged", in: r))
        let quit = try #require(offset("scripts/quit-running.sh", in: r))
        let abort = try #require(offset(#"echo "nothing installed"; exit 1"#, in: r))
        let swap = try #require(offset(#"sudo mv "$(DEST)""#, in: r))
        let reopen = try #require(offset(#"open "$(DEST)""#, in: r))
        #expect(verify < quit && quit < abort && abort < swap && swap < reopen)
    }

    @Test func quitScriptParsesAndNeverLaunchesTheApp() {
        let script = repoFile("scripts/quit-running.sh")
        #expect(Spawn.run("/bin/bash", ["-n", repoRoot.appendingPathComponent("scripts/quit-running.sh").path],
                          timeout: 10).status == 0)
        // The quit is guarded by `is running` (a bare `tell … to quit` launches a stopped app) and sent once.
        #expect(script.contains(#"if application id \"$ID\" is running then"#))
        #expect(script.components(separatedBy: "to quit").count == 2)
    }

    @Test func unregisterHelperQuitsTheAppEvenWithoutARegisteredHelper() throws {
        let source = repoFile("Sources/Insomnia/App/HelperCommands.swift")
        let quit = try #require(offset("quitRunningApp(timeout: 5)", in: source))
        let notRegistered = try #require(offset("No lid-mode helper is registered.", in: source))
        #expect(quit < notRegistered)
    }
}

// MARK: - R10: sudoers safety daemon

@Suite("Fix A: safety daemon script")
struct FixASafetyScriptTests {
    /// The real script with stand-in pmset / ioreg and a temp boot marker.
    private func run(_ dir: FixATempDir, root: String, battery: String = "", pmsetRC: Int = 0) -> Int32 {
        dir.write("pmset", "#!/bin/sh\necho \"$*\" >> '\(dir.path("pmset.log"))'\nexit \(pmsetRC)\n", executable: true)
        dir.write("root.txt", root)
        dir.write("battery.txt", battery)
        dir.write("ioreg", """
            #!/bin/sh
            case "$*" in *IOPMrootDomain*) cat '\(dir.path("root.txt"))' ;; *AppleSmartBattery*) cat '\(dir.path("battery.txt"))' ;; esac

            """, executable: true)
        var script = SudoersBackend.safetyScript
        script = substitute(script, SudoersBackend.bootMarker, dir.path("booted"))
        script = substitute(script, "/usr/bin/pmset", dir.path("pmset"))
        script = substitute(script, "/usr/sbin/ioreg", dir.path("ioreg"))
        return Spawn.run("/bin/sh", ["-c", script], timeout: 10).status
    }

    @Test func bootResetsEvenWhenTheFlagIsNotPublishedYet() {
        let dir = FixATempDir()
        #expect(run(dir, root: "") == 0)   // SleepDisabled absent from ioreg: must not read as 0
        #expect(dir.lines("pmset.log") == ["-a disablesleep 0"])
        #expect(dir.exists("booted"))
    }

    @Test func aFailedBootResetIsRetriedNextRun() {
        let dir = FixATempDir()
        _ = run(dir, root: "  \"SleepDisabled\" = Yes", pmsetRC: 1)
        #expect(!dir.exists("booted"))
        _ = run(dir, root: "  \"SleepDisabled\" = Yes")
        #expect(dir.lines("pmset.log").count == 2)
        #expect(dir.exists("booted"))
    }

    @Test func afterBootOnlyAVerifiedYesReachesTheBackstop() {
        let dir = FixATempDir()
        dir.write("booted", "")
        let lowBattery = "  \"ExternalConnected\" = No\n  \"CurrentCapacity\" = 9\n  \"MaxCapacity\" = 100\n"
        #expect(run(dir, root: "  \"SleepDisabled\" = No", battery: lowBattery) == 0)
        #expect(run(dir, root: "", battery: lowBattery) == 0)
        #expect(dir.read("pmset.log").isEmpty)
        _ = run(dir, root: "  \"SleepDisabled\" = Yes", battery: lowBattery)
        #expect(dir.lines("pmset.log") == ["-a disablesleep 0", "sleepnow"])
    }

    @Test func backstopIgnoresAGoodBattery() {
        let dir = FixATempDir()
        dir.write("booted", "")
        _ = run(dir, root: "  \"SleepDisabled\" = Yes",
                battery: "  \"ExternalConnected\" = No\n  \"CurrentCapacity\" = 50\n  \"MaxCapacity\" = 100\n")
        #expect(dir.read("pmset.log").isEmpty)
    }
}

// MARK: - R57 / R90: the sudoers watchdog, run for real with stand-ins

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite("Fix A: watchdog script")
struct FixAWatchdogTests {
    /// Watchdog.script with `echo reset` for the two sudo resets, `cat root.txt` for ioreg, and short timings.
    static func stubScript(_ dir: FixATempDir, settle: String = "0.2", timeout: Int = 30) -> String {
        var s = Watchdog.script
        s = substitute(s, "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0", "echo reset >> '\(dir.path("log"))'")
        s = substitute(s, "/usr/sbin/ioreg -r -c IOPMrootDomain -d 1", "/bin/cat '\(dir.path("root.txt"))'")
        s = substitute(s, "sleep \(Watchdog.resetSettle);", "sleep \(settle);")
        s = substitute(s, "read -r -t \(Int(HelperInfo.heartbeatTimeout))", "read -r -t \(timeout)")
        return s
    }

    private func arm(_ dir: FixATempDir, settle: String = "0.2", timeout: Int = 30, flag: String = "No",
                     markerPID: String = "\(getpid())", lost: Flag = Flag()) throws -> (Watchdog, LidMarker) {
        dir.write("root.txt", "  \"SleepDisabled\" = \(flag)\n")
        let marker = LidMarker(url: dir.url.appendingPathComponent("marker dir/lid-engaged"))
        #expect(marker.write())
        let dog = try Watchdog.arm(script: Self.stubScript(dir, settle: settle, timeout: timeout),
                                   environment: ["M": marker.url.path, "P": markerPID], onExit: { lost.set() })
        return (dog, marker)
    }

    @Test func eofResetsTwiceAndDeletesOurMarker() async throws {
        let dir = FixATempDir()
        let lost = Flag()
        let (dog, marker) = try arm(dir, lost: lost)
        #expect(dog.heartbeat())
        dog.abandon()
        await expectEventually { dir.lines("log").count == 2 && !marker.exists }
        #expect(!lost.isSet)   // an abandon is intentional
        // R90: renamed, not deleted, so the next launch still shows the recovery banner.
        #expect(FileManager.default.fileExists(atPath: marker.breadcrumb.path))
    }

    @Test func disarmExitsWithoutTouchingAnything() async throws {
        let dir = FixATempDir()
        let (dog, marker) = try arm(dir)
        dog.disarm()
        try await Task.sleep(for: .milliseconds(600))
        #expect(dir.read("log").isEmpty)
        #expect(marker.exists)
    }

    @Test func silenceResetsAndReportsTheLoss() async throws {
        let dir = FixATempDir()
        let lost = Flag()
        let (_, marker) = try arm(dir, timeout: 1, lost: lost)
        await expectEventually { dir.lines("log").count == 2 && lost.isSet }
        #expect(!marker.exists)
    }

    @Test func termResetsAndReportsTheLoss() async throws {
        let dir = FixATempDir()
        let lost = Flag()
        let (dog, _) = try arm(dir, lost: lost)
        try await Task.sleep(for: .milliseconds(100))   // let bash install its trap
        kill(dog.pid, SIGTERM)
        await expectEventually { dir.lines("log").count == 2 && lost.isSet }
    }

    @Test func anotherInstancesMarkerIsKept() async throws {
        let dir = FixATempDir()
        let (dog, marker) = try arm(dir, markerPID: "1")
        dog.abandon()
        await expectEventually { dir.lines("log").count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(marker.exists)
        #expect(!FileManager.default.fileExists(atPath: marker.breadcrumb.path))
    }

    @Test func markerIsKeptWhileTheFlagStillReadsOne() async throws {
        let dir = FixATempDir()
        let (dog, marker) = try arm(dir, flag: "Yes")
        dog.abandon()
        await expectEventually { dir.lines("log").count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(marker.exists)   // launch recovery still needs it
    }

    @Test func stopSupersededCancelsTheDelayedReset() async throws {
        let dir = FixATempDir()
        let (dog, _) = try arm(dir, settle: "1")
        dog.abandon()
        await expectEventually { dir.lines("log").count == 1 }
        dog.stopSuperseded()
        try await Task.sleep(for: .milliseconds(1500))
        #expect(dir.lines("log").count == 1)
    }
}

// MARK: - R74 / R75: SudoersBackend

private final class SudoLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func append(_ args: [String]) { lock.withLock { calls.append(args) } }
    var all: [[String]] { lock.withLock { calls } }
}

@Suite("Fix A: sudoers backend")
struct FixASudoersBackendTests {
    @Test func engageTimeoutHandsTheFlagToTheWatchdog() async {
        let dir = FixATempDir()
        dir.write("root.txt", "  \"SleepDisabled\" = No\n")
        let log = SudoLog()
        let marker = LidMarker(url: dir.url.appendingPathComponent("lid-engaged"))
        let backend = SudoersBackend(userName: "nobody", marker: marker,
                                     runSudo: { args in log.append(args); return args.last == "1" ? -1 : 0 },
                                     watchdogScript: FixAWatchdogTests.stubScript(dir))
        #expect(await backend.engage(onLost: {}) == -1)
        // The watchdog was abandoned, not left armed for a release to disarm: its reset / sleep / reset covers a
        // `pmset … 1` that lands late.
        #expect(await backend.heartbeat() == .safetyNetLost)
        await expectEventually { dir.lines("log").count == 2 }
        #expect(log.all == [["/usr/bin/pmset", "-a", "disablesleep", "1"]])
    }

    @Test func aNormalEngageKeepsTheWatchdogArmed() async {
        let dir = FixATempDir()
        dir.write("root.txt", "  \"SleepDisabled\" = No\n")
        let backend = SudoersBackend(userName: "nobody", marker: LidMarker(url: dir.url.appendingPathComponent("m")),
                                     runSudo: { _ in 0 }, watchdogScript: FixAWatchdogTests.stubScript(dir))
        #expect(await backend.engage(onLost: {}) == 0)
        #expect(await backend.heartbeat() == nil)
        await backend.abandon()
        await expectEventually { dir.lines("log").count == 2 }
    }

    @Test func ruleProbeIsListModeAndNeverSetsTheFlag() {
        // `sudo -n -l <command>` asks sudoers without running pmset, so a status refresh can't clear a foreign flag.
        #expect(SudoersBackend.ruleProbe == ["-l", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        let source = repoFile("Sources/Insomnia/Core/Privileged/SudoersBackend.swift")
        #expect(source.contains("rulePresent && runSudo(Self.ruleProbe) == 0"))
    }
}

// MARK: - R56: helper decisions

@Suite("Fix A: helper policy")
struct FixAHelperPolicyTests {
    @Test func statusOwnership() {
        #expect(HelperPolicy.statusOwnsFlag(ownsFlag: true, sessionUIDs: [], callerUID: 501))       // reset pending
        #expect(HelperPolicy.statusOwnsFlag(ownsFlag: true, sessionUIDs: [501], callerUID: 501))
        #expect(!HelperPolicy.statusOwnsFlag(ownsFlag: true, sessionUIDs: [502], callerUID: 501))   // other user
        #expect(!HelperPolicy.statusOwnsFlag(ownsFlag: false, sessionUIDs: [], callerUID: 501))
    }

    @Test func resetOnlyWhenTheLastSessionIsGone() {
        #expect(HelperPolicy.resetsAfterDrop(remainingSessions: 0, ownsFlag: true))
        #expect(!HelperPolicy.resetsAfterDrop(remainingSessions: 1, ownsFlag: true))
        #expect(!HelperPolicy.resetsAfterDrop(remainingSessions: 0, ownsFlag: false))
    }

    @Test func sigtermExitCode() {
        #expect(HelperPolicy.terminateExitCode(ownsFlag: false, resetSucceeded: false) == 0)
        #expect(HelperPolicy.terminateExitCode(ownsFlag: true, resetSucceeded: true) == 0)
        #expect(HelperPolicy.terminateExitCode(ownsFlag: true, resetSucceeded: false) == 75)   // respawned, retries
    }

    @Test func startUpResetsAnythingButAVerifiedZero() {
        #expect(HelperPolicy.startUpResets(flag: true))
        #expect(HelperPolicy.startUpResets(flag: nil))
        #expect(!HelperPolicy.startUpResets(flag: false))
    }
}

// MARK: - R58: the exact code requirements, and the scripts' copies of them

@Suite("Fix A: code requirements")
struct FixARequirementTests {
    @Test func exactRequirementStrings() {
        let tail = " and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\""
            + " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
        #expect(HelperInfo.clientRequirement(teamID: "ABCDE12345") == "identifier \"com.gdeml.Insomnia\"" + tail)
        #expect(HelperInfo.helperRequirement(teamID: "ABCDE12345") == "identifier \"com.gdeml.Insomnia.helper\"" + tail)
    }

    @Test func scriptsCheckTheSameRequirements() throws {
        for (file, teamVar) in [("scripts/build.sh", "$APP_TEAM"), ("scripts/lid-verify.sh", "$TEAM")] {
            let text = repoFile(file)
            let line = try #require(text.split(separator: "\n").first { $0.contains("req() { echo \"") }, "\(file)")
            let start = try #require(line.range(of: "echo \""))
            let end = try #require(line.range(of: "\"; }", options: .backwards))
            let template = String(line[start.upperBound..<end.lowerBound]).replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: teamVar, with: "ABCDE12345")
            #expect(template.replacingOccurrences(of: "$1", with: HelperInfo.appBundleID)
                    == HelperInfo.clientRequirement(teamID: "ABCDE12345"), "\(file)")
            #expect(template.replacingOccurrences(of: "$1", with: HelperInfo.label)
                    == HelperInfo.helperRequirement(teamID: "ABCDE12345"), "\(file)")
        }
    }
}

// MARK: - R64: heartbeat reply mapping

@Suite("Fix A: helper heartbeat mapping")
struct FixAHeartbeatMappingTests {
    @Test func replies() {
        #expect(HelperBackend.heartbeatError(HelperResult.ok.rawValue) == nil)
        #expect(HelperBackend.heartbeatError(HelperResult.overridden.rawValue) == .overridden)
        #expect(HelperBackend.heartbeatError(HelperResult.notEngaged.rawValue) == .safetyNetLost)
        #expect(HelperBackend.heartbeatError(HelperResult.backstop.rawValue) == .safetyNetLost)
        #expect(HelperBackend.heartbeatError(-1) == .safetyNetLost)   // no answer
    }
}

// MARK: - R39 / R40 / R44 / R41: setup and the test drive

@MainActor
@Suite("Fix A: lid setup", .serialized)
struct FixALidSetupTests {
    @Test func testDriveUsesItsOwnShortHoldAndNeverTheSwitch() {
        let h = Harness()
        let hold = LidSetupActions.beginTestDrive(engine: h.engine, settings: h.settings)
        #expect(hold != nil)
        #expect(!h.settings.closedLidMode)
        #expect(h.engine.manualHold?.options.lid == true)
        #expect(h.engine.manualHold?.end == h.clock.now.addingTimeInterval(120))
        #expect(h.lid.desired == true)
        LidSetupActions.endTestDrive(hold, engine: h.engine)
        #expect(h.engine.manualHold == nil)
        #expect(h.engine.status == .asleep)
        #expect(h.lid.desired == false)
        #expect(!h.settings.closedLidMode)
    }

    @Test func testDriveNeverReplacesTheUsersHold() {
        let h = Harness()
        h.engine.activate(.indefinite, source: .panel)
        let users = h.engine.manualHold?.id
        #expect(LidSetupActions.beginTestDrive(engine: h.engine, settings: h.settings) == nil)
        #expect(h.engine.manualHold?.id == users)
        LidSetupActions.endTestDrive(nil, engine: h.engine)
        #expect(h.engine.manualHold?.id == users)
    }

    @Test func endingTheDriveLeavesAHoldTheUserStartedMeanwhile() {
        let h = Harness()
        let hold = LidSetupActions.beginTestDrive(engine: h.engine, settings: h.settings)
        h.engine.activate(.minutes(60), source: .panel)
        LidSetupActions.endTestDrive(hold, engine: h.engine)
        #expect(h.engine.manualHold != nil)
    }

    @Test func finishingWithoutTheSwitchStartsNothing() async {
        let h = Harness()
        await h.engine.start()
        LidSetupActions.finish(requestedLid: false, settings: h.settings)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(!h.settings.closedLidMode)
        #expect(h.engine.status == .asleep)
        LidSetupActions.finish(requestedLid: true, settings: h.settings)
        #expect(h.settings.closedLidMode)
        await h.engine.prepareForQuit()
    }

    @Test func onlyTheLidSwitchRequestsLid() {
        let saved = AppRouter.shared.startLidSetupHandler
        defer { AppRouter.shared.startLidSetupHandler = saved }
        var requests: [Bool] = []
        AppRouter.shared.startLidSetupHandler = { requests.append($0) }
        var state = PanelState()
        state.helper = .notInstalled
        PanelModel.fixed(state).send(.setLid(true))
        AppRouter.shared.startLidSetup()   // welcome card, Dock, panel "Setup needed ›"
        #expect(requests == [true, false])
    }

    @Test func notNowRevertsTheSwitchWhileTheHelperIsntReady() {
        let settings = Settings(defaults: ScratchDefaults.make("FixA"))
        settings.closedLidMode = true
        LidSetupActions.revertSwitchIfUnfinished(helper: .installed, settings: settings)
        #expect(settings.closedLidMode)
        LidSetupActions.revertSwitchIfUnfinished(helper: .requiresApproval, settings: settings)
        #expect(!settings.closedLidMode)
    }

    @Test func setupEndingsAllSaySomething() {
        #expect(LidSetupView.advance(after: .installed) == .finish)
        #expect(LidSetupView.advance(after: .requiresApproval) == .approve(nil))
        #expect(LidSetupView.advance(after: .daemonDisabled) == .approve(nil))
        #expect(LidSetupView.initialStep(.daemonDisabled) == .approve)
        if case .approve(let p?) = LidSetupView.advance(after: .unreachable) { #expect(p.canRepair) } else {
            Issue.record("unreachable should show the approval step with a problem")
        }
        for status: HelperStatus in [.partial(sudoers: false, safetyDaemon: true), .notInstalled, .leftoverHelper] {
            if case .problem(let p) = LidSetupView.advance(after: status) {
                #expect(!p.message.isEmpty)
            } else {
                Issue.record("\(status) must show a problem, not stay silent")
            }
        }
    }
}

// MARK: - ClosedLidController: R42, R46, R60–R63, R65, R73, R88, R89

/// A controller on the fake backend and flag, with its own marker directory.
@MainActor
final class LidRig {
    let system = LidFakeSystem()
    let backend: LidFakeBackend
    let power = FakePower()
    let dir: URL
    let marker: LidMarker
    let controller: ClosedLidController

    init(kind: PrivilegeBackendKind = .helper, abandonWait: Duration = .zero, lostWait: Duration = .zero) async {
        backend = LidFakeBackend(kind: kind, system: system)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("insomnia-lid-\(UUID().uuidString)")
        marker = LidMarker(url: dir.appendingPathComponent("lid-engaged"))
        let b = backend
        let reconciler = LidReconciler(makeBackend: { b }, system: system, marker: marker, readbackInterval: .zero,
                                       abandonWait: abandonWait, lostWait: lostWait)
        controller = ClosedLidController(power: power, refreshLid: {}, reconciler: reconciler, liveSystem: false)
        await controller.start()
        await controller.refreshHelper()
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func engage() async {
        controller.setDesired(true)
        await controller.idle()
    }

    /// Engaged, then a release that can't clear the flag.
    func makeStuck() async {
        await engage()
        backend.configure {
            $0.releaseResult = -1
            $0.abandonClearsFlag = false
        }
        controller.setDesired(false)
        await controller.idle()
    }

    func waitFor(_ status: LidStatus, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.status != status && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            await controller.idle()
        }
        return controller.status == status
    }
}

@MainActor
@Suite("Fix A: lid controller", .serialized)
struct FixALidControllerTests {
    // R88
    @Test func cancelledRemoveReEngages() async {
        let rig = await LidRig()
        await rig.engage()
        rig.backend.configure { $0.uninstallError = .cancelled }
        await #expect(throws: LidSetupError.cancelled) { try await rig.controller.uninstall() }
        #expect(rig.controller.status == .engaged(lidClosed: false))
        #expect(rig.backend.calls == ["engage", "release", "uninstall", "engage"])
    }

    @Test func resetWithPasswordReEngagesWhenStillWanted() async {
        let rig = await LidRig()
        await rig.makeStuck()
        rig.controller.setDesired(true)
        await rig.controller.idle()
        #expect(await rig.controller.resetWithPassword() == nil)
        #expect(rig.controller.status == .engaged(lidClosed: false))
    }

    // R42
    @Test func resetWithPasswordReportsFailures() async {
        let rig = await LidRig()
        await rig.makeStuck()
        rig.backend.configure { $0.resetError = .scriptFailed(code: 1, detail: "nope") }
        #expect(await rig.controller.resetWithPassword() == .scriptFailed(code: 1, detail: "nope"))
        #expect(rig.controller.status == .stuck)
        rig.backend.configure { $0.resetError = .cancelled }
        #expect(await rig.controller.resetWithPassword() == nil)   // a cancelled prompt says nothing
        #expect(rig.controller.status == .stuck)
    }

    @Test func resetWithPasswordSkipsThePromptWhenTheFlagIsAlreadyClear() async {
        let rig = await LidRig()
        await rig.makeStuck()
        rig.system.flag = false
        #expect(await rig.controller.resetWithPassword() == nil)
        #expect(rig.controller.status == .off)
        #expect(!rig.backend.calls.contains("resetWithPassword"))
        #expect(!rig.marker.exists)
    }

    @Test func repeatedResetClicksPromptOnce() async {
        let rig = await LidRig()
        await rig.makeStuck()
        async let first = rig.controller.resetWithPassword()
        async let second = rig.controller.resetWithPassword()
        _ = await (first, second)
        #expect(rig.backend.calls.filter { $0 == "resetWithPassword" }.count == 1)
    }

    // R89
    @Test func otherUserResumesOnceTheFlagIsClear() async {
        let rig = await LidRig()
        rig.backend.configure { $0.engageResult = HelperResult.otherUser.rawValue }
        await rig.engage()
        #expect(rig.controller.status == .error(.otherUser))
        rig.system.flag = true   // the other user's lid mode
        await rig.controller.refreshHelper()
        await rig.controller.idle()
        #expect(rig.controller.status == .error(.otherUser))
        rig.backend.configure { $0.engageResult = 0 }
        rig.system.flag = false  // they let go
        await rig.controller.refreshHelper()
        await rig.controller.idle()
        #expect(rig.controller.status == .engaged(lidClosed: false))
    }

    // R61
    @Test func recoveryLeavesAForeignFlagAlone() async {
        let rig = await LidRig()
        #expect(rig.marker.write())
        rig.system.flag = true
        #expect(await rig.controller.recoverIfNeeded() == false)
        #expect(rig.controller.foreignSleepDisabled)
        #expect(rig.system.flag == true)
        #expect(!rig.marker.exists)
        #expect(rig.backend.calls.isEmpty)
    }

    @Test func recoveryWithASilentHelperIsStuck() async {
        let rig = await LidRig()
        #expect(rig.marker.write())
        rig.system.flag = true
        rig.backend.configure { $0.ownsUnknown = true }
        #expect(await rig.controller.recoverIfNeeded() == false)
        #expect(rig.controller.status == .stuck)
        #expect(rig.marker.exists)
    }

    @Test func recoveryThatCantClearOurFlagIsStuck() async {
        let rig = await LidRig()
        #expect(rig.marker.write())
        rig.system.flag = true
        rig.backend.configure {
            $0.owns = true
            $0.releaseResult = -1
            $0.abandonClearsFlag = false
        }
        #expect(await rig.controller.recoverIfNeeded() == false)
        #expect(rig.controller.status == .stuck)
        #expect(rig.backend.calls == ["release", "abandon"])
    }

    // R62
    @Test func driftOnAPowerSourceChangeReportsAnOverride() async {
        let rig = await LidRig()
        await rig.engage()
        rig.system.flag = false        // cleared by someone else, safety net alive
        rig.power.isOnAC.toggle()
        rig.controller.powerChanged()
        await rig.controller.idle()
        #expect(rig.controller.status == .error(.overridden))
    }

    @Test func driftCheckWhileHealthyChangesNothing() async {
        let rig = await LidRig()
        await rig.engage()
        rig.power.isOnAC.toggle()
        rig.controller.powerChanged()
        await rig.controller.idle()
        #expect(rig.controller.status == .engaged(lidClosed: false))
        #expect(rig.backend.calls == ["engage"])
    }

    @Test func stuckRecheckGoesOffOrReEngages() async {
        let off = await LidRig()
        await off.makeStuck()
        off.controller.stuckCheckForTesting()
        await off.controller.idle()
        #expect(off.controller.status == .stuck)   // still 1
        off.system.flag = false
        off.controller.stuckCheckForTesting()
        await off.controller.idle()
        #expect(off.controller.status == .off)
        #expect(!off.marker.exists)

        let again = await LidRig()
        await again.makeStuck()
        again.controller.setDesired(true)
        again.system.flag = false
        again.controller.stuckCheckForTesting()
        await again.controller.idle()
        #expect(again.controller.status == .engaged(lidClosed: false))
    }

    // R63
    @Test func aLostSafetyNetWaitsLongerThanAPlainRelease() async {
        let plain = await LidRig(abandonWait: .milliseconds(20), lostWait: .seconds(3))
        await plain.engage()
        plain.backend.configure {
            $0.releaseResult = -1
            $0.abandonClearsFlagAfter = .milliseconds(300)
        }
        plain.controller.setDesired(false)
        await plain.controller.idle()
        #expect(plain.controller.status == .stuck)

        let heartbeat = await LidRig(abandonWait: .milliseconds(20), lostWait: .seconds(3))
        await heartbeat.engage()
        heartbeat.backend.configure {
            $0.heartbeatResult = .safetyNetLost
            $0.releaseResult = -1
            $0.abandonClearsFlagAfter = .milliseconds(300)
        }
        heartbeat.controller.heartbeatForTesting()
        await heartbeat.controller.idle()
        #expect(heartbeat.controller.status == .error(.safetyNetLost))

        let lost = await LidRig(abandonWait: .milliseconds(20), lostWait: .seconds(3))
        await lost.engage()
        lost.backend.configure {
            $0.releaseResult = -1
            $0.abandonClearsFlagAfter = .milliseconds(300)
        }
        lost.backend.fireLost()
        #expect(await lost.waitFor(.error(.safetyNetLost)))
    }

    // R65
    @Test func anEvenBurstOfFlipsDoesNothing() async {
        let rig = await LidRig()
        for on in [true, false, true, false] { rig.controller.setDesired(on) }
        await rig.controller.idle()
        #expect(rig.backend.calls.isEmpty)
        #expect(rig.controller.status == .off)
    }

    @Test func anOddBurstEngagesOnce() async {
        let rig = await LidRig()
        for on in [true, false, true] { rig.controller.setDesired(on) }
        await rig.controller.idle()
        #expect(rig.backend.calls == ["engage"])
    }

    @Test func aFlipDuringEngageReleasesAfterIt() async {
        let rig = await LidRig()
        rig.backend.configure { $0.engageBlocked = true }
        rig.controller.setDesired(true)
        await expectEventually { rig.backend.calls == ["engage"] }
        rig.controller.setDesired(false)
        rig.backend.configure { $0.engageBlocked = false }
        await rig.controller.idle()
        #expect(rig.backend.calls == ["engage", "release"])
        #expect(rig.controller.status == .off)
    }

    // R60
    @Test func quitTimeoutAbandonsAndNeverReEngages() async {
        let rig = await LidRig()
        await rig.engage()
        rig.backend.configure { $0.releaseBlocked = true }
        let start = Date()
        await rig.controller.releaseForQuit(timeout: .milliseconds(50))
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(rig.backend.calls == ["engage", "release", "abandon"])
        rig.backend.configure { $0.releaseBlocked = false }
        await rig.controller.idle()
        rig.controller.setDesired(true)
        await rig.controller.idle()
        #expect(!rig.backend.calls.dropFirst().contains("engage"))
    }

    // R46 / R73
    @Test func twoSetupViewsKeepOnePollAlive() async throws {
        let rig = await LidRig()
        rig.backend.configure { $0.status = .requiresApproval }
        await rig.controller.refreshHelper()
        let sheet = UUID(), window = UUID()
        rig.controller.watchApproval(true, by: sheet)
        rig.controller.watchApproval(true, by: window)
        rig.controller.watchApproval(false, by: sheet)   // the sheet closes; the window still waits
        let before = rig.backend.statusCalls
        try await Task.sleep(for: .milliseconds(1300))
        #expect(rig.backend.statusCalls > before)
        rig.controller.watchApproval(false, by: window)
        try await Task.sleep(for: .milliseconds(50))
        let stopped = rig.backend.statusCalls
        try await Task.sleep(for: .milliseconds(1300))
        #expect(rig.backend.statusCalls == stopped)
    }

    @Test func aCancelledPollNeverOrphansItsReplacement() async throws {
        let rig = await LidRig()
        rig.backend.configure { $0.status = .requiresApproval }
        await rig.controller.refreshHelper()
        let view = UUID()
        rig.controller.watchApproval(true, by: view)
        rig.controller.watchApproval(false, by: view)
        rig.controller.watchApproval(true, by: view)
        try await Task.sleep(for: .milliseconds(50))     // the cancelled poll finishes
        rig.controller.watchApproval(false, by: view)    // must stop the replacement
        try await Task.sleep(for: .milliseconds(50))
        let stopped = rig.backend.statusCalls
        try await Task.sleep(for: .milliseconds(1300))
        #expect(rig.backend.statusCalls == stopped)
    }
}
