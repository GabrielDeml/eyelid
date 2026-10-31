import Foundation
import Testing
@testable import Insomnia

// Policy.evaluate: holds → guards → derived status. docs/CLOSED_LID.md §5–§6, ARCHITECTURE.md "Core/Policy.swift".

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func manual(end: Date? = nil, screen: Bool = false, lid: Bool = false, start: Date = t0) -> Hold {
    Hold(owner: .manual(.panel), options: AwakeOptions(screen: screen, lid: lid), start: start, end: end)
}

private func babysit(_ target: WatchTarget = .process(name: "ffmpeg"), lid: Bool = false) -> Hold {
    Hold(owner: .babysit(target), options: AwakeOptions(screen: false, lid: lid), start: t0)
}

private func client(_ label: String = "make", screen: Bool = false, lid: Bool = false) -> Hold {
    Hold(owner: .client(connection: UUID(), label: label), options: AwakeOptions(screen: screen, lid: lid),
         start: t0, followsSettings: false)
}

private func rule(_ id: UUID, start: Date = t0, lid: Bool = false) -> Hold {
    Hold(owner: .rule(id), options: AwakeOptions(screen: false, lid: lid), start: start)
}

/// On battery, healthy, nothing held.
private func input(_ configure: (inout PolicyInput) -> Void = { _ in }) -> PolicyInput {
    var i = PolicyInput()
    i.hasBattery = true
    i.batteryPercent = 80
    i.isOnAC = false
    i.now = t0
    configure(&i)
    return i
}

@Suite("Policy: status and precedence")
struct PolicyStatusTests {
    @Test func nothingHeldIsAsleep() {
        let out = Policy.evaluate(input())
        #expect(out.status == .asleep)
        #expect(!out.assertSystem)
        #expect(!out.assertDisplay)
        #expect(!out.wantLid)
        #expect(!out.lidAllowed)
        #expect(out.guards.isEmpty)
        #expect(!out.endManualForBatteryFloor)
    }

    @Test func timedManualHold() {
        let end = t0.addingTimeInterval(3600)
        let out = Policy.evaluate(input { $0.holds = [manual(end: end)] })
        #expect(out.status == .timed(end: end))
        #expect(out.assertSystem)
        #expect(!out.assertDisplay)
    }

    @Test func indefiniteManualHold() {
        let out = Policy.evaluate(input { $0.holds = [manual()] })
        #expect(out.status == .indefinite)
        #expect(out.status.isAwake)
    }

    @Test func expiredHoldsAreIgnored() {
        // end == now counts as expired; Policy never trusts the engine to have pruned it.
        let out = Policy.evaluate(input { $0.holds = [manual(end: t0)] })
        #expect(out.status == .asleep)
        #expect(!out.assertSystem)
        let later = Policy.evaluate(input { $0.holds = [manual(end: t0.addingTimeInterval(-5)), client()] })
        #expect(later.status == .client(label: "make"))
    }

    @Test func manualBeatsEverything() {
        let out = Policy.evaluate(input { $0.holds = [rule(UUID()), client(), babysit(), manual()] })
        #expect(out.status == .indefinite)
    }

    @Test func babysitBeatsClientAndRules() {
        let target = WatchTarget.pid(4411, name: "ffmpeg")
        let out = Policy.evaluate(input { $0.holds = [rule(UUID()), client(), babysit(target)] })
        #expect(out.status == .watching(target))
    }

    @Test func clientBeatsRules() {
        let out = Policy.evaluate(input { $0.holds = [rule(UUID()), client("cargo")] })
        #expect(out.status == .client(label: "cargo"))
    }

    @Test func rulesAreAutomaticInStartOrder() {
        let a = UUID(), b = UUID(), missing = UUID()
        let out = Policy.evaluate(input {
            $0.holds = [rule(b, start: t0.addingTimeInterval(10)), rule(a, start: t0), rule(missing)]
            $0.ruleConditions = [a: .onAC, b: .app(bundleID: "com.apple.dt.Xcode", name: "Xcode")]
        })
        #expect(out.status == .automatic([.onAC, .app(bundleID: "com.apple.dt.Xcode", name: "Xcode")]))
        #expect(out.assertSystem)
    }

