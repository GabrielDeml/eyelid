import AppKit
import Darwin
import Foundation
import Observation
import os

// MARK: - WatchMonitor: rules + babysit/CLI watches (ARCHITECTURE.md "Core/WatchMonitor.swift")
//
// | Target / condition  | How it's checked                                                                         |
// |---------------------|------------------------------------------------------------------------------------------|
// | .app                | NSWorkspace.runningApplications + KVO on it (no polling; the didLaunch / didTerminate    |
// |                     | notifications skip LSUIElement apps such as Docker and Ollama), bursts coalesced         |
// | .process            | ProcessTable.scan (proc_listallpids + ProcessMatcher), every 5 s ONLY while some enabled  |
// |                     | process rule or process watch exists; the scan runs off the main thread. PIDs of running |
// |                     | apps with a UI are dropped (Claude.app is an app, not the `claude` CLI)                  |
// | .pid                | DispatchSource process-exit source (no polling); already gone → onExit right away        |
// | .onAC / .externalDisplay | PowerMonitor (`.insomniaPowerDidChange`)                                            |
//
// Watches end, and process rules turn off, after the target has been gone for `grace` (5 s), so an app relaunch, a quick
// restart or a shell loop between two runs doesn't end the hold. Idle cost with no process rule and no watch: zero timers.

/// A running app as the monitor sees it (no icon: icons are fetched only for the While… menu).
struct RunningAppInfo: Equatable, Sendable {
    var bundleID: String
    var name: String
    var pid: Int32
    /// `.regular` activation policy (has a Dock icon). Only these are offered in While… ▸ Running apps.
    var isRegular: Bool
    /// Not `.prohibited` (regular or LSUIElement/accessory): an app with a UI. Its PID never counts as a process match.
    var hasUI: Bool = true
}

/// One process that matched a name.
struct ProcessHit: Equatable, Sendable {
    var pid: Int32
    var uid: uid_t
}

/// The system calls WatchMonitor depends on. `LiveWatchSystem` is the real one; tests inject a fake.
@MainActor
protocol WatchSystem: AnyObject {
    func now() -> Date
    func runningApps() -> [RunningAppInfo]
    /// Lower-cased name → matching processes (own PID excluded). Runs off the main thread in the live system.
    func scanProcesses(_ names: Set<String>) async -> [String: [ProcessHit]]
    func pidIsAlive(_ pid: Int32) -> Bool
    /// Calls `handler` on the main actor when `pid` exits. Keep the token; releasing it stops observing.
    func observeExit(of pid: Int32, _ handler: @escaping @MainActor () -> Void) -> AnyObject?
}

@MainActor
@Observable
final class WatchMonitor: WatchMonitoring {
    static let shared = WatchMonitor()

    /// Names the While… ▸ Suggested submenu looks for (UX.md §2.2 F), in display order.
    static let suggestedNames = ["claude", "codex", "xcodebuild", "ffmpeg", "rsync", "make", "cargo", "npm", "python3"]
    /// A watched target must be gone this long before `onExit` fires.
    static let grace: TimeInterval = 5
    /// Process polling interval (only while a process rule or process watch needs it).
    static let pollInterval: TimeInterval = 5

    /// Enabled rules whose condition is currently true (including rules the engine has paused; it filters them).
    private(set) var satisfiedRules: [Rule] = []
    /// Lower-cased process name → matching PIDs (sorted), for every name a rule or watch needs. Feeds the babysit
    /// subline / Why awake ("ffmpeg (4411)") and the Automations "active now" dots.
    private(set) var processMatches: [String: [Int32]] = [:]
    /// Running regular apps (not Insomnia itself), one per bundle id, sorted by name. Assigned only on change, so the
    /// Automations app pickers re-render when an app launches or quits (no icons: those are fetched by the While… menu).
    private(set) var regularApps: [RunningAppInfo] = []

    // MARK: Dependencies

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let power: any PowerReading
    @ObservationIgnored private let system: any WatchSystem
    @ObservationIgnored private let schedulesTimers: Bool
    @ObservationIgnored private let logger = Logger(subsystem: "com.gdeml.Insomnia", category: "watch")
    /// EventLog (or any sink). Assigned by AppDelegate; nil in tests.
    @ObservationIgnored var eventLog: (any EventLogging)?

