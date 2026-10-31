import Foundation
import Testing
@testable import Insomnia

// WatchMonitor + ProcessMatcher: matching rule, rules, grace period. A fake WatchSystem stands in for NSWorkspace,
// libproc and DispatchSource; no timers run (schedulesTimers: false), the tests drive evaluation directly.

@MainActor
final class WatchFakeSystem: WatchSystem {
    var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var apps: [RunningAppInfo] = []
    /// lower-cased name → pids
    var processes: [String: [Int32]] = [:]
    var alivePIDs: Set<Int32> = []
    private(set) var exitHandlers: [Int32: @MainActor () -> Void] = [:]
    private(set) var scans = 0

    func now() -> Date { clock }
    func advance(_ s: TimeInterval) { clock = clock.addingTimeInterval(s) }
    func runningApps() -> [RunningAppInfo] { apps }
    func scanProcesses(_ names: Set<String>) async -> [String: [ProcessHit]] {
        scans += 1
        var result: [String: [ProcessHit]] = [:]
        for name in names { result[name] = (processes[name] ?? []).map { ProcessHit(pid: $0, uid: 501) } }
        return result
    }
    func pidIsAlive(_ pid: Int32) -> Bool { alivePIDs.contains(pid) }
    func observeExit(of pid: Int32, _ handler: @escaping @MainActor () -> Void) -> AnyObject? {
        exitHandlers[pid] = handler
        return NSObject()
    }
    func kill(_ pid: Int32) {
        alivePIDs.remove(pid)
        exitHandlers.removeValue(forKey: pid)?()
    }
}

@MainActor
private final class ExitCounter {
    var count = 0
}

@MainActor
private final class IDBox {
    var id: UUID?
}

@MainActor
private func makeMonitor(rules: [Rule] = [], power: FakePower = FakePower())
    -> (WatchMonitor, WatchFakeSystem, Settings) {
    let defaults = ScratchDefaults.make("Watch")
    let settings = Settings(defaults: defaults)
    settings.rules = rules
    let system = WatchFakeSystem()
    let monitor = WatchMonitor(settings: settings, power: power, system: system, schedulesTimers: false)
    return (monitor, system, settings)
}

private let xcode = RunningAppInfo(bundleID: "com.apple.dt.Xcode", name: "Xcode", pid: 700, isRegular: true)

@Suite("ProcessMatcher")
struct ProcessMatcherTests {
    @Test func plainBinaryMatchesProcNameAndPath() {
        #expect(ProcessMatcher.matches("ffmpeg", procName: "ffmpeg", path: "/opt/homebrew/bin/ffmpeg", argv: ["ffmpeg", "-i", "a.mov"]))
        #expect(ProcessMatcher.matches("FFmpeg", procName: "ffmpeg", path: nil, argv: []))   // case-insensitive
        #expect(!ProcessMatcher.matches("ffprobe", procName: "ffmpeg", path: "/opt/homebrew/bin/ffmpeg", argv: ["ffmpeg"]))
    }

