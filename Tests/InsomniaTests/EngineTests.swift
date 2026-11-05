import Foundation
import Testing
@testable import Insomnia

// MARK: Fakes

@MainActor
final class FakePower: PowerSource {
    var state = PowerState(hasBattery: true, batteryPercent: 80, isOnAC: true, thermal: .nominal, hasLid: true,
                           isLidClosed: false, externalDisplays: 0)
    var onChange: (() -> Void)?
    var idleSeconds: TimeInterval = 0
    func refreshLid() {}
    func set(_ body: (inout PowerState) -> Void) {
        body(&state)
        onChange?()
    }
}

@MainActor
final class FakeLid: LidControlling {
    var isReady = true
    var needsSetup = false
    var isEngaged = false
    var isStuck = false
    var needsAttention = false
    var onChange: (() -> Void)?
    /// Engages as soon as it is asked to (a perfect helper).
    var follows = true
    private(set) var events: [String] = []
    private(set) var closedWithoutDisplay = false

    var desired: Bool? { events.last(where: { $0.hasPrefix("desired:") }).map { $0 == "desired:true" } }

    func setDesired(_ on: Bool) {
        events.append("desired:\(on)")
        if follows { isEngaged = on && isReady }
    }
    func update(closedWithoutDisplay closed: Bool) { closedWithoutDisplay = closed }
    func sleepNow() {
        events.append("sleepNow")
        isEngaged = false
    }
    func userActed() { events.append("userActed") }
    func install() { events.append("install") }
    func releaseForQuit() async {
        events.append("releaseForQuit")
        isEngaged = false
    }
}

@MainActor
final class FakeAssertions: AssertionApplying {
    private(set) var hasSystemAssertion = false
    private(set) var hasDisplayAssertion = false
    private(set) var releaseAllCount = 0
    func update(system: Bool, display: Bool, reason: String) {
        hasSystemAssertion = system
        hasDisplayAssertion = display
    }
    func releaseAll() {
        releaseAllCount += 1
        update(system: false, display: false, reason: "")
    }
}

@MainActor
final class Rig {
    var t = Date(timeIntervalSince1970: 1_000_000)
    let power = FakePower()
    let lid = FakeLid()
    let assertions = FakeAssertions()
    let prefs = Preferences(defaults: ScratchDefaults.make("engine"))
    lazy var engine: Engine = Engine(prefs: prefs, power: power, lid: lid, assertions: assertions,
                                     now: { [unowned self] in self.t }, armsTimers: false)

    init(_ configure: (Rig) -> Void = { _ in }) {
        configure(self)
        engine.start()
    }

    func advance(_ seconds: TimeInterval) {
        t = t.addingTimeInterval(seconds)
        engine.reconcile()
    }

    var sleeps: Int { lid.events.filter { $0 == "sleepNow" }.count }
}

// MARK: Keep awake

@MainActor
@Suite("Engine: keep awake")
struct EngineKeepAwakeTests {
    @Test func toggleHoldsSystemAndScreen() {
        let r = Rig()
        r.engine.toggle()
        #expect(r.engine.isOn && r.engine.endsAt == nil)
        #expect(r.assertions.hasSystemAssertion && r.assertions.hasDisplayAssertion)
        #expect(r.engine.mode == .screenOn)
        r.engine.toggle()
        #expect(!r.engine.isOn && !r.assertions.hasSystemAssertion && !r.assertions.hasDisplayAssertion)
        #expect(r.engine.mode == .off)
    }

    @Test func keepScreenOnAppliesLive() {
        let r = Rig()
        r.engine.toggle()
        r.prefs.keepScreenOn = false
        #expect(r.assertions.hasSystemAssertion && !r.assertions.hasDisplayAssertion)
        #expect(r.engine.mode == .awake)
    }

    @Test func timerExpires() {
        let r = Rig()
        r.engine.start(minutes: 60)
        #expect(r.engine.runMinutes == 60 && r.engine.endsAt == r.t.addingTimeInterval(3600))
        r.advance(3599)
        #expect(r.engine.isOn)
        r.advance(1)
        #expect(!r.engine.isOn && !r.assertions.hasSystemAssertion)
    }

    @Test func powerButtonUsesItsSetting() {
        let r = Rig { $0.prefs.powerButtonMinutes = 120 }
        r.engine.toggle()
        #expect(r.engine.endsAt == r.t.addingTimeInterval(7200))
    }

    @Test func quitReleasesEverything() async {
        let r = Rig()
        r.engine.toggle()
        await r.engine.prepareForQuit()
        #expect(r.assertions.releaseAllCount == 1 && !r.assertions.hasSystemAssertion)
        #expect(r.lid.events.last == "releaseForQuit")
    }
}

