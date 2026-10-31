import Foundation
import Testing
import UserNotifications
@testable import Insomnia
import InsomniaShared

// Regression tests for the 2026-10-31 review, group D (engine, narrator, notifier). Each test names its finding.

/// Labels instead of copy, so a test can tell which moment produced the quip. `date` is handed out once.
@MainActor
private final class StubNarrator: Narrating {
    var date: String?
    func line(_ m: Moment, _ p: Personality, now: Date) -> String? {
        switch m {
        case .activated: return "activated"
        case .lidReopened: return "welcome back"
        case .awake(let hours): return "awake \(hours)"
        case .idle: return "idle"
        case .recoveredAfterCrash: return "recovered"
        default: return nil
        }
    }
    func dateLine(_ p: Personality, now: Date) -> String? {
        defer { date = nil }
        return date
    }
    func notification(_ id: NotificationID, _ p: Personality, context: [String: String]) -> (title: String, body: String) {
        FallbackCopy.notification(id, context: context)
    }
}

/// Records titles and clears (FakeNotifier records ids only).
@MainActor
private enum RecordingNotifier: NotificationPosting {
    static var posted: [(id: NotificationID, title: String)] = []
    static var cleared: [NotificationID] = []
    static func post(_ id: NotificationID, title: String, body: String) { posted.append((id, title)) }
    static func clear(_ id: NotificationID) { cleared.append(id) }
    static func reset() {
        posted = []
        cleared = []
    }
    static func count(_ id: NotificationID) -> Int { posted.filter { $0.id == id }.count }
}

@MainActor
private func harness(defaults: UserDefaults = ScratchDefaults.make("FixD"), bootID: String? = "boot-1",
                     narrator: (any Narrating)? = nil) -> Harness {
    let h = Harness(defaults: defaults, bootID: bootID)
    RecordingNotifier.reset()
    h.engine.notifier = RecordingNotifier.self
    h.engine.narrator = narrator
    h.settings.lidBatteryCalloutShown = true   // keep the first-engagement banner out of the way
    return h
}

@Suite("Review fixes D: engine, narrator, notifier", .serialized)
@MainActor
struct FixDTests {
    // MARK: R12 — the mission report survives the status flip that follows it

    @Test func r12MissionReportSurvivesTheLidOpenPass() {
        let narrator = StubNarrator()
        let h = harness(narrator: narrator)
        h.settings.closedLidMode = true
        h.engine.activate(.indefinite, source: .panel)
        h.power.isLidClosed = true
        h.lid.converge(lidClosed: true)
        h.clock.advance(10 * 60)

        // ClosedLidController order: the report (onChange) first, then `.engaged(lidClosed: false)` (onChange).
        h.power.isLidClosed = false
        let report = ReopenReport(closedFor: 600, batteryStart: 80, batteryEnd: 74, worstThermal: .nominal)
        h.lid.reopenReport = report
        h.lid.onChange?()
        h.lid.status = .engaged(lidClosed: false)
        h.lid.onChange?()
        #expect(h.engine.banner == .reopen(report))
        #expect(h.engine.quip == "welcome back")

        // A real state change still clears it.
        h.engine.deactivate(.user(.panel))
        #expect(h.engine.banner == nil)
    }

    @Test func r12RecoveredBannerSurvivesActivateOnLaunchAndEngagement() async {
        let h = harness(narrator: StubNarrator())
        h.lid.recovers = true
        h.settings.closedLidMode = true
        h.settings.activateOnLaunch = true
        await h.engine.start()
        #expect(h.engine.status == .indefinite)
        #expect(h.engine.banner == .recovered)
        h.lid.converge(lidClosed: false)                    // lid mode engages after launch
        #expect(h.engine.lid == .engaged(lidClosed: false))
        #expect(h.engine.banner == .recovered)              // stays until dismissed
        h.engine.dismissBanner()
        #expect(h.engine.banner == nil)
        await h.engine.prepareForQuit()
    }

    // MARK: R13 — wall-clock jumps are not awake time

    @Test func r13ForwardJumpIsNotCreditedAndMovesTheAwakeStretch() async {
        let narrator = StubNarrator()
        let h = harness(narrator: narrator)
        await h.engine.start()                              // starts time accounting
        h.engine.activate(.indefinite, source: .panel)
        let since = h.engine.awakeSince
        h.clock.advance(60)
        h.engine.reevaluate()
        #expect(h.stats.awake == 60)

        h.clock.jump(30 * 86_400)                           // the user sets the clock 30 days ahead
        h.engine.systemClockChanged()
        #expect(h.stats.awake == 60)
        #expect(h.engine.awakeSince == since?.addingTimeInterval(30 * 86_400))
        #expect(h.engine.quip != "awake 72")
        #expect(h.engine.quip != "awake 2")

        h.clock.advance(60)
        h.engine.reevaluate()
        #expect(h.stats.awake == 120)
    }