    // MARK: State

    private struct Watch {
        let target: WatchTarget
        let onExit: @MainActor () -> Void
        var goneSince: Date?
        /// PID targets: the exit source. Released with the watch.
        var exitToken: AnyObject?
    }

    @ObservationIgnored private var apps: [RunningAppInfo] = []
    @ObservationIgnored private var scannedNames: Set<String> = []
    @ObservationIgnored private var watches: [UUID: Watch] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var scanInFlight = false
    @ObservationIgnored private var scanAgain = false
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var graceTimer: Timer?
    @ObservationIgnored private var graceDeadline: Date?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var appsObservation: NSKeyValueObservation?
    @ObservationIgnored private var appsChangePending = false
    /// Process rules that were satisfied and have no match now: kept satisfied until `since + grace`. The condition is
    /// stored so that editing a rule's name doesn't inherit the old name's grace.
    @ObservationIgnored private var ruleGoneSince: [Rule.ID: (condition: RuleCondition, since: Date)] = [:]

    init(settings: Settings = .shared, power: any PowerReading = PowerMonitor.shared,
         system: (any WatchSystem)? = nil, schedulesTimers: Bool = true) {
        self.settings = settings
        self.power = power
        self.system = system ?? LiveWatchSystem()
        self.schedulesTimers = schedulesTimers
    }

    // MARK: - Lifecycle

    /// Reads apps and rules once and subscribes to changes. Idempotent. Call before `AwakeEngine.start()`.
    func start() {
        guard !started else { return }
        started = true
        startObserving()
        reloadApps()
        recomputeRules()
        updatePolling()
        if !namesNeeded().isEmpty { scanNow() }
    }

    /// Re-checks everything now (wake from sleep; tests).
    func refresh() {
        reloadApps()
        evaluateWatches()
        recomputeRules()
        scanNow()
    }

    // MARK: - WatchMonitoring

    /// Calls `onExit` once, on the main actor, when the target has been gone for `grace`. Never synchronously from
    /// inside this call (a PID that is already gone fires on the next run-loop turn).
    func watch(_ target: WatchTarget, onExit: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        var entry = Watch(target: target, onExit: onExit)
        switch target {
        case .app:
            if !isAppRunning(target) { entry.goneSince = system.now() }
        case .process:
            break   // unknown until the first scan (treated as running meanwhile)
        case .pid(let pid, _):
            if system.pidIsAlive(pid) {
                entry.exitToken = system.observeExit(of: pid) { [weak self] in self?.pidExited(id) }
                // The process may have exited between the check and the registration: look again.
                if !system.pidIsAlive(pid) { entry.goneSince = system.now() }
            } else {
                // Already gone: fire "immediately" (the next turn), without the grace period.
                entry.goneSince = system.now().addingTimeInterval(-Self.grace)
            }
        }
        watches[id] = entry
        log("watch \(target.displayName)")
        updatePolling()
        if case .process(let name) = target, !scannedNames.contains(Self.key(name)) { scanNow() }
        scheduleGrace()
        return id
    }

    func cancelWatch(_ id: UUID) {
        guard let entry = watches.removeValue(forKey: id) else { return }
        log("stop watching \(entry.target.displayName)")
        updatePolling()
        scheduleGrace()
    }

    // MARK: - Queries (While… menu, Why awake, Automations)

    /// Running now? `.process` uses the last scan when the name is being tracked, else scans synchronously.
    func isRunning(_ target: WatchTarget) -> Bool {
        switch target {
        case .app: return isAppRunning(target)
        case .pid(let pid, _): return system.pidIsAlive(pid)
        case .process(let name):
            let key = Self.key(name)
            guard !key.isEmpty else { return false }
            if scannedNames.contains(key) { return !(processMatches[key] ?? []).isEmpty }
            return !(ProcessMatcher.excludingApps(ProcessTable.scan([key]), appPIDs: Self.appPIDs(apps))[key] ?? []).isEmpty
        }
    }

