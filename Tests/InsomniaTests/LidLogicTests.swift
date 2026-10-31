import Foundation
import Testing
@testable import Insomnia

// The pure lid pieces of the engine: desired flag, latch, LidStatus derivation, lid-closed counters, EyeMood.
// docs/CLOSED_LID.md §5, §7; ARCHITECTURE.md AwakeEngine steps 6–8.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite("Lid: desired flag")
struct DesiredLidTests {
    @Test func requiresEveryCondition() {
        #expect(Policy.desiredLid(lidAllowed: true, hasLid: true, helper: .installed, latched: false))
        #expect(!Policy.desiredLid(lidAllowed: false, hasLid: true, helper: .installed, latched: false))
        #expect(!Policy.desiredLid(lidAllowed: true, hasLid: false, helper: .installed, latched: false))
        #expect(!Policy.desiredLid(lidAllowed: true, hasLid: true, helper: .requiresApproval, latched: false))
        #expect(!Policy.desiredLid(lidAllowed: true, hasLid: true, helper: .notInstalled, latched: false))
        #expect(!Policy.desiredLid(lidAllowed: true, hasLid: true, helper: .unreachable, latched: false))
        #expect(!Policy.desiredLid(lidAllowed: true, hasLid: true, helper: .installed, latched: true))
    }
}

@Suite("Lid: latch")
struct LatchTests {
    @Test func latchesWhenAGuardTripsWithTheLidClosed() {
        #expect(Policy.latch(previous: false, lidGuardTripped: true, isLidClosed: true, lidOpened: false, userAction: false))
    }

    @Test func doesNotLatchWithTheLidOpen() {
        #expect(!Policy.latch(previous: false, lidGuardTripped: true, isLidClosed: false, lidOpened: false, userAction: false))
    }

    @Test func staysLatchedAfterTheGuardClearsWhileClosed() {
        // The DarkWake case: the guard cleared inside the bag, but nothing re-engages.
        #expect(Policy.latch(previous: true, lidGuardTripped: false, isLidClosed: true, lidOpened: false, userAction: false))
    }

    @Test func clamshellOpenClearsIt() {
        #expect(!Policy.latch(previous: true, lidGuardTripped: false, isLidClosed: false, lidOpened: true, userAction: false))
        // Opened while the guard is still tripped: lid is open, so no latch (the guard itself still suspends).
        #expect(!Policy.latch(previous: true, lidGuardTripped: true, isLidClosed: false, lidOpened: true, userAction: false))
    }

    @Test func userActionClearsItOnceTheGuardIsGone() {
        #expect(!Policy.latch(previous: true, lidGuardTripped: false, isLidClosed: true, lidOpened: false, userAction: true))
    }

    @Test func userActionCannotBeatAGuardThatIsStillTrippedInsideTheBag() {
        #expect(Policy.latch(previous: true, lidGuardTripped: true, isLidClosed: true, lidOpened: false, userAction: true))
    }

    @Test func noGuardNoLatch() {
        #expect(!Policy.latch(previous: false, lidGuardTripped: false, isLidClosed: true, lidOpened: false, userAction: false))
    }
}

@Suite("Lid: LidStatus derivation")
struct LidStatusTests {
    private func derive(controller: LidStatus = .off, wantLid: Bool = true, hasLid: Bool = true,
                        helper: HelperStatus = .installed, guards: [GuardReason] = [], latched: Bool = false) -> LidStatus {
        Policy.lidStatus(controller: controller, wantLid: wantLid, hasLid: hasLid, helper: helper,
                         lidGuards: guards, latched: latched)
    }

    @Test func stuckAlwaysWins() {
        #expect(derive(controller: .stuck, wantLid: false) == .stuck)
        #expect(derive(controller: .stuck, hasLid: false) == .stuck)
        #expect(derive(controller: .stuck, helper: .unreachable, guards: [.thermal], latched: true) == .stuck)
    }

    @Test func notWantedIsOff() {
        #expect(derive(controller: .engaged(lidClosed: false), wantLid: false) == .off)
        #expect(derive(controller: .error(.readbackMismatch), wantLid: false) == .off)
    }

    @Test func desktopsAreAlwaysOff() {
        #expect(derive(hasLid: false, helper: .notInstalled) == .off)
    }

    @Test func missingHelperNeedsSetup() {
        for helper: HelperStatus in [.notInstalled, .requiresApproval, .unreachable, .notFound, .unsafeLocation,
                                     .leftoverHelper, .daemonDisabled, .partial(sudoers: true, safetyDaemon: false),
                                     .versionMismatch(running: "a", bundled: "b")] {
            #expect(derive(helper: helper, guards: [.thermal]) == .needsSetup)
        }
    }

