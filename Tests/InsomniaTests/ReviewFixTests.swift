import AppKit
import Foundation
import InsomniaShared
import Testing
@testable import Insomnia

/// Regression tests for the review fixes: URL holds never get lid, URL durations can't overflow, the lid-engaged quip
/// budget, a real sleep restarting the awake stretch, and the Narrator pool sizes.

@MainActor
private final class LabelNarrator: Narrating {
    func line(_ m: Moment, _ p: Personality, now: Date) -> String? {
        switch m {
        case .activated: return "activated"
        case .lidEngaged: return "lid"
        default: return nil
        }
    }
    func notification(_ id: NotificationID, _ p: Personality, context: [String: String]) -> (title: String, body: String) {
        ("", "")
    }
}

@Suite("Review fixes", .serialized)
@MainActor
struct ReviewFixTests {
    // MARK: URL scheme (Decision 10)

    @Test func urlToggleAndExtendNeverStartALidHold() {
        let h = Harness()
        h.settings.closedLidMode = true
        URLCommandHandler.perform(URLCommand(action: .toggle), settings: h.settings, engine: h.engine)
        #expect(h.engine.manualHold != nil)
        #expect(h.engine.manualHold?.options.lid == false)
        #expect(h.engine.manualHold?.followsSettings == false)

        h.engine.deactivate(.user(.panel))
        URLCommandHandler.perform(URLCommand(action: .extend(minutes: 30)), settings: h.settings, engine: h.engine)
        #expect(h.engine.manualHold?.options.lid == false)
    }

    @Test func urlExtendNeverProlongsALidHold() {
        let h = Harness()
        h.settings.closedLidMode = true
        h.engine.activate(.minutes(60), source: .panel)
        #expect(h.engine.manualHold?.options.lid == true)
        let end = h.engine.manualHold?.end
        URLCommandHandler.perform(URLCommand(action: .extend(minutes: 30)), settings: h.settings, engine: h.engine)
        #expect(h.engine.manualHold?.end == end)
        h.engine.extend(minutes: 15, source: .panel)   // the panel still can
        #expect(h.engine.manualHold?.end == end?.addingTimeInterval(15 * 60))
    }

    @Test func hugeUrlDurationsSaturateInsteadOfCrashing() {
        let week = URLCommand.When.minutes(7 * 24 * 60)
        #expect(URLCommand.parseDuration("999999999999999999h") == week)
        #expect(URLCommand.parseDuration("999999999999999999999m") == week)
        #expect(URLCommand.parseDuration("9223372036854775807h9223372036854775807m") == week)
        #expect(URLCommand.parseDuration("99999999999999999999999") == week)
        #expect(URLCommand.parseDuration("1h30") == .minutes(90))
        #expect(URLCommand.parseDuration("0h0m") == nil)
    }

    // MARK: Engine

    @Test func lidEngagedQuipIsEarnedOncePerDayThenRotates() {
        let h = Harness()
        h.engine.narrator = LabelNarrator()
        h.settings.closedLidMode = true
        h.engine.activate(.minutes(60), source: .panel)
        #expect(h.engine.quip == "activated")
        h.lid.converge(lidClosed: false)
        #expect(h.engine.quip == "lid")                   // the day's first engagement is earned

        h.engine.deactivate(.user(.panel))
        h.lid.converge(lidClosed: false)
        h.clock.advance(60)
        h.engine.activate(.minutes(60), source: .panel)   // inside the 4 h budget: no activated line
        h.lid.converge(lidClosed: false)
        #expect(h.engine.quip != "lid")                   // a later engagement rotates under the same budget
        #expect(h.engine.quip != "activated")
    }

    @Test func realSleepRestartsTheAwakeStretch() {
        let h = Harness()
        h.engine.activate(.indefinite, source: .panel)
        h.clock.advance(9 * 3600)
        h.engine.systemDidWake()
        #expect(h.engine.awakeSince == h.clock.now)
    }

    // MARK: Copy

    @Test func escalationBucketsHaveEightLinesEach() {
        for p in [Personality.cheeky, .unhinged] {
            for kind in [CopyKind.awake2, .awake8] {
                #expect(Copy.pool(kind, p).count >= 8, "\(p) \(kind)")
            }
        }
    }

    @Test func professionalBodiesNeverRepeatTheirTitle() {
        let n = Narrator(settings: Settings(defaults: ScratchDefaults.make("Copy")))
        for (id, context) in [(NotificationID.batteryFloor, ["floor": "20"]), (.lidHeat, [:]), (.ended, [:]),
                              (.targetExited, ["name": "ffmpeg"])] {
            let copy = n.notification(id, .professional, context: context)
            #expect(!copy.body.isEmpty)
            #expect(copy.body.lowercased() != copy.title.lowercased() + ".")
            #expect(!copy.body.lowercased().hasPrefix(copy.title.lowercased()))
        }
    }

    // MARK: Entry point

    @Test func onlyTheFirstArgumentPicksTheLaunchCommand() {
        let isCLI: (String) -> Bool = { ["status", "run", "on"].contains($0) }
        #expect(LaunchCommand.parse(["Insomnia"], isCLICommand: isCLI) == .app)
        #expect(LaunchCommand.parse(["Insomnia", "--export-icon", "/tmp/x"], isCLICommand: isCLI) == .exportIcon("/tmp/x"))
        #expect(LaunchCommand.parse(["Insomnia", "--export-icon"], isCLICommand: isCLI) == .exportIcon(nil))
        #expect(LaunchCommand.parse(["insomnia", "status", "--export-icon", "/tmp/x"], isCLICommand: isCLI)
                == .cli(["status", "--export-icon", "/tmp/x"]))
        #expect(LaunchCommand.parse(["insomnia", "run", "--", "tool", "--snapshot", "out"], isCLICommand: isCLI)
                == .cli(["run", "--", "tool", "--snapshot", "out"]))
        #expect(LaunchCommand.parse(["Insomnia", "--bogus"], isCLICommand: isCLI) == .usage)
    }

    // MARK: Lid safety

    @Test func watchdogResetsTwiceAroundTheSpawnTimeout() throws {
        #expect(Watchdog.resetSettle > 5)
        #expect(Watchdog.script.components(separatedBy: "/usr/bin/pmset -a disablesleep 0").count == 3)
        #expect(Spawn.run("/bin/bash", ["-n", "-c", Watchdog.script], timeout: 10).status == 0)
    }

    @Test func spawnReturnsPromptlyWithoutPolling() {
        let start = Date()
        for _ in 0..<5 { #expect(Spawn.run("/usr/bin/true", [], timeout: 5).status == 0) }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(Spawn.run("/bin/sh", ["-c", "exit 3"], timeout: 5).status == 3)
        #expect(Spawn.run("/bin/sleep", ["5"], timeout: 0.3).status == -1)
    }
}