    /// The PID shown next to a target: the (lowest) matched PID for a process name, the app's PID, or the PID itself.
    func matchedPID(for target: WatchTarget) -> Int32? {
        switch target {
        case .pid(let pid, _): return pid
        case .process(let name): return processMatches[Self.key(name)]?.first
        case .app(let bundleID, _): return apps.first { $0.bundleID == bundleID }?.pid
        }
    }

    /// "ffmpeg (4411)" for a process target with a known match; otherwise `displayName`.
    func displayNameWithPID(_ target: WatchTarget) -> String {
        if case .process(let name) = target, let pid = matchedPID(for: target) { return "\(name) (\(pid))" }
        return target.displayName
    }

    /// For the While… menu: running regular apps (not Insomnia itself), sorted by name.
    func runningApps() -> [(bundleID: String, name: String, icon: NSImage)] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != own }
            .compactMap { app -> (bundleID: String, name: String, icon: NSImage)? in
                guard let id = app.bundleIdentifier else { return nil }
                let icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
                return (id, app.localizedName ?? id, icon)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// For While… ▸ Suggested: this user's command-line processes whose name the matcher finds among `suggestedNames`,
    /// in that order, one entry per PID. The process scan runs off the main thread (a cold scan of ~1,600 processes
    /// takes ~50 ms); the result is also kept in `lastSuggested` so the next menu opens with it at once.
    func runningSuggestedProcesses() async -> [(name: String, pid: Int32)] {
        let names = Set(Self.suggestedNames)
        let raw = await Task.detached(priority: .userInitiated) { ProcessTable.scan(names) }.value
        let uid = getuid()
        // GUI apps are under Running apps (the Claude desktop app would otherwise match "claude").
        let hits = ProcessMatcher.excludingApps(raw, appPIDs: Self.appPIDs(system.runningApps()))
        let result = Self.suggestedNames.flatMap { name in
            (hits[name] ?? []).filter { $0.uid == uid }.map { (name: name, pid: $0.pid) }
        }
        lastSuggested = result
        return result
    }

    /// The previous Suggested scan (nil before the first), shown while a fresh one runs.
    @ObservationIgnored private(set) var lastSuggested: [(name: String, pid: Int32)]?

    // MARK: - Evaluation

    /// Applies a finished process scan. Internal so tests can drive it.
    func performScan() async {
        let names = namesNeeded()
        let raw = names.isEmpty ? [:] : await system.scanProcesses(names)
        // After the scan, on the main actor: a running app's PID is never a process match (Claude.app's executable is
        // "Claude", so a rule or watch for the `claude` CLI would otherwise never end while the app is open).
        let results = ProcessMatcher.excludingApps(raw, appPIDs: Self.appPIDs(apps))
        var matches: [String: [Int32]] = [:]
        for name in names { matches[name] = (results[name] ?? []).map(\.pid).sorted() }
        scannedNames = names
        if matches != processMatches { processMatches = matches }
        evaluateWatches()
        recomputeRules()
    }

    /// Updates each watch's gone-since, fires the ones past their grace period, and schedules the next check.
    func evaluateWatches() {
        let t = system.now()
        var due: [(UUID, Watch)] = []
        for (id, var w) in watches {
            if isAlive(w) {
                w.goneSince = nil
            } else if w.goneSince == nil {
                w.goneSince = t
                log("\(w.target.displayName) is gone; ending in \(Int(Self.grace)) s unless it returns")
            }
            watches[id] = w
            if let gone = w.goneSince, t.timeIntervalSince(gone) >= Self.grace - 0.05 { due.append((id, w)) }
        }
        for (id, _) in due { watches[id] = nil }
        if !due.isEmpty { updatePolling() }
        scheduleGrace()
        for (_, w) in due {
            log("\(w.target.displayName) exited")
            w.onExit()
        }
    }

    private func isAlive(_ w: Watch) -> Bool {
        switch w.target {
        case .app: return isAppRunning(w.target)
        case .pid:
            // The exit source (or the registration check) sets goneSince; a PID never comes back.
            return w.goneSince == nil
        case .process(let name):
            let key = Self.key(name)
            guard scannedNames.contains(key) else { return true }   // not scanned yet: assume running
            return !(processMatches[key] ?? []).isEmpty
        }
    }

    private func pidExited(_ id: UUID) {
        guard var w = watches[id], w.goneSince == nil else { return }
        w.goneSince = system.now()
        w.exitToken = nil
        watches[id] = w
        log("\(w.target.displayName) exited; ending in \(Int(Self.grace)) s")
        scheduleGrace()
    }

    private func recomputeRules() {
        let t = system.now()
        var gone: [Rule.ID: (condition: RuleCondition, since: Date)] = [:]
        let satisfied = settings.rules.filter { rule in
            guard rule.enabled else { return false }
            if isSatisfied(rule.condition) { return true }
            // Process rules get the watches' grace period: one empty scan (a `for f in *.mov; do ffmpeg …` loop between
            // two runs) mustn't drop the hold, clear the eyes' pause and recreate the hold with a new start.
            guard case .process = rule.condition else { return false }
            let since: Date
            if let g = ruleGoneSince[rule.id], g.condition == rule.condition {
                since = g.since
            } else if satisfiedRules.contains(where: { $0.id == rule.id && $0.condition == rule.condition }) {
                since = t
                log("\(rule.condition.phrase): no match; the rule stays on for \(Int(Self.grace)) s unless it returns")
            } else {
                return false
            }
            guard t.timeIntervalSince(since) < Self.grace - 0.05 else { return false }
            gone[rule.id] = (rule.condition, since)
            return true
        }
        ruleGoneSince = gone   // removed, disabled, edited and matched-again rules drop out here
        scheduleGrace()
        guard satisfied != satisfiedRules else { return }
        let before = Set(satisfiedRules.map(\.id)), after = Set(satisfied.map(\.id))
        satisfiedRules = satisfied
        for rule in satisfied where !before.contains(rule.id) { log("rule on: \(rule.condition.phrase)") }
        for id in before.subtracting(after) {
            let phrase = settings.rules.first { $0.id == id }?.condition.phrase ?? "removed rule"
            log("rule off: \(phrase)")
        }
        NotificationCenter.default.post(name: .insomniaRulesDidChange, object: self)
    }

    /// Pure-ish: depends only on the monitor's caches and PowerReading.
    func isSatisfied(_ c: RuleCondition) -> Bool {
        switch c {
        case .app(let bundleID, _): return apps.contains { $0.bundleID == bundleID }
        case .process(let name):
            let key = Self.key(name)
            return !key.isEmpty && !(processMatches[key] ?? []).isEmpty
        case .onAC: return power.isOnAC
        case .externalDisplay: return power.externalDisplayCount > 0
        }
    }

    private func isAppRunning(_ target: WatchTarget) -> Bool {
        guard case .app(let bundleID, _) = target else { return false }
        return apps.contains { $0.bundleID == bundleID }
    }

    // MARK: - Polling (only while needed)

    /// Lower-cased names the scan must cover: enabled process rules + process watches.
    private func namesNeeded() -> Set<String> {
        var names = Set<String>()
        for rule in settings.rules where rule.enabled {
            if case .process(let name) = rule.condition { names.insert(Self.key(name)) }
        }
        for w in watches.values {
            if case .process(let name) = w.target { names.insert(Self.key(name)) }
        }
        names.remove("")
        return names
    }

    private func updatePolling() {
        let needed = !namesNeeded().isEmpty
        if needed, pollTimer == nil, schedulesTimers {
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scanNow() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
            log("process polling on")
        } else if !needed, let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
            log("process polling off")
        }
        if !needed, !processMatches.isEmpty || !scannedNames.isEmpty {
            processMatches = [:]
            scannedNames = []
        }
    }

    /// One scan at a time; a request during a scan runs one more afterwards.
    private func scanNow() {
        guard !scanInFlight else { scanAgain = true; return }
        scanInFlight = true
        Task { [weak self] in
            guard let self else { return }
            await self.performScan()
            self.scanInFlight = false
            if self.scanAgain {
                self.scanAgain = false
                self.scanNow()
            }
        }
    }

    // MARK: - Grace timer

    private func scheduleGrace() {
        let since = watches.values.compactMap(\.goneSince) + ruleGoneSince.values.map(\.since)
        let next = since.map { $0.addingTimeInterval(Self.grace) }.min()
        guard next != graceDeadline else { return }
        graceTimer?.invalidate()
        graceTimer = nil
        graceDeadline = next
        guard let next, schedulesTimers else { return }
        let fire = max(next, Date().addingTimeInterval(0.01))
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.graceExpired() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        graceTimer = timer
    }

    private func graceExpired() {
        graceDeadline = nil
        graceTimer = nil
        reloadApps()
        // Process targets get a fresh scan first (it ends in evaluateWatches + recomputeRules); the rest are decided now.
        let hasProcessWatch = watches.values.contains { if case .process = $0.target { $0.goneSince != nil } else { false } }
        if hasProcessWatch || !ruleGoneSince.isEmpty {
            scanNow()
        } else {
            evaluateWatches()
            recomputeRules()
        }
    }

    // MARK: - Observation

    private func startObserving() {
        let center = NotificationCenter.default
        observe(center, .insomniaSettingsDidChange, object: settings) { monitor, key in
            guard key == "rules.v1" else { return }
            monitor.updatePolling()
            monitor.recomputeRules()
            if !monitor.namesNeeded().isSubset(of: monitor.scannedNames) { monitor.scanNow() }
        }
        observe(center, .insomniaPowerDidChange, object: power) { monitor, _ in monitor.recomputeRules() }

        // KVO, not didLaunch/didTerminate: AppKit doesn't post those for LSUIElement apps (Docker, Ollama, Google Drive).
        appsObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            Task { @MainActor in self?.runningApplicationsDidChange() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification, object: nil) { monitor, _ in monitor.refresh() }
    }

    /// `runningApplications` changed. A launch changes it several times in a row: one refresh per burst, on the next
    /// main-actor turn. Internal so tests can drive it.
    func runningApplicationsDidChange() {
        guard !appsChangePending else { return }
        appsChangePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appsChangePending = false
            self.appsChanged()
        }
    }

    /// Apps launched or quit. Internal so tests can drive it.
    func appsChanged() {
        reloadApps()
        evaluateWatches()
        recomputeRules()
    }

    private func reloadApps() {
        apps = system.runningApps()
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        let regular = apps
            .filter { $0.isRegular && $0.bundleID != own && seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if regular != regularApps { regularApps = regular }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject?,
                         _ handler: @escaping @MainActor (WatchMonitor, _ settingsKey: String?) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, key)
            }
        }
        observers.append((center, token))
    }

    // MARK: - Helpers

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// PIDs of running apps with a UI (regular or LSUIElement): never process matches. Shared by the rule/watch scan,
    /// While… ▸ Suggested and the Process name… prompt.
    nonisolated static func appPIDs(_ apps: [RunningAppInfo]) -> Set<Int32> {
        Set(apps.filter(\.hasUI).map(\.pid))
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        eventLog?.log("watch", message)
    }
}

