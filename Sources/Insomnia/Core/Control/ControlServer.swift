import Darwin
import Foundation
import os

// MARK: - The app end of the CLI socket (ARCHITECTURE.md "Core/Control", CLOSED_LID.md §3 "CLI socket")
//
// Security: the directory is 0700 and must be ours (not a symlink), the socket is 0600, and every connection is
// dropped unless `getpeereid` says the peer runs as our uid. Every socket sets SO_NOSIGPIPE and close-on-exec.
// Single owner: `start()` first connects to an existing socket; if something answers, it refuses instead of stealing it.
// I/O: one DispatchSource per fd on the main queue; requests are answered on the main actor, in order, per connection.

/// What the server asks of the app. `EngineControlResponder` is the real one; tests inject fakes.
@MainActor
protocol ControlResponding: AnyObject {
    func respond(to request: ControlRequest, connection: UUID, peerPID: pid_t?) -> ControlResponse
    /// The connection closed (EOF, error, or the peer died): end anything scoped to it.
    func connectionClosed(_ connection: UUID)
}

@MainActor
final class ControlServer {
    static let shared = ControlServer(socketURL: ControlPaths.socket, responder: EngineControlResponder.shared)

    enum StartError: Error, Equatable, CustomStringConvertible {
        /// Another process answers on the socket (another copy of Insomnia).
        case alreadyRunning
        case pathTooLong
        /// The socket directory is not a directory we own, or is a symlink.
        case unsafeDirectory(String)
        case system(call: String, errno: Int32)

        var description: String {
            switch self {
            case .alreadyRunning: return "another process already answers on the control socket"
            case .pathTooLong: return "the control socket path is too long for a Unix socket"
            case .unsafeDirectory(let why): return "unsafe control socket directory: \(why)"
            case .system(let call, let e): return "\(call) failed: \(String(cString: strerror(e)))"
            }
        }
    }

    /// Only our own uid can connect, and `insomnia run` / `watch` keep their connection for the command's lifetime
    /// (`xargs -P 40 insomnia run -- …`). `start()` raises the soft descriptor limit to fit.
    static let maxConnections = 512
    /// A client that never reads its responses is cut off rather than buffered without limit.
    static let maxPendingOutput = 1 << 20

    let socketURL: URL
    private let responder: any ControlResponding
    private let logger = Logger(subsystem: "com.gdeml.Insomnia", category: "control")
    private var listenSource: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var socketIdentity: (dev: dev_t, ino: ino_t)?
    private var connections: [UUID: Connection] = [:]

    private(set) var isRunning = false
    /// Requests are buffered, not answered, until the app is ready (after `AwakeEngine.start()` has resolved the lid
    /// helper), so a CLI that launched the app never sees a spurious "lid mode not set up".
    private(set) var isReady: Bool

    init(socketURL: URL, responder: any ControlResponding, ready: Bool = false) {
        self.socketURL = socketURL
        self.responder = responder
        self.isReady = ready
    }

    // MARK: Lifecycle

    /// Prepares the directory, refuses if another process owns the socket, then binds and listens. Idempotent.
    func start() throws(StartError) {
        guard !isRunning else { return }
        Self.raiseDescriptorLimit(to: UInt64(Self.maxConnections) + 256)
        let path = socketURL.path
        guard let address = ControlSocket.address(path) else { throw .pathTooLong }
        try Self.prepareDirectory(socketURL.deletingLastPathComponent())

        var st = stat()
        if lstat(path, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFDIR { throw .unsafeDirectory("the socket path is a directory") }
            if Self.someoneAnswers(at: address) { throw .alreadyRunning }
            unlink(path)   // stale socket from a crash (or junk) inside our own 0700 directory
        }

        let fd = ControlSocket.make()
        guard fd >= 0 else { throw .system(call: "socket", errno: errno) }
        ControlSocket.setNonBlocking(fd)
        let bindError = ControlSocket.bind(fd, to: address)
        guard bindError == 0 else { close(fd); throw .system(call: "bind", errno: bindError) }
        // The 0700 directory already keeps others out; 0600 is belt and braces (bind honours the umask).
        guard chmod(path, 0o600) == 0 else {
            let e = errno
            close(fd); unlink(path)
            throw .system(call: "chmod", errno: e)
        }
        guard listen(fd, SOMAXCONN) == 0 else {
            let e = errno
            close(fd); unlink(path)
            throw .system(call: "listen", errno: e)
        }
        if lstat(path, &st) == 0 { socketIdentity = (st.st_dev, st.st_ino) }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptPending() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenFD = fd
        listenSource = source
        isRunning = true
        logger.info("control socket listening at \(path, privacy: .public)")
    }