    @Test func renamedProcessMatchesArgv0() {
        // `claude` sets its process title; proc_name still says node / the versioned binary.
        #expect(ProcessMatcher.matches("claude", procName: "2.1.3", path: "/Users/x/.local/share/claude/versions/2.1.3",
                                       argv: ["claude", "--resume"]))
    }

    @Test func interpreterFirstNonFlagArgument() {
        #expect(ProcessMatcher.matches("codex", procName: "node", path: "/opt/homebrew/Cellar/node/24.1.0/bin/node",
                                       argv: ["node", "/opt/homebrew/bin/codex", "exec"]))
        #expect(ProcessMatcher.matches("npm", procName: "node", path: "/usr/local/bin/node",
                                       argv: ["node", "--max-old-space-size=4096", "/usr/local/bin/npm", "run", "build"]))
        #expect(ProcessMatcher.matches("train.py", procName: "Python", path: "/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python",
                                       argv: ["python3", "-u", "train.py"]))
        #expect(ProcessMatcher.matches("pytest", procName: "python3.12", path: nil, argv: ["python3.12", "-m", "pytest"]))
    }

    @Test func nonInterpreterIgnoresArguments() {
        #expect(!ProcessMatcher.matches("all", procName: "make", path: "/usr/bin/make", argv: ["make", "-j8", "all"]))
        #expect(!ProcessMatcher.matches("", procName: "make", path: nil, argv: ["make"]))
    }

    @Test func interpreterDetection() {
        for name in ["node", "bun", "deno", "ruby", "Python", "python3", "python3.13"] { #expect(ProcessMatcher.isInterpreter(name)) }
        for name in ["make", "zsh", "swift", "nodejs-helper"] { #expect(!ProcessMatcher.isInterpreter(name)) }
    }

    @Test func basename() {
        #expect(ProcessMatcher.basename("/usr/bin/make") == "make")
        #expect(ProcessMatcher.basename("make") == "make")
        #expect(ProcessMatcher.basename("/a/b/") == "b")
    }

    @Test func parsesProcArgs2() {
        var bytes: [UInt8] = []
        var argc = Int32(3).littleEndian
        withUnsafeBytes(of: &argc) { bytes += $0 }
        bytes += Array("/usr/local/bin/node".utf8) + [0, 0, 0, 0]          // exec path + padding
        for arg in ["node", "/usr/local/bin/codex", "exec"] { bytes += Array(arg.utf8) + [0] }
        bytes += Array("HOME=/Users/x".utf8) + [0]                          // environment: ignored
        let parsed = bytes.withUnsafeBytes { ProcessMatcher.parseProcArgs($0) }
        #expect(parsed?.execPath == "/usr/local/bin/node")
        #expect(parsed?.argv == ["node", "/usr/local/bin/codex", "exec"])
    }

    @Test func rejectsTruncatedProcArgs() {
        let parsed = [UInt8](repeating: 0, count: 2).withUnsafeBytes { ProcessMatcher.parseProcArgs($0) }
        #expect(parsed == nil)
    }

    @Test func liveScanFindsThisTestRunnerParent() {
        // The real table: launchd (pid 1) is always there; our own pid is always excluded.
        let pids = ProcessTable.allPIDs()
        #expect(pids.contains(1))
        #expect(ProcessTable.isAlive(1))
        let ownName = AssertionInspector.processName(pid: getpid()) ?? ""
        let hits = ProcessTable.scan([ownName.lowercased()])
        #expect(!(hits[ownName.lowercased()] ?? []).contains { $0.pid == getpid() })
    }
}

@MainActor
@Suite("WatchMonitor rules")
struct WatchMonitorRuleTests {
    @Test func appRuleFollowsRunningApps() {
        let rule = Rule(condition: .app(bundleID: xcode.bundleID, name: "Xcode"))
        let (monitor, system, _) = makeMonitor(rules: [rule])
        monitor.start()
        #expect(monitor.satisfiedRules.isEmpty)
        system.apps = [xcode]
        monitor.appsChanged()
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])
        system.apps = []
        monitor.appsChanged()
        #expect(monitor.satisfiedRules.isEmpty)
    }

    @Test func powerRules() {
        let power = FakePower()
        power.isOnAC = true
        power.externalDisplayCount = 0
        let ac = Rule(condition: .onAC), display = Rule(condition: .externalDisplay)
        let (monitor, _, _) = makeMonitor(rules: [ac, display], power: power)
        monitor.start()
        #expect(monitor.satisfiedRules.map(\.id) == [ac.id])
        #expect(monitor.isSatisfied(.onAC))
        #expect(!monitor.isSatisfied(.externalDisplay))
        power.externalDisplayCount = 1
        #expect(monitor.isSatisfied(.externalDisplay))
    }

    @Test func disabledRulesNeverSatisfy() {
        var rule = Rule(condition: .onAC)
        rule.enabled = false
        let power = FakePower()
        power.isOnAC = true
        let (monitor, _, _) = makeMonitor(rules: [rule], power: power)
        monitor.start()
        #expect(monitor.satisfiedRules.isEmpty)
    }

    @Test func processRuleAfterScanAndPostsOnlyOnChange() async {
        let rule = Rule(condition: .process(name: "FFmpeg"))
        let (monitor, system, _) = makeMonitor(rules: [rule])
        monitor.start()
        let posts = ExitCounter()
        let token = NotificationCenter.default.addObserver(forName: .insomniaRulesDidChange, object: monitor, queue: nil) { _ in
            MainActor.assumeIsolated { posts.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        system.processes["ffmpeg"] = [4411]
        await monitor.performScan()
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])
        #expect(monitor.processMatches["ffmpeg"] == [4411])
        #expect(posts.count == 1)

        await monitor.performScan()   // nothing changed
        #expect(posts.count == 1)

        system.processes["ffmpeg"] = []
        await monitor.performScan()
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])   // grace period
        system.advance(WatchMonitor.grace)
        await monitor.performScan()
        #expect(monitor.satisfiedRules.isEmpty)
        #expect(posts.count == 2)
    }

    @Test func editingRulesRecomputes() {
        let power = FakePower()
        power.isOnAC = true
        let (monitor, _, settings) = makeMonitor(rules: [], power: power)
        monitor.start()
        #expect(monitor.satisfiedRules.isEmpty)
        let rule = Rule(condition: .onAC)
        settings.rules = [rule]   // posts .insomniaSettingsDidChange("rules.v1") → recompute
        #expect(monitor.satisfiedRules.map(\.id) == [rule.id])
        settings.rules = []
        #expect(monitor.satisfiedRules.isEmpty)
    }

    @Test func emptyProcessNameIsIgnored() async {
        let (monitor, system, _) = makeMonitor(rules: [Rule(condition: .process(name: "  "))])
        monitor.start()
        await monitor.performScan()
        #expect(monitor.satisfiedRules.isEmpty)
        #expect(system.scans == 0)
    }
}

