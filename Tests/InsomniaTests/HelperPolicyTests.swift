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

    @Test func requirementStringsParseAndPinTheTeamAndTheApp() throws {
        let hash = "c728e36cb09d4114b03bf4f805f4579194235104"
        let client = try #require(HelperInfo.clientRequirement(teamID: "ABCDE12345", appCDHash: hash.uppercased()))
        let helper = HelperInfo.helperRequirement(teamID: "ABCDE12345")
        #expect(HelperInfo.isValidRequirement(client))
        #expect(HelperInfo.isValidRequirement(helper))
        #expect(client.contains("identifier \"com.gdeml.Insomnia\""))
        #expect(helper.contains("identifier \"com.gdeml.Insomnia.helper\""))
        #expect(client.contains("get-task-allow"))
        #expect(client.hasSuffix(" and cdhash H\"\(hash)\""))
        #expect(!helper.contains("cdhash"))
        #expect(!HelperInfo.isValidRequirement("identifier \"x\" and and"))
    }

    /// The cdhash is spliced into requirement text: anything but 40 ASCII hex digits is refused.
    @Test func clientRequirementRefusesAMalformedCDHash() {
        for bad in ["", "abc", String(repeating: "g", count: 40), String(repeating: "a", count: 41),
                    String(repeating: "a", count: 39) + "\"", String(repeating: "\u{FF41}", count: 40)] {
            #expect(HelperInfo.clientRequirement(teamID: "ABCDE12345", appCDHash: bad) == nil)
        }
    }
}

@Suite("Helper policy: heat, shut in, after a reset")
struct HelperHeatTests {
    @Test func shutInNeedsTheLidClosedAndTreatsUnknownAsYes() {
        #expect(HelperPolicy.isShutIn(lidClosed: true, lidCloseSleeps: true))
        #expect(HelperPolicy.isShutIn(lidClosed: true, lidCloseSleeps: nil))
        #expect(!HelperPolicy.isShutIn(lidClosed: true, lidCloseSleeps: false))   // clamshell mode
        #expect(!HelperPolicy.isShutIn(lidClosed: false, lidCloseSleeps: true))
        #expect(!HelperPolicy.isShutIn(lidClosed: nil, lidCloseSleeps: true))     // desktop
    }

    @Test func criticalTripsWithAnyLid() {
        #expect(HelperPolicy.heatTrips(thermal: .critical, seriousFor: 0, shutIn: false))
        #expect(HelperPolicy.heatTrips(thermal: .critical, seriousFor: nil, shutIn: true))
    }

    @Test func seriousTripsOnlyShutInAfterTheWindow() {
        let w = HelperInfo.thermalSeriousWindow
        #expect(!HelperPolicy.heatTrips(thermal: .serious, seriousFor: w - 1, shutIn: true))
        #expect(HelperPolicy.heatTrips(thermal: .serious, seriousFor: w, shutIn: true))
        #expect(!HelperPolicy.heatTrips(thermal: .serious, seriousFor: w * 10, shutIn: false))
        #expect(!HelperPolicy.heatTrips(thermal: .fair, seriousFor: nil, shutIn: true))
        #expect(!HelperPolicy.heatTrips(thermal: .nominal, seriousFor: nil, shutIn: true))
        #expect(w > 60)   // the app's own 60 s rule fires first
    }

    @Test func engageIsRefusedWhileHot() {
        #expect(HelperPolicy.engage(alreadyEngaged: false, engagedUID: nil, requesterUID: 501, onBattery: false,
                                    batteryPercent: 80, flag: false, ownsFlag: false, hot: true) == .refuse(.hot))
        #expect(HelperPolicy.engage(alreadyEngaged: false, engagedUID: nil, requesterUID: 501, onBattery: false,
                                    batteryPercent: 80, flag: false, ownsFlag: false, hot: false) == .setFlag)
    }

    @Test func whatFollowsAReset() {
        #expect(!HelperPolicy.sleeps(after: .nothing, shutIn: true))
        #expect(HelperPolicy.sleeps(after: .sleepIfShutIn, shutIn: true))
        #expect(!HelperPolicy.sleeps(after: .sleepIfShutIn, shutIn: false))
        #expect(HelperPolicy.sleeps(after: .sleep, shutIn: false))
    }

    @Test func batteryPercentClampsAbsurdCapacities() {
        let r = PowerSourceReading.parse(providingType: "Battery Power", descriptions: [
            ["Type": "InternalBattery", "Current Capacity": Int.max, "Max Capacity": 1],
        ])
        #expect(r.percent == 100)
    }
}

/// CodeSignature.installedAppCDHash on a scratch bundle. The real one needs a root-owned bundle, so these pass an
/// `isSafe` that accepts the test's own files, and check the default separately.
@Suite("Installed-app pin")
struct InstalledAppPinTests {
    /// <tmp>/X.app/Contents/MacOS/{Insomnia, InsomniaHelper}, both copies of a signed system binary.
    private func scratchBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString)/X.app")
        let macOS = root.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Insomnia").path)
        try FileManager.default.copyItem(atPath: "/usr/bin/false",
                                         toPath: macOS.appendingPathComponent("InsomniaHelper").path)
        return root
    }

    @Test func readsTheAppThroughDescriptorsAndChecksTheHelper() throws {
        let bundle = try scratchBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let app = bundle.appendingPathComponent("Contents/MacOS/Insomnia")
        let helper = bundle.appendingPathComponent("Contents/MacOS/InsomniaHelper")
        let appHash = try #require(CodeSignature.cdhash(ofFileAt: app))
        let helperHash = try #require(CodeSignature.cdhash(ofFileAt: helper))
        #expect(CodeSignature.installedAppCDHash(bundle: bundle.path, runningHelperCDHash: helperHash,
                                                 isSafe: { _ in true }) == appHash)
        // Not the helper this process is running: refused.
        #expect(CodeSignature.installedAppCDHash(bundle: bundle.path, runningHelperCDHash: appHash,
                                                 isSafe: { _ in true }) == nil)
        // One unsafe component anywhere: refused.
        var seen = 0
        #expect(CodeSignature.installedAppCDHash(bundle: bundle.path, runningHelperCDHash: helperHash,
                                                 isSafe: { _ in seen += 1; return seen != 3 }) == nil)
        // The default insists on root: this user's files never pass.
        #expect(CodeSignature.installedAppCDHash(bundle: bundle.path, runningHelperCDHash: helperHash) == nil)
    }

    @Test func refusesSymlinksAnywhere() throws {
        let bundle = try scratchBundle()
        let base = bundle.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        let helperHash = try #require(CodeSignature.cdhash(ofFileAt: bundle.appendingPathComponent("Contents/MacOS/InsomniaHelper")))
        // The bundle itself a symlink.
        let link = base.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
        #expect(CodeSignature.installedAppCDHash(bundle: link.path, runningHelperCDHash: helperHash,
                                                 isSafe: { _ in true }) == nil)
        // The app binary a symlink.
        let app = bundle.appendingPathComponent("Contents/MacOS/Insomnia")
        try FileManager.default.removeItem(at: app)
        try FileManager.default.createSymbolicLink(atPath: app.path, withDestinationPath: "/usr/bin/true")
        #expect(CodeSignature.installedAppCDHash(bundle: bundle.path, runningHelperCDHash: helperHash,
                                                 isSafe: { _ in true }) == nil)
    }

    @Test func aclIsDetected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("acl-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fd = open(file.path, O_RDONLY)
        defer { close(fd) }
        #expect(!InstallLocation.hasACL(descriptor: fd))
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow write", file.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        #expect(InstallLocation.hasACL(descriptor: fd))
    }
}