// MARK: - Live system

@MainActor
final class LiveWatchSystem: WatchSystem {
    func now() -> Date { Date() }

    func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let id = app.bundleIdentifier else { return nil }
            return RunningAppInfo(bundleID: id, name: app.localizedName ?? id, pid: app.processIdentifier,
                                  isRegular: app.activationPolicy == .regular,
                                  hasUI: app.activationPolicy != .prohibited)
        }
    }

    func scanProcesses(_ names: Set<String>) async -> [String: [ProcessHit]] {
        await Task.detached(priority: .utility) { ProcessTable.scan(names) }.value
    }

    func pidIsAlive(_ pid: Int32) -> Bool { ProcessTable.isAlive(pid) }

    func observeExit(of pid: Int32, _ handler: @escaping @MainActor () -> Void) -> AnyObject? {
        ProcessExitObservation(pid: pid, handler: handler)
    }
}

/// A DispatchSource process-exit source on the main queue; cancelled on deinit.
@MainActor
private final class ProcessExitObservation {
    private let source: DispatchSourceProcess

    init(pid: Int32, handler: @escaping @MainActor () -> Void) {
        let box = HandlerBox(handler)
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { box.fire() }
        }
        source.resume()
    }

    deinit { source.cancel() }

    /// Main-actor box so the Sendable event handler can carry a main-actor closure; fires at most once.
    @MainActor
    private final class HandlerBox {
        private var handler: (@MainActor () -> Void)?
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
        func fire() {
            let h = handler
            handler = nil
            h?()
        }
    }
}