    @Test func r13BackwardJumpCreditsNothingAndLosesNothing() async {
        let h = harness()
        await h.engine.start()                              // starts time accounting
        h.engine.activate(.indefinite, source: .panel)
        h.clock.advance(60)
        h.clock.jump(-3600)
        h.engine.systemClockChanged()
        #expect(h.stats.awake == 60)                        // the real minute before the change still counts
        h.clock.advance(60)
        h.engine.reevaluate()
        #expect(h.stats.awake == 120)
    }

    @Test func r13UnannouncedJumpIsCappedAtMonotonicTime() async {
        let h = harness()
        await h.engine.start()                              // starts time accounting
        h.engine.activate(.indefinite, source: .panel)
        h.clock.advance(30)
        h.clock.jump(86_400)                                // no NSSystemClockDidChange: the backstop cap
        h.engine.reevaluate()
        #expect(h.stats.awake == 30)
    }

    @Test func r13JumpNeverTripsTheLidBatteryCap() {
        let h = harness()
        h.settings.closedLidMode = true
        h.settings.lidMaxOnBatteryMinutes = 15
        h.engine.activate(.indefinite, source: .panel)
        h.power.isLidClosed = true
        h.lid.converge(lidClosed: true)
        h.clock.advance(60)
        h.engine.reevaluate()
        #expect(h.engine.lidBagSeconds == 60)

        h.clock.jump(86_400)
        h.engine.systemClockChanged()
        #expect(h.engine.lidBagSeconds == 60)
        #expect(h.engine.lid == .engaged(lidClosed: true))
        h.clock.jump(86_400)                                // and the unannounced kind
        h.engine.reevaluate()
        #expect(h.engine.lidBagSeconds == 60)
        #expect(h.engine.lid == .engaged(lidClosed: true))
    }

    // MARK: R14 — no escalation from the stale stretch before didWake

    @Test func r14NoEscalationQuipBetweenSleepAndWake() async {
        let narrator = StubNarrator()
        let h = harness(narrator: narrator)
        await h.engine.start()                              // starts time accounting
        h.engine.activate(.indefinite, source: .panel)
        h.clock.advance(3600)
        h.engine.reevaluate()
        h.engine.systemWillSleep()
        h.clock.jump(14 * 3600)                             // asleep 14 h: wall clock moves, uptime doesn't
        h.engine.reevaluate()                               // a power observer runs before the engine's didWake
        #expect(h.engine.quip != "awake 8")
        #expect(h.engine.quip != "awake 2")
        h.engine.systemDidWake()
        #expect(h.engine.awakeSince == h.clock.now)
        #expect(h.engine.quip != "awake 8")
        #expect(h.stats.awake == 3600)                      // sleep is never awake time
    }

    // MARK: R15 — one coherent post per refresh