    /// Start answering (buffered requests first). Call once the engine has started.
    func setReady() {
        guard !isReady else { return }
        isReady = true
        for connection in Array(connections.values) { process(connection) }
    }

    /// Closes every connection and removes the socket file if it is still ours. Used at quit, so it deliberately
    /// does not tell the responder: client holds end with the process.
    func stop() {
        guard isRunning else { return }
        for connection in connections.values { connection.teardown() }
        connections.removeAll()
        listenSource?.cancel()
        listenSource = nil
        listenFD = -1
        var st = stat()
        if let id = socketIdentity, lstat(socketURL.path, &st) == 0, st.st_dev == id.dev, st.st_ino == id.ino {
            unlink(socketURL.path)
        }
        socketIdentity = nil
        isRunning = false
    }

    var connectionCount: Int { connections.count }

    // MARK: Accept

    private func acceptPending() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return   // EAGAIN: drained. Anything else: try again on the next event.
            }
            admit(fd)
        }
    }

    private func admit(_ fd: Int32) {
        ControlSocket.configure(fd)
        ControlSocket.setNonBlocking(fd)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            logger.error("control socket: rejected a peer running as uid \(uid)")
            close(fd)
            return
        }
        guard connections.count < Self.maxConnections else {
            logger.error("control socket: too many connections; dropping one")
            close(fd)
            return
        }
        let connection = Connection(fd: fd, peerPID: ControlSocket.peerPID(fd), server: self)
        connections[connection.id] = connection
        connection.start()
    }

    // MARK: Requests

    fileprivate func process(_ connection: Connection) {
        guard isReady else { return }
        while connections[connection.id] != nil, let line = connection.nextLine() {
            let response: ControlResponse
            if line.count > ControlSocket.maxLineBytes {
                response = .failure("request too long")
            } else {
                do {
                    let request = try ControlCoding.decode(ControlRequest.self, line: line)
                    response = responder.respond(to: request, connection: connection.id, peerPID: connection.peerPID)
                } catch {
                    response = .failure(ControlCoding.describe(error))
                }
            }
            guard let data = try? ControlCoding.line(response) else { continue }
            connection.send(data)
        }
        if connection.inputClosed { connection.closeWhenFlushed() }
    }

    fileprivate func closed(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.id) != nil else { return }
        connection.teardown()
        responder.connectionClosed(connection.id)
    }

    // MARK: Helpers

    /// Creates the directory 0700 if needed; refuses a symlink or one we don't own; tightens loose permissions.
    static func prepareDirectory(_ directory: URL) throws(StartError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            let code = underlying?.domain == NSPOSIXErrorDomain ? Int32(underlying?.code ?? Int(EIO)) : EIO
            throw .system(call: "mkdir", errno: code)
        }
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { throw .system(call: "lstat", errno: errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw .unsafeDirectory("not a directory (or a symlink)") }
        guard st.st_uid == getuid() else { throw .unsafeDirectory("owned by uid \(st.st_uid)") }
        if (st.st_mode & 0o077) != 0, chmod(directory.path, 0o700) != 0 { throw .system(call: "chmod", errno: errno) }
    }

    /// GUI apps start with a soft limit of 256 descriptors; never lowers it, never exceeds the hard limit.
    static func raiseDescriptorLimit(to wanted: UInt64) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < wanted else { return }
        limit.rlim_cur = min(wanted, limit.rlim_max)
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }

    /// True if a live listener accepts a connection at `address` (the single-owner check).
    static func someoneAnswers(at address: sockaddr_un) -> Bool {
        let fd = ControlSocket.make()
        guard fd >= 0 else { return false }
        defer { close(fd) }
        ControlSocket.setNonBlocking(fd)
        let e = ControlSocket.connect(fd, to: address)
        return e == 0 || e == EINPROGRESS || e == EAGAIN   // EAGAIN: a listener with a full backlog is still alive
    }
}

// MARK: - One client connection

