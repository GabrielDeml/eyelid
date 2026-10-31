import Foundation
import Observation
import Testing
@testable import Insomnia

// Review fixes, group C (watching): R19–R27. Process matching is tested as a pure, table-driven function over realistic
// process records (shapes taken from a live process table: name, path, argv, uid, isApp); WatchMonitor behaviour with
// a fake WatchSystem (no timers); a few live checks against the real process table (pid 1, our own pid).

private let me: uid_t = 501

/// One row of a process table as the scan sees it.
private struct Proc {
    var pid: Int32
    var name: String           // proc_name (own processes) / comm (other users')
    var path: String?          // proc_pidpath
    var argv: [String] = []    // KERN_PROCARGS2; unreadable (empty) for other users' processes
    var uid: uid_t = me
    var isApp = false          // an NSRunningApplication with a UI (regular or LSUIElement)
}

private let python314 = "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"
private let pythonCLT = "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
private let claudeApp = "/Applications/Claude.app/Contents/MacOS/Claude"
private let claudeHelper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

private let table: [Proc] = [
    // `claude` CLI: proc_name and executable are its version; only argv[0] says "claude".
    Proc(pid: 9137, name: "2.1.310", path: "/Users/x/.local/share/claude/versions/2.1.310", argv: ["claude", "-c"]),
    // Claude.app and its helpers.
    Proc(pid: 53135, name: "Claude", path: claudeApp, argv: [claudeApp], isApp: true),
    Proc(pid: 53140, name: "Claude Helper", path: claudeHelper, argv: [claudeHelper, "--type=gpu-process"]),
    Proc(pid: 52604, name: "chrome-native-h", path: "/Applications/Claude.app/Contents/Helpers/chrome-native-host",
         argv: ["/Applications/Claude.app/Contents/Helpers/chrome-native-host", "chrome-extension://abc/"]),
    // `python3 train.py` (Homebrew) and `/usr/bin/python3 train.py` (CLT) re-exec into the framework's Python.app.
    // R23 follow-up: this one has a matplotlib (macosx backend) window open, so it is also a regular app named
    // "Python"; python3 and train.py must still find it.
    Proc(pid: 33189, name: "Python", path: python314, argv: [python314, "-u", "train.py"], isApp: true),
    Proc(pid: 33190, name: "Python", path: pythonCLT, argv: [pythonCLT, "train.py"]),
    // uv venv: the real binary is python3.11, argv[0] is the venv's `python`.
    Proc(pid: 10238, name: "python3.11", path: "/Users/x/.local/share/uv/python/cpython-3.11.15-macos-aarch64-none/bin/python3.11",
         argv: ["/Users/x/proj/.venv/bin/python", "-m", "ipykernel_launcher", "-f", "k.json"]),
    // `npm run build`: npm sets process.title, which overwrites the argv area.
    Proc(pid: 7000, name: "node", path: "/opt/homebrew/Cellar/node/23.10.0_1/bin/node", argv: ["npm run build", "", "", ""]),
    // `codex`: node running a script.
    Proc(pid: 7001, name: "node", path: "/opt/homebrew/Cellar/node/23.10.0_1/bin/node",
         argv: ["node", "/opt/homebrew/bin/codex", "exec"]),
    // A node under a path with a space and no arguments: not a retitle.
    Proc(pid: 7002, name: "node", path: "/Applications/My Tools/node", argv: ["/Applications/My Tools/node", ""]),
    // Root's processes: argv unreadable, PROC_PIDTBSDINFO refused; comm + path still work.
    Proc(pid: 1, name: "launchd", path: "/sbin/launchd", uid: 0),
    Proc(pid: 4242, name: "rsync", path: "/usr/bin/rsync", argv: ["rsync", "-a", "src", "dst"], uid: 0),
    // LSUIElement app vs its CLI.
    Proc(pid: 800, name: "Docker", path: "/Applications/Docker.app/Contents/MacOS/Docker", isApp: true),
    Proc(pid: 801, name: "docker", path: "/usr/local/bin/docker", argv: ["docker", "compose", "up"]),
    Proc(pid: 900, name: "Google Chrome", path: chrome, argv: [chrome], isApp: true),
    Proc(pid: 901, name: "make", path: "/usr/bin/make", argv: ["make", "-j8", "all"]),
]