// MARK: - Process table (libproc + sysctl; nonisolated, runs off the main thread)

enum ProcessTable {
    /// Lower-cased query name → matching processes. Excludes our own PID and zombies, but not apps (callers drop app
    /// PIDs on the main actor: `ProcessMatcher.excludingApps`). Every process, including other users' and root's, answers
    /// to its proc_name and executable basename (PROC_PIDT_SHORTBSDINFO + proc_pidpath, which work for any process;
    /// PROC_PIDTBSDINFO fails with EPERM for other users). This user's processes also answer to argv[0] and an
    /// interpreter's script (KERN_PROCARGS2; other users' argv isn't readable). This user's processes' names are cached
    /// by PID + start time once older than `settleTime` (a self-renaming tool like `claude` has renamed itself by then),
    /// so a steady-state scan costs one proc_pidinfo per own process and two cheap calls per other user's process.
    static func scan(_ names: Set<String>) -> [String: [ProcessHit]] {
        let wanted = Set(names.map { $0.lowercased() }.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [:] }
        let own = getpid(), uid = getuid()
        let now = UInt64(max(0, time(nil)))
        let cached = cache.withLock { $0 }
        var seen: [CacheKey: Set<String>] = [:]
        var result: [String: [ProcessHit]] = [:]
        var argBuffer: [UInt8] = []
        for pid in allPIDs() where pid > 0 && pid != own {
            guard let short = shortInfo(pid) else { continue }   // gone, or a zombie
            let candidates: Set<String>
            if short.uid == uid, let info = bsdInfo(pid) {
                let key = CacheKey(pid: pid, startSec: info.startSec, startUsec: info.startUsec)
                if let hit = cached[key] {
                    candidates = hit
                } else {
                    var argv: [String] = []
                    var path = executablePath(pid)
                    if argBuffer.isEmpty { argBuffer = [UInt8](repeating: 0, count: argMax) }
                    if let args = arguments(pid, buffer: &argBuffer) {
                        argv = args.argv
                        if path == nil { path = args.execPath }
                    }
                    candidates = ProcessMatcher.candidateNames(procName: info.name, path: path, argv: argv)
                }
                if now >= info.startSec, now - info.startSec >= settleTime { seen[key] = candidates }
            } else {
                // Another user's (or root's) process: comm + executable path; never cached (no start time to key by).
                candidates = ProcessMatcher.candidateNames(procName: short.comm, path: executablePath(pid), argv: [])
            }
            for name in wanted.intersection(candidates) {
                result[name, default: []].append(ProcessHit(pid: pid, uid: short.uid))
            }
        }
        let settled = seen
        cache.withLock { $0 = settled }   // only live processes stay cached
        return result
    }

