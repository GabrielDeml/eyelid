import AppKit
import Darwin
import Foundation
import Testing
@testable import Insomnia
import InsomniaShared

/// Regression tests for the 2026-10-31 review, group E (CLI, URL scheme, app lifecycle, control socket):
/// nohup and `run` (R30), CLI launches (R31, R99), URL queueing and scheme case (R87, R77), URL log sanitising (R4),
/// insomnia://sleep refused over work holds (R32), URL `on` never-lid (R66), socket abuse paths (R70), and the run/watch hold
/// lifecycle end to end, including taking the hold back after the app restarts (R100, R98).

// MARK: - R30: signals ignored at start stay ignored

@Suite("Fix E: run and nohup", .serialized)
@MainActor
struct FixENohupTests {
    private func runAndWait(_ argv: [String], inheritedIgnored: Set<Int32>) -> WaitStatus? {
        guard case .success(let pid) = CLIRunner.spawn(argv, inheritedIgnored: inheritedIgnored) else { return nil }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return WaitStatus(status)
    }

    @Test func ignoredSignalsAreNotForwarded() {
        #expect(CLIRunner.forwarded(inheritedIgnored: []) == [SIGINT, SIGTERM, SIGHUP, SIGQUIT])
        #expect(CLIRunner.forwarded(inheritedIgnored: [SIGHUP]) == [SIGINT, SIGTERM, SIGQUIT])
        #expect(CLIRunner.forwarded(inheritedIgnored: [SIGINT, SIGQUIT, SIGPIPE]) == [SIGTERM, SIGHUP])
    }

    @Test func detectsAnIgnoredDisposition() {
        let previous = signal(SIGHUP, SIG_IGN)
        defer { signal(SIGHUP, previous) }
        #expect(InheritedSignals.ignoredNow([SIGHUP, SIGTERM]) == [SIGHUP])
        signal(SIGHUP, SIG_DFL)
        #expect(InheritedSignals.ignoredNow([SIGHUP]).isEmpty)
    }

    /// `nohup insomnia run -- job`: the job must keep nohup's SIG_IGN for SIGHUP, as `nohup job` would.
    @Test func childKeepsAnInheritedIgnoredSIGHUP() {
        let previous = signal(SIGHUP, SIG_IGN)
        defer { signal(SIGHUP, previous) }
        #expect(runAndWait(["/bin/sh", "-c", "kill -HUP $$; exit 3"], inheritedIgnored: [SIGHUP]) == .exited(3))
        // Not ignored at start: the child gets the default action back.
        #expect(runAndWait(["/bin/sh", "-c", "kill -HUP $$; exit 3"], inheritedIgnored: []) == .signaled(SIGHUP))
    }
}

// MARK: - R31 / R99: how the CLI launches the app

@Suite("Fix E: CLI launch", .serialized)
@MainActor
struct FixECLILaunchTests {
    @Test func launchMarksTheAppAsCLILaunched() {
        let app = URL(fileURLWithPath: "/Applications/Insomnia.app")
        #expect(CLI.launchArguments(ownApp: app) == ["-g", "--env", "INSOMNIA_LAUNCHED_BY_CLI=1", "-a", app.path])
        #expect(CLI.launchArguments(ownApp: nil) == ["-g", "--env", "INSOMNIA_LAUNCHED_BY_CLI=1", "-b", "com.gdeml.Insomnia"])
        #expect(CLI.wasLaunchedByCLI(["INSOMNIA_LAUNCHED_BY_CLI": "1"]))
        #expect(!CLI.wasLaunchedByCLI([:]))
    }

    @Test func aCommandLaunchSkipsStartKeepingAwakeAtLaunch() async {
        let h = Harness()
        h.settings.activateOnLaunch = true
        await h.engine.start(activateOnLaunch: false)
        #expect(h.engine.manualHold == nil)
        #expect(!h.engine.isAwake)

        let normal = Harness()
        normal.settings.activateOnLaunch = true
        await normal.engine.start()
        #expect(normal.engine.manualHold != nil)
    }