    @Test func ruleHoldWithUnknownConditionIsStillAwake() {
        let out = Policy.evaluate(input { $0.holds = [rule(UUID())] })
        #expect(out.status == .automatic([]))
        #expect(out.status.isAwake)
    }

    @Test func displayAssertionWhenAnyHoldWantsScreen() {
        #expect(!Policy.evaluate(input { $0.holds = [manual(), client()] }).assertDisplay)
        #expect(Policy.evaluate(input { $0.holds = [manual(), client(screen: true)] }).assertDisplay)
    }

    @Test func wantLidWhenAnyHoldAsksForLid() {
        let out = Policy.evaluate(input { $0.holds = [manual(), rule(UUID(), lid: true)] })
        #expect(out.wantLid)
        #expect(out.lidAllowed)
        let none = Policy.evaluate(input { $0.holds = [manual(), client()] })
        #expect(!none.wantLid)
        #expect(!none.lidAllowed)
    }
}

@Suite("Policy: battery floors")
struct PolicyBatteryTests {
    @Test(arguments: [20, 19, 5, 0])
    func lidFloorTripsAtOrBelowFloor(percent: Int) {
        let out = Policy.evaluate(input { $0.batteryPercent = percent; $0.batteryFloor = 20 })
        #expect(out.guards.contains(.batteryFloor))
    }

    @Test func lidFloorDoesNotTripAboveFloor() {
        let out = Policy.evaluate(input { $0.batteryPercent = 21; $0.batteryFloor = 20 })
        #expect(!out.guards.contains(.batteryFloor))
    }

    @Test func lidFloorNeverTripsOnACOrWithoutBattery() {
        #expect(!Policy.evaluate(input { $0.batteryPercent = 5; $0.isOnAC = true }).guards.contains(.batteryFloor))
        #expect(!Policy.evaluate(input { $0.batteryPercent = 5; $0.hasBattery = false }).guards.contains(.batteryFloor))
    }

    @Test func lidFloorHysteresisClearsAtFloorPlusThree() {
        func eval(_ percent: Int, was: Bool) -> Bool {
            Policy.evaluate(input {
                $0.batteryPercent = percent
                $0.batteryFloor = 20
                $0.previousGuards = was ? [.batteryFloor] : []
            }).guards.contains(.batteryFloor)
        }
        #expect(eval(21, was: true))
        #expect(eval(22, was: true))
        #expect(!eval(23, was: true))
        #expect(!eval(21, was: false))   // hysteresis only holds a trip, never creates one
        #expect(!eval(22, was: false))
    }

    @Test func lidFloorClearsImmediatelyOnAC() {
        let out = Policy.evaluate(input {
            $0.batteryPercent = 10
            $0.isOnAC = true
            $0.previousGuards = [.batteryFloor]
        })
        #expect(!out.guards.contains(.batteryFloor))
    }