@MainActor
private final class Connection {
    let id = UUID()
    let fd: Int32
    let peerPID: pid_t?
    private unowned let server: ControlServer
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private var input = Data()
    private var output = Data()
    private var writeArmed = false
    private var tornDown = false
    private var pendingCancels = 2
    private var closeAfterFlush = false
    /// An over-long request was answered once; drop the rest of it, up to and including its newline, silently.
    private var discardingRestOfLine = false
    private(set) var inputClosed = false

    init(fd: Int32, peerPID: pid_t?, server: ControlServer) {
        self.fd = fd
        self.peerPID = peerPID
        self.server = server
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
    }

    func start() {
        readSource.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        writeSource.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        // The fd is closed once both sources have been cancelled (dispatch may still be using it until then).
        let finish: @Sendable () -> Void = { [self] in
            MainActor.assumeIsolated {
                pendingCancels -= 1
                if pendingCancels == 0 { close(fd) }
            }
        }
        readSource.setCancelHandler(handler: finish)
        writeSource.setCancelHandler(handler: finish)
        readSource.resume()   // the write source stays suspended until a write would block
    }

    /// The next complete line (without "\n"), or nil. An over-long partial line is returned as-is so the server can
    /// answer "request too long" once; the rest of that line is then discarded without another answer, so responses
    /// stay one per request.
    func nextLine() -> Data? {
        if discardingRestOfLine {
            guard let newline = input.firstIndex(of: 0x0A) else {
                input.removeAll()
                return nil
            }
            input.removeSubrange(input.startIndex...newline)
            discardingRestOfLine = false
        }
        if let newline = input.firstIndex(of: 0x0A) {
            let line = input[input.startIndex..<newline]
            input.removeSubrange(input.startIndex...newline)
            return Data(line)
        }
        if input.count > ControlSocket.maxLineBytes {
            defer { input.removeAll() }
            discardingRestOfLine = !inputClosed
            return input
        }
        if inputClosed, !input.isEmpty {   // last request without a trailing newline (e.g. `printf … | nc -U`)
            defer { input.removeAll() }
            return input
        }
        return nil
    }

    func send(_ data: Data) {
        guard !tornDown else { return }
        output.append(data)
        if output.count > ControlServer.maxPendingOutput {
            server.closed(self)
            return
        }
        flush()
    }

    func closeWhenFlushed() {
        closeAfterFlush = true
        if output.isEmpty { server.closed(self) }
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if !readSource.isCancelled { readSource.cancel() }
        if !writeArmed { writeSource.resume() }   // a suspended source never runs its cancel handler
        writeArmed = true
        writeSource.cancel()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !tornDown {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                input.append(contentsOf: buffer[0..<n])
                if input.count > ControlSocket.maxLineBytes * 2 { break }   // let the server reject it
                continue
            }
            if n == 0 {
                // EOF: answer what was already sent, then close. A `hold` ends here.
                inputClosed = true
                readSource.cancel()
                break
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            server.closed(self)   // ECONNRESET and friends
            return
        }
        guard !tornDown else { return }
        server.process(self)
    }

    private func flush() {
        while !output.isEmpty, !tornDown {
            let n = output.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                output.removeFirst(n)
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if !writeArmed { writeArmed = true; writeSource.resume() }
                return
            }
            server.closed(self)   // EPIPE: the peer is gone
            return
        }
        guard !tornDown else { return }
        if writeArmed { writeArmed = false; writeSource.suspend() }
        if closeAfterFlush { server.closed(self) }
    }
}

// MARK: - The real responder: requests → AwakeEngine

@MainActor
final class EngineControlResponder: ControlResponding {
    /// The responder behind `ControlServer.shared`.
    static let shared = EngineControlResponder()

    /// Other processes' assertions for `insomnia why` (AssertionInspector), and the PIDs of apps (shown by name
    /// only). nil → the section is omitted.
    var foreignProvider: (@MainActor () -> (assertions: [ForeignAssertion], appPIDs: Set<Int32>))?

    private let engine: AwakeEngine
    private let settings: Settings
    private let power: any PowerReading
    private let sleepDisabled: @MainActor () -> Bool?
    private let clock: @MainActor () -> Date
    private var holding: Set<UUID> = []
    private let logger = Logger(subsystem: "com.gdeml.Insomnia", category: "cli")

    static let lidNotSetUp = "lid mode not set up: open Insomnia ▸ Settings ▸ Lid & Safety"
    static let noLid = "this Mac has no lid, so there is no lid mode"

