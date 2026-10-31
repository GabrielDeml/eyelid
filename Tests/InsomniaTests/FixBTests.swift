import AppKit
import Foundation
import ServiceManagement
import Testing
@testable import Insomnia

/// Regression tests for the 2026-10-31 review, group B (panel, Dock, Settings UI). The AppKit presentation itself
/// can't run headless, so these pin the state logic each fix rests on.
@Suite("Review fixes: panel, Dock and Settings UI", .serialized)
@MainActor
struct FixBTests {
    // MARK: R33: a Dock presence switch keeps the panel through its own deactivation

    @Test func presenceSwitchStaysActiveUntilTheLatestSwitchSettles() {
        var gate = PresenceSwitch()
        #expect(!gate.isActive)
        let first = gate.begin()
        let second = gate.begin()          // a second toggle before the first settled
        #expect(gate.isActive)
        let staleEnded = gate.end(first)   // the stale completion must not drop the guard
        #expect(!staleEnded)
        #expect(gate.isActive)
        let ended = gate.end(second)
        #expect(ended)
        #expect(!gate.isActive)
        _ = gate.end(second)               // ending twice is harmless
        #expect(!gate.isActive)
    }

    // MARK: R34 / R72: a stale fade-out never orders out a re-shown panel

    @Test func staleFadeOutTokenIsNotCurrentAfterAFadeIn() {
        var fades = Generation()
        let fadeOut = fades.advance()
        #expect(fades.isCurrent(fadeOut))
        _ = fades.advance()                // re-shown during the 120 ms fade-out
        #expect(!fades.isCurrent(fadeOut))
    }

    @Test func showingAnOpenPanelRefocusesInsteadOfClosing() {
        #expect(PanelHost.showPlan(isOpen: false, openInWindow: true, wantsWindow: true) == .present)
        #expect(PanelHost.showPlan(isOpen: false, openInWindow: false, wantsWindow: false) == .present)
        #expect(PanelHost.showPlan(isOpen: true, openInWindow: true, wantsWindow: true) == .refocus)
        #expect(PanelHost.showPlan(isOpen: true, openInWindow: false, wantsWindow: false) == .refocus)
        #expect(PanelHost.showPlan(isOpen: true, openInWindow: false, wantsWindow: true) == .replace)
        #expect(PanelHost.showPlan(isOpen: true, openInWindow: true, wantsWindow: false) == .replace)
    }

    // MARK: R6: the panel window follows its content, top edge pinned

    @Test func resizedFrameKeepsTheTopEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let frame = NSRect(x: 100, y: 500, width: 320, height: 80)
        let grown = PanelHost.resizedFrame(frame, to: CGSize(width: 320, height: 230), within: visible)
        #expect(grown.maxY == frame.maxY)
        #expect(grown.height == 230)
        #expect(grown.minX == frame.minX)
        let shrunk = PanelHost.resizedFrame(grown, to: CGSize(width: 320, height: 80), within: visible)
        #expect(shrunk == frame)
    }

    @Test func resizedFrameStaysOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let low = NSRect(x: 100, y: 20, width: 320, height: 80)
        let grown = PanelHost.resizedFrame(low, to: CGSize(width: 320, height: 300), within: visible)
        #expect(grown.minY == visible.minY)
        #expect(grown.height == 300)
    }

    // MARK: R92: clicking the item while a session-less panel is open closes it

    @Test func sessionClickTogglesAnOpenPanel() {
        func r(option: Bool = false, secondary: Bool = false, toggles: Bool = false, keyboard: Bool = false,
               open: Bool = false) -> StatusItemController.SessionResponse {
            StatusItemController.sessionResponse(option: option, secondary: secondary, primaryToggles: toggles,
                                                 keyboard: keyboard, panelOpen: open)
        }
        #expect(r() == .showPanel)
        #expect(r(open: true) == .closePanel)
        #expect(r(keyboard: true, open: true) == .closePanel)
        #expect(r(option: true, open: true) == .whyAwake)
        #expect(r(secondary: true, open: true) == .secondary)
        #expect(r(toggles: true, open: true) == .toggleAwake)
        #expect(r(toggles: true, keyboard: true) == .showPanel)
    }

    // MARK: R93: the Dock header has no dead links; a stuck flag gets a real item

    @Test func dockHeaderNeverShowsTheResetLink() {
        var s = PanelState()
        s.lid = .stuck
        let header = DockController.dockHeader(s)
        #expect(!header.contains("Reset"))
        #expect(header == "Lid mode is stuck on · Your Mac won't sleep")
        #expect(DockController.offersReset(.stuck))
        #expect(!DockController.offersReset(.off))
        #expect(!DockController.offersReset(.error(.readbackMismatch)))

        var rule = PanelState()
        rule.status = .automatic([.onAC])
        rule.extraHolds = 2
        let ruleHeader = DockController.dockHeader(rule)
        #expect(!ruleHeader.contains("edit in Settings"))
        #expect(!ruleHeader.contains("more"))
    }

    // MARK: R95: the hidden-item card waits for an open panel

    @Test func hiddenItemCardWaitsForTheWelcomePanel() {
        typealias C = HiddenItemCardController
        #expect(C.decide(alreadyShown: false, force: false, panelOpen: true) == .waitForPanel)
        #expect(C.decide(alreadyShown: false, force: false, panelOpen: false) == .show)
        #expect(C.decide(alreadyShown: true, force: false, panelOpen: false) == .skip)
        #expect(C.decide(alreadyShown: true, force: false, panelOpen: true) == .skip)
        #expect(C.decide(alreadyShown: true, force: true, panelOpen: true) == .show)
    }

    // MARK: R9: one poke counter, the engine's

    @Test func eyesCrossAtTheEnginesTwentiethPoke() {
        var s = PanelState()
        s.personality = .cheeky
        var state = s
        let model = PanelModel(provider: { state }, handler: { action in
            if action == .eyes { state.pokeCount += 1 }   // the engine's gap-chain counter
        })
        for _ in 0..<19 { model.send(.eyes) }
        #expect(model.cues.crossEyes == 0)
        model.send(.eyes)
        #expect(model.cues.crossEyes == 1)
        model.send(.eyes)
        #expect(model.cues.crossEyes == 1)
    }

    @Test func eyesNeverCrossInProfessional() {
        var state = PanelState()
        state.personality = .professional
        let model = PanelModel(provider: { state }, handler: { _ in state.pokeCount += 1 })
        for _ in 0..<25 { model.send(.eyes) }
        #expect(model.cues.crossEyes == 0)
    }

    // MARK: R96: Sleep Now closes the panel first

    @Test func sleepNowClosesThePanel() {
        let router = AppRouter.shared
        let previous = router.closePanelHandler
        defer { router.closePanelHandler = previous }
        var closed = 0
        var sent: [PanelAction] = []
        router.closePanelHandler = { closed += 1 }
        let model = PanelModel(provider: { PanelState() }, handler: { sent.append($0) })
        model.send(.sleepNow)
        #expect(closed == 1)
        #expect(sent == [.sleepNow])
    }

    // MARK: R94: ⌘W closes the panel

    @Test func commandWClosesThePanel() throws {
        var sent: [PanelAction] = []
        let model = PanelModel(provider: { PanelState() }, handler: { sent.append($0) })
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                  timestamp: 0, windowNumber: 0, context: nil, characters: "w",
                                                  charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(model.handleKey(event))
        #expect(sent == [.closePanel])
        let q = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                              timestamp: 0, windowNumber: 0, context: nil, characters: "q",
                                              charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        #expect(!model.handleKey(q))   // ⌘Q still reaches the main menu
    }

    // MARK: R43: H′ "Off for this session" for any fixed hold without lid

    @Test func fixedClientHoldWithoutLidSaysOffForThisSession() {
        let client = Hold(owner: .client(connection: UUID(), label: "make"), options: .systemOnly, followsSettings: false)
        let manualFollowing = Hold(owner: .manual(.panel), options: AwakeOptions(screen: true, lid: true))
        let fixedLid = Hold(owner: .manual(.cli), options: AwakeOptions(screen: false, lid: true), followsSettings: false)
        let rule = Hold(owner: .rule(UUID()), options: .systemOnly)
        #expect(LivePanelState.fixedHoldWithoutLid([client]))
        #expect(!LivePanelState.fixedHoldWithoutLid([client, manualFollowing]))
        #expect(!LivePanelState.fixedHoldWithoutLid([fixedLid]))
        #expect(!LivePanelState.fixedHoldWithoutLid([rule]))
        #expect(!LivePanelState.fixedHoldWithoutLid([]))

        var s = PanelState()
        s.status = .client(label: "make")
        s.closedLidMode = true
        s.helper = .installed
        s.fixedHoldWithoutLid = LivePanelState.fixedHoldWithoutLid([client])
        #expect(PlainCopy.lidSublabel(s)?.text == "Off for this session")
    }

    // MARK: R78: the awake battery-floor banner talks about keeping awake, not lid mode

    @Test func awakeBatteryFloorBannerCopy() {
        let banner = PlainCopy.banner(.batteryFloor(percent: 20), PanelState())
        #expect(banner.text == "Stopped keeping awake at 20% battery")   // UX §10 battery-stop
        #expect(!banner.text.contains("Lid"))
    }

    // MARK: R37: Until… 23:58 / 23:59 means midnight, not 24 h from now

    @Test func untilNearMidnightRoundsToMidnight() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 14, minute: 53)))
        func pick(_ h: Int, _ m: Int) throws -> Date {
            let picked = try #require(cal.date(bySettingHour: h, minute: m, second: 0, of: now))
            guard case .until(let end) = UntilPicker.target(for: picked, now: now, calendar: cal) else {
                Issue.record("not an until"); return now
            }
            return end
        }
        for m in [58, 59] {
            let end = try pick(23, m)
            #expect(cal.component(.hour, from: end) == 0)
            #expect(cal.component(.minute, from: end) == 0)
            #expect(end.timeIntervalSince(now) < 10 * 3600)
        }
        let rounded = try pick(10, 58)   // nearest 5 minutes: 10:58 → 11:00, tomorrow
        #expect(cal.component(.hour, from: rounded) == 11)
        #expect(cal.component(.minute, from: rounded) == 0)
        #expect(cal.isDate(rounded, inSameDayAs: now.addingTimeInterval(86_400)))
        let soon = try pick(14, 58)
        #expect(cal.component(.minute, from: soon) == 0)
        #expect(cal.component(.hour, from: soon) == 15)
    }

    // MARK: R45: the launch-at-login error clears once the status matches the request

    @Test func launchAtLoginErrorClearsWhenTheStatusCatchesUp() {
        let login = LaunchAtLogin()
        login.recordFailure(true, code: 1)
        login.apply(.notRegistered)
        #expect(login.note?.isError == true)
        login.apply(.enabled)
        #expect(login.note == nil)

        login.recordFailure(false, code: 2)
        login.apply(.enabled)                 // a failed unregister stays .enabled: keep the error
        #expect(login.note?.isError == true)
        login.apply(.notRegistered)
        #expect(login.note == nil)
    }

    // MARK: R97: the PATH warning is re-checked

    @Test func pathWarningIsRecheckedAndClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-fixb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent("Insomnia.app/Contents/MacOS/Insomnia")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: exe.path, contents: Data("#!/bin/sh\n".utf8))
        let installer = CLIInstaller(link: root.appendingPathComponent("home/.local/bin/insomnia"),
                                     target: exe.resolvingSymlinksInPath())
        try installer.install()

        let answers = PathAnswers([.missing, .missing, .onPath])
        var now = Date(timeIntervalSince1970: 1_000_000)
        let model = CLIInstallModel(installer: installer, checkPath: { _, _ in answers.next() }, clock: { now })
        await model.refresh()
        #expect(model.path == .missing)
        #expect(answers.calls == 1)

        await model.refresh()                                 // activation right after: debounced
        #expect(answers.calls == 1)
        now += CLIInstallModel.pathRecheckInterval
        await model.refresh()                                 // later activation: asks again
        #expect(answers.calls == 2)
        #expect(model.path == .missing)

        await model.refresh(force: true)                      // "Check Again"
        #expect(answers.calls == 3)
        #expect(model.path == .onPath)

        now += 10 * CLIInstallModel.pathRecheckInterval
        await model.refresh()                                 // on PATH: no more shell runs
        #expect(answers.calls == 3)

        model.remove()                                        // a removed link forgets the answer
        #expect(model.path == nil)
    }

    // MARK: R8: the recorder ends with its window and ignores other windows' keys

    @Test func recorderStopsWhenItsWindowResignsKey() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: true)
        let session = RecorderSession()
        var results: [String] = []
        session.start(in: window) { results.append("\($0)") }
        #expect(session.isRecording)

        // ⌘⇧K typed into another Insomnia window (the panel) passes through untouched.
        let k: UInt32 = 40
        #expect(!session.handle(type: .keyDown, keyCode: k, flags: [.command, .shift], window: ObjectIdentifier(other)))
        #expect(session.isRecording)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!session.isRecording)
        #expect(results == ["cancelled"])

        // A new session in the same window takes a combo typed there.
        session.start(in: window) { results.append("\($0)") }
        #expect(session.handle(type: .keyDown, keyCode: k, flags: [.command, .shift], window: ObjectIdentifier(window)))
        #expect(!session.isRecording)
        #expect(results.count == 2)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)   // no observers left
        #expect(results.count == 2)
    }
}

/// Scripted login-shell answers for the PATH re-check test.
private final class PathAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ShellPATH.Status]
    private var count = 0

    init(_ answers: [ShellPATH.Status]) { queue = answers }

    var calls: Int { lock.withLock { count } }

    func next() -> ShellPATH.Status? {
        lock.withLock {
            count += 1
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }
}