    @Test func unknownPercentKeepsPreviousState() {
        #expect(Policy.evaluate(input { $0.batteryPercent = nil; $0.previousGuards = [.batteryFloor] })
            .guards.contains(.batteryFloor))
        #expect(!Policy.evaluate(input { $0.batteryPercent = nil }).guards.contains(.batteryFloor))
    }

    @Test func lidFloorAffectsOnlyLid() {
        let out = Policy.evaluate(input {
            $0.batteryPercent = 10
            $0.holds = [manual(screen: true, lid: true)]
        })
        #expect(out.guards == [.batteryFloor])
        #expect(out.status == .indefinite)
        #expect(out.assertSystem)
        #expect(out.assertDisplay)
        #expect(out.wantLid)
        #expect(!out.lidAllowed)
        #expect(!out.endManualForBatteryFloor)
    }

    @Test func awakeFloorIsOptIn() {
        let off = Policy.evaluate(input { $0.batteryPercent = 10; $0.holds = [manual()] })
        #expect(!off.guards.contains(.awakeBatteryFloor))
        #expect(off.status == .indefinite)
    }

    @Test func awakeFloorEndsManualAndSuspendsEverything() {
        let out = Policy.evaluate(input {
            $0.batteryPercent = 15
            $0.awakeBatteryFloorEnabled = true
            $0.holds = [manual(screen: true, lid: true), client(screen: true), rule(UUID(), lid: true)]
        })
        #expect(out.guards == [.batteryFloor, .awakeBatteryFloor])
        #expect(out.status == .suspended(.awakeBatteryFloor))
        #expect(!out.status.isAwake)
        #expect(!out.assertSystem)
        #expect(!out.assertDisplay)
        #expect(!out.wantLid)
        #expect(!out.lidAllowed)
        #expect(out.endManualForBatteryFloor)
    }

    @Test func awakeFloorSuspendsNonManualWithoutEndingThem() {
        let out = Policy.evaluate(input {
            $0.batteryPercent = 15
            $0.awakeBatteryFloorEnabled = true
            $0.holds = [babysit(), rule(UUID())]
        })
        #expect(out.status == .suspended(.awakeBatteryFloor))
        #expect(!out.endManualForBatteryFloor)
        #expect(!out.assertSystem)
    }

    @Test func awakeFloorWithNothingHeldIsJustAsleep() {
        let out = Policy.evaluate(input { $0.batteryPercent = 15; $0.awakeBatteryFloorEnabled = true })
        #expect(out.guards.contains(.awakeBatteryFloor))
        #expect(out.status == .asleep)
        #expect(!out.endManualForBatteryFloor)
    }

    @Test func awakeFloorHasItsOwnHysteresis() {
        func eval(_ percent: Int, was: Set<GuardReason>) -> Set<GuardReason> {
            Policy.evaluate(input {
                $0.batteryPercent = percent
                $0.awakeBatteryFloorEnabled = true
                $0.previousGuards = was
                $0.holds = [rule(UUID())]
            }).guards
        }
        #expect(eval(22, was: [.batteryFloor, .awakeBatteryFloor]).contains(.awakeBatteryFloor))
        #expect(!eval(23, was: [.batteryFloor, .awakeBatteryFloor]).contains(.awakeBatteryFloor))
        // Switched on while already inside the hysteresis band: trips only at the floor itself.
        #expect(!eval(21, was: [.batteryFloor]).contains(.awakeBatteryFloor))
        #expect(eval(21, was: [.batteryFloor]).contains(.batteryFloor))
    }
}

@Suite("Policy: thermal, Low Power Mode, AC-only")
struct PolicyThermalTests {
    @Test(arguments: [ProcessInfo.ThermalState.serious, .critical])
    func seriousOrWorseTripsImmediately(state: ProcessInfo.ThermalState) {
        let out = Policy.evaluate(input { $0.thermal = state })
        #expect(out.guards.contains(.thermal))
        #expect(out.thermalClearSince == nil)
    }

    @Test func fairOutsideTheBagNeverTrips() {
        let out = Policy.evaluate(input {
            $0.thermal = .fair
            $0.isBag = false
            $0.thermalBagFairSince = t0.addingTimeInterval(-3600)
        })
        #expect(!out.guards.contains(.thermal))
        #expect(out.thermalBagFairSince == nil)   // the window only runs in the bag
        #expect(out.recheckAt == nil)
    }

    @Test func fairInTheBagStartsAFiveMinuteWindow() {
        let out = Policy.evaluate(input { $0.thermal = .fair; $0.isBag = true })
        #expect(!out.guards.contains(.thermal))
        #expect(out.thermalBagFairSince == t0)
        #expect(out.recheckAt == t0.addingTimeInterval(300))
    }

