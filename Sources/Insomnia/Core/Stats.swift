import Foundation
import Observation

/// Lifetime stats for the About sheet, milestones (100 / 500 / 1,000 h, each shown once ever) and the poke badge
/// (ARCHITECTURE.md "Core/Stats.swift"). Backed by UserDefaults (`stats.*`).
///
/// The engine credits wall time on each re-evaluation, never per second. Writes are batched: at most once per 30 s of
/// added time, plus immediately on session end, reset, badge, survival, and `flush()` (call it on termination).
@MainActor
@Observable
final class Stats: StatsRecording {
    static let shared = Stats()

    private(set) var totalAwakeSeconds: TimeInterval
    private(set) var sessionCount: Int
    private(set) var longestSessionSeconds: TimeInterval
    private(set) var lidClosedSeconds: TimeInterval
    private(set) var lidCloseSurvivals: Int
    /// Hours: 100, 500, 1000. Each is reported once, ever.
    private(set) var milestonesShown: Set<Int>
    /// Earned at 50 pokes within one poke streak (UX §9).
    private(set) var pokeBadge: Bool
    private(set) var firstLaunch: Date

    static let milestoneHours = [100, 500, 1000]
    /// One cup per 45 minutes awake (UX §4.4 About).
    static let secondsPerCup: TimeInterval = 45 * 60
    /// Batch window for time-only changes.
    static let saveInterval: TimeInterval = 30

    var cupsOfCoffeeEquivalent: Int { Int(totalAwakeSeconds / Self.secondsPerCup) }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var unsavedSeconds: TimeInterval = 0

    private enum Key {
        static let total = "stats.totalAwakeSeconds"
        static let sessions = "stats.sessionCount"
        static let longest = "stats.longestSessionSeconds"
        static let lidClosed = "stats.lidClosedSeconds"
        static let survivals = "stats.lidCloseSurvivals"
        static let milestones = "stats.milestonesShown"
        static let poke = "stats.pokeBadge"
        static let firstLaunch = "stats.firstLaunch"
    }

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        totalAwakeSeconds = max(0, defaults.double(forKey: Key.total))
        sessionCount = max(0, defaults.integer(forKey: Key.sessions))
        longestSessionSeconds = max(0, defaults.double(forKey: Key.longest))
        lidClosedSeconds = max(0, defaults.double(forKey: Key.lidClosed))
        lidCloseSurvivals = max(0, defaults.integer(forKey: Key.survivals))
        milestonesShown = Set((defaults.array(forKey: Key.milestones) as? [Int]) ?? [])
        pokeBadge = defaults.bool(forKey: Key.poke)
        // init writes nothing (like Settings): a first launch date is persisted with the first save.
        firstLaunch = (defaults.object(forKey: Key.firstLaunch) as? Date) ?? now
    }

    // MARK: StatsRecording

    func recordSessionStarted() {
        sessionCount += 1
        save()
    }

    func recordSessionEnded(duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return save() }
        if duration > longestSessionSeconds { longestSessionSeconds = duration }
        save()
    }

    /// Adds awake wall time. Returns the highest milestone (hours) crossed for the first time, or nil.
    func addAwakeTime(_ s: TimeInterval) -> Int? {
        guard s.isFinite, s > 0 else { return nil }
        totalAwakeSeconds += s
        noteUnsaved(s)
        let hours = totalAwakeSeconds / 3600
        let crossed = Self.milestoneHours.filter { Double($0) <= hours && !milestonesShown.contains($0) }
        guard let highest = crossed.max() else { return nil }
        // Crossing two at once (e.g. imported stats) reports the biggest and retires the rest silently.
        milestonesShown.formUnion(crossed)
        save()
        return highest
    }

    func addLidClosedTime(_ s: TimeInterval) {
        guard s.isFinite, s > 0 else { return }
        lidClosedSeconds += s
        noteUnsaved(s)
    }

    func recordLidCloseSurvival() {
        lidCloseSurvivals += 1
        save()
    }

    func awardPokeBadge() {
        guard !pokeBadge else { return }
        pokeBadge = true
        save()
    }

    // MARK: Maintenance

    /// Clears every number and badge. Milestones already shown stay retired (each is shown once, ever).
    func reset(now: Date = Date()) {
        totalAwakeSeconds = 0
        sessionCount = 0
        longestSessionSeconds = 0
        lidClosedSeconds = 0
        lidCloseSurvivals = 0
        pokeBadge = false
        firstLaunch = now
        save()
    }

    /// Writes anything batched. Call from `applicationWillTerminate`.
    func flush() {
        if unsavedSeconds > 0 { save() }
    }

    private func noteUnsaved(_ s: TimeInterval) {
        unsavedSeconds += s
        if unsavedSeconds >= Self.saveInterval { save() }
    }

    private func save() {
        unsavedSeconds = 0
        defaults.set(totalAwakeSeconds, forKey: Key.total)
        defaults.set(sessionCount, forKey: Key.sessions)
        defaults.set(longestSessionSeconds, forKey: Key.longest)
        defaults.set(lidClosedSeconds, forKey: Key.lidClosed)
        defaults.set(lidCloseSurvivals, forKey: Key.survivals)
        defaults.set(milestonesShown.sorted(), forKey: Key.milestones)
        defaults.set(pokeBadge, forKey: Key.poke)
        defaults.set(firstLaunch, forKey: Key.firstLaunch)
    }
}