    private func makeApp(bundleID: String) throws -> (root: URL, app: URL, exe: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixe-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Insomnia.app")
        let exe = app.appendingPathComponent("Contents/MacOS/Insomnia")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: exe.path, contents: Data("#!/bin/sh\n".utf8))
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Insomnia",
                                    "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return (root, app, exe)
    }

    /// Through `~/.local/bin/insomnia`, Bundle.main has no bundle id; resolving the symlink finds the .app.
    @Test func aSymlinkedCLIFindsItsOwnApp() throws {
        let (root, app, exe) = try makeApp(bundleID: "com.gdeml.Insomnia")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("insomnia")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)

        #expect(CLI.ownAppBundle(executable: link)?.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path)
        #expect(CLI.ownAppBundle(executable: exe)?.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path)
        #expect(CLI.ownAppBundle(executable: nil) == nil)
        #expect(CLI.ownAppBundle(executable: URL(fileURLWithPath: "/usr/bin/true")) == nil)
    }

    @Test func anotherAppsExecutableIsNotOurs() throws {
        let (root, _, exe) = try makeApp(bundleID: "com.example.NotInsomnia")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CLI.ownAppBundle(executable: exe) == nil)
    }
}

// MARK: - URL scheme: R87, R77, R4, R32, R66

@Suite("Fix E: URL scheme", .serialized)
@MainActor
struct FixEURLTests {
    /// A URL that arrives before launching has finished wiring waits; the scheme's case doesn't matter.
    @Test func urlsBeforeLaunchAreQueuedNotDropped() throws {
        let delegate = AppDelegate()
        let url = try #require(URL(string: "Insomnia://panel"))
        delegate.receive(url)
        #expect(delegate.pendingURLs == [url])
        #expect(URLCommand.parse(url)?.action == .panel)
    }

