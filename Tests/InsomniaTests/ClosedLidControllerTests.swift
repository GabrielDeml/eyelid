import Foundation
import InsomniaShared
import os
import Testing
@testable import Insomnia

// ClosedLidController + LidReconciler against a fake backend and a fake SleepDisabled (docs/CLOSED_LID.md §4.3,
// §7). No XPC, no sudo, no pmset, no IORegistry writes; the marker lives in a temp directory.

/// The fake "kernel" flag plus the unprivileged pmset verbs.
final class LidFakeSystem: LidSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _flag: Bool? = false
    private var _commands: [LidSystemCommand] = []
    var flag: Bool? {
        get { lock.withLock { _flag } }
        set { lock.withLock { _flag = newValue } }
    }
    var commands: [LidSystemCommand] { lock.withLock { _commands } }
    func sleepDisabled() -> Bool? { flag }
    func run(_ command: LidSystemCommand) { lock.withLock { _commands.append(command) } }
}

final class LidFakeBackend: PrivilegedBackend, @unchecked Sendable {
    let kind: PrivilegeBackendKind
    let system: LidFakeSystem
    private let lock = NSLock()
    private var state = State()

    struct State {
        var status: HelperStatus = .installed
        var engageResult: Int32 = 0
        var engageSetsFlag = true
        var releaseResult: Int32 = 0
        var releaseClearsFlag = true
        var abandonClearsFlag = true
        var heartbeatResult: LidError?
        var owns = false
        var calls: [String] = []
        var onLost: (@Sendable () -> Void)?
    }

    init(kind: PrivilegeBackendKind = .helper, system: LidFakeSystem) {
        self.kind = kind
        self.system = system
    }

    func configure(_ change: (inout State) -> Void) { lock.withLock { change(&state) } }
    var calls: [String] { lock.withLock { state.calls } }
    private func record(_ c: String) { lock.withLock { state.calls.append(c) } }

    func fireLost() {
        let cb = lock.withLock { state.onLost }
        cb?()
    }

    func status() async -> HelperStatus { lock.withLock { state.status } }
    func install() async throws(LidSetupError) -> HelperStatus { record("install"); return lock.withLock { state.status } }
    func uninstall(resetFlag: Bool) async throws(LidSetupError) { record("uninstall") }

    func engage(onLost: @escaping @Sendable () -> Void) async -> Int32 {
        record("engage")
        // Like the real helper: a flag that is already 1 and not ours is refused and left alone.
        if kind == .helper, system.flag == true, !(lock.withLock { state.owns }) {
            return HelperResult.foreignFlag.rawValue
        }
        let s = lock.withLock { () -> State in
            state.onLost = onLost
            if state.engageResult == 0 && state.engageSetsFlag { state.owns = true }
            return state
        }
        if s.engageResult == 0 && s.engageSetsFlag { system.flag = true }
        return s.engageResult
    }

    func release() async -> Int32 {
        record("release")
        let s = lock.withLock { state }
        if s.releaseResult == 0 && s.releaseClearsFlag {
            system.flag = false
            lock.withLock { state.owns = false; state.onLost = nil }
        }
        return s.releaseResult
    }

    func abandon() async {
        record("abandon")
        let clears = lock.withLock { () -> Bool in state.onLost = nil; return state.abandonClearsFlag }
        if clears { system.flag = false; lock.withLock { state.owns = false } }
    }

    func heartbeat() async -> LidError? { record("heartbeat"); return lock.withLock { state.heartbeatResult } }
    func ownsFlag() async -> Bool { lock.withLock { state.owns } }
    func resetWithPassword() async throws(LidSetupError) { record("resetWithPassword"); system.flag = false }
}

@MainActor
@Suite("ClosedLidController", .serialized)
struct ClosedLidControllerTests {
    let system = LidFakeSystem()
    let backend: LidFakeBackend
    let power = FakePower()
    let marker: LidMarker
    let clock = TestClock()
    let controller: ClosedLidController

    init() async {
        backend = LidFakeBackend(system: system)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("insomnia-lid-\(UUID().uuidString)")
        marker = LidMarker(url: dir.appendingPathComponent("lid-engaged"))
        let b = backend
        let reconciler = LidReconciler(makeBackend: { b }, system: system, marker: marker,
                                       readbackInterval: .zero, abandonWait: .zero, lostWait: .zero)
        let clock = self.clock
        controller = ClosedLidController(power: power, refreshLid: {}, reconciler: reconciler, liveSystem: false,
                                         clock: { clock.now })
        await controller.start()
        await controller.refreshHelper()
    }

    private func engage() async {
        controller.setDesired(true)
        await controller.idle()
    }

    @Test func startsResolvedAndInstalled() {
        #expect(controller.backendKind == .helper)
        #expect(controller.helper == .installed)
        #expect(controller.status == .off)
    }

    @Test func engageThenRelease() async {
        var changes = 0
        controller.onChange = { changes += 1 }
        await engage()
        #expect(controller.status == .engaged(lidClosed: false))
        #expect(system.flag == true)
        #expect(marker.exists)
        #expect(changes >= 2)   // .engaging, .engaged

        controller.setDesired(false)
        await controller.idle()
        #expect(controller.status == .off)
        #expect(system.flag == false)
        #expect(!marker.exists)
        #expect(backend.calls == ["engage", "release"])
    }