    @Test func fairInTheBagTripsAfterFiveMinutes() {
        let almost = Policy.evaluate(input {
            $0.thermal = .fair; $0.isBag = true; $0.thermalBagFairSince = t0.addingTimeInterval(-299)
        })
        #expect(!almost.guards.contains(.thermal))
        #expect(almost.recheckAt == t0.addingTimeInterval(1))

        let done = Policy.evaluate(input {
            $0.thermal = .fair; $0.isBag = true; $0.thermalBagFairSince = t0.addingTimeInterval(-300)
        })
        #expect(done.guards.contains(.thermal))
        #expect(done.thermalBagFairSince == t0.addingTimeInterval(-300))
    }

    @Test func leavingTheBagResetsTheWindow() {
        let out = Policy.evaluate(input {
            $0.thermal = .fair; $0.isBag = false; $0.thermalBagFairSince = t0.addingTimeInterval(-200)
        })
        #expect(out.thermalBagFairSince == nil)
        let back = Policy.evaluate(input { $0.thermal = .fair; $0.isBag = true; $0.thermalBagFairSince = nil })
        #expect(back.thermalBagFairSince == t0)
    }

    @Test func clearsOnlyAfterSixtySecondsOfCalm() {
        // First calm evaluation: still tripped, clock starts.
        let first = Policy.evaluate(input { $0.thermal = .nominal; $0.previousGuards = [.thermal] })
        #expect(first.guards.contains(.thermal))
        #expect(first.thermalClearSince == t0)
        #expect(first.recheckAt == t0.addingTimeInterval(60))

        let at59 = Policy.evaluate(input {
            $0.thermal = .nominal; $0.previousGuards = [.thermal]; $0.thermalClearSince = t0.addingTimeInterval(-59)
        })
        #expect(at59.guards.contains(.thermal))

        let at60 = Policy.evaluate(input {
            $0.thermal = .nominal; $0.previousGuards = [.thermal]; $0.thermalClearSince = t0.addingTimeInterval(-60)
        })
        #expect(!at60.guards.contains(.thermal))
        #expect(at60.thermalClearSince == nil)
    }

    @Test func fairOutsideBagCountsAsCalm() {
        let out = Policy.evaluate(input {
            $0.thermal = .fair; $0.isBag = false; $0.previousGuards = [.thermal]
            $0.thermalClearSince = t0.addingTimeInterval(-61)
        })
        #expect(!out.guards.contains(.thermal))
    }

    @Test func reTripDuringClearWindowResetsIt() {
        let out = Policy.evaluate(input {
            $0.thermal = .serious; $0.previousGuards = [.thermal]; $0.thermalClearSince = t0.addingTimeInterval(-50)
        })
        #expect(out.guards.contains(.thermal))
        #expect(out.thermalClearSince == nil)
    }

    @Test func calmWithoutPriorTripIsQuiet() {
        let out = Policy.evaluate(input { $0.thermal = .nominal; $0.thermalClearSince = t0 })
        #expect(!out.guards.contains(.thermal))
        #expect(out.thermalClearSince == nil)
    }

    @Test func lowPowerModeTripsAndClearsWithTheSetting() {
        #expect(Policy.evaluate(input { $0.lowPowerMode = true }).guards == [.lowPowerMode])
        #expect(Policy.evaluate(input { $0.lowPowerMode = false; $0.previousGuards = [.lowPowerMode] }).guards.isEmpty)
    }

    @Test func acRequiredOnlyOnBatteryWhenAsked() {
        #expect(Policy.evaluate(input { $0.lidRequiresAC = true }).guards == [.acRequired])
        #expect(Policy.evaluate(input { $0.lidRequiresAC = true; $0.isOnAC = true }).guards.isEmpty)
        #expect(Policy.evaluate(input { $0.lidRequiresAC = false }).guards.isEmpty)
        // Desktop: no battery, never "waiting for power adapter".
        #expect(Policy.evaluate(input { $0.lidRequiresAC = true; $0.hasBattery = false }).guards.isEmpty)
    }

    @Test func lidGuardsNeverTouchAssertions() {
        let out = Policy.evaluate(input {
            $0.thermal = .critical; $0.lowPowerMode = true; $0.lidRequiresAC = true
            $0.holds = [manual(screen: true, lid: true)]
        })
        #expect(out.assertSystem && out.assertDisplay)
        #expect(out.status == .indefinite)
        #expect(out.wantLid && !out.lidAllowed)
    }
}

