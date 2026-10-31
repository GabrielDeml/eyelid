import Foundation
import Testing
@testable import Insomnia

@MainActor
@Suite("Stats")
struct StatsTests {
    private static func defaults() -> UserDefaults {
        ScratchDefaults.make("Stats")
    }

    @Test func milestonesFireOnceEver() {
        let d = Self.defaults()
        let stats = Stats(defaults: d)
        #expect(stats.addAwakeTime(99 * 3600) == nil)
        #expect(stats.addAwakeTime(2 * 3600) == 100)
        #expect(stats.addAwakeTime(3600) == nil)
        // A fresh instance (relaunch) remembers.
        let again = Stats(defaults: d)
        #expect(again.milestonesShown == [100])
        #expect(again.addAwakeTime(400 * 3600) == 500)
        // Reset clears numbers but milestones never repeat.
        again.reset()
        #expect(again.totalAwakeSeconds == 0)
        #expect(again.addAwakeTime(600 * 3600) == nil)
        #expect(again.addAwakeTime(500 * 3600) == 1000)
    }

    @Test func crossingSeveralReportsTheHighest() {
        let stats = Stats(defaults: Self.defaults())
        #expect(stats.addAwakeTime(600 * 3600) == 500)
        #expect(stats.milestonesShown == [100, 500])
    }

    @Test func sessionsAndCoffee() {
        let stats = Stats(defaults: Self.defaults())
        stats.recordSessionStarted()
        stats.recordSessionEnded(duration: 3600)
        stats.recordSessionStarted()
        stats.recordSessionEnded(duration: 600)
        #expect(stats.sessionCount == 2)
        #expect(stats.longestSessionSeconds == 3600)
        _ = stats.addAwakeTime(90 * 60)
        #expect(stats.cupsOfCoffeeEquivalent == 2)
        stats.recordSessionEnded(duration: -5)   // ignored
        #expect(stats.longestSessionSeconds == 3600)
    }

    @Test func timeIsBatchedThenFlushed() {
        let d = Self.defaults()
        let stats = Stats(defaults: d)
        stats.addLidClosedTime(10)
        #expect(d.double(forKey: "stats.lidClosedSeconds") == 0)   // batched (< 30 s)
        stats.addLidClosedTime(25)
        #expect(d.double(forKey: "stats.lidClosedSeconds") == 35)  // crossed the 30 s batch
        stats.addLidClosedTime(5)
        stats.flush()
        #expect(d.double(forKey: "stats.lidClosedSeconds") == 40)
    }

    @Test func badgeAndSurvivalsPersist() {
        let d = Self.defaults()
        let stats = Stats(defaults: d)
        stats.awardPokeBadge()
        stats.recordLidCloseSurvival()
        let again = Stats(defaults: d)
        #expect(again.pokeBadge)
        #expect(again.lidCloseSurvivals == 1)
    }
}
