import Foundation
import InsomniaShared
import os
import ServiceManagement
import Testing
@testable import Insomnia

/// A scripted helper. The flag follows engage/release unless a test says otherwise.
final class FakeClient: HelperClienting {
    struct Script {
        var setup = LidSetup.ready
        var flag: Bool? = false
        var engage = HelperResult.ok.rawValue
        var release = HelperResult.ok.rawValue
        var heartbeat = HelperResult.ok.rawValue
        /// The flag after a successful release (false = the helper reset it).
        var flagAfterRelease: Bool? = false
        /// The flag after an abandon (the helper's invalidation reset).
        var flagAfterAbandon: Bool? = false
        var answer: HelperAnswer?
        var calls: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: Script())
    func edit(_ body: @Sendable (inout Script) -> Void) { state.withLock { body(&$0) } }
    var calls: [String] { state.withLock { $0.calls } }
    private func log(_ s: String) { state.withLock { $0.calls.append(s) } }

    func setup(hasLid: Bool) async -> LidSetup { hasLid ? state.withLock { $0.setup } : .noLid }
    func install() async -> (setup: LidSetup, error: String?) {
        log("install")
        return (state.withLock { $0.setup }, nil)
    }
    func upgradeIfNeeded(savedCDHash: String?) async -> String? { nil }
    func bundledCDHash() async -> String? { "abc" }
    func engage(onLost: @escaping @Sendable () -> Void) async -> Int32 {
        log("engage")
        return state.withLock { s in
            if s.engage == HelperResult.ok.rawValue { s.flag = true }
            return s.engage
        }
    }
    func release() async -> Int32 {
        log("release")
        return state.withLock { s in
            if s.release == HelperResult.ok.rawValue { s.flag = s.flagAfterRelease }
            return s.release
        }
    }
    func abandon() async {
        log("abandon")
        state.withLock { $0.flag = $0.flagAfterAbandon }
    }
    func heartbeat() async -> Int32 { state.withLock { $0.heartbeat } }
    func query() async -> HelperAnswer? { state.withLock { $0.answer } }
    func flag() async -> Bool? { state.withLock { $0.flag } }
    func pmset(_ verb: String) async { log(verb) }
    func resetWithPassword() async -> Bool {
        log("reset")
        state.withLock { $0.flag = false }
        return true
    }
}

@MainActor
func makeLid(_ client: FakeClient, hasLid: Bool = true) -> LidController {
    LidController(client: client, prefs: Preferences(defaults: ScratchDefaults.make("lid")), hasLid: hasLid,
                  stuckWait: .milliseconds(30), lostWait: .milliseconds(60), pollStep: .milliseconds(5),
                  runsTimers: false)
}