    @Test func firstGuardSuspends() {
        #expect(derive(controller: .engaged(lidClosed: true), guards: [.thermal, .lidBatteryCap]) == .suspended(.thermal))
    }

    @Test func guardBeatsLatch() {
        #expect(derive(guards: [.acRequired], latched: true) == .suspended(.acRequired))
    }

    @Test func latchedOnceGuardsClear() {
        #expect(derive(controller: .off, latched: true) == .latched)
    }

    @Test func otherwiseTheControllerSpeaks() {
        #expect(derive(controller: .engaging) == .engaging)
        #expect(derive(controller: .engaged(lidClosed: true)) == .engaged(lidClosed: true))
        #expect(derive(controller: .error(.foreignFlag)) == .error(.foreignFlag))
        #expect(derive(controller: .off) == .off)
    }
}

@Suite("Lid: closed counters")
struct LidCounterTests {
    @Test func accumulatesBagAndACSeparately() {
        var c = LidCloseCounters()
        c.advance(to: t0, mode: .bag)
        c.advance(to: t0.addingTimeInterval(40 * 60), mode: .closedOnAC)   // 40 min in the bag, then plugged in
        c.advance(to: t0.addingTimeInterval(70 * 60), mode: .closedOnAC)
        #expect(c.bagSeconds == 40 * 60)
        #expect(c.closedACSeconds == 30 * 60)
    }

    @Test func idleCreditsNothing() {
        var c = LidCloseCounters()
        c.advance(to: t0, mode: .idle)
        c.advance(to: t0.addingTimeInterval(3600), mode: .bag)
        #expect(c.bagSeconds == 0 && c.closedACSeconds == 0)
    }

    @Test func survivesNewHoldsAndPowerChangesButResetsOnLidOpen() {
        var c = LidCloseCounters()
        c.advance(to: t0, mode: .bag)
        c.advance(to: t0.addingTimeInterval(600), mode: .idle)    // released (guard), still closed
        c.advance(to: t0.addingTimeInterval(900), mode: .bag)     // re-engaged
        c.advance(to: t0.addingTimeInterval(1200), mode: .bag)
        #expect(c.bagSeconds == 900)
        c.lidOpened(at: t0.addingTimeInterval(1300))
        #expect(c.bagSeconds == 0 && c.closedACSeconds == 0)
        #expect(c.mode == .idle)
    }

    @Test func clockGoingBackwardsCreditsNothing() {
        var c = LidCloseCounters()
        c.advance(to: t0, mode: .bag)
        c.advance(to: t0.addingTimeInterval(-500), mode: .bag)
        #expect(c.bagSeconds == 0)
    }

    @Test func capDeadlines() {
        var c = LidCloseCounters()
        c.advance(to: t0, mode: .bag)
        c.advance(to: t0.addingTimeInterval(20 * 60), mode: .bag)
        #expect(c.capDeadline(batteryCapMinutes: 60, acCapMinutes: nil) == t0.addingTimeInterval(60 * 60))

        c.advance(to: t0.addingTimeInterval(30 * 60), mode: .closedOnAC)
        #expect(c.capDeadline(batteryCapMinutes: 60, acCapMinutes: nil) == nil)          // no AC cap
        #expect(c.capDeadline(batteryCapMinutes: 60, acCapMinutes: 60) == t0.addingTimeInterval(90 * 60))

        c.advance(to: t0.addingTimeInterval(31 * 60), mode: .idle)
        #expect(c.capDeadline(batteryCapMinutes: 60, acCapMinutes: 60) == nil)
    }

    @Test func capAlreadyReachedHasNoDeadline() {
        var c = LidCloseCounters()
        c.advance(to: t0, mode: .bag)
        c.advance(to: t0.addingTimeInterval(16 * 60), mode: .bag)
        #expect(c.capDeadline(batteryCapMinutes: 15, acCapMinutes: nil) == nil)
    }

    @Test func modeFromState() {
        #expect(LidCloseCounters.mode(engaged: true, isLidClosed: true, externalDisplays: 0, isOnAC: false) == .bag)
        #expect(LidCloseCounters.mode(engaged: true, isLidClosed: true, externalDisplays: 0, isOnAC: true) == .closedOnAC)
        #expect(LidCloseCounters.mode(engaged: true, isLidClosed: true, externalDisplays: 1, isOnAC: false) == .idle)
        #expect(LidCloseCounters.mode(engaged: true, isLidClosed: false, externalDisplays: 0, isOnAC: false) == .idle)
        #expect(LidCloseCounters.mode(engaged: false, isLidClosed: true, externalDisplays: 0, isOnAC: false) == .idle)
    }
}