    init(engine: AwakeEngine = .shared,
         settings: Settings = .shared,
         power: any PowerReading = PowerMonitor.shared,
         sleepDisabled: @escaping @MainActor () -> Bool? = { RootDomain.sleepDisabled() },
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.engine = engine
        self.settings = settings
        self.power = power
        self.sleepDisabled = sleepDisabled
        self.clock = clock
    }

    func respond(to request: ControlRequest, connection: UUID, peerPID: pid_t?) -> ControlResponse {
        let response = handle(request, connection: connection)
        let who = peerPID.map { " (pid \($0))" } ?? ""
        if request != .status && request != .why {
            let outcome = response.ok ? "ok" : "refused: \(response.error ?? "?")"
            log("\(Self.describe(request))\(who) → \(outcome)")
        }
        return response
    }

    func connectionClosed(_ connection: UUID) {
        guard holding.remove(connection) != nil else { return }
        engine.endClientHold(connection: connection)
        log("hold released (connection closed)")
    }

    private func handle(_ request: ControlRequest, connection: UUID) -> ControlResponse {
        switch request {
        case .status:
            return .success(status())

        case .why:
            return .success(status(), why: whyRows())

        case .on(let durationText, let untilText, let screen, let lid):
            let duration: AwakeDuration
            switch (durationText, untilText) {
            case (.some, .some):
                return .failure("give a duration or --until, not both")
            case (.some(let text), nil):
                guard let d = ControlDuration.parse(text) else {
                    return .failure("couldn't read the duration \"\(text)\"; try 45m, 2h, 90 or forever")
                }
                duration = d
            case (nil, .some(let text)):
                guard let t = ControlDuration.clock(text) else {
                    return .failure("couldn't read the time \"\(text)\"; use HH:mm, like 17:30")
                }
                duration = .nextOccurrence(hour: t.hour, minute: t.minute, after: clock())
            case (nil, nil):
                duration = settings.defaultDuration
            }
            if lid == true, let refusal = lidRefusal() { return .failure(refusal) }
            // Flags fix this hold's options (unset ones from Settings, read now). No flags: follow Settings like the
            // panel. Either way Settings are never written (CLOSED_LID.md §5).
            let options: AwakeOptions? = (screen == nil && lid == nil)
                ? nil : AwakeOptions(screen: screen ?? settings.keepScreenOn, lid: lid ?? settings.closedLidMode)
            engine.activate(duration, source: .cli, options: options)
            return .success(status())

        case .off:
            engine.deactivate(.user(.cli))
            return .success(status())

        case .toggle:
            if engine.isAwake && engine.isHeldOnlyByClients {
                return .failure("held by a command; it lets go when the command ends")
            }
            engine.toggle(source: .cli)
            return .success(status())

        case .extend(let text):
            guard let minutes = ControlDuration.minutes(text) else {
                return .failure("couldn't read \"\(text)\"; try 15m or 1h")
            }
            engine.extend(minutes: minutes, source: .cli)
            return .success(status())

        case .hold(let label, let screen, let lid):
            guard !holding.contains(connection) else { return .failure("this connection already holds") }
            if lid, let refusal = lidRefusal() { return .failure(refusal) }
            engine.beginClientHold(connection: connection, label: Self.sanitizedLabel(label),
                                   options: AwakeOptions(screen: screen, lid: lid))
            holding.insert(connection)
            return .success(status())
        }
    }

    /// nil when lid mode can engage; otherwise the refusal text (exit code 4 in the CLI).
    private func lidRefusal() -> String? {
        if engine.canEngageLid { return nil }
        return power.hasLid ? Self.lidNotSetUp : Self.noLid
    }

    // MARK: Status

    func status() -> StatusPayload {
        let now = clock()
        var remaining: Int?
        var endsAt: Date?
        let state: String
        switch engine.status {
        case .asleep: state = "asleep"
        case .timed(let end):
            state = "timed"
            endsAt = end
            remaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        case .indefinite: state = "indefinite"
        case .watching: state = "watching"
        case .client: state = "client"
        case .automatic: state = "automatic"
        case .suspended: state = "suspended"
        }
        let lidClosedEngaged = engine.lid == .engaged(lidClosed: true) && power.externalDisplayCount == 0
        let screen = engine.isAwake && !lidClosedEngaged && engine.holds.contains { $0.options.screen }
        return StatusPayload(
            state: state,
            remainingSeconds: remaining,
            endsAt: endsAt,
            screen: screen,
            lid: Self.lidName(engine.lid),
            guards: orderedGuards().map(\.rawValue),
            holds: holdTitles(),
            headline: engine.headline,
            lidDetail: lidDetail(engine.lid))
    }