    @Test func r15PowerMonitorPostsOnceWithACoherentSnapshot() {
        final class Seen: @unchecked Sendable { var states: [(percent: Int?, onAC: Bool)] = [] }
        let monitor = PowerMonitor()
        let seen = Seen()
        let token = NotificationCenter.default.addObserver(forName: .insomniaPowerDidChange, object: monitor,
                                                           queue: nil) { _ in
            MainActor.assumeIsolated { seen.states.append((monitor.batteryPercent, monitor.isOnAC)) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        monitor.apply(PowerSourceReading(hasBattery: true, percent: 21, isOnAC: false, isCharging: false))
        #expect(seen.states.count == 1)
        // Plugging in at the floor: observers must never see 20% with the old "on battery".
        monitor.apply(PowerSourceReading(hasBattery: true, percent: 20, isOnAC: true, isCharging: true))
        #expect(seen.states.count == 2)
        #expect(seen.states.last?.percent == 20)
        #expect(seen.states.last?.onAC == true)
        monitor.apply(PowerSourceReading(hasBattery: true, percent: 20, isOnAC: true, isCharging: true))
        #expect(seen.states.count == 2)                     // nothing changed: no post
    }

    // MARK: R16 — out-of-range stored hotkey values

    @Test func r16OutOfRangeHotKeyValuesFallBackToDefaults() {
        let d = ScratchDefaults.make("FixD.hotkey")
        let defaults = Settings(defaults: ScratchDefaults.make("FixD.hotkeyDefaults"))
        d.set(-1, forKey: "hotKeyCode")
        d.set(Int(UInt32.max) + 1, forKey: "hotKeyModifiers")
        let s = Settings(defaults: d)                       // used to trap
        #expect(s.hotKeyCode == defaults.hotKeyCode)
        #expect(s.hotKeyModifiers == defaults.hotKeyModifiers)
        d.set(34, forKey: "hotKeyCode")
        #expect(Settings(defaults: d).hotKeyCode == 34)
    }

    // MARK: R17 — a user action retries from .error

    @Test func r17UserActionRetriesFromAnAlarmingError() {
        let h = harness()
        h.settings.closedLidMode = true
        h.engine.activate(.indefinite, source: .panel)
        h.lid.status = .error(.overridden)
        h.lid.onChange?()
        #expect(h.lid.retries == 0)                         // never by itself (CLOSED_LID §7)
        h.engine.activate(.minutes(120), source: .cli)
        #expect(h.lid.retries == 0)                         // the CLI isn't a user action on a surface
        h.engine.activate(.minutes(120), source: .panel)
        #expect(h.lid.retries == 1)
        h.engine.extend(minutes: 15, source: .hotkey)
        #expect(h.lid.retries == 2)
    }

    @Test func r17NoRetryForInformationalErrorsOrWhenNotWanted() {
        let h = harness()
        h.settings.closedLidMode = true
        h.engine.activate(.indefinite, source: .panel)
        h.lid.status = .error(.foreignFlag)
        h.lid.onChange?()
        h.engine.activate(.minutes(120), source: .panel)
        #expect(h.lid.retries == 0)
        h.lid.status = .error(.readbackMismatch)
        h.lid.onChange?()
        h.engine.deactivate(.user(.panel))                  // lid mode no longer wanted
        #expect(h.lid.retries == 0)
    }

    // MARK: R47 / R52 — notification delivery and the queue

    @Test func r47ACachedDenialStillDelivers() {
        #expect(Notifier.disposition(for: .denied) == .deliver)
        #expect(Notifier.disposition(for: .allowed) == .deliver)
        #expect(Notifier.disposition(for: .notDetermined) == .enqueue)
        #expect(Notifier.disposition(for: .unknown) == .enqueue)
    }

    @Test func r52QueueDropsStaleSessionPostsAndRechecksTheGate() {
        var q = NotificationQueue()
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        q.enqueue(.ended, title: "ended", body: "", at: t0)
        q.enqueue(.lidStuck, title: "stuck", body: "", at: t0)
        q.enqueue(.targetExited, title: "old", body: "", at: t0)
        q.enqueue(.targetExited, title: "new", body: "", at: t0.addingTimeInterval(9 * 60))   // latest per id
        let drained = q.drain(now: t0.addingTimeInterval(10 * 60), shouldDeliver: { _ in true })
        #expect(drained.map(\.id) == [.lidStuck, .targetExited])
        #expect(drained.last?.title == "new")
        #expect(q.entries.isEmpty)

        q.enqueue(.endingSoon, title: "", body: "", at: t0)
        q.enqueue(.foreignFlag, title: "", body: "", at: t0)
        let gated = q.drain(now: t0, shouldDeliver: { !$0.isSessionNotification })   // session notifications off now
        #expect(gated.map(\.id) == [.foreignFlag])

        q.enqueue(.recovered, title: "", body: "", at: t0)
        q.remove(.recovered)
        #expect(q.entries.isEmpty)
    }

    @Test func r52ANewAwakeStretchClearsStaleOutcomes() {
        let h = harness()
        h.engine.activate(.indefinite, source: .panel)
        #expect(RecordingNotifier.cleared.contains(.ended))
        #expect(RecordingNotifier.cleared.contains(.targetExited))
    }

    // MARK: R48 — "Allow Sleep" from a notification releases rules too

    @Test func r48AllowSleepPausesARuleHold() {
        let h = harness()
        let rule = Rule(condition: .onAC, enabled: true)
        h.watch.satisfiedRules = [rule]
        h.engine.reevaluate()
        #expect(h.engine.isAwake)
        Notifier.handleResponse(actionIdentifier: Notifier.Action.stop.rawValue, requestIdentifier: "lid-heat",
                                engine: h.engine)
        #expect(!h.engine.isAwake)
        #expect(h.engine.pausedRuleIDs.contains(rule.id))
        // While asleep it never activates.
        Notifier.handleResponse(actionIdentifier: Notifier.Action.stop.rawValue, requestIdentifier: "lid-heat",
                                engine: h.engine)
        #expect(!h.engine.isAwake)
    }

    // MARK: R49 — frontmost notifications reach Notification Center

    @Test func r49ForegroundPresentationListsWithoutSound() {
        let options = NotificationDelegate.foregroundPresentation
        #expect(options.contains(.banner))
        #expect(options.contains(.list))
        #expect(!options.contains(.sound))
    }

    // MARK: R50 — date lines are earned

    @Test func r50DateLineIsExemptFromTheBudget() {
        let narrator = StubNarrator()
        let h = harness(narrator: narrator)
        narrator.date = "boo"
        h.engine.activate(.minutes(60), source: .panel)
        #expect(h.engine.quip == "boo")
        h.engine.deactivate(.user(.panel))
        h.clock.advance(60)
        h.engine.activate(.minutes(60), source: .panel)   // inside 4 h: the budget wasn't spent on the date line
        #expect(h.engine.quip == "activated")
    }

    @Test func r50DateLineOnPanelOpenKeepsTheDaysIdleLine() {
        let narrator = StubNarrator()
        let h = harness(narrator: narrator)
        narrator.date = "boo"
        h.engine.setPanelVisible(true)
        #expect(h.engine.quip == "boo")
        h.engine.setPanelVisible(false)
        h.engine.setPanelVisible(true)
        #expect(h.engine.quip == "idle")
    }

    // MARK: R51 — Professional never spends the budget

    @Test func r51ProfessionalMomentsDontSpendTheBudget() {
        let h = harness()
        h.engine.narrator = Narrator(settings: h.settings, calendar: Calendar(identifier: .gregorian), seed: 1)
        h.settings.personality = .professional
        h.engine.activate(.minutes(60), source: .panel)
        #expect(h.engine.quip == nil)
        h.engine.deactivate(.user(.panel))
        h.settings.personality = .cheeky
        h.clock.advance(60)
        h.engine.activate(.minutes(60), source: .panel)
        #expect(h.engine.quip != nil)
    }

    @Test func r51PersonalityChangeClearsTheQuip() async {
        let h = harness(narrator: StubNarrator())
        await h.engine.start()
        h.engine.activate(.minutes(60), source: .panel)
        #expect(h.engine.quip == "activated")
        h.settings.personality = .unhinged
        for _ in 0..<5 where h.engine.quip != nil { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(h.engine.quip == nil)
        await h.engine.prepareForQuit()
    }

    // MARK: R53 — the target-exited notification names the target without its pid

    @Test func r53TargetExitedTitleHasNoPid() {
        let h = harness()
        h.engine.babysit(.pid(4411, name: "ffmpeg"))
        h.watch.exitAll()
        #expect(RecordingNotifier.posted.last?.id == .targetExited)
        #expect(RecordingNotifier.posted.last?.title == "ffmpeg finished")
    }

    // MARK: R59 — quit releases lid mode exactly once

    @Test func r59PrepareForQuitReleasesLidModeOnce() async {
        let h = harness()
        h.settings.closedLidMode = true
        h.engine.activate(.indefinite, source: .panel)
        h.power.isLidClosed = true
        h.lid.converge(lidClosed: true)
        await h.engine.prepareForQuit()
        #expect(h.lid.quitReleases == 1)
        #expect(!h.assertions.hasSystemAssertion)
        #expect(!h.assertions.hasDisplayAssertion)
        await h.engine.prepareForQuit()
        #expect(h.lid.quitReleases == 1)
    }

    // MARK: R69 — the foreign-flag notification posts once per boot

    private func tripForeignFlag(_ h: Harness) {
        h.settings.closedLidMode = true
        h.engine.activate(.indefinite, source: .panel)
        h.lid.status = .error(.foreignFlag)
        h.lid.onChange?()
    }

    @Test func r69ForeignFlagNotifiesOncePerBoot() {
        let shared = ScratchDefaults.make("FixD.boot")
        let first = harness(defaults: shared, bootID: "100")
        tripForeignFlag(first)
        #expect(RecordingNotifier.count(.foreignFlag) == 1)
        #expect(first.settings.foreignFlagNotifiedBoot == "100")

        let sameBoot = harness(defaults: shared, bootID: "100")   // relaunch, same boot
        tripForeignFlag(sameBoot)
        #expect(RecordingNotifier.count(.foreignFlag) == 0)

        let newBoot = harness(defaults: shared, bootID: "200")
        tripForeignFlag(newBoot)
        #expect(RecordingNotifier.count(.foreignFlag) == 1)
    }

    @Test func r69UnknownBootNotifiesAndIsNeverStored() {
        let shared = ScratchDefaults.make("FixD.unknownBoot")
        let h = harness(defaults: shared, bootID: nil)
        tripForeignFlag(h)
        #expect(RecordingNotifier.count(.foreignFlag) == 1)
        #expect(h.settings.foreignFlagNotifiedBoot == nil)
        let next = harness(defaults: shared, bootID: "300")
        tripForeignFlag(next)
        #expect(RecordingNotifier.count(.foreignFlag) == 1)
    }
}