    /// Seconds after start before a process's names are cached.
    static let settleTime: UInt64 = 10

    private struct CacheKey: Hashable, Sendable {
        var pid: Int32
        var startSec: UInt64
        var startUsec: UInt64
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [CacheKey: Set<String>]())

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: libproc

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), pids.count)))
    }

    /// The name a PID is shown by (While… ▸ PID…, `insomnia watch --pid`): basename(argv[0]) for this user's processes
    /// (`claude`'s proc_name and executable are its version, "2.1.310"), else basename(proc_pidpath) (works for root's
    /// processes, where proc_name fails), else the short name. nil when nothing resolves (the process is gone).
    static func displayName(pid: Int32) -> String? {
        guard pid > 0, let short = shortInfo(pid) else { return nil }
        var argv: [String] = []
        var procName = short.comm
        if short.uid == getuid() {
            if let info = bsdInfo(pid) { procName = info.name }
            var buffer = [UInt8](repeating: 0, count: argMax)
            argv = arguments(pid, buffer: &buffer)?.argv ?? []
        }
        return ProcessMatcher.displayName(procName: procName, path: executablePath(pid), argv: argv)
    }

    /// PROC_PIDT_SHORTBSDINFO: readable for every user's processes. nil if gone or a zombie.
    private static func shortInfo(_ pid: Int32) -> (comm: String, uid: uid_t)? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        if info.pbsi_status == UInt32(SZOMB) { return nil }
        return (withUnsafeBytes(of: info.pbsi_comm) { cString($0) }, info.pbsi_uid)
    }

    /// PROC_PIDTBSDINFO: this user's processes only (EPERM for other users' on current macOS).
    private static func bsdInfo(_ pid: Int32) -> (name: String, uid: uid_t, startSec: UInt64, startUsec: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        if info.pbi_status == UInt32(SZOMB) { return nil }
        var name = withUnsafeBytes(of: info.pbi_name) { cString($0) }
        if name.isEmpty { name = withUnsafeBytes(of: info.pbi_comm) { cString($0) } }
        return (name, info.pbi_uid, info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// KERN_PROCARGS2 for `pid` into a reused buffer. nil for other users' processes (EINVAL/EPERM) or on error.
    private static func arguments(_ pid: Int32, buffer: inout [UInt8]) -> (execPath: String?, argv: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let ok = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0) == 0
        }
        guard ok, size > 0 else { return nil }
        return buffer.withUnsafeBytes { ProcessMatcher.parseProcArgs(UnsafeRawBufferPointer(rebasing: $0.prefix(size))) }
    }

    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()

    private static func cString(_ bytes: UnsafeRawBufferPointer) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes.prefix(end), as: UTF8.self)
    }
}