    @Test func noEngageWithoutTheHelper() async {
        backend.configure { $0.status = .requiresApproval }
        await controller.refreshHelper()
        await engage()
        #expect(controller.status == .off)
        #expect(backend.calls.isEmpty)
    }

    @Test func foreignFlagIsNeverTouched() async {
        system.flag = true
        await engage()
        #expect(controller.status == .error(.foreignFlag))
        #expect(controller.foreignSleepDisabled)
        #expect(system.flag == true)
        #expect(!marker.exists)
        #expect(backend.calls == ["engage"])   // the helper refused and changed nothing

        controller.setDesired(false)   // not ours: going .off must not try to release it
        await controller.idle()
        #expect(controller.status == .off)
        #expect(system.flag == true)
        #expect(backend.calls == ["engage"])
    }

    @Test func foreignFlagClearsAndLidModeEngagesByItself() async {
        system.flag = true
        await engage()
        #expect(controller.status == .error(.foreignFlag))
        system.flag = false            // the other app let go
        await controller.refreshHelper()
        await controller.idle()
        #expect(controller.status == .engaged(lidClosed: false))
        #expect(!controller.foreignSleepDisabled)
    }

    @Test func helperRefusalOtherUserNeedsNoRelease() async {
        backend.configure { $0.engageResult = HelperResult.otherUser.rawValue }
        await engage()
        #expect(controller.status == .error(.otherUser))
        #expect(!marker.exists)
        #expect(backend.calls == ["engage"])
    }

    @Test func readbackMismatchReleasesAndReportsError() async {
        backend.configure { $0.engageSetsFlag = false }
        await engage()
        #expect(controller.status == .error(.readbackMismatch))
        #expect(system.flag == false)
        #expect(!marker.exists)
        #expect(backend.calls == ["engage", "release"])
    }

    @Test func failedSetIsCommandFailed() async {
        backend.configure { $0.engageResult = HelperResult.setFailed.rawValue }
        await engage()
        #expect(controller.status == .error(.commandFailed(HelperResult.setFailed.rawValue)))
    }

    @Test func retryFromErrorEngages() async {
        backend.configure { $0.engageSetsFlag = false }
        await engage()
        #expect(controller.status == .error(.readbackMismatch))
        backend.configure { $0.engageSetsFlag = true }
        controller.retry()
        await controller.idle()
        #expect(controller.status == .engaged(lidClosed: false))
    }

    @Test func errorDoesNotRetryByItself() async {
        backend.configure { $0.engageSetsFlag = false }
        await engage()
        backend.configure { $0.engageSetsFlag = true }
        controller.setDesired(true)   // the engine re-publishing the same value is not a retry
        await controller.idle()
        #expect(controller.status == .error(.readbackMismatch))
    }

    @Test func releaseFailureFallsBackToTheSafetyNet() async {
        await engage()
        backend.configure { $0.releaseResult = -1 }
        controller.setDesired(false)
        await controller.idle()
        // The safety net cleared it, and lid mode isn't wanted any more: the error resolves to .off.
        #expect(controller.status == .off)
        #expect(system.flag == false)
        #expect(!marker.exists)
        #expect(backend.calls == ["engage", "release", "abandon"])
    }

    @Test func heartbeatFailureWhileWantedReportsTheLoss() async {
        await engage()
        backend.configure {
            $0.heartbeatResult = .safetyNetLost
            $0.releaseResult = -1
        }
        controller.heartbeatForTesting()
        await controller.idle()
        #expect(controller.status == .error(.safetyNetLost))   // the cause, not the release's own error code
        #expect(system.flag == false)
        #expect(backend.calls == ["engage", "heartbeat", "release", "abandon"])
    }

    @Test func heartbeatOverride() async {
        await engage()
        backend.configure { $0.heartbeatResult = .overridden }
        controller.heartbeatForTesting()
        await controller.idle()
        #expect(controller.status == .error(.overridden))
        #expect(!marker.exists)
    }

    @Test func releaseThatCannotClearIsStuck() async {
        await engage()
        backend.configure {
            $0.releaseResult = -1
            $0.abandonClearsFlag = false
        }
        controller.setDesired(false)
        await controller.idle()
        #expect(controller.status == .stuck)
        #expect(marker.exists)   // kept: the next launch still knows

        // Stuck survives a new desire; only Reset with password (or the flag reading 0) clears it.
        controller.setDesired(true)
        await controller.idle()
        #expect(controller.status == .stuck)
        await controller.resetWithPassword()
        #expect(controller.status == .off)
        #expect(!marker.exists)
    }

    @Test func heartbeatHelperNotEngagedIsNotAFailure() async {
        backend.configure {
            $0.releaseResult = HelperResult.notEngaged.rawValue
            $0.releaseClearsFlag = false
        }
        await engage()
        system.flag = false   // the helper already dropped the session and reset
        controller.setDesired(false)
        await controller.idle()
        #expect(controller.status == .off)
        #expect(!backend.calls.contains("abandon"))
    }