@Suite("EyeMood priority")
struct EyeMoodTests {
    @Test func alarmedBeatsEverything() {
        #expect(EyeMood(status: .indefinite, lid: .stuck) == .alarmed)
        #expect(EyeMood(status: .asleep, lid: .error(.safetyNetLost)) == .alarmed)
    }

    @Test func informationalErrorsDoNotAlarm() {
        #expect(EyeMood(status: .indefinite, lid: .error(.foreignFlag)) == .awake)
        #expect(EyeMood(status: .indefinite, lid: .error(.otherUser)) == .awake)
    }

    @Test func squintForAlarmGuardsOnly() {
        #expect(EyeMood(status: .indefinite, lid: .suspended(.thermal)) == .squint)
        #expect(EyeMood(status: .indefinite, lid: .suspended(.acRequired)) == .awake)
        #expect(EyeMood(status: .indefinite, lid: .suspended(.lidBatteryCap)) == .awake)
        #expect(EyeMood(status: .suspended(.awakeBatteryFloor), lid: .off) == .squint)
    }

    @Test func lidThenAwakeThenWatching() {
        #expect(EyeMood(status: .indefinite, lid: .engaged(lidClosed: false)) == .lid)
        #expect(EyeMood(status: .timed(end: t0), lid: .off) == .awake)
        #expect(EyeMood(status: .client(label: "make"), lid: .off) == .watching)
        #expect(EyeMood(status: .automatic([]), lid: .latched) == .watching)
        #expect(EyeMood(status: .asleep, lid: .off) == .asleep)
    }
}

@Suite("RootDomain + power source parsing")
struct PlatformParsingTests {
    @Test func clamshellBits() {
        for (bits, closed, sleeps) in [(UInt(0), false, false), (1, true, false), (2, false, true), (3, true, true)] {
            let decoded = RootDomain.decodeClamshell(bits)
            #expect(decoded.closed == closed)
            #expect(decoded.causesSleep == sleeps)
        }
        #expect(RootDomain.clamshellStateChangeMessage == 0xE003_4100)
    }

    /// Read-only probes of this Mac (IORegistry + IOPS). Values vary per machine; only their shape is checked.
    @Test func liveReadsAreSane() {
        let reading = PowerSourceReading.current()
        if let percent = reading.percent { #expect((0...100).contains(percent)) }
        if !reading.hasBattery { #expect(reading.isOnAC) }
        // Desktops have no AppleClamshellState; laptops report a Bool. Either way the reader must not crash.
        _ = RootDomain.clamshellClosed()
        _ = RootDomain.clamshellCausesSleep()
        _ = RootDomain.sleepDisabled()
    }

    @Test func desktopWithoutBattery() {
        let r = PowerSourceReading.parse(providingType: "AC Power", descriptions: [])
        #expect(r == .desktop)
        #expect(r.isOnAC && !r.hasBattery && r.batteryPercent == nil)
    }

    @Test func laptopOnBattery() {
        let r = PowerSourceReading.parse(providingType: "Battery Power", descriptions: [[
            "Type": "InternalBattery", "Is Present": true, "Current Capacity": 42, "Max Capacity": 100,
            "Is Charging": false, "Power Source State": "Battery Power",
        ]])
        #expect(r == PowerSourceReading(hasBattery: true, percent: 42, isOnAC: false, isCharging: false))
    }

    @Test func laptopChargingOnAC() {
        let r = PowerSourceReading.parse(providingType: "AC Power", descriptions: [[
            "Type": "InternalBattery", "Current Capacity": 4500, "Max Capacity": 5000, "Is Charging": true,
        ]])
        #expect(r == PowerSourceReading(hasBattery: true, percent: 90, isOnAC: true, isCharging: true))
    }

    @Test func fallsBackToBatteryStateAndIgnoresUPS() {
        let r = PowerSourceReading.parse(providingType: nil, descriptions: [
            ["Type": "UPS", "Current Capacity": 100, "Max Capacity": 100],
            ["Type": "InternalBattery", "Current Capacity": 10, "Max Capacity": 0, "Power Source State": "Battery Power"],
        ])
        #expect(r.hasBattery && !r.isOnAC)
        #expect(r.percent == nil)   // max 0: unknown, never a division by zero
    }
}

private extension PowerSourceReading {
    var batteryPercent: Int? { percent }
}
