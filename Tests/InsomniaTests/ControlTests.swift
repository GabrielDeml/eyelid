import Darwin
import Foundation
import Testing
@testable import Insomnia

// ControlProtocol (wire format, durations), EngineControlResponder (requests → AwakeEngine with fakes) and
// ControlServer over a real Unix socket in a temporary folder (no app, no IOKit).

@Suite("Control protocol")
struct ControlProtocolTests {
    private func json(_ r: ControlRequest) throws -> String {
        let data = try ControlCoding.line(r)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func requestsAreFlatObjectsKeyedByCmd() throws {
        #expect(try json(.on(duration: "2h", until: nil, screen: true, lid: nil)) == #"{"cmd":"on","duration":"2h","screen":true}"# + "\n")
        #expect(try json(.status) == #"{"cmd":"status"}"# + "\n")
        #expect(try json(.extend(by: "15m")) == #"{"by":"15m","cmd":"extend"}"# + "\n")
        #expect(try json(.hold(label: "make", screen: false, lid: true)) == #"{"cmd":"hold","label":"make","lid":true,"screen":false}"# + "\n")
    }

    @Test(arguments: [
        ControlRequest.on(duration: "45m", until: nil, screen: nil, lid: false),
        .on(duration: nil, until: "17:30", screen: false, lid: true),
        .on(duration: nil, until: nil, screen: nil, lid: nil),
        .off, .toggle, .extend(by: "1h"), .status, .why,
        .hold(label: "ffmpeg", screen: true, lid: false),
    ])
    func requestsRoundTrip(_ request: ControlRequest) throws {
        let line = try ControlCoding.line(request)
        #expect(line.last == 0x0A)
        let decoded = try ControlCoding.decode(ControlRequest.self, line: line.dropLast())
        #expect(decoded == request)
    }

    @Test func holdDefaultsItsFlagsAndUnknownCommandsAreNamed() throws {
        let hold = try ControlCoding.decode(ControlRequest.self, line: Data(#"{"cmd":"hold","label":"x"}"#.utf8))
        #expect(hold == .hold(label: "x", screen: false, lid: false))
        do {
            _ = try ControlCoding.decode(ControlRequest.self, line: Data(#"{"cmd":"nap"}"#.utf8))
            Issue.record("expected a decoding error")
        } catch {
            #expect(ControlCoding.describe(error) == "unknown command \"nap\"")
        }
        do {
            _ = try ControlCoding.decode(ControlRequest.self, line: Data("hello".utf8))
            Issue.record("expected a decoding error")
        } catch {
            #expect(ControlCoding.describe(error) == "bad request: not JSON")
        }
    }

    @Test func responsesRoundTripWithISODates() throws {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let response = ControlResponse.success(
            StatusPayload(state: "timed", remainingSeconds: 60, endsAt: end, screen: true, lid: "off", guards: [],
                          holds: ["You · 1h timer"], headline: "Wide awake", lidDetail: nil),
            why: [WhyRow(section: "System", who: "SleepDisabled", what: "No")])
        let line = try ControlCoding.line(response)
        #expect(String(decoding: line, as: UTF8.self).contains(#""endsAt":"2027-01-15T08:00:00Z""#))
        #expect(try ControlCoding.decode(ControlResponse.self, line: line.dropLast()) == response)
        #expect(!String(decoding: try ControlCoding.line(ControlResponse.failure("x")), as: UTF8.self).contains("status"))
    }

    @Test(arguments: [
        ("45m", 45), ("2h", 120), ("1h30m", 90), ("1h 30m", 90), ("90", 90), ("1d", 1440), ("2 hours", 120),
        (" 15M ", 15),
    ])
    func durationsParse(_ text: String, _ minutes: Int) {
        #expect(ControlDuration.minutes(text) == minutes)
        #expect(ControlDuration.parse(text) == .minutes(minutes))
    }

    @Test(arguments: ["", "0", "0m", "abc", "90s", "-5", "1.5h", "h", "99999999", "400d", "forever"])
    func badMinutesAreRejected(_ text: String) {
        #expect(ControlDuration.minutes(text) == nil)
    }

    @Test func foreverIsIndefinite() {
        for word in ["forever", "Forever", "∞", "indefinite", "inf"] {
            #expect(ControlDuration.parse(word) == .indefinite)
        }
    }

    @Test func clockTimes() {
        #expect(ControlDuration.clock("17:30")! == (17, 30))
        #expect(ControlDuration.clock("7:05")! == (7, 5))
        #expect(ControlDuration.clock("00:00")! == (0, 0))
        for bad in ["24:00", "7:5", "17-30", "", "17:60", "117:00", "a:bc", "5pm"] {
            #expect(ControlDuration.clock(bad) == nil, "\(bad)")
        }
    }

    @Test func socketAddressFitsSunPath() {
        #expect(ControlSocket.address("/tmp/x.sock") != nil)
        #expect(ControlSocket.address(String(repeating: "a", count: 103)) != nil)
        #expect(ControlSocket.address(String(repeating: "a", count: 104)) == nil)
        #expect(ControlSocket.address("") == nil)
        #expect(ControlPaths.socket.path.hasSuffix("Library/Application Support/Insomnia/control.sock"))
    }
}

// MARK: - Responder ↔ engine

@Suite("Control responder", .serialized)
@MainActor
struct ControlResponderTests {
    private func make(_ h: Harness, sleepDisabled: Bool? = false) -> EngineControlResponder {
        EngineControlResponder(engine: h.engine, settings: h.settings, power: h.power,
                               sleepDisabled: { sleepDisabled }, clock: { h.clock.now })
    }

    @Test func onWithoutFlagsFollowsSettings() {
        let h = Harness()
        let r = make(h)
        let response = r.respond(to: .on(duration: "2h", until: nil, screen: nil, lid: nil), connection: UUID(), peerPID: nil)
        #expect(response.ok)
        #expect(response.status?.state == "timed")
        #expect(response.status?.remainingSeconds == 7200)
        #expect(response.status?.headline == "Wide awake")
        #expect(h.engine.manualHold?.followsSettings == true)
        #expect(h.engine.manualHold?.owner == .manual(.cli))
    }

    @Test func flagsFixTheHoldAndNeverWriteSettings() {
        let h = Harness()
        h.settings.keepScreenOn = true
        let r = make(h)
        let response = r.respond(to: .on(duration: "forever", until: nil, screen: false, lid: nil), connection: UUID(), peerPID: nil)
        #expect(response.ok)
        #expect(response.status?.state == "indefinite")
        #expect(response.status?.screen == false)
        #expect(h.engine.manualHold?.followsSettings == false)
        #expect(h.engine.manualHold?.options == AwakeOptions(screen: false, lid: false))
        #expect(h.settings.keepScreenOn == true)
    }

    @Test func untilUsesTheNextOccurrence() {
        let h = Harness()
        let r = make(h)
        let response = r.respond(to: .on(duration: nil, until: "17:30", screen: nil, lid: nil), connection: UUID(), peerPID: nil)
        guard case .until(let expected) = AwakeDuration.nextOccurrence(hour: 17, minute: 30, after: h.clock.now) else {
            Issue.record("nextOccurrence")
            return
        }
        #expect(response.status?.endsAt == expected)
        #expect(!r.respond(to: .on(duration: "1h", until: "17:30", screen: nil, lid: nil), connection: UUID(), peerPID: nil).ok)
        #expect(!r.respond(to: .on(duration: "soon", until: nil, screen: nil, lid: nil), connection: UUID(), peerPID: nil).ok)
    }

    @Test func lidIsRefusedUntilSetUp() {
        let h = Harness()
        h.lid.helper = .notInstalled
        let r = make(h)
        let on = r.respond(to: .on(duration: nil, until: nil, screen: nil, lid: true), connection: UUID(), peerPID: nil)
        #expect(!on.ok)
        #expect(on.error == EngineControlResponder.lidNotSetUp)
        #expect(h.engine.status == .asleep)
        let hold = r.respond(to: .hold(label: "make", screen: false, lid: true), connection: UUID(), peerPID: nil)
        #expect(hold.error == EngineControlResponder.lidNotSetUp)
        #expect(h.engine.clientHolds.isEmpty)
    }

    @Test func lidOnADesktopSaysSo() {
        let h = Harness()
        h.power.hasLid = false
        let r = make(h)
        #expect(r.respond(to: .on(duration: nil, until: nil, screen: nil, lid: true), connection: UUID(), peerPID: nil).error
                == EngineControlResponder.noLid)
    }

    @Test func lidIsAllowedWhenReady() {
        let h = Harness()
        let r = make(h)
        let response = r.respond(to: .on(duration: "1h", until: nil, screen: nil, lid: true), connection: UUID(), peerPID: nil)
        #expect(response.ok)
        #expect(h.engine.manualHold?.options.lid == true)
        #expect(h.lid.desired == true)
    }

    @Test func holdLivesExactlyAsLongAsTheConnection() {
        let h = Harness()
        let r = make(h)
        let connection = UUID()
        let response = r.respond(to: .hold(label: "make", screen: false, lid: false), connection: connection, peerPID: 42)
        #expect(response.ok)
        #expect(response.status?.state == "client")
        #expect(response.status?.headline == "Awake for make")
        #expect(response.status?.holds == ["Command · make (CLI)"])   // worded as Why awake words it
        #expect(!r.respond(to: .hold(label: "again", screen: false, lid: false), connection: connection, peerPID: 42).ok)
        // The eyes (and `toggle`) can't release a command's hold.
        #expect(!r.respond(to: .toggle, connection: UUID(), peerPID: nil).ok)
        r.connectionClosed(connection)
        #expect(h.engine.status == .asleep)
        r.connectionClosed(connection)   // idempotent
    }

    @Test func offEndsManualButNotCommands() {
        let h = Harness()
        let r = make(h)
        _ = r.respond(to: .on(duration: "1h", until: nil, screen: nil, lid: nil), connection: UUID(), peerPID: nil)
        let c = UUID()
        _ = r.respond(to: .hold(label: "make", screen: false, lid: false), connection: c, peerPID: nil)
        let off = r.respond(to: .off, connection: UUID(), peerPID: nil)
        #expect(off.ok)
        #expect(off.status?.state == "client")
        r.connectionClosed(c)
        #expect(r.status().state == "asleep")
    }

    @Test func extendStartsOrPushesATimer() {
        let h = Harness()
        let r = make(h)
        #expect(r.respond(to: .extend(by: "15m"), connection: UUID(), peerPID: nil).status?.remainingSeconds == 900)
        #expect(r.respond(to: .extend(by: "1h"), connection: UUID(), peerPID: nil).status?.remainingSeconds == 4500)
        #expect(!r.respond(to: .extend(by: "later"), connection: UUID(), peerPID: nil).ok)
    }

    @Test func whyListsHoldsAndSystem() {
        let h = Harness()
        let r = make(h, sleepDisabled: false)
        r.foreignProvider = {
            ([ForeignAssertion(id: "100:1", pid: 100, process: "zoom.us", type: "PreventUserIdleDisplaySleep",
                               name: "Meeting", since: nil)], [100])
        }
        _ = r.respond(to: .hold(label: "ffmpeg", screen: true, lid: false), connection: UUID(), peerPID: nil)
        let rows = r.respond(to: .why, connection: UUID(), peerPID: nil).why ?? []
        #expect(rows.first == WhyRow(section: "Insomnia", who: "Command", what: "ffmpeg (CLI) · screen on"))
        #expect(rows.contains(WhyRow(section: "Other apps", who: "zoom.us", what: "Preventing display sleep")))
        #expect(rows.contains(WhyRow(section: "System", who: "SleepDisabled", what: "No")))
        #expect(rows.contains { $0.who == "Power" && $0.what.contains("Lid: open") })
    }

    @Test func labelsAreSanitized() {
        #expect(EngineControlResponder.sanitizedLabel("ma\nke\t -j8") == "ma ke -j8")
        #expect(EngineControlResponder.sanitizedLabel("   ") == "a command")
        let long = EngineControlResponder.sanitizedLabel(String(repeating: "x", count: 100))
        #expect(long.count == 40)
        #expect(long.hasSuffix("…"))
    }
}

// MARK: - Server over a real socket

/// Records what the server forwards; answers every request with a fixed status.
@MainActor
private final class RecordingResponder: ControlResponding {
    var requests: [ControlRequest] = []
    var closed: [UUID] = []
    func respond(to request: ControlRequest, connection: UUID, peerPID: pid_t?) -> ControlResponse {
        requests.append(request)
        return .success(StatusPayload(state: "asleep", screen: false, lid: "off", guards: [], holds: [], headline: "Sleep allowed"))
    }
    func connectionClosed(_ connection: UUID) { closed.append(connection) }
}

/// A short private folder: sun_path holds 104 bytes, and the default temporary folder can be long.
private func makeSocketDirectory() throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/ins-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Blocking client work runs off the main actor, which keeps the server's main-queue sources free to fire.
private func exchange(_ path: String, _ lines: [String], closeWrite: Bool = false) async -> [String] {
    await Task.detached { () -> [String] in
        guard let address = ControlSocket.address(path) else { return ["no address"] }
        let fd = ControlSocket.make()
        defer { close(fd) }
        guard ControlSocket.connect(fd, to: address) == 0 else { return ["connect failed \(errno)"] }
        ControlSocket.setTimeouts(fd, seconds: 5)
        let payload = Data(lines.joined().utf8)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if closeWrite { shutdown(fd, SHUT_WR) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let expected = lines.joined().split(separator: "\n", omittingEmptySubsequences: true).count
        while received.split(separator: 0x0A).count < expected {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            received.append(contentsOf: buffer[0..<n])
        }
        return received.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }
    }.value
}

@Suite("Control server", .serialized)
@MainActor
struct ControlServerTests {
    @Test func listensPrivatelyAndAnswersInOrder() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("control.sock")
        let responder = RecordingResponder()
        let server = ControlServer(socketURL: socket, responder: responder, ready: true)
        try server.start()
        defer { server.stop() }

        var st = stat()
        #expect(lstat(socket.path, &st) == 0)
        #expect((st.st_mode & S_IFMT) == S_IFSOCK)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(lstat(dir.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)

        let replies = await exchange(socket.path, [#"{"cmd":"status"}"# + "\n", "nonsense\n", #"{"cmd":"why"}"# + "\n"])
        #expect(replies.count == 3)
        #expect(replies[0].contains(#""ok":true"#))
        #expect(replies[1].contains(#""error":"bad request: not JSON""#))
        #expect(replies[2].contains(#""ok":true"#))
        #expect(responder.requests == [.status, .why])
    }

    @Test func answersALastLineWithoutNewlineThenReportsTheClose() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("control.sock")
        let responder = RecordingResponder()
        let server = ControlServer(socketURL: socket, responder: responder, ready: true)
        try server.start()
        defer { server.stop() }

        let replies = await exchange(socket.path, [#"{"cmd":"hold","label":"make"}"#], closeWrite: true)
        #expect(replies.first?.contains(#""ok":true"#) == true)
        try await waitUntil { responder.closed.count == 1 }
        #expect(server.connectionCount == 0)
    }

    @Test func buffersRequestsUntilReady() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("control.sock")
        let responder = RecordingResponder()
        let server = ControlServer(socketURL: socket, responder: responder)
        try server.start()
        defer { server.stop() }

        async let replies = exchange(socket.path, [#"{"cmd":"status"}"# + "\n"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(responder.requests.isEmpty)
        server.setReady()
        #expect(await replies.first?.contains(#""ok":true"#) == true)
    }

    @Test func refusesToStealALiveSocketButReplacesAStaleOne() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("control.sock")
        let first = ControlServer(socketURL: socket, responder: RecordingResponder(), ready: true)
        try first.start()
        let second = ControlServer(socketURL: socket, responder: RecordingResponder(), ready: true)
        #expect(throws: ControlServer.StartError.alreadyRunning) { try second.start() }
        first.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path))

        // A stale socket file (bound, never listening: what a crash leaves behind).
        let stale = ControlSocket.make()
        #expect(ControlSocket.bind(stale, to: try #require(ControlSocket.address(socket.path))) == 0)
        close(stale)
        try second.start()
        defer { second.stop() }
        let replies = await exchange(socket.path, [#"{"cmd":"status"}"# + "\n"])
        #expect(replies.count == 1)
    }

    @Test func refusesASymlinkedDirectory() throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let server = ControlServer(socketURL: link.appendingPathComponent("control.sock"), responder: RecordingResponder())
        #expect(throws: ControlServer.StartError.unsafeDirectory("not a directory (or a symlink)")) { try server.start() }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<50 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }
}