// MARK: Lid mode

@MainActor
@Suite("Engine: lid mode")
struct EngineLidTests {
    @Test func lidWantedOnlyWhenOnAndSetAndReady() {
        let r = Rig { $0.prefs.closedLidMode = true }
        #expect(r.lid.desired != true)
        r.engine.toggle()
        #expect(r.lid.desired == true && r.engine.mode == .lid)
        r.engine.toggle()
        #expect(r.lid.desired == false)
    }

    @Test func lidSwitchAlsoTurnsInsomniaOn() {
        let r = Rig()
        r.engine.setLidMode(true)
        #expect(r.engine.isOn && r.prefs.closedLidMode && r.lid.desired == true)
    }

    @Test func lidSwitchRegistersTheHelperWhenNeeded() {
        let r = Rig { $0.lid.needsSetup = true; $0.lid.isReady = false }
        r.engine.setLidMode(true)
        #expect(r.lid.events.contains("install"))
        #expect(r.lid.desired != true)
    }

    @Test func noLidModeOnADesktop() {
        let r = Rig { $0.power.state.hasLid = false; $0.prefs.closedLidMode = true }
        r.engine.toggle()
        #expect(r.lid.desired != true)
    }

    @Test func screenAssertionDropsWhileShutWithoutDisplay() {
        let r = Rig { $0.prefs.closedLidMode = true }
        r.engine.toggle()
        r.power.set { $0.isLidClosed = true }
        #expect(r.lid.closedWithoutDisplay)
        #expect(r.assertions.hasSystemAssertion && !r.assertions.hasDisplayAssertion)
        r.power.set { $0.externalDisplays = 1 }
        #expect(r.assertions.hasDisplayAssertion)
    }

    @Test func sleepWhenLidClosesBlocksLidModeOnBattery() {
        let r = Rig { $0.prefs.closedLidMode = true; $0.prefs.whenUnplugged = .sleepWhenLidCloses }
        r.engine.toggle()
        #expect(r.lid.desired == true)
        r.power.set { $0.isOnAC = false }
        #expect(r.lid.desired == false && r.engine.isOn)
        r.power.set { $0.isOnAC = true }
        #expect(r.lid.desired == true)
    }

    @Test func keepGoingKeepsLidModeOnBattery() {
        let r = Rig { $0.prefs.closedLidMode = true; $0.prefs.whenUnplugged = .keepGoing }
        r.engine.toggle()
        r.power.set { $0.isOnAC = false }
        #expect(r.lid.desired == true)
    }

    /// Dropped with the lid shut (in a bag): re-plugging must not re-arm it until the lid opens or the user acts.
    @Test func latchHoldsUntilTheLidOpens() {
        let r = Rig { $0.prefs.closedLidMode = true; $0.prefs.whenUnplugged = .sleepWhenLidCloses }
        r.engine.toggle()
        r.power.set { $0.isLidClosed = true }
        r.power.set { $0.isOnAC = false }
        #expect(r.lid.desired == false)
        r.power.set { $0.isOnAC = true }
        #expect(r.lid.desired == false)
        r.power.set { $0.isLidClosed = false }
        #expect(r.lid.desired == true)
    }

    @Test func userActionClearsTheLatch() {
        let r = Rig { $0.prefs.closedLidMode = true; $0.prefs.whenUnplugged = .sleepWhenLidCloses }
        r.engine.toggle()
        r.power.set { $0.isLidClosed = true }
        r.power.set { $0.isOnAC = false }
        r.power.set { $0.isOnAC = true }
        r.engine.start(minutes: 60)
        #expect(r.lid.desired == true)
    }
}

// MARK: When unplugged

@MainActor
@Suite("Engine: when unplugged")
struct EngineUnpluggedTests {
    @Test func turnOffFiresOnTheUnplugMoment() {
        let r = Rig { $0.prefs.whenUnplugged = .turnOff }
        r.engine.toggle()
        r.power.set { $0.isOnAC = false }
        #expect(!r.engine.isOn)
        #expect(r.engine.notice?.isWarning == false)
        // Starting again on battery works.
        r.engine.toggle()
        r.engine.reconcile()
        #expect(r.engine.isOn)
    }

    @Test func turnOffIgnoresADesktop() {
        let r = Rig { $0.prefs.whenUnplugged = .turnOff; $0.power.state.hasBattery = false }
        r.engine.toggle()
        r.power.set { $0.isOnAC = false }   // nonsense reading on a desktop: no battery, so never "on battery"
        #expect(r.engine.isOn)
    }
}

