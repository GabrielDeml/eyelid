import Foundation
import Testing
@testable import Insomnia

// AwakeEngine wired to fakes: no IOPM assertions, no IORegistry, no lid helper, a hand-driven clock.

@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Monotonic time: moves with `advance`, not with `jump` (a wall-clock change).
    var uptime: TimeInterval = 1_000
    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        uptime += seconds
    }
    func jump(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
final class FakePower: PowerReading {
    var hasBattery = true
    var batteryPercent: Int? = 80
    var isOnAC = false
    var isCharging = false
    var thermalState: ProcessInfo.ThermalState = .nominal
    var isLowPowerMode = false
    var hasLid = true
    var isLidClosed = false
    var externalDisplayCount = 0
}

@MainActor
final class FakeAssertions: AssertionApplying {
    private(set) var hasSystemAssertion = false
    private(set) var hasDisplayAssertion = false
    private(set) var reason = ""
    func update(system: Bool, display: Bool, reason: String) {
        hasSystemAssertion = system
        hasDisplayAssertion = display
        self.reason = reason
    }
    func releaseAll() { update(system: false, display: false, reason: "") }
}

@MainActor
final class FakeLid: LidControlling {
    var backendKind: PrivilegeBackendKind? = .helper
    var helper: HelperStatus = .installed
    var status: LidStatus = .off
    var reopenReport: ReopenReport?
    var onChange: (@MainActor () -> Void)?
    private(set) var desiredLog: [Bool] = []
    private(set) var retries = 0
    private(set) var quitReleases = 0
    var desired: Bool? { desiredLog.last }

    func start() async {}
    var recovers = false
    func recoverIfNeeded() async -> Bool { recovers }
    func refreshHelper() async {}
    func setDesired(_ engaged: Bool) { desiredLog.append(engaged) }
    func retry() { retries += 1 }
    func releaseForQuit(timeout: Duration) async {
        quitReleases += 1
        status = .off
    }
    func sleepNow() async {}

    /// Simulates the reconciler converging on the desired flag.
    func converge(lidClosed: Bool) {
        status = desired == true ? .engaged(lidClosed: lidClosed) : .off
        onChange?()
    }
}

@MainActor
final class FakeWatch: WatchMonitoring {
    var satisfiedRules: [Rule] = []
    private(set) var watches: [UUID: @MainActor () -> Void] = [:]
    func watch(_ target: WatchTarget, onExit: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        watches[id] = onExit
        return id
    }
    func cancelWatch(_ id: UUID) { watches[id] = nil }
    func exitAll() { for exit in watches.values { exit() } }
}

@MainActor
final class FakeStats: StatsRecording {
    var started = 0, ended = 0, awake: TimeInterval = 0, pokeBadge = false
    func recordSessionStarted() { started += 1 }
    func recordSessionEnded(duration: TimeInterval) { ended += 1 }
    func addAwakeTime(_ s: TimeInterval) -> Int? { awake += s; return nil }
    func addLidClosedTime(_ s: TimeInterval) {}
    func recordLidCloseSurvival() {}
    func awardPokeBadge() { pokeBadge = true }
}

@MainActor
enum FakeNotifier: NotificationPosting {
    static var posted: [NotificationID] = []
    static func post(_ id: NotificationID, title: String, body: String) { posted.append(id) }
    static func clear(_ id: NotificationID) {}
}

@MainActor
struct Harness {
    let clock = TestClock()
    let power = FakePower()
    let assertions = FakeAssertions()
    let lid = FakeLid()
    let watch = FakeWatch()
    let stats = FakeStats()
    let settings: Settings
    let engine: AwakeEngine

    /// `defaults`: share one store between harnesses (state that outlives a run); `bootID`: the boot the engine sees.
    init(lidController: Bool = true, defaults: UserDefaults = ScratchDefaults.make("Engine"),
         bootID: String? = "boot-1") {
        settings = Settings(defaults: defaults)
        let clock = clock
        engine = AwakeEngine(settings: settings, power: power, assertions: assertions, clock: { clock.now },
                             uptime: { clock.uptime }, bootID: { bootID })
        if lidController { engine.lidController = lid }
        engine.watchMonitor = watch
        engine.stats = stats
        engine.notifier = FakeNotifier.self
        FakeNotifier.posted = []
    }
}

@Suite("AwakeEngine", .serialized)
@MainActor
struct AwakeEngineTests {
    @Test func startsAsleepWithNothingAsserted() {
        let h = Harness()
        h.engine.reevaluate()
        #expect(h.engine.status == .asleep)
        #expect(h.engine.mood == .asleep)
        #expect(!h.assertions.hasSystemAssertion)
    }

    @Test func activateTimedHoldAssertsAndCountsDown() {
        let h = Harness()
        h.engine.activate(.minutes(60), source: .panel)
        let end = h.clock.now.addingTimeInterval(3600)
        #expect(h.engine.status == .timed(end: end))
        #expect(h.engine.mood == .awake)
        #expect(h.assertions.hasSystemAssertion)
        #expect(h.assertions.hasDisplayAssertion == h.settings.keepScreenOn)
        #expect(h.assertions.reason == "Insomnia: 1h timer")
        #expect(h.engine.remaining == 3600)
        #expect(h.engine.progress == 0)
        #expect(h.stats.started == 1)
    }

    @Test func keepScreenOnFollowsSettingsLive() {
        let h = Harness()
        h.settings.keepScreenOn = false
        h.engine.activate(.indefinite, source: .panel)
        #expect(!h.assertions.hasDisplayAssertion)
        h.settings.keepScreenOn = true
        h.engine.reevaluate()
        #expect(h.assertions.hasDisplayAssertion)
    }

    @Test func fixedOptionsIgnoreSettings() {
        let h = Harness()
        h.settings.keepScreenOn = true
        h.engine.activate(.indefinite, source: .cli, options: AwakeOptions(screen: false, lid: false))
        #expect(!h.assertions.hasDisplayAssertion)
        #expect(h.engine.manualHold?.followsSettings == false)
    }

    @Test func pastUntilIsIgnored() {
        let h = Harness()
        h.engine.activate(.until(h.clock.now.addingTimeInterval(-60)), source: .panel)
        #expect(h.engine.status == .asleep)
    }

    @Test func timerExpiresAndNotifies() {
        let h = Harness()
        h.engine.activate(.minutes(30), source: .panel)
        h.clock.advance(25 * 60)
        h.engine.reevaluate()
        #expect(FakeNotifier.posted == [.endingSoon])
        h.clock.advance(5 * 60)
        h.engine.reevaluate()
        #expect(h.engine.status == .asleep)
        #expect(!h.assertions.hasSystemAssertion)
        #expect(FakeNotifier.posted == [.endingSoon, .ended])
        #expect(h.stats.ended == 1)
    }

    @Test func sessionNotificationsCanBeSilenced() {
        let h = Harness()
        h.settings.sessionNotifications = false
        h.engine.activate(.minutes(30), source: .panel)
        h.clock.advance(31 * 60)
        h.engine.reevaluate()
        #expect(FakeNotifier.posted.isEmpty)
    }

    @Test func extendPushesTimedEndOnly() {
        let h = Harness()
        h.engine.activate(.minutes(30), source: .panel)
        let end = h.clock.now.addingTimeInterval(1800)
        h.engine.extend(minutes: 15)
        #expect(h.engine.status == .timed(end: end.addingTimeInterval(900)))

        h.engine.activate(.indefinite, source: .panel)
        h.engine.extend(minutes: 15)
        #expect(h.engine.status == .indefinite)
    }

    @Test func extendWithNothingStartsATimedHold() {
        let h = Harness()
        h.engine.extend(minutes: 15)
        #expect(h.engine.status == .timed(end: h.clock.now.addingTimeInterval(900)))
    }

    @Test func toggleOnAndOff() {
        let h = Harness()
        h.engine.toggle(source: .hotkey)
        #expect(h.engine.status == .indefinite)   // default duration is ∞
        h.engine.toggle(source: .hotkey)
        #expect(h.engine.status == .asleep)
        #expect(!h.assertions.hasSystemAssertion)
    }

    @Test func clientOnlyHoldsCannotBeToggledOff() {
        let h = Harness()
        let connection = UUID()
        h.engine.beginClientHold(connection: connection, label: "make", options: .systemOnly)
        #expect(h.engine.status == .client(label: "make"))
        #expect(h.engine.isHeldOnlyByClients)
        h.engine.toggle(source: .panel)
        #expect(h.engine.status == .client(label: "make"))
        h.engine.endClientHold(connection: connection)
        #expect(h.engine.status == .asleep)
    }

    @Test func babysitEndsWhenTheTargetExits() {
        let h = Harness()
        let target = WatchTarget.pid(4411, name: "ffmpeg")
        h.engine.babysit(target)
        #expect(h.engine.status == .watching(target))
        #expect(h.engine.mood == .watching)
        h.watch.exitAll()
        #expect(h.engine.status == .asleep)
        #expect(FakeNotifier.posted == [.targetExited])
    }

    @Test func deactivateEndsManualAndBabysitButNotClients() {
        let h = Harness()
        h.engine.babysit(.process(name: "rsync"))
        h.engine.activate(.indefinite, source: .panel)
        h.engine.beginClientHold(connection: UUID(), label: "cargo", options: .systemOnly)
        h.engine.deactivate(.user(.panel))
        #expect(h.engine.status == .client(label: "cargo"))
        #expect(h.watch.watches.isEmpty)
    }

    @Test func rulesHoldAndPauseUntilTheyRetrigger() {
        let h = Harness()
        let rule = Rule(condition: .app(bundleID: "com.apple.dt.Xcode", name: "Xcode"))
        h.watch.satisfiedRules = [rule]
        h.engine.reevaluate()
        #expect(h.engine.status == .automatic([rule.condition]))
        let holdID = h.engine.ruleHolds.first?.id
        h.engine.reevaluate()
        #expect(h.engine.ruleHolds.first?.id == holdID)   // stable across passes

        h.engine.toggle(source: .panel)                    // the eyes pause it
        #expect(h.engine.status == .asleep)
        #expect(h.engine.pausedRuleIDs == [rule.id])
        h.engine.reevaluate()
        #expect(h.engine.status == .asleep)                // still satisfied, still paused

        h.watch.satisfiedRules = []                        // Xcode quits: pause lifts
        h.engine.reevaluate()
        #expect(h.engine.pausedRuleIDs.isEmpty)
        h.watch.satisfiedRules = [rule]                    // Xcode again
        h.engine.reevaluate()
        #expect(h.engine.status == .automatic([rule.condition]))
    }

    @Test func awakeBatteryFloorEndsManualHold() {
        let h = Harness()
        h.settings.awakeBatteryFloorEnabled = true
        h.engine.activate(.indefinite, source: .panel)
        h.power.batteryPercent = 19
        h.engine.reevaluate()
        #expect(h.engine.manualHold == nil)
        #expect(h.engine.status == .asleep)
        #expect(h.engine.banner == .batteryFloor(percent: 20))
        #expect(!h.assertions.hasSystemAssertion)
        #expect(FakeNotifier.posted == [.batteryStop])
    }

    @Test func awakeBatteryFloorSuspendsRules() {
        let h = Harness()
        h.settings.awakeBatteryFloorEnabled = true
        h.watch.satisfiedRules = [Rule(condition: .process(name: "ffmpeg"))]
        h.engine.reevaluate()
        h.power.batteryPercent = 10
        h.engine.reevaluate()
        #expect(h.engine.status == .suspended(.awakeBatteryFloor))
        #expect(h.engine.mood == .squint)
        #expect(!h.assertions.hasSystemAssertion)
        h.power.isOnAC = true
        h.engine.reevaluate()
        #expect(h.engine.status == .automatic([.process(name: "ffmpeg")]))
    }

    @Test func withoutALidControllerLidModeNeedsSetup() {
        let h = Harness(lidController: false)
        h.settings.closedLidMode = true
        h.engine.activate(.indefinite, source: .panel)
        #expect(h.engine.lid == .needsSetup)
        #expect(!h.engine.canEngageLid)
    }

    @Test func desktopsNeverShowLid() {
        let h = Harness()
        h.power.hasLid = false
        h.settings.closedLidMode = true
        h.engine.activate(.indefinite, source: .panel)
        #expect(h.engine.lid == .off)
        #expect(h.lid.desired != true)
    }

    @Test func lidEngagesThroughTheController() {
        let h = Harness()
        h.settings.closedLidMode = true
        h.engine.activate(.indefinite, source: .panel)
        #expect(h.lid.desired == true)
        h.lid.converge(lidClosed: false)
        #expect(h.engine.lid == .engaged(lidClosed: false))
        #expect(h.engine.mood == .lid)
        #expect(h.engine.banner == .lidBatteryCallout)     // first engagement on battery
        #expect(h.settings.lidBatteryCalloutShown)

        h.engine.deactivate(.user(.panel))
        #expect(h.lid.desired == false)
        #expect(h.engine.lid == .off)
    }

    @Test func displayAssertionDropsWhileEngagedAndClosed() {
        let h = Harness()
        h.settings.closedLidMode = true
        h.settings.keepScreenOn = true
        h.engine.activate(.indefinite, source: .panel)
        h.lid.converge(lidClosed: false)
        #expect(h.assertions.hasDisplayAssertion)
        h.power.isLidClosed = true
        h.lid.converge(lidClosed: true)
        #expect(!h.assertions.hasDisplayAssertion)
        #expect(h.assertions.hasSystemAssertion)
        h.power.externalDisplayCount = 1
        h.engine.reevaluate()
        #expect(h.assertions.hasDisplayAssertion)
    }

    @Test func lowPowerModeSuspendsLidAndNotifiesOnce() {
        let h = Harness()
        h.settings.closedLidMode = true
        h.engine.activate(.indefinite, source: .panel)
        h.lid.converge(lidClosed: false)
        h.power.isLowPowerMode = true
        h.engine.reevaluate()
        #expect(h.engine.lid == .suspended(.lowPowerMode))
        #expect(h.engine.mood == .squint)
        #expect(h.lid.desired == false)
        #expect(h.assertions.hasSystemAssertion)            // plain keep-awake continues
        h.engine.reevaluate()
        #expect(FakeNotifier.posted.filter { $0 == .lidLPM }.count == 1)
    }

    @Test func batteryCapLatchesInTheBagUntilTheLidOpens() {
        let h = Harness()
        h.settings.closedLidMode = true
        h.settings.lidMaxOnBatteryMinutes = 15
        h.engine.activate(.indefinite, source: .panel)
        h.power.isLidClosed = true
        h.lid.converge(lidClosed: true)
        #expect(h.engine.lid == .engaged(lidClosed: true))

        h.clock.advance(15 * 60)
        h.engine.reevaluate()
        #expect(h.engine.lidBagSeconds == 15 * 60)
        #expect(h.engine.lid == .suspended(.lidBatteryCap))
        #expect(h.engine.latched)
        #expect(h.lid.desired == false)
        #expect(FakeNotifier.posted.contains(.lidCap))
        h.lid.converge(lidClosed: true)                     // controller released

        // Plugging in inside the bag doesn't clear the battery cap (counter resets only on lid open).
        h.power.isOnAC = true
        h.engine.reevaluate()
        #expect(h.engine.lid == .suspended(.lidBatteryCap))

        // Opening the lid resets counters and the latch; lid mode is wanted again.
        h.power.isLidClosed = false
        h.engine.reevaluate()
        #expect(h.engine.lidBagSeconds == 0)
        #expect(!h.engine.latched)
        #expect(h.lid.desired == true)
    }

    @Test func thermalGuardLatchesAfterClearingInsideTheBag() {
        let h = Harness()
        h.settings.closedLidMode = true
        h.engine.activate(.indefinite, source: .panel)
        h.power.isLidClosed = true
        h.lid.converge(lidClosed: true)
        h.power.thermalState = .serious
        h.engine.reevaluate()
        #expect(h.engine.lid == .suspended(.thermal))
        h.lid.converge(lidClosed: true)

        h.power.thermalState = .nominal
        h.clock.advance(61)
        h.engine.reevaluate()                               // calm window starts
        h.clock.advance(61)
        h.engine.reevaluate()                               // guard clears; latch holds
        #expect(!h.engine.guards.contains(.thermal))
        #expect(h.engine.lid == .latched)
        #expect(h.lid.desired == false)

        h.engine.activate(.minutes(60), source: .panel)    // a user action clears the latch
        #expect(!h.engine.latched)
        #expect(h.lid.desired == true)
    }

    @Test func turningTheLidSwitchOnStartsAHold() async {
        let h = Harness()
        await h.engine.start()
        #expect(h.engine.status == .asleep)
        h.settings.closedLidMode = true
        // Settings posts on the main queue; give the observer a turn.
        await Task.yield()
        for _ in 0..<5 where h.engine.status == .asleep { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(h.engine.status == .indefinite)
        #expect(h.lid.desired == true)
        await h.engine.prepareForQuit()
        #expect(!h.assertions.hasSystemAssertion)
    }

    @Test func pokeCounterResetsAfterIdle() {
        let h = Harness()
        for _ in 0..<5 { h.engine.poke() }
        #expect(h.engine.pokeCount == 5)
        h.clock.advance(9)
        h.engine.poke()
        #expect(h.engine.pokeCount == 1)
        for _ in 0..<49 { h.engine.poke() }
        #expect(h.engine.pokeCount == 50)
        #expect(h.stats.pokeBadge)
    }

    @Test func bannerClearsOnTheNextStateChange() {
        let h = Harness()
        h.engine.showBanner(.setupResult("Lid mode is ready"))
        h.engine.reevaluate()
        #expect(h.engine.banner == .setupResult("Lid mode is ready"))
        h.engine.activate(.indefinite, source: .panel)
        #expect(h.engine.banner == nil)
    }

    @Test func prepareForQuitReleasesEverything() async {
        let h = Harness()
        h.engine.activate(.indefinite, source: .panel)
        await h.engine.prepareForQuit()
        #expect(!h.assertions.hasSystemAssertion)
        h.engine.reevaluate()
        #expect(!h.assertions.hasSystemAssertion)
    }
}