    @Test func safetyNetLostWhileEngaged() async {
        await engage()
        backend.fireLost()
        system.flag = false
        for _ in 0..<20 where controller.status != .error(.safetyNetLost) {
            await Task.yield()
            await controller.idle()
        }
        #expect(controller.status == .error(.safetyNetLost))
        #expect(!marker.exists)
    }

    @Test func quitReleases() async {
        await engage()
        await controller.releaseForQuit(timeout: .seconds(2))
        #expect(controller.status == .off)
        #expect(system.flag == false)
        // After quit nothing re-engages.
        controller.setDesired(true)
        await controller.idle()
        #expect(controller.status == .off)
    }

    @Test func sleepNowReleasesThenSleeps() async {
        await engage()
        await controller.sleepNow()
        #expect(controller.status == .off)
        #expect(system.flag == false)
        #expect(system.commands.last == .sleepNow)
    }

    @Test func releaseWithLidShutSleepsTheMac() async {
        power.isLidClosed = true
        await engage()
        #expect(controller.status == .engaged(lidClosed: true))
        #expect(system.commands == [.displaySleepNow])
        controller.setDesired(false)
        await controller.idle()
        #expect(system.commands == [.displaySleepNow, .sleepNow])
    }

    @Test func lidCloseWhileEngagedBlanksTheScreenOnlyWithoutExternalDisplay() async {
        await engage()
        power.externalDisplayCount = 1
        controller.powerChanged()
        power.isLidClosed = true
        controller.powerChanged()
        #expect(controller.status == .engaged(lidClosed: true))
        await Task.yield()
        #expect(!system.commands.contains(.displaySleepNow))
        // Unplugging the last external display with the lid shut blanks the panel.
        power.externalDisplayCount = 0
        controller.powerChanged()
        for _ in 0..<10 where !system.commands.contains(.displaySleepNow) { await Task.yield() }
        #expect(system.commands.contains(.displaySleepNow))
    }

    @Test func reopenReportAfterFiveMinutesClosed() async {
        await engage()
        power.batteryPercent = 82
        power.isLidClosed = true
        controller.powerChanged()
        clock.advance(72 * 60)
        power.batteryPercent = 61
        power.thermalState = .fair
        controller.powerChanged()
        power.isLidClosed = false
        controller.powerChanged()
        let report = controller.reopenReport
        #expect(report?.closedFor == TimeInterval(72 * 60))
        #expect(report?.batteryStart == 82)
        #expect(report?.batteryEnd == 61)
        #expect(report?.worstThermal == .fair)
    }

    @Test func noReopenReportForAShortClose() async {
        await engage()
        power.isLidClosed = true
        controller.powerChanged()
        clock.advance(60)
        power.isLidClosed = false
        controller.powerChanged()
        #expect(controller.reopenReport == nil)
    }

    @Test func recoveryWithFlagAlreadyClear() async {
        #expect(marker.write())
        #expect(await controller.recoverIfNeeded())
        #expect(!marker.exists)
    }

    @Test func recoveryWithoutMarkerDoesNothing() async {
        #expect(await controller.recoverIfNeeded() == false)
    }
}

@MainActor
@Suite("ClosedLidController (sudoers)", .serialized)
struct ClosedLidControllerSudoersTests {
    @Test func recoveryResetsOurFlag() async {
        let system = LidFakeSystem()
        let backend = LidFakeBackend(kind: .sudoers, system: system)
        let marker = LidMarker(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-lid-\(UUID().uuidString)/lid-engaged"))
        #expect(marker.write())
        system.flag = true
        backend.configure { $0.owns = true }
        let reconciler = LidReconciler(makeBackend: { backend }, system: system, marker: marker,
                                       readbackInterval: .zero, abandonWait: .zero, lostWait: .zero)
        let controller = ClosedLidController(power: FakePower(), refreshLid: {}, reconciler: reconciler, liveSystem: false)
        await controller.start()
        #expect(controller.backendKind == .sudoers)
        #expect(await controller.recoverIfNeeded())
        #expect(system.flag == false)
        #expect(!marker.exists)
    }

    @Test func sudoersExitCodesAreNotHelperRefusals() async {
        // `sudo` exiting 1 must not be read as HelperResult.foreignFlag: it's a failed command, released and reported.
        let system = LidFakeSystem()
        let backend = LidFakeBackend(kind: .sudoers, system: system)
        backend.configure { $0.engageResult = 1 }
        let marker = LidMarker(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-lid-\(UUID().uuidString)/lid-engaged"))
        let reconciler = LidReconciler(makeBackend: { backend }, system: system, marker: marker,
                                       readbackInterval: .zero, abandonWait: .zero, lostWait: .zero)
        let controller = ClosedLidController(power: FakePower(), refreshLid: {}, reconciler: reconciler, liveSystem: false)
        await controller.start()
        await controller.refreshHelper()
        controller.setDesired(true)
        await controller.idle()
        #expect(controller.status == .error(.commandFailed(1)))
        #expect(backend.calls == ["engage", "release"])
    }
}