// MARK: Safety

@MainActor
@Suite("Engine: safety")
struct EngineSafetyTests {
    @Test func criticalWithTheLidOpenAndSomeoneTypingTurnsOff() {
        let r = Rig()
        r.engine.toggle()
        r.power.set { $0.thermal = .critical }
        #expect(!r.engine.isOn && r.sleeps == 0)
        #expect(r.engine.notice?.text == "Turned off because your Mac got hot")
        #expect(r.engine.needsAttention)
        r.engine.panelOpened()
        #expect(!r.engine.needsAttention)
    }

    @Test func criticalWhileIdleSleeps() {
        let r = Rig { $0.power.idleSeconds = 600 }
        r.engine.toggle()
        r.power.set { $0.thermal = .critical }
        #expect(!r.engine.isOn && r.sleeps == 1)
        #expect(r.engine.notice?.text == "Slept because your Mac got hot")
    }

    @Test func seriousWithTheLidOpenWaitsFiveMinutes() {
        let r = Rig { $0.power.idleSeconds = 600 }
        r.engine.toggle()
        r.power.set { $0.thermal = .serious }
        r.advance(299)
        #expect(r.engine.isOn)
        r.advance(1)
        #expect(!r.engine.isOn && r.sleeps == 1)
    }

    @Test func seriousInABagSleepsAfterAMinute() {
        let r = Rig { $0.prefs.closedLidMode = true }
        r.engine.toggle()
        r.power.set { $0.isLidClosed = true }
        r.power.set { $0.thermal = .serious }
        r.advance(59)
        #expect(r.engine.isOn)
        r.advance(1)
        #expect(!r.engine.isOn)
        // The lid release is queued before the sleep.
        let events = r.lid.events
        let release = events.lastIndex(of: "desired:false")
        let sleep = events.lastIndex(of: "sleepNow")
        #expect(release != nil && sleep != nil && release! < sleep!)
    }

    @Test func bagRuleTripsAtFairAfterFiveMinutes() {
        let r = Rig { $0.prefs.closedLidMode = true }
        r.engine.toggle()
        r.power.set { $0.isLidClosed = true }
        r.power.set { $0.thermal = .fair }
        r.advance(299)
        #expect(r.engine.isOn)
        r.advance(1)
        #expect(!r.engine.isOn && r.sleeps == 1)
    }

    /// The bag window counts from when the bag condition began, not from when the Mac got warm.
    @Test func bagWindowStartsWhenTheLidCloses() {
        let r = Rig { $0.prefs.closedLidMode = true }
        r.engine.toggle()
        r.power.set { $0.thermal = .fair }
        r.advance(600)
        r.power.set { $0.isLidClosed = true }
        #expect(r.engine.isOn)
        r.advance(299)
        #expect(r.engine.isOn)
        r.advance(1)
        #expect(!r.engine.isOn && r.sleeps == 1)
    }

    @Test func clockSetBackDoesNotStretchAWindow() {
        let r = Rig { $0.power.idleSeconds = 600 }
        r.engine.toggle()
        r.power.set { $0.thermal = .serious }
        r.advance(-3600)
        r.advance(299)
        #expect(r.engine.isOn)
        r.advance(1)
        #expect(!r.engine.isOn)
    }

    @Test func fairWithTheLidOpenIsFine() {
        let r = Rig()
        r.engine.toggle()
        r.power.set { $0.thermal = .fair }
        r.advance(3600)
        #expect(r.engine.isOn)
    }

    @Test func overheatProtectionCanBeSwitchedOff() {
        let r = Rig { $0.prefs.overheatProtection = false; $0.power.idleSeconds = 600 }
        r.engine.toggle()
        r.power.set { $0.thermal = .critical }
        #expect(r.engine.isOn && r.sleeps == 0)
    }

    @Test func tripActionAlwaysSleep() {
        let r = Rig { $0.prefs.tripAction = .sleep }
        r.engine.toggle()
        r.power.set { $0.thermal = .critical }
        #expect(r.sleeps == 1)
    }

    @Test func tripActionTurnOffNeverSleepsWithTheLidOpen() {
        let r = Rig { $0.prefs.tripAction = .turnOff; $0.power.idleSeconds = 600 }
        r.engine.toggle()
        r.power.set { $0.thermal = .critical }
        #expect(!r.engine.isOn && r.sleeps == 0)
    }

    @Test func nothingHappensWhileOff() {
        let r = Rig { $0.power.idleSeconds = 600 }
        r.power.set { $0.thermal = .critical }
        #expect(r.sleeps == 0 && r.engine.notice == nil)
    }