    /// R77 follow-up: the Apple Event handler itself takes `Insomnia://` (no case-sensitive scheme check of its own).
    @Test func getURLEventWithACapitalisedSchemeIsQueued() throws {
        let delegate = AppDelegate()
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "Insomnia://panel"), forKeyword: keyDirectObject)
        delegate.handleGetURL(event, withReply: NSAppleEventDescriptor.null())
        #expect(delegate.pendingURLs == [try #require(URL(string: "Insomnia://panel"))])
    }

    @Test func untrustedParameterNamesStayOneLine() throws {
        let h = Harness()
        let log = EventLog(mirrorsToSystemLog: false)
        h.engine.eventLog = log
        let forged = "x%0A2026-10-31%2015:01:12%20%20lid%20%20engaged%20(readback%20%E2%9C%93)"
        let url = try #require(URL(string: "insomnia://on?for=1m&\(forged)=1"))
        URLCommandHandler.handle(url, settings: h.settings, engine: h.engine)
        #expect(!log.entries.isEmpty)
        for entry in log.entries {
            #expect(!entry.message.contains("\n"))
            #expect(!entry.message.contains("\r"))
        }
        #expect(!log.text().split(separator: "\n").contains { $0.hasPrefix("2026-10-31 15:01:12") })
        #expect(log.entries.first?.message.hasPrefix("on: ignored x 2026-10-31") == true)

        // An unknown host: host and names are sanitised too.
        let bad = try #require(URL(string: "insomnia://nope?a%0Ab=1"))
        URLCommandHandler.handle(bad, settings: h.settings, engine: h.engine)
        #expect(log.entries.last?.message == "ignored insomnia://nope?a b")
    }

    @Test func manyOrLongNamesAreCapped() {
        let names = (1...8).map { "n\($0)" }
        #expect(URLCommandHandler.names(names, separator: ", ") == "n1, n2, n3, n4, n5 +3 more")
        let long = URLCommandHandler.names([String(repeating: "y", count: 100)], separator: ", ")
        #expect(long.count == 40)
        #expect(long.hasSuffix("…"))
        #expect(URLCommandHandler.names([""], separator: ", ") == "\"\"")
        #expect(LogText.oneLine("a\r\n\tb\u{7}c", limit: 40) == "a b c")
    }

    /// R32 follow-up: no dialog (Shortcuts run it unattended); refused while a command-line client holds the Mac.
    @Test func sleepFromALinkNeverOverridesWorkInProgress() async throws {
        let h = Harness()
        let log = EventLog(mirrorsToSystemLog: false)
        h.engine.eventLog = log
        h.engine.activate(.minutes(60), source: .panel)
        let client = UUID()
        h.engine.beginClientHold(connection: client, label: "make", options: AwakeOptions(screen: false, lid: false))
        URLCommandHandler.perform(URLCommand(action: .sleep), settings: h.settings, engine: h.engine)
        #expect(h.engine.manualHold != nil)   // refused: nothing ended
        #expect(h.engine.clientHolds.count == 1)
        #expect(log.entries.last?.message == "sleep now: refused, a command is keeping the Mac awake")

        // Only the user's own manual hold left: sleeps at once, without asking.
        h.engine.endClientHold(connection: client)
        URLCommandHandler.perform(URLCommand(action: .sleep), settings: h.settings, engine: h.engine)
        #expect(log.entries.last?.message == "sleep now")
        for _ in 0..<50 where h.engine.manualHold != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(h.engine.manualHold == nil)   // FakeLid.sleepNow: never sleeps this Mac
    }

    /// Decision 10 at the perform level: `on` with lid mode switched on still starts a hold without lid.
    @Test func urlOnNeverStartsALidHold() {
        let h = Harness()
        h.settings.closedLidMode = true
        h.settings.keepScreenOn = false
        URLCommandHandler.perform(URLCommand(action: .on(.forever, screen: nil)), settings: h.settings, engine: h.engine)
        #expect(h.engine.manualHold?.options.lid == false)
        #expect(h.engine.manualHold?.options.screen == false)
        #expect(h.engine.manualHold?.followsSettings == false)
        #expect(!h.lid.desiredLog.contains(true))

        h.engine.deactivate(.user(.panel))
        URLCommandHandler.perform(URLCommand(action: .on(.minutes(30), screen: true)), settings: h.settings, engine: h.engine)
        #expect(h.engine.manualHold?.options == AwakeOptions(screen: true, lid: false))
        #expect(h.engine.manualHold?.followsSettings == false)
        #expect(!h.lid.desiredLog.contains(true))
    }
}

// MARK: - R70: control socket abuse paths

@MainActor
private final class OKResponder: ControlResponding {
    var requests: [ControlRequest] = []
    var closed = 0
    func respond(to request: ControlRequest, connection: UUID, peerPID: pid_t?) -> ControlResponse {
        requests.append(request)
        return .success(StatusPayload(state: "asleep", screen: false, lid: "off", guards: [], holds: [], headline: "Sleep allowed"))
    }
    func connectionClosed(_ connection: UUID) { closed += 1 }
}

/// A short private folder: sun_path holds 104 bytes, and the default temporary folder can be long.
private func shortSocketDirectory() throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/ins-e-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Fix E: control socket", .serialized)
@MainActor
struct FixEControlSocketTests {
    @Test(.enabled(if: getuid() != 0, "root owns /usr"))
    func refusesADirectoryOwnedBySomeoneElse() {
        #expect(throws: ControlServer.StartError.unsafeDirectory("owned by uid 0")) {
            try ControlServer.prepareDirectory(URL(fileURLWithPath: "/usr", isDirectory: true))
        }
    }

    /// A request line far past the limit gets exactly one "request too long"; the rest of it is dropped, and the next
    /// request on the same connection is still answered.
    @Test func anOverlongLineIsAnsweredOnceAndTheNextRequestStillWorks() async throws {
        let dir = try shortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("control.sock")
        let responder = OKResponder()
        let server = ControlServer(socketURL: socket, responder: responder, ready: true)
        try server.start()
        defer { server.stop() }

        let payload = Data(String(repeating: "x", count: 200 * 1024).utf8) + Data("\n".utf8)
            + Data((#"{"cmd":"status"}"# + "\n").utf8)
        let path = socket.path
        let replies = await Task.detached { () -> [String] in
            guard let address = ControlSocket.address(path) else { return ["no address"] }
            let fd = ControlSocket.make()
            defer { close(fd) }
            guard ControlSocket.connect(fd, to: address) == 0 else { return ["connect failed"] }
            ControlSocket.setTimeouts(fd, seconds: 5)
            let sent = payload.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
                }
                return true
            }
            guard sent else { return ["write failed"] }
            shutdown(fd, SHUT_WR)
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { break }   // EOF once the server has answered everything
                received.append(contentsOf: buffer[0..<n])
            }
            return received.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }
        }.value

        #expect(replies.count == 2)
        #expect(replies.first?.contains(#""error":"request too long""#) == true)
        #expect(replies.last?.contains(#""ok":true"#) == true)
        #expect(responder.requests == [.status])
    }
}