/// The process-name matching rule from `WatchTarget.process` (Models.swift), as pure functions.
enum ProcessMatcher {
    /// node, bun, deno, ruby, Python*, python3* (case-insensitive).
    static func isInterpreter(_ basename: String) -> Bool {
        let b = basename.lowercased()
        return b == "node" || b == "bun" || b == "deno" || b == "ruby" || b.hasPrefix("python")
    }

    /// The names a process answers to, lower-cased: proc_name, basename(executable path), basename(argv[0]), and, when
    /// any of those is an interpreter, basename of the first non-flag argument after argv[0]. Plus:
    /// - Python versions: `python3` re-execs into `…/Python.framework/Versions/3.x/…/Python.app/Contents/MacOS/Python`,
    ///   and uv/pyenv run `python3.11`, so a Python process also answers to "python", "python3" and "python3.x".
    /// - A retitled interpreter (npm sets process.title, so argv becomes `["npm run build", "", "", ""]`): the first
    ///   word of argv[0], "npm".
    static func candidateNames(procName: String, path: String?, argv: [String]) -> Set<String> {
        var names = Set<String>()
        var bases: [String] = []
        if !procName.isEmpty { bases.append(procName) }
        if let path, !path.isEmpty { bases.append(basename(path)) }
        if let first = argv.first, !first.isEmpty { bases.append(basename(first)) }
        for b in bases {
            names.insert(b.lowercased())
            names.formUnion(pythonAliases(b))
        }
        for p in [path, argv.first].compactMap({ $0 }) {
            guard let v = pythonFrameworkVersion(p) else { continue }
            names.formUnion(["python", "python\(v.major)", "python\(v.major).\(v.minor)"])
        }
        if bases.contains(where: isInterpreter) {
            if let script = scriptArgument(argv) { names.insert(basename(script).lowercased()) }
            if let title = retitledCommand(argv) { names.insert(title.lowercased()) }
        }
        names.remove("")
        return names
    }