    /// Trips once per episode: turning back on while still hot works, with lid mode paused.
    @Test func turningOnDuringAnEpisodeStaysOnWithLidPaused() {
        let r = Rig { $0.prefs.closedLidMode = true }
        r.engine.toggle()
        r.power.set { $0.thermal = .critical }
        #expect(!r.engine.isOn)
        r.engine.toggle()
        r.engine.reconcile()
        #expect(r.engine.isOn && r.engine.hotEpisode && r.lid.desired == false)
        r.power.set { $0.thermal = .nominal }
        #expect(!r.engine.hotEpisode && r.lid.desired == true)
    }

    @Test func lowBatteryTripsOnBattery() {
        let r = Rig { $0.power.state.isOnAC = false; $0.power.state.batteryPercent = 40; $0.power.idleSeconds = 600 }
        r.engine.toggle()
        r.power.set { $0.batteryPercent = 12 }
        #expect(!r.engine.isOn && r.sleeps == 1)
        #expect(r.engine.notice?.text == "Slept: battery at 12%")
    }

    @Test func lowBatteryRespectsItsSwitchAndThreshold() {
        let r = Rig { $0.power.state.isOnAC = false; $0.prefs.lowBatteryPercent = 30 }
        r.engine.toggle()
        r.power.set { $0.batteryPercent = 31 }
        #expect(r.engine.isOn)
        r.power.set { $0.batteryPercent = 30 }
        #expect(!r.engine.isOn)

        let off = Rig { $0.power.state.isOnAC = false; $0.prefs.lowBatteryProtection = false }
        off.engine.toggle()
        off.power.set { $0.batteryPercent = 5 }
        #expect(off.engine.isOn)
    }

    @Test func lowBatteryRule() {
        let battery = PowerState(hasBattery: true, batteryPercent: 12, isOnAC: false)
        #expect(Engine.isLowBattery(battery, threshold: 12, was: false))
        var p = battery
        p.batteryPercent = 13
        #expect(!Engine.isLowBattery(p, threshold: 12, was: false))
        #expect(Engine.isLowBattery(p, threshold: 12, was: true))      // hysteresis: clears at 15
        p.batteryPercent = 15
        #expect(!Engine.isLowBattery(p, threshold: 12, was: true))
        p.batteryPercent = nil                                           // unknown keeps the previous answer
        #expect(Engine.isLowBattery(p, threshold: 12, was: true))
        #expect(!Engine.isLowBattery(p, threshold: 12, was: false))
        p.batteryPercent = 1
        p.isOnAC = true                                                  // never on the adapter
        #expect(!Engine.isLowBattery(p, threshold: 12, was: true))
    }

    @Test func thresholdNeverReachesTheHelperBackstop() {
        let prefs = Preferences(defaults: ScratchDefaults.make("clamp"))
        prefs.lowBatteryPercent = 5
        #expect(prefs.lowBatteryPercent == 11)
        prefs.lowBatteryPercent = 90
        #expect(prefs.lowBatteryPercent == 50)
    }
}

@MainActor
@Suite("Preferences")
struct PreferencesTests {
    @Test func defaultsAndPersistence() {
        let defaults = ScratchDefaults.make("prefs")
        let a = Preferences(defaults: defaults)
        #expect(a.keepScreenOn && !a.closedLidMode && a.whenUnplugged == .sleepWhenLidCloses)
        #expect(a.overheatProtection && a.lowBatteryProtection && a.lowBatteryPercent == 12)
        #expect(a.timerPresets == [60, 120, 240, 480] && a.powerButtonMinutes == 0)
        a.closedLidMode = true
        a.timerPresets = [15, 30, 45, 60]
        a.tripAction = .turnOff
        let b = Preferences(defaults: defaults)
        #expect(b.closedLidMode && b.timerPresets == [15, 30, 45, 60] && b.tripAction == .turnOff)
    }

    @Test func initNeverWrites() {
        let defaults = ScratchDefaults.make("prefs-init")
        _ = Preferences(defaults: defaults)
        #expect(defaults.dictionaryRepresentation().isEmpty)
    }

    @Test func durations() {
        #expect(DurationText.short(minutes: 45) == "45m")
        #expect(DurationText.short(minutes: 120) == "2h")
        #expect(DurationText.short(minutes: 90) == "1h 30m")
        let now = Date(timeIntervalSince1970: 0)
        #expect(DurationText.left(until: now.addingTimeInterval(61), now: now) == "2m left")
        #expect(DurationText.left(until: now.addingTimeInterval(102 * 60), now: now) == "1h 42m left")
    }
}