/// Lets the controller's tasks run until `condition` holds (at most ~2 s).
@MainActor
func settle(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
@Suite("Lid controller")
struct LidControllerTests {
    @Test func engagesAndReleasesWithReadback() async {
        let client = FakeClient()
        let lid = makeLid(client)
        await lid.start()
        #expect(lid.isReady)
        lid.setDesired(true)
        await settle { lid.isEngaged }
        #expect(lid.isEngaged)
        lid.setDesired(false)
        await settle { lid.state == .off }
        #expect(lid.state == .off)
        #expect(client.calls == ["engage", "release"])
    }

    @Test func releaseWithTheLidShutSleepsTheMac() async {
        let client = FakeClient()
        let lid = makeLid(client)
        await lid.start()
        lid.setDesired(true)
        await settle { lid.isEngaged }
        lid.update(closedWithoutDisplay: true)
        lid.setDesired(false)
        await settle { client.calls.contains("sleepnow") }
        let calls = client.calls
        #expect(calls.contains("displaysleepnow"))
        #expect(calls.firstIndex(of: "release")! < calls.firstIndex(of: "sleepnow")!)
    }

    @Test func displaySleepOnlyWhileEngaged() async {
        let client = FakeClient()
        let lid = makeLid(client)
        await lid.start()
        lid.update(closedWithoutDisplay: true)
        lid.update(closedWithoutDisplay: false)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!client.calls.contains("displaysleepnow"))
    }

    @Test func sleepNowReleasesFirst() async {
        let client = FakeClient()
        let lid = makeLid(client)
        await lid.start()
        lid.setDesired(true)
        await settle { lid.isEngaged }
        lid.setDesired(false)
        lid.sleepNow()
        await settle { client.calls.contains("sleepnow") && lid.state == .off }
        #expect(client.calls == ["engage", "release", "sleepnow"])
    }

    @Test func foreignFlagIsNeverTakenOverAndRetriedWhenClear() async {
        let client = FakeClient()
        client.edit { $0.flag = true; $0.engage = HelperResult.foreignFlag.rawValue }
        let lid = makeLid(client)
        await lid.start()
        lid.setDesired(true)
        await settle { lid.state == .failed(.foreignFlag) }
        #expect(lid.state == .failed(.foreignFlag) && lid.needsAttention)
        client.edit { $0.flag = false; $0.engage = HelperResult.ok.rawValue }
        lid.recheckFlag()
        await settle { lid.isEngaged }
        #expect(lid.isEngaged)
    }

    @Test func failedReleaseThatStaysSetIsStuckUntilReset() async {
        let client = FakeClient()
        client.edit { $0.flagAfterRelease = true; $0.flagAfterAbandon = true }
        let lid = makeLid(client)
        await lid.start()
        lid.setDesired(true)
        await settle { lid.isEngaged }
        lid.setDesired(false)
        await settle { lid.isStuck }
        #expect(lid.isStuck)
        lid.resetWithPassword()
        await settle { lid.state == .off }
        #expect(lid.state == .off && client.calls.contains("reset"))
    }

    /// Someone ran `sudo pmset -a disablesleep 0`: never re-applied without a user action.
    @Test func overrideIsStickyUntilTheUserActs() async {
        let client = FakeClient()
        let lid = makeLid(client)
        await lid.start()
        lid.setDesired(true)
        await settle { lid.isEngaged }
        client.edit { $0.heartbeat = HelperResult.overridden.rawValue; $0.flag = false }
        lid.beat()
        await settle { lid.state == .failed(.overridden) }
        #expect(lid.state == .failed(.overridden))
        lid.setDesired(true)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(client.calls.filter { $0 == "engage" }.count == 1)
        client.edit { $0.heartbeat = HelperResult.ok.rawValue }
        lid.userActed()
        await settle { lid.isEngaged }
        #expect(client.calls.filter { $0 == "engage" }.count == 2)
    }

    /// The helper's reset doesn't sleep the Mac: losing lid mode in a bag must.
    @Test func lossWithTheLidShutSleepsTheMac() async {
        let client = FakeClient()
        let lid = makeLid(client)
        await lid.start()
        lid.setDesired(true)
        await settle { lid.isEngaged }
        lid.update(closedWithoutDisplay: true)
        client.edit { $0.heartbeat = -1 }
        lid.beat()
        await settle { client.calls.contains("sleepnow") }
        #expect(lid.state == .failed(.lost) && client.calls.contains("sleepnow"))
    }

    @Test func aFailureThatGotStuckStaysAFailureWhenItClears() async {
        let client = FakeClient()
        client.edit { $0.flagAfterAbandon = true }
        let lid = makeLid(client)
        await lid.start()
        lid.setDesired(true)
        await settle { lid.isEngaged }
        client.edit { $0.heartbeat = -1 }
        lid.beat()
        await settle { lid.isStuck }
        #expect(lid.isStuck)
        client.edit { $0.flag = false }
        lid.recheckFlag()
        await settle { lid.state == .failed(.lost) }
        #expect(lid.state == .failed(.lost))
        #expect(client.calls.filter { $0 == "engage" }.count == 1)   // no silent re-engage
    }

    @Test func nothingEngagesBeforeLaunchRecoveryFinishes() async {
        let client = FakeClient()
        let lid = makeLid(client)
        lid.setDesired(true)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!client.calls.contains("engage"))
        await lid.start()
        await settle { lid.isEngaged }
        #expect(lid.isEngaged)
    }

    @Test func noAnswerOnEngageAbandonsAndReadsBack() async {
        let client = FakeClient()
        client.edit { $0.engage = -1 }
        let lid = makeLid(client)
        await lid.start()
        lid.setDesired(true)
        await settle { lid.state == .failed(.setFailed) }
        #expect(lid.state == .failed(.setFailed) && client.calls.contains("abandon"))
    }

    @Test func launchWithOurFlagStillSetWaitsThenReportsStuck() async {
        let client = FakeClient()
        client.edit {
            $0.flag = true
            $0.answer = HelperAnswer(version: "1.0.0", cdhash: "abc", sleepDisabled: true, ownsFlag: true)
        }
        let lid = makeLid(client)
        await lid.start()
        #expect(lid.isStuck)
    }

    @Test func launchLeavesAForeignFlagAlone() async {
        let client = FakeClient()
        client.edit {
            $0.flag = true
            $0.answer = HelperAnswer(version: "1.0.0", cdhash: "abc", sleepDisabled: true, ownsFlag: false)
        }
        let lid = makeLid(client)
        await lid.start()
        #expect(lid.state == .off && client.calls.isEmpty)
    }

    @Test func notReadyNeverEngages() async {
        let client = FakeClient()
        client.edit { $0.setup = .needsApproval }
        let lid = makeLid(client)
        await lid.start()
        lid.setDesired(true)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!client.calls.contains("engage") && lid.needsAttention)
        client.edit { $0.setup = .ready }
        await lid.refreshSetup()
        await settle { lid.isEngaged }
        #expect(lid.isEngaged)
    }

    @Test func desktopHasNoLid() async {
        let lid = makeLid(FakeClient(), hasLid: false)
        await lid.start()
        #expect(lid.setup == .noLid && !lid.isReady)
    }

    @Test func quitReleases() async {
        let client = FakeClient()
        let lid = makeLid(client)
        await lid.start()
        lid.setDesired(true)
        await settle { lid.isEngaged }
        await lid.releaseForQuit()
        #expect(client.calls.suffix(2) == ["release", "abandon"])
    }

    @Test func serviceStatusMapping() {
        #expect(HelperClient.map(.enabled) == .ready)
        #expect(HelperClient.map(.requiresApproval) == .needsApproval)
        #expect(HelperClient.map(.notRegistered) == .notRegistered)
        #expect(HelperClient.map(.notFound) == .notRegistered)   // never registered, on macOS 27
    }
}