@MainActor
@Suite("WatchMonitor watches")
struct WatchMonitorWatchTests {
    @Test func appWatchEndsAfterGrace() {
        let (monitor, system, _) = makeMonitor()
        system.apps = [xcode]
        monitor.start()
        let exits = ExitCounter()
        _ = monitor.watch(.app(bundleID: xcode.bundleID, name: "Xcode")) { exits.count += 1 }

        system.apps = []
        monitor.appsChanged()
        #expect(exits.count == 0)
        system.advance(4)
        monitor.evaluateWatches()
        #expect(exits.count == 0)
        system.advance(1)
        monitor.evaluateWatches()
        #expect(exits.count == 1)
        system.advance(10)
        monitor.evaluateWatches()
        #expect(exits.count == 1)   // once
    }

    @Test func appRelaunchWithinGraceKeepsWatching() {
        let (monitor, system, _) = makeMonitor()
        system.apps = [xcode]
        monitor.start()
        let exits = ExitCounter()
        _ = monitor.watch(.app(bundleID: xcode.bundleID, name: "Xcode")) { exits.count += 1 }
        system.apps = []
        monitor.appsChanged()
        system.advance(3)
        system.apps = [xcode]
        monitor.appsChanged()
        system.advance(10)
        monitor.evaluateWatches()
        #expect(exits.count == 0)
    }

    @Test func processWatchUsesScansAndGrace() async {
        let (monitor, system, _) = makeMonitor()
        monitor.start()
        system.processes["make"] = [9001]
        let exits = ExitCounter()
        _ = monitor.watch(.process(name: "make")) { exits.count += 1 }
        monitor.evaluateWatches()
        #expect(exits.count == 0)   // not scanned yet: assumed running
        await monitor.performScan()
        #expect(monitor.matchedPID(for: .process(name: "make")) == 9001)
        #expect(monitor.displayNameWithPID(.process(name: "make")) == "make (9001)")

        system.processes["make"] = []
        await monitor.performScan()
        #expect(exits.count == 0)
        system.advance(5)
        await monitor.performScan()
        #expect(exits.count == 1)
    }