/// The scan's pipeline over `table`: candidate names per record (other users' argv unreadable), then app PIDs dropped.
private func matched(_ query: String, in procs: [Proc] = table) -> [Int32] {
    let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var hits: [String: [ProcessHit]] = [:]
    for p in procs {
        let argv = p.uid == me ? p.argv : []
        if ProcessMatcher.candidateNames(procName: p.name, path: p.path, argv: argv).contains(key) {
            hits[key, default: []].append(ProcessHit(pid: p.pid, uid: p.uid))
        }
    }
    let apps = WatchMonitor.appNames(procs.filter(\.isApp).map {
        RunningAppInfo(bundleID: "app.\($0.pid)", name: $0.name, pid: $0.pid, isRegular: true,
                       executable: $0.path.map { URL(fileURLWithPath: $0).lastPathComponent })
    })
    return (ProcessMatcher.excludingApps(hits, apps: apps)[key] ?? []).map(\.pid).sorted()
}

@Suite("Fix C: process matching table")
struct FixCMatcherTests {
    @Test(arguments: [
        // R23: the CLI, never Claude.app or its helpers.
        ("claude", [9137]),
        ("Claude", [9137]),
        // R20: python3 / python3.x / python.
        ("python3", [10238, 33189, 33190]),
        ("python3.14", [33189]),
        ("python3.9", [33190]),
        ("python3.11", [10238]),
        ("python", [10238, 33189, 33190]),
        ("train.py", [33189, 33190]),
        ("ipykernel_launcher", [10238]),
        // R21: npm's retitled argv; node itself still matches.
        ("npm", [7000]),
        ("node", [7000, 7001, 7002]),
        ("codex", [7001]),
        // R19: root's processes.
        ("launchd", [1]),
        ("rsync", [4242]),
        // R23 for an LSUIElement app: the CLI only.
        ("docker", [801]),
        ("make", [901]),
        // Negatives: words of a retitle, a path with a space, an app's name.
        ("run", []), ("build", []), ("npm run build", [7000]),
        ("my", []), ("/applications/my", []), ("tools", []),
        ("google", []), ("google chrome", []), ("all", []), ("", []),
    ] as [(String, [Int32])])
    func matches(query: String, expected: [Int32]) {
        #expect(matched(query) == expected, "query \(query)")
    }

    @Test func pythonAliases() {
        #expect(ProcessMatcher.pythonAliases("python3.12") == ["python3", "python"])
        #expect(ProcessMatcher.pythonAliases("python3.13t") == ["python3", "python"])
        #expect(ProcessMatcher.pythonAliases("python3") == ["python"])
        #expect(ProcessMatcher.pythonAliases("Python").isEmpty)
        #expect(ProcessMatcher.pythonAliases("python3-config").isEmpty)
        #expect(ProcessMatcher.pythonAliases("pythonista").isEmpty)
    }

    @Test func pythonFrameworkVersion() {
        #expect(ProcessMatcher.pythonFrameworkVersion(python314).map { "\($0.major).\($0.minor)" } == "3.14")
        #expect(ProcessMatcher.pythonFrameworkVersion(pythonCLT).map { "\($0.major).\($0.minor)" } == "3.9")
        #expect(ProcessMatcher.pythonFrameworkVersion("/Library/Frameworks/Python.framework/Versions/Current/bin/x") == nil)
        #expect(ProcessMatcher.pythonFrameworkVersion("/Library/Frameworks/Foo.framework/Versions/3.1/Foo") == nil)
    }