    static func lidName(_ lid: LidStatus) -> String {
        switch lid {
        case .off: return "off"
        case .needsSetup: return "needs-setup"
        case .engaging: return "engaging"
        case .engaged(let closed): return closed ? "engaged-closed" : "engaged"
        case .suspended: return "suspended"
        case .latched: return "latched"
        case .error: return "error"
        case .stuck: return "stuck"
        }
    }

    private func lidDetail(_ lid: LidStatus) -> String? {
        switch lid {
        case .off: return nil
        case .needsSetup: return "needs setup (Insomnia ▸ Settings ▸ Lid & Safety)"
        case .engaging: return "applying…"
        case .engaged(let closed): return closed ? "on · lid closed" : "on · close the lid anytime"
        case .suspended(let g):
            return "paused · " + PlainCopy.guardPhrase(g, batteryFloor: settings.batteryFloorPercent,
                                                       batteryCap: settings.lidMaxOnBatteryMinutes,
                                                       acCap: settings.lidMaxOnACMinutes)
        case .latched: return "paused · open the lid to resume"
        case .error(.foreignFlag): return "another app already turned sleep off"
        case .error(.otherUser): return "another user on this Mac is using it"
        case .error(.overridden): return "turned off by something else · Mac sleeps normally"
        case .error: return "couldn't apply · Mac sleeps normally"
        case .stuck: return "stuck on · Mac won't sleep · reset it from the Insomnia panel"
        }
    }

    private func orderedGuards() -> [GuardReason] {
        (engine.guards.contains(.awakeBatteryFloor) ? [.awakeBatteryFloor] : []) + engine.lidGuards
    }

    // MARK: Why awake (UX.md §1.5): the same report as the ⌥-click menu and Diagnostics

    func whyRows() -> [WhyRow] {
        let foreign = foreignProvider?()
        let input = whyInput(sleepDisabled: sleepDisabled(), foreign: foreign?.assertions ?? [],
                             appPIDs: foreign?.appPIDs ?? [])
        return WhyAwakeReport.build(input).cliRows.map { WhyRow(section: $0.section, who: $0.who, what: $0.what) }
    }

    /// "You · 1h timer · screen on · lid", worded as Why awake words them.
    private func holdTitles() -> [String] {
        let input = whyInput(sleepDisabled: nil, foreign: [], appPIDs: [])
        return input.holds.map { WhyAwakeReport.holdRow($0, input).title }
    }

    private func whyInput(sleepDisabled: Bool?, foreign: [ForeignAssertion], appPIDs: Set<Int32>) -> WhyAwakeInput {
        WhyAwakeInput.make(engine: engine, settings: settings, power: power, sleepDisabled: sleepDisabled,
                           foreign: foreign, appPIDs: appPIDs)
    }

    // MARK: Helpers

    /// Labels come from another process: one line, no control characters, at most 40 characters.
    static func sanitizedLabel(_ raw: String) -> String {
        let cleaned = LogText.oneLine(raw, limit: 40)
        return cleaned.isEmpty ? "a command" : cleaned
    }

    static func describe(_ request: ControlRequest) -> String {
        switch request {
        case .on(let d, let u, let s, let l):
            var parts = ["on"]
            if let d { parts.append(d) }
            if let u { parts.append("until \(u)") }
            if let s { parts.append(s ? "--screen" : "--no-screen") }
            if let l { parts.append(l ? "--lid" : "--no-lid") }
            return parts.joined(separator: " ")
        case .extend(let by): return "extend \(by)"
        case .hold(let label, let s, let l):
            return "hold \"\(sanitizedLabel(label))\"" + (s ? " --screen" : "") + (l ? " --lid" : "")
        default: return request.command
        }
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        engine.eventLog?.log("cli", message)
    }
}

/// Text another process or a web page chose, made safe for one event-log line: control and newline characters become
/// spaces, whitespace runs collapse, and past `limit` characters it is cut with "…" (so it can't forge log lines).
enum LogText {
    static func oneLine(_ raw: String, limit: Int) -> String {
        let cleaned = raw.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return cleaned.count > limit ? String(cleaned.prefix(max(0, limit - 1))) + "…" : cleaned
    }
}