    @Test func pidAlreadyGoneFiresWithoutGrace() {
        let (monitor, _, _) = makeMonitor()
        monitor.start()
        let exits = ExitCounter()
        _ = monitor.watch(.pid(4242, name: "ffmpeg")) { exits.count += 1 }
        #expect(exits.count == 0)   // never synchronously inside watch()
        monitor.evaluateWatches()
        #expect(exits.count == 1)
    }

    @Test func pidExitEndsAfterGrace() {
        let (monitor, system, _) = makeMonitor()
        system.alivePIDs = [4411]
        monitor.start()
        let exits = ExitCounter()
        _ = monitor.watch(.pid(4411, name: "ffmpeg")) { exits.count += 1 }
        system.kill(4411)
        monitor.evaluateWatches()
        #expect(exits.count == 0)
        system.advance(5)
        monitor.evaluateWatches()
        #expect(exits.count == 1)
    }

    @Test func cancelledWatchNeverFires() {
        let (monitor, system, _) = makeMonitor()
        system.alivePIDs = [4411]
        monitor.start()
        let exits = ExitCounter()
        let id = monitor.watch(.pid(4411, name: "ffmpeg")) { exits.count += 1 }
        monitor.cancelWatch(id)
        system.kill(4411)
        system.advance(10)
        monitor.evaluateWatches()
        #expect(exits.count == 0)
    }

    @Test func onExitMayCancelItselfSafely() {
        let (monitor, _, _) = makeMonitor()
        monitor.start()
        let exits = ExitCounter()
        let box = IDBox()
        box.id = monitor.watch(.pid(1234, name: "x")) {
            exits.count += 1
            if let id = box.id { monitor.cancelWatch(id) }   // what the engine does in endBabysit
        }
        monitor.evaluateWatches()
        monitor.evaluateWatches()
        #expect(exits.count == 1)
    }
}

@MainActor
@Suite("While… prompt lookups")
struct WhilePromptLookupTests {
    @Test func processLookup() {
        #expect(WhilePrompt.processLookup(name: "ffmpeg", pids: []) == .unavailable("No running process named \u{201C}ffmpeg\u{201D}"))
        #expect(WhilePrompt.processLookup(name: "ffmpeg", pids: [4411])
                == .found(.process(name: "ffmpeg"), summary: "Running · pid 4411"))
        #expect(WhilePrompt.processLookup(name: "node", pids: [9, 3, 7, 5])
                == .found(.process(name: "node"), summary: "4 running · pid 3, 5, 7, …"))
    }

    @Test func pidLookup() {
        #expect(WhilePrompt.pidLookup(pid: 77, alive: false, name: nil) == .unavailable("No process with PID 77"))
        #expect(WhilePrompt.pidLookup(pid: 77, alive: true, name: "rsync") == .found(.pid(77, name: "rsync"), summary: "rsync"))
        #expect(WhilePrompt.pidLookup(pid: 77, alive: true, name: nil) == .found(.pid(77, name: "pid 77"), summary: "pid 77"))
    }

    @Test func lookupValidatesInput() async {
        #expect(await WhilePrompt.lookup(.pid, "  ") == .empty)
        #expect(await WhilePrompt.lookup(.pid, "abc") == .unavailable("Enter a process number"))
        #expect(await WhilePrompt.lookup(.pid, "\(getpid())") == .unavailable("That's Insomnia itself"))
        if case .found(let target, _) = await WhilePrompt.lookup(.pid, "1") {
            #expect(target == .pid(1, name: "launchd"))   // root's process: named by its executable path
        } else {
            Issue.record("pid 1 should resolve")
        }
    }
}