    @Test func retitledCommand() {
        #expect(ProcessMatcher.retitledCommand(["npm run build", "", "", ""]) == "npm")
        #expect(ProcessMatcher.retitledCommand(["npm exec vite"]) == "npm")
        #expect(ProcessMatcher.retitledCommand(["node", "/opt/homebrew/bin/npm", "run", "build"]) == nil)
        #expect(ProcessMatcher.retitledCommand(["/Applications/My Tools/node", ""]) == nil)
        #expect(ProcessMatcher.retitledCommand(["npm run build", "x"]) == nil)
        #expect(ProcessMatcher.retitledCommand(["npm"]) == nil)
        #expect(ProcessMatcher.retitledCommand([]) == nil)
    }

    @Test func retitleOnlyForInterpreters() {
        // A non-interpreter whose argv[0] has words never yields its first word.
        let names = ProcessMatcher.candidateNames(procName: "Google Chrome Helper", path: nil, argv: ["Google Chrome Helper", ""])
        #expect(!names.contains("google"))
    }

    // R27: the name a PID is shown by.
    @Test func displayNames() {
        #expect(ProcessMatcher.displayName(procName: "2.1.310", path: "/Users/x/.local/share/claude/versions/2.1.310",
                                           argv: ["claude", "-c"]) == "claude")
        #expect(ProcessMatcher.displayName(procName: "launchd", path: "/sbin/launchd", argv: []) == "launchd")
        #expect(ProcessMatcher.displayName(procName: "", path: "/usr/libexec/some-very-long-daemon-name", argv: [])
                == "some-very-long-daemon-name")
        #expect(ProcessMatcher.displayName(procName: "node", path: "/opt/homebrew/bin/node",
                                           argv: ["npm run build", "", ""]) == "npm")
        #expect(ProcessMatcher.displayName(procName: "Python", path: python314, argv: [python314, "x.py"]) == "Python")
        #expect(ProcessMatcher.displayName(procName: "rsync", path: nil, argv: []) == "rsync")
        #expect(ProcessMatcher.displayName(procName: "", path: nil, argv: []) == nil)
    }

    @Test func pidTargetNeverShowsThePIDTwice() {
        #expect(WatchTarget.pid(77, name: "pid 77").displayName == "pid 77")
        #expect(WatchTarget.pid(77, name: "").displayName == "pid 77")
        #expect(WatchTarget.pid(77, name: "rsync").displayName == "rsync (77)")
    }
}

@Suite("Fix C: live process table")
struct FixCLiveTests {
    // R19: root's processes are visible (launchd is pid 1, owned by root).
    @Test func scanSeesRootProcesses() {
        let hits = ProcessTable.scan(["launchd"])["launchd"] ?? []
        #expect(hits.contains { $0.pid == 1 && $0.uid == 0 })
    }

    // R27: root's PIDs resolve to a name (proc_name fails for them); our own via argv[0].
    @MainActor
    @Test func displayNameResolvesRootAndOwn() {
        #expect(ProcessTable.displayName(pid: 1) == "launchd")
        #expect(ProcessTable.displayName(pid: getpid())?.isEmpty == false)
        #expect(CLIRunner.processName(1) == "launchd")
    }

    @MainActor
    @Test func pidPromptNamesRootProcess() async {
        #expect(await WhilePrompt.lookup(.pid, "1") == .found(.pid(1, name: "launchd"), summary: "launchd"))
    }
}

// MARK: - WatchMonitor

@MainActor
private final class FixCFakeSystem: WatchSystem {
    var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var apps: [RunningAppInfo] = []
    var processes: [String: [Int32]] = [:]
    private(set) var appReads = 0