@Suite("Policy: lid caps")
struct PolicyCapTests {
    @Test func batteryCapAlwaysApplies() {
        let below = Policy.evaluate(input { $0.lidBagSeconds = 3599; $0.lidBatteryCapMinutes = 60 })
        #expect(!below.guards.contains(.lidBatteryCap))
        let at = Policy.evaluate(input { $0.lidBagSeconds = 3600; $0.lidBatteryCapMinutes = 60 })
        #expect(at.guards.contains(.lidBatteryCap))
    }

    @Test func batteryCapIsCounterBasedEvenOnAC() {
        // Closed 40+ min on battery, then plugged in: the battery counter keeps its value (resets only on lid open).
        let out = Policy.evaluate(input {
            $0.isOnAC = true; $0.lidBagSeconds = 15 * 60; $0.lidBatteryCapMinutes = 15
        })
        #expect(out.guards.contains(.lidBatteryCap))
    }

    @Test func acCapOffByDefault() {
        let out = Policy.evaluate(input { $0.isOnAC = true; $0.lidClosedACSeconds = 100 * 3600; $0.lidACCapMinutes = nil })
        #expect(!out.guards.contains(.lidACCap))
    }

    @Test func acCapWhenEnabled() {
        let below = Policy.evaluate(input { $0.isOnAC = true; $0.lidClosedACSeconds = 4 * 3600 - 1; $0.lidACCapMinutes = 240 })
        #expect(!below.guards.contains(.lidACCap))
        let at = Policy.evaluate(input { $0.isOnAC = true; $0.lidClosedACSeconds = 4 * 3600; $0.lidACCapMinutes = 240 })
        #expect(at.guards.contains(.lidACCap))
    }

    @Test func capsAreIndependent() {
        let out = Policy.evaluate(input {
            $0.lidBagSeconds = 10; $0.lidBatteryCapMinutes = 60
            $0.lidClosedACSeconds = 3600; $0.lidACCapMinutes = 60
        })
        #expect(out.guards == [.lidACCap])
    }

    @Test func capsBlockLidButNotAwake() {
        let out = Policy.evaluate(input {
            $0.lidBagSeconds = 7200; $0.holds = [manual(lid: true)]
        })
        #expect(out.wantLid && !out.lidAllowed)
        #expect(out.assertSystem)
        #expect(out.status == .indefinite)
    }
}

@Suite("Policy: guard priority")
struct PolicyPriorityTests {
    @Test func lidGuardsAreReportedAlarmsFirst() {
        let out = Policy.evaluate(input {
            $0.batteryPercent = 5; $0.thermal = .critical; $0.lowPowerMode = true; $0.lidRequiresAC = true
            $0.lidBagSeconds = 1e6; $0.lidClosedACSeconds = 1e6; $0.lidACCapMinutes = 60
            $0.awakeBatteryFloorEnabled = true
        })
        #expect(out.lidGuards == [.batteryFloor, .thermal, .lowPowerMode, .acRequired, .lidBatteryCap, .lidACCap])
        #expect(!out.lidGuards.contains(.awakeBatteryFloor))
        #expect(out.guards.contains(.awakeBatteryFloor))
    }

    @Test func userChosenLimitsComeAfterAlarms() {
        let out = Policy.evaluate(input { $0.lidRequiresAC = true; $0.lowPowerMode = true })
        #expect(out.lidGuards.first == .lowPowerMode)
    }

    @Test func squintAndScopeFlags() {
        #expect(GuardReason.awakeBatteryFloor.affectsAllHolds)
        #expect(GuardReason.allCases.filter(\.affectsAllHolds) == [.awakeBatteryFloor])
        #expect(!GuardReason.acRequired.squints && !GuardReason.lidBatteryCap.squints && !GuardReason.lidACCap.squints)
        #expect(GuardReason.thermal.squints && GuardReason.batteryFloor.squints && GuardReason.lowPowerMode.squints)
    }
}