// MARK: - R100 / R98: run and watch against a fake app

/// A blocking control-socket "app" on its own thread. For each planned connection it answers the `hold` with ok,
/// then either closes at once (the app quit) or waits for the CLI to close (the hold's end), and records when.
private final class FakeHoldServer: @unchecked Sendable {
    enum Event: Equatable { case hold, eof, droppedByServer }
    let path: String
    private let fd: Int32
    private let reply: Data
    /// Waits this long after reading a hold before answering it (and recording `.hold`).
    private let replyDelay: TimeInterval
    private let lock = NSLock()
    private var recorded: [(Event, Date)] = []
    private let done = DispatchSemaphore(value: 0)

    init(path: String, reply: Data, replyDelay: TimeInterval = 0) throws {
        self.path = path
        self.reply = reply
        self.replyDelay = replyDelay
        unlink(path)
        fd = ControlSocket.make()
        guard let address = ControlSocket.address(path), ControlSocket.bind(fd, to: address) == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
    }

    var events: [(Event, Date)] { lock.withLock { recorded } }

    private func record(_ e: Event) { lock.withLock { recorded.append((e, Date())) } }

    /// `dropAfterReply[i]`: close connection i right after answering its hold.
    func serve(dropAfterReply plan: [Bool]) {
        let listener = fd
        Thread.detachNewThread { [self] in
            for drop in plan {
                let c = accept(listener, nil, nil)
                guard c >= 0 else { break }
                ControlSocket.setTimeouts(c, seconds: 10)
                var line = Data()
                var byte: UInt8 = 0
                while read(c, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
                if replyDelay > 0 { Thread.sleep(forTimeInterval: replyDelay) }
                record(.hold)
                _ = reply.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
                if drop {
                    close(c)
                    record(.droppedByServer)
                    continue
                }
                var scratch = [UInt8](repeating: 0, count: 64)
                while true {
                    let n = scratch.withUnsafeMutableBytes { read(c, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                }
                record(.eof)
                close(c)
            }
            done.signal()
        }
    }

    func waitUntilServed(seconds: Double = 5) -> Bool { done.wait(timeout: .now() + seconds) == .success }

    func stop() {
        close(fd)
        unlink(path)
    }
}

@MainActor
private func connector(_ path: String, retryMilliseconds: Int = 2000) -> CLIRunner.Connector {
    CLIRunner.Connector(connect: { ControlClient.connect(path: path).map { .success($0) } ?? .failure(.notRunning) },
                        reconnect: { ControlClient.connect(path: path) },
                        retryMilliseconds: retryMilliseconds)
}

@Suite("Fix E: run/watch hold lifecycle", .serialized)
@MainActor
struct FixEHoldLifecycleTests {
    /// No signal handling in the test process: every forwardable signal counts as already ignored, so `run` leaves
    /// the test runner's dispositions alone.
    private let leaveSignalsAlone: Set<Int32> = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
    private let options = AwakeOptions(screen: false, lid: false)

    private func okReply() throws -> Data {
        try ControlCoding.line(ControlResponse.success(StatusPayload(state: "client", screen: false, lid: "off", guards: [],
                                                                      holds: ["Command · sh"], headline: "Awake")))
    }

    private func makeServer(replyDelay: TimeInterval = 0) throws -> (FakeHoldServer, URL) {
        let dir = try shortSocketDirectory()
        return (try FakeHoldServer(path: dir.appendingPathComponent("c.sock").path, reply: try okReply(),
                                   replyDelay: replyDelay), dir)
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    @Test func runHoldsForExactlyTheCommandsLifetime() throws {
        // The app answers the hold 200 ms late: a command started before the answer would be stamped before `.hold`.
        let (server, dir) = try makeServer(replyDelay: 0.2)
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        server.serve(dropAfterReply: [false])
        let started = dir.appendingPathComponent("started").path

        let code = CLIRunner.run(["/bin/sh", "-c", "/usr/bin/touch '\(started)'; sleep 0.3; exit 7"], options: options,
                                 connector: connector(server.path), inheritedIgnored: leaveSignalsAlone)
        #expect(code == 7)
        #expect(server.waitUntilServed())
        let events = server.events
        #expect(events.map(\.0) == [.hold, .eof])
        // The hold was answered before the command started, and released only after it exited.
        let childStart = try #require(modified(started))
        if events.count == 2 {
            #expect(childStart >= events[0].1)
            #expect(events[1].1.timeIntervalSince(childStart) >= 0.3)
        }
    }

    /// R100 follow-up: a SIGTERM sent to `run` reaches the command, whose own exit code comes back. Only SIGTERM is
    /// forwarded here, and the test sends it only once the command is up, i.e. while `run` has it set to SIG_IGN, so
    /// the test process itself never sees it; its disposition is put back afterwards.
    @Test func runForwardsSIGTERMToTheCommand() throws {
        let (server, dir) = try makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        server.serve(dropAfterReply: [false])
        let started = dir.appendingPathComponent("started").path
        var saved = sigaction()
        sigaction(SIGTERM, nil, &saved)
        defer { sigaction(SIGTERM, &saved, nil) }

        let sender = Thread {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: started) && Date() < deadline { usleep(10_000) }
            guard FileManager.default.fileExists(atPath: started) else { return }
            kill(getpid(), SIGTERM)
        }
        sender.start()
        let script = "trap 'exit 9' TERM; /usr/bin/touch '\(started)'; i=0; "
            + "while [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done; exit 3"
        let code = CLIRunner.run(["/bin/sh", "-c", script], options: options, connector: connector(server.path),
                                 inheritedIgnored: [SIGINT, SIGHUP, SIGQUIT])
        #expect(code == 9)
        #expect(server.waitUntilServed())
        #expect(server.events.map(\.0) == [.hold, .eof])
    }

    /// The app quits mid-run (R98): the command keeps running, and the hold comes back once the app answers again.
    @Test func runTakesTheHoldBackAfterTheAppReturns() throws {
        let (server, dir) = try makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        server.serve(dropAfterReply: [true, false])

        let code = CLIRunner.run(["/bin/sh", "-c", "sleep 0.8; exit 7"], options: options,
                                 connector: connector(server.path, retryMilliseconds: 100), inheritedIgnored: leaveSignalsAlone)
        #expect(code == 7)
        #expect(server.waitUntilServed())
        #expect(server.events.map(\.0) == [.hold, .droppedByServer, .hold, .eof])
    }

    @Test func watchHoldsUntilThePIDExits() throws {
        let (server, dir) = try makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        server.serve(dropAfterReply: [false])
        guard case .success(let pid) = CLIRunner.spawn(["/bin/sleep", "0.3"], inheritedIgnored: []) else {
            Issue.record("spawn failed")
            return
        }
        let start = Date()
        let code = CLIRunner.watch(pid: pid, options: options, connector: connector(server.path))
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        #expect(code == CLIExit.ok)
        #expect(server.waitUntilServed())
        let events = server.events
        #expect(events.map(\.0) == [.hold, .eof])
        if events.count == 2 { #expect(events[1].1.timeIntervalSince(start) >= 0.25) }
    }
}