    func now() -> Date { clock }
    func advance(_ s: TimeInterval) { clock = clock.addingTimeInterval(s) }
    func runningApps() -> [RunningAppInfo] { appReads += 1; return apps }
    func scanProcesses(_ names: Set<String>) async -> [String: [ProcessHit]] {
        var result: [String: [ProcessHit]] = [:]
        for name in names { result[name] = (processes[name] ?? []).map { ProcessHit(pid: $0, uid: 501) } }
        return result
    }
    func pidIsAlive(_ pid: Int32) -> Bool { false }
    func observeExit(of pid: Int32, _ handler: @escaping @MainActor () -> Void) -> AnyObject? { nil }
}

@MainActor
private final class Flag { var value = 0 }

@MainActor
private func makeMonitor(rules: [Rule] = []) -> (WatchMonitor, FixCFakeSystem, Settings) {
    let settings = Settings(defaults: ScratchDefaults.make("FixC"))
    settings.rules = rules
    let system = FixCFakeSystem()
    let monitor = WatchMonitor(settings: settings, power: FakePower(), system: system, schedulesTimers: false)
    return (monitor, system, settings)
}

private let claudeDesktop = RunningAppInfo(bundleID: "com.anthropic.claudefordesktop", name: "Claude", pid: 53135,
                                           isRegular: true)
private let dockerApp = RunningAppInfo(bundleID: "com.docker.docker", name: "Docker", pid: 800, isRegular: false)
private let backgroundAgent = RunningAppInfo(bundleID: "com.example.agent", name: "agent", pid: 4411, isRegular: false,
                                             hasUI: false)