    static func matches(_ name: String, procName: String, path: String?, argv: [String]) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !key.isEmpty && candidateNames(procName: procName, path: path, argv: argv).contains(key)
    }

    /// Drops hits whose PID is a running app with a UI (`WatchMonitor.appPIDs`): an app is watched as an app, not by
    /// process name. Run on the main actor right after the scan.
    static func excludingApps(_ hits: [String: [ProcessHit]], appPIDs: Set<Int32>) -> [String: [ProcessHit]] {
        guard !appPIDs.isEmpty else { return hits }
        return hits.mapValues { $0.filter { !appPIDs.contains($0.pid) } }
    }

    /// The name to show for a process (see `ProcessTable.displayName(pid:)`). nil if nothing is known.
    static func displayName(procName: String, path: String?, argv: [String]) -> String? {
        let interpreter = isInterpreter(procName) || path.map { isInterpreter(basename($0)) } == true
        if interpreter, let title = retitledCommand(argv) { return title }
        if let first = argv.first, !basename(first).isEmpty { return basename(first) }
        if let path, !basename(path).isEmpty { return basename(path) }
        return procName.isEmpty ? nil : procName
    }

    /// "python3.12" → ["python3", "python"]; "python3" → ["python"]. Anything else (e.g. "python3-config") → [].
    static func pythonAliases(_ base: String) -> Set<String> {
        let b = base.lowercased()
        guard b.hasPrefix("python") else { return [] }
        let parts = b.dropFirst("python".count).split(separator: ".", omittingEmptySubsequences: false)
        guard let major = parts.first, !major.isEmpty, major.allSatisfy(\.isASCII), major.allSatisfy(\.isNumber),
              parts.count <= 2, parts.count == 1 || parts[1].first?.isNumber == true else { return [] }
        return parts.count == 2 ? ["python\(major)", "python"] : ["python"]
    }

    /// (3, 14) for `…/Python.framework/Versions/3.14/…` or the Command Line Tools' `…/Python3.framework/Versions/3.9/…`.
    static func pythonFrameworkVersion(_ path: String) -> (major: String, minor: String)? {
        guard let r = path.range(of: ".framework/Versions/") else { return nil }
        let framework = basename(String(path[..<r.lowerBound]))
        guard framework == "Python" || framework == "Python3" else { return nil }
        let parts = path[r.upperBound...].prefix { $0 != "/" }.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// The command an interpreter retitled itself to (node's process.title overwrites the argv area): argv[0] holds
    /// words ("npm run build", "npm exec vite") and every other argv entry is empty. nil when argv[0] is a path (a path
    /// with a space, "/Applications/My Tools/node", must not yield "/applications/my") or there are real arguments.
    static func retitledCommand(_ argv: [String]) -> String? {
        guard let first = argv.first, argv.dropFirst().allSatisfy(\.isEmpty),
              let word = first.split(whereSeparator: \.isWhitespace).first, word.count < first.count,
              !word.contains("/") else { return nil }
        return String(word)
    }

    /// First argument after argv[0] that doesn't start with "-".
    static func scriptArgument(_ argv: [String]) -> String? {
        argv.dropFirst().first { !$0.hasPrefix("-") && !$0.isEmpty }
    }

    static func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
    }

    /// KERN_PROCARGS2 layout: Int32 argc, the exec path, NUL padding, then argc NUL-terminated argv strings
    /// (environment follows; ignored).
    static func parseProcArgs(_ bytes: UnsafeRawBufferPointer) -> (execPath: String?, argv: [String])? {
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = Int(bytes.loadUnaligned(as: Int32.self))
        guard argc >= 0, argc < 1 << 16 else { return nil }
        var i = MemoryLayout<Int32>.size
        func readString() -> String? {
            guard i < bytes.count else { return nil }
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            let s = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
            return s
        }
        let exec = readString()
        while i < bytes.count, bytes[i] == 0 { i += 1 }   // padding after the exec path
        var argv: [String] = []
        while argv.count < argc, i < bytes.count {
            guard let s = readString() else { break }
            argv.append(s)
            i += 1   // the NUL
        }
        return (exec?.isEmpty == false ? exec : nil, argv)
    }
}
