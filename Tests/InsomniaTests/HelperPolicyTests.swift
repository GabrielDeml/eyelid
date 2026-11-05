import Foundation
import InsomniaShared
import ServiceManagement
import Testing
@testable import Insomnia

// The root helper's decisions (InsomniaShared.HelperPolicy) and the app's status mapping (HelperBackend.mapStatus),
// docs/CLOSED_LID.md §2.5–§2.6. Pure: no root, no XPC, no IOKit writes.

@Suite("Helper policy: engage")
struct HelperEngageTests {
    private func decide(engaged: Bool = false, engagedUID: UInt32? = nil, uid: UInt32 = 501, battery: Bool = false,
                        percent: Int? = 80, flag: Bool? = false, owns: Bool = false) -> HelperPolicy.EngageDecision {
        HelperPolicy.engage(alreadyEngaged: engaged, engagedUID: engagedUID, requesterUID: uid, onBattery: battery,
                            batteryPercent: percent, flag: flag, ownsFlag: owns)
    }

    @Test func idleWithFlagZeroSetsTheFlag() {
        #expect(decide() == .setFlag)
    }

    @Test func foreignFlagIsNeverTakenOver() {
        #expect(decide(flag: true, owns: false) == .refuse(.foreignFlag))
    }

    @Test func unreadableFlagIsNeverWrittenBlind() {
        #expect(decide(flag: nil) == .refuse(.setFailed))
    }

    @Test func ownedFlagPendingResetIsAdopted() {
        #expect(decide(flag: true, owns: true) == .join)
    }

    @Test func sameUserJoinsAnEngagedSet() {
        #expect(decide(engagedUID: 501, uid: 501, flag: true, owns: true) == .join)
    }

    @Test func otherUserIsRefusedWhileEngaged() {
        #expect(decide(engagedUID: 501, uid: 502, flag: true, owns: true) == .refuse(.otherUser))
    }

    @Test func anyUserMayEngageWhenIdle() {
        #expect(decide(engagedUID: nil, uid: 502) == .setFlag)
    }

    @Test func alreadyEngagedSessionJustRearms() {
        #expect(decide(engaged: true, engagedUID: 501, flag: true, owns: true) == .alreadyEngaged)
    }

    @Test func backstopRefusesAtTenPercentOnBattery() {
        #expect(decide(battery: true, percent: 10) == .refuse(.backstop))
        #expect(decide(battery: true, percent: 11) == .setFlag)
        #expect(decide(battery: false, percent: 5) == .setFlag)          // on AC: no backstop
        #expect(decide(battery: true, percent: nil) == .setFlag)         // unknown percent never trips
    }
}

@Suite("Helper policy: heartbeat, backstop, start-up")
struct HelperLifecycleTests {
    @Test func heartbeatFromLiveSessionIsOK() {
        #expect(HelperPolicy.heartbeat(sessionEngaged: true, dropReason: nil, flag: true, ownsFlag: true) == .ok)
    }

    @Test func heartbeatSeesExternalClear() {
        #expect(HelperPolicy.heartbeat(sessionEngaged: true, dropReason: nil, flag: false, ownsFlag: true) == .overridden)
    }

    @Test func heartbeatFromDroppedSessionRepliesItsReason() {
        #expect(HelperPolicy.heartbeat(sessionEngaged: false, dropReason: .backstop, flag: nil, ownsFlag: false)
                == .reply(.backstop))
        #expect(HelperPolicy.heartbeat(sessionEngaged: false, dropReason: nil, flag: nil, ownsFlag: false)
                == .reply(.notEngaged))
    }

    @Test func backstopTripsOnlyOnBatteryAtOrBelowTenWithFlagSet() {
        #expect(HelperPolicy.backstopTrips(onBattery: true, batteryPercent: 10, flag: true))
        #expect(!HelperPolicy.backstopTrips(onBattery: true, batteryPercent: 10, flag: false))
        #expect(!HelperPolicy.backstopTrips(onBattery: false, batteryPercent: 3, flag: true))
        #expect(!HelperPolicy.backstopTrips(onBattery: true, batteryPercent: 11, flag: true))
        #expect(!HelperPolicy.backstopTrips(onBattery: true, batteryPercent: nil, flag: true))
    }

    @Test func backstopPollOnlyAtOrBelowFifteenOnBattery() {
        #expect(HelperPolicy.needsBackstopPoll(onBattery: true, batteryPercent: 15))
        #expect(!HelperPolicy.needsBackstopPoll(onBattery: true, batteryPercent: 16))
        #expect(!HelperPolicy.needsBackstopPoll(onBattery: false, batteryPercent: 5))
    }

    @Test func missingBootMarkerIsABoot() {
        #expect(HelperPolicy.startReset(savedBootUUID: nil, currentBootUUID: "A", ownershipFileExists: true) == .bootReset)
        #expect(HelperPolicy.startReset(savedBootUUID: nil, currentBootUUID: nil, ownershipFileExists: false) == .bootReset)
    }

    @Test func differentBootUUIDIsABoot() {
        #expect(HelperPolicy.startReset(savedBootUUID: "A", currentBootUUID: "B", ownershipFileExists: false) == .bootReset)
    }

    @Test func sameBootWithOwnershipFileIsARestartReset() {
        #expect(HelperPolicy.startReset(savedBootUUID: "A", currentBootUUID: "A", ownershipFileExists: true) == .restartReset)
        #expect(HelperPolicy.startReset(savedBootUUID: "A", currentBootUUID: "A", ownershipFileExists: false) == .none)
    }

    @Test func unreadableBootUUIDNeverClearsAForeignFlag() {
        #expect(HelperPolicy.startReset(savedBootUUID: "A", currentBootUUID: nil, ownershipFileExists: false) == .none)
    }

    @Test func requirementStringsParseAndPinTheTeam() {
        let client = HelperInfo.clientRequirement(teamID: "ABCDE12345")
        let helper = HelperInfo.helperRequirement(teamID: "ABCDE12345")
        #expect(HelperInfo.isValidRequirement(client))
        #expect(HelperInfo.isValidRequirement(helper))
        #expect(client.contains("identifier \"com.gdeml.Insomnia\""))
        #expect(helper.contains("identifier \"com.gdeml.Insomnia.helper\""))
        #expect(client.contains("get-task-allow"))
        #expect(!HelperInfo.isValidRequirement("identifier \"x\" and and"))
    }
}