@MainActor
@Suite("Fix C: WatchMonitor")
struct FixCWatchMonitorTests {
    // R23: a running app's PID never satisfies a process rule or keeps a process watch alive.
    @Test func appPIDsNeverMatchProcessTargets() async {
        let rule = Rule(condition: .process(name: "claude"))
        let (monitor, system, _) = makeMonitor(rules: [rule])
        system.apps = [claudeDesktop, backgroundAgent]
        monitor.start()
        system.processes["claude"] = [53135, 9137]
        let exits = Flag()
        _ = monitor.watch(.process(name: "claude")) { exits.value += 1 }
        await monitor.performScan()
        #expect(monitor.processMatches["claude"] == [9137])
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])

        // The CLI exits; only Claude.app is left.
        system.processes["claude"] = [53135]
        await monitor.performScan()
        system.advance(WatchMonitor.grace)
        await monitor.performScan()
        #expect(monitor.processMatches["claude"] == [])
        #expect(monitor.satisfiedRules.isEmpty)
        #expect(exits.value == 1)

        // A process without a UI (a .prohibited "app") still matches by name.
        system.processes["agent"] = [4411]
        _ = monitor.watch(.process(name: "agent")) {}
        await monitor.performScan()
        #expect(monitor.processMatches["agent"] == [4411])
    }

    @Test func appPIDsAreUIAppsOnly() {
        #expect(WatchMonitor.appPIDs([claudeDesktop, dockerApp, backgroundAgent]) == [53135, 800])
    }

    @Test func promptSaysWhenOnlyAnAppMatched() {
        #expect(WhilePrompt.processLookup(name: "Claude", pids: [], appMatched: true)
                == .unavailable("That's an app: use Running apps"))
        #expect(WhilePrompt.processLookup(name: "zzz", pids: []) == .unavailable("No running process named \u{201C}zzz\u{201D}"))
    }

    // R25: a process rule survives a gap shorter than the grace period, then turns off.
    @Test func processRuleHasGracePeriod() async {
        let rule = Rule(condition: .process(name: "ffmpeg"))
        let (monitor, system, _) = makeMonitor(rules: [rule])
        monitor.start()
        let posts = Flag()
        let token = NotificationCenter.default.addObserver(forName: .insomniaRulesDidChange, object: monitor, queue: nil) { _ in
            MainActor.assumeIsolated { posts.value += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        system.processes["ffmpeg"] = [100]
        await monitor.performScan()
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])
        #expect(posts.value == 1)

        // Between two files of a shell loop: no match for 3 s, then the next ffmpeg.
        system.processes["ffmpeg"] = []
        await monitor.performScan()
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])
        system.advance(3)
        await monitor.performScan()
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])
        system.processes["ffmpeg"] = [101]
        await monitor.performScan()
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])
        #expect(posts.value == 1)   // never flickered off

        // Gone for good: off once the grace period has passed (counted from the first empty scan).
        system.processes["ffmpeg"] = []
        await monitor.performScan()
        system.advance(4)
        await monitor.performScan()
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])
        system.advance(1)
        await monitor.performScan()
        #expect(monitor.satisfiedRules.isEmpty)
        #expect(posts.value == 2)
        system.advance(10)
        await monitor.performScan()
        #expect(monitor.satisfiedRules.isEmpty)   // no grace for a rule that is already off
    }

    @Test func graceNeverTurnsAnUnmatchedRuleOn() async {
        let (monitor, system, _) = makeMonitor(rules: [Rule(condition: .process(name: "ffmpeg"))])
        monitor.start()
        await monitor.performScan()
        #expect(monitor.satisfiedRules.isEmpty)
        system.advance(1)
        await monitor.performScan()
        #expect(monitor.satisfiedRules.isEmpty)
    }

    @Test func disablingOrEditingARuleDropsItsGrace() async {
        var rule = Rule(condition: .process(name: "ffmpeg"))
        let (monitor, system, settings) = makeMonitor(rules: [rule])
        monitor.start()
        system.processes["ffmpeg"] = [100]
        await monitor.performScan()
        system.processes["ffmpeg"] = []
        await monitor.performScan()
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])   // in grace

        rule.condition = .process(name: "rsync")
        settings.rules = [rule]   // recomputes: the edited rule doesn't inherit ffmpeg's grace
        #expect(monitor.satisfiedRules.isEmpty)

        rule.condition = .process(name: "ffmpeg")
        settings.rules = [rule]
        system.processes["ffmpeg"] = [100]
        await monitor.performScan()
        system.processes["ffmpeg"] = []
        await monitor.performScan()
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])
        rule.enabled = false
        settings.rules = [rule]
        #expect(monitor.satisfiedRules.isEmpty)
    }

    // R22: runningApplications KVO changes are coalesced into one refresh that updates app rules.
    @Test func runningApplicationsChangesAreCoalesced() async {
        let rule = Rule(condition: .app(bundleID: dockerApp.bundleID, name: "Docker"))
        let (monitor, system, _) = makeMonitor(rules: [rule])
        monitor.start()
        #expect(monitor.satisfiedRules.isEmpty)
        let before = system.appReads
        system.apps = [dockerApp]   // LSUIElement: no didLaunch notification, only the KVO change
        monitor.runningApplicationsDidChange()
        monitor.runningApplicationsDidChange()
        monitor.runningApplicationsDidChange()
        for _ in 0..<100 where system.appReads == before { await Task.yield() }
        #expect(system.appReads == before + 1)
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])

        system.apps = []
        monitor.runningApplicationsDidChange()
        for _ in 0..<100 where !monitor.satisfiedRules.isEmpty { await Task.yield() }
        #expect(monitor.satisfiedRules.isEmpty)
    }

    // R26: the Automations pickers read an observed list of regular apps, assigned only on change.
    @Test func regularAppsIsObservedAndSorted() {
        let (monitor, system, _) = makeMonitor()
        let xcode = RunningAppInfo(bundleID: "com.apple.dt.Xcode", name: "Xcode", pid: 700, isRegular: true)
        let xcode2 = RunningAppInfo(bundleID: "com.apple.dt.Xcode", name: "Xcode", pid: 701, isRegular: true)
        let arc = RunningAppInfo(bundleID: "company.thebrowser.Browser", name: "Arc", pid: 702, isRegular: true)
        system.apps = [xcode, dockerApp, arc, xcode2, backgroundAgent]
        monitor.start()
        #expect(monitor.regularApps.map(\.name) == ["Arc", "Xcode"])

        let changes = Flag()
        func track() {
            withObservationTracking { _ = monitor.regularApps } onChange: {
                MainActor.assumeIsolated { changes.value += 1 }
            }
        }
        track()
        monitor.appsChanged()   // same apps: no assignment, no re-render
        #expect(changes.value == 0)
        system.apps = [xcode, arc, claudeDesktop]
        monitor.appsChanged()
        #expect(changes.value == 1)
        #expect(monitor.regularApps.map(\.name) == ["Arc", "Claude", "Xcode"])
    }
}