@Suite("Power parsing")
struct PowerParsingTests {
    @Test func clamshellBits() {
        #expect(RootDomain.decodeClamshell(1).closed && !RootDomain.decodeClamshell(2).closed)
        #expect(RootDomain.clamshellStateChangeMessage == 0xE003_4100)
    }

    @Test func desktopWithoutBattery() {
        #expect(PowerSourceReading.parse(providingType: "AC Power", descriptions: []) == .desktop)
    }

    @Test func laptopOnBattery() {
        let r = PowerSourceReading.parse(providingType: "Battery Power", descriptions: [[
            "Type": "InternalBattery", "Is Present": true, "Current Capacity": 42, "Max Capacity": 100,
        ]])
        #expect(r.hasBattery && r.percent == 42 && !r.isOnAC)
    }

    @Test func unknownCapacityIsUnknownNotZero() {
        let r = PowerSourceReading.parse(providingType: nil, descriptions: [
            ["Type": "UPS", "Current Capacity": 100, "Max Capacity": 100],
            ["Type": "InternalBattery", "Current Capacity": 10, "Max Capacity": 0, "Power Source State": "Battery Power"],
        ])
        #expect(r.hasBattery && r.percent == nil && !r.isOnAC)
    }

    @Test func absentBatteryIsADesktop() {
        let r = PowerSourceReading.parse(providingType: "AC Power", descriptions: [[
            "Type": "InternalBattery", "Is Present": false, "Current Capacity": 50, "Max Capacity": 100,
        ]])
        #expect(r == .desktop)
    }
}