// MARK: - R24: system noise in Why awake?

@Suite("Fix C: Why awake noise")
struct FixCAssertionNoiseTests {
    private let when = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The dictionaries as IOPMCopyAssertionsByProcess returns them on this macOS.
    private var windowServerTickle: [String: Any] {
        ["AssertPID": NSNumber(value: 412), "Process Name": "WindowServer", "AssertLevel": NSNumber(value: 255),
         "AssertType": "UserIsActive", "AssertionTrueType": "UserIsActive", "AssertionId": NSNumber(value: 35418),
         "AssertName": "com.apple.iohideventsystem.queue.tickle serviceID:100000bac service:AppleHIDKeyboardEventDriverV2 product:Apple Internal Keyboard / Trackpad eventType:3",
         "TimeoutSeconds": NSNumber(value: 3600), "TimeoutAction": "TimeoutActionRelease", "AssertStartWhen": when]
    }
    private var powerdDisplayOn: [String: Any] {
        ["AssertPID": NSNumber(value: 355), "Process Name": "powerd", "AssertLevel": NSNumber(value: 255),
         "AssertType": "PreventUserIdleSystemSleep", "AssertionTrueType": "PreventUserIdleSystemSleep",
         "AssertionId": NSNumber(value: 40177), "AssertName": "Powerd - Prevent sleep while display is on",
         "AssertStartWhen": when]
    }
    private var powerdDelayDisplayOff: [String: Any] {
        ["AssertPID": NSNumber(value: 355), "Process Name": "powerd", "AssertLevel": NSNumber(value: 255),
         "AssertType": "InternalPreventDisplaySleep", "AssertionId": NSNumber(value: 40178),
         "AssertName": "com.apple.powermanagement.delayDisplayOff", "AssertStartWhen": when]
    }

    @Test func idleMacAfterTheClickHasNothingToShow() {
        let parsed = AssertionInspector.parse([windowServerTickle, powerdDisplayOn, powerdDelayDisplayOff],
                                              ownPID: 99, processName: { _ in nil })
        #expect(parsed.isEmpty)
        var input = WhyAwakeInput()
        input.foreign = parsed
        #expect(WhyAwakeReport.build(input).isNothing)
    }

    @Test func realAssertionsAreKept() {
        var otherUserActive = windowServerTickle
        otherUserActive["AssertPID"] = NSNumber(value: 700)
        otherUserActive["Process Name"] = "Remote Desktop"
        var powerdForClient = powerdDelayDisplayOff
        powerdForClient["AssertionOnBehalfOfPID"] = NSNumber(value: 808)
        let caffeinate: [String: Any] = [
            "AssertPID": NSNumber(value: 33384), "Process Name": "caffeinate", "AssertType": "PreventUserIdleSystemSleep",
            "AssertName": "caffeinate command-line tool", "AssertionId": NSNumber(value: 1), "AssertStartWhen": when]
        let parsed = AssertionInspector.parse([windowServerTickle, otherUserActive, powerdForClient, caffeinate],
                                              ownPID: 99, processName: { _ in nil })
        #expect(parsed.map(\.process) == ["caffeinate", "powerd", "Remote Desktop"])
    }
}
