import Darwin
import Foundation

// MARK: - The CLI ↔ app wire protocol (ARCHITECTURE.md "Core/Control", Decision 11)
//
// JSON Lines over a Unix stream socket at `ControlPaths.socket`: one request object per line, one response line per
// request, in order. Requests are flat objects keyed by "cmd" so they are easy to write by hand:
//
//   {"cmd":"on","duration":"2h","screen":true}      {"cmd":"status"}      {"cmd":"extend","by":"15m"}
//   {"cmd":"hold","label":"make","screen":false,"lid":false}   (held until this connection closes)
//
// Everything here is pure and nonisolated: the CLI process (no NSApplication, no main actor work) and the app share it.

/// One request line.
enum ControlRequest: Equatable, Sendable {
    /// duration: "45m", "2h", "1h30m", "90" (minutes) or "forever"; until: "HH:mm" (next occurrence). Both nil → the
    /// default duration. screen/lid nil → taken from Settings (and the hold follows Settings when both are nil).
    case on(duration: String?, until: String?, screen: Bool?, lid: Bool?)
    case off
    /// Eyes-button semantics (`AwakeEngine.toggle`). Refused when only command holds keep the Mac awake.
    case toggle
    case extend(by: String)
    case status
    case why
    /// Connection-scoped client hold (`insomnia run` / `watch`); released when the connection closes.
    case hold(label: String, screen: Bool, lid: Bool)

    var command: String {
        switch self {
        case .on: return "on"
        case .off: return "off"
        case .toggle: return "toggle"
        case .extend: return "extend"
        case .status: return "status"
        case .why: return "why"
        case .hold: return "hold"
        }
    }
}

extension ControlRequest: Codable {
    private enum Key: String, CodingKey { case cmd, duration, until, screen, lid, by, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let cmd = try c.decode(String.self, forKey: .cmd)
        switch cmd {
        case "on":
            self = .on(duration: try c.decodeIfPresent(String.self, forKey: .duration),
                       until: try c.decodeIfPresent(String.self, forKey: .until),
                       screen: try c.decodeIfPresent(Bool.self, forKey: .screen),
                       lid: try c.decodeIfPresent(Bool.self, forKey: .lid))
        case "off": self = .off
        case "toggle": self = .toggle
        case "extend": self = .extend(by: try c.decode(String.self, forKey: .by))
        case "status": self = .status
        case "why": self = .why
        case "hold":
            self = .hold(label: try c.decode(String.self, forKey: .label),
                         screen: try c.decodeIfPresent(Bool.self, forKey: .screen) ?? false,
                         lid: try c.decodeIfPresent(Bool.self, forKey: .lid) ?? false)
        default:
            throw DecodingError.dataCorruptedError(forKey: .cmd, in: c, debugDescription: "unknown command \"\(cmd)\"")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(command, forKey: .cmd)
        switch self {
        case .on(let duration, let until, let screen, let lid):
            try c.encodeIfPresent(duration, forKey: .duration)
            try c.encodeIfPresent(until, forKey: .until)
            try c.encodeIfPresent(screen, forKey: .screen)
            try c.encodeIfPresent(lid, forKey: .lid)
        case .extend(let by):
            try c.encode(by, forKey: .by)
        case .hold(let label, let screen, let lid):
            try c.encode(label, forKey: .label)
            try c.encode(screen, forKey: .screen)
            try c.encode(lid, forKey: .lid)
        case .off, .toggle, .status, .why:
            break
        }
    }
}

/// One response line. `status` accompanies every successful command (so the CLI can print the new state).
struct ControlResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var error: String?
    var status: StatusPayload?
    var why: [WhyRow]?

    init(ok: Bool, error: String? = nil, status: StatusPayload? = nil, why: [WhyRow]? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
        self.why = why
    }

    static func success(_ status: StatusPayload?, why: [WhyRow]? = nil) -> ControlResponse {
        ControlResponse(ok: true, status: status, why: why)
    }

    static func failure(_ message: String) -> ControlResponse { ControlResponse(ok: false, error: message) }
}

/// The derived state, machine-readable (`insomnia status --json`).
struct StatusPayload: Codable, Equatable, Sendable {
    /// asleep · timed · indefinite · watching · client · automatic · suspended
    var state: String
    /// Timed manual hold only.
    var remainingSeconds: Int?
    var endsAt: Date?
    /// The display is being kept on.
    var screen: Bool
    /// off · needs-setup · engaging · engaged · engaged-closed · suspended · latched · error · stuck
    var lid: String
    /// Tripped guards, `GuardReason` raw values (batteryFloor, thermal, …).
    var guards: [String]
    /// Live holds, one plain line each: "You · 1h timer · screen on", "Command · make".
    var holds: [String]
    /// The plain headline every surface shows (UX.md §8): "Wide awake", "Awake for make".
    var headline: String?
    /// Plain lid-mode line when there is something to say: "on · lid closed", "paused · running hot".
    var lidDetail: String?

    var isAwake: Bool { state != "asleep" && state != "suspended" }
}

/// One row of "Why is my Mac awake?" (UX.md §1.5). Sections: Insomnia, Guards, Other apps, System.
struct WhyRow: Codable, Equatable, Sendable {
    var section: String
    var who: String
    var what: String

    enum Section {
        static let insomnia = "Insomnia"
        static let guards = "Guards"
        static let otherApps = "Other apps"
        static let system = "System"
    }
}

/// JSON Lines encoding shared by both ends. Dates are ISO 8601.
enum ControlCoding {
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// One line, terminated by "\n". The compact encoder never emits a raw newline (strings escape it).
    static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder().encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        try decoder().decode(type, from: line)
    }

    /// A human-sized reason a request line couldn't be read.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "bad request" }
        switch error {
        case .dataCorrupted(let ctx): return ctx.debugDescription.hasPrefix("unknown command") ? ctx.debugDescription : "bad request: not JSON"
        case .keyNotFound(let key, _): return "bad request: missing \"\(key.stringValue)\""
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return "bad request: wrong type for \"\(ctx.codingPath.last?.stringValue ?? "?")\""
        @unknown default: return "bad request"
        }
    }
}

// MARK: - Durations and clock times (shared by the CLI's validation and the server)

enum ControlDuration {
    /// A year. Anything longer is a typo, and "forever" exists.
    static let maxMinutes = 366 * 24 * 60

    private static let foreverWords: Set<String> = ["forever", "indefinite", "indefinitely", "inf", "infinite",
                                                    "infinity", "∞"]

    /// "45m", "2h", "1h30m", "1h30", "90" (minutes), "1d", "forever" → a duration. nil if unreadable or zero.
    /// Past `cap`: nil, or `cap` when `saturating` (URLs: any web page can send these values, so the arithmetic
    /// saturates instead of overflowing).
    static func parse(_ text: String, cap: Int = maxMinutes, saturating: Bool = false) -> AwakeDuration? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if foreverWords.contains(t) { return .indefinite }
        return minutes(t, cap: cap, saturating: saturating).map { .minutes($0) }
    }

    /// Minutes only (no "forever"): for `extend` and timed `on`. A bare number is minutes, and so is a bare number
    /// after the last unit ("1h30").
    static func minutes(_ text: String, cap: Int = maxMinutes, saturating: Bool = false) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        var total = 0
        var rest = Substring(t)
        while !rest.isEmpty {
            let digits = rest.prefix(while: \.isASCIIDigit)
            guard !digits.isEmpty else { return nil }
            rest = rest.dropFirst(digits.count).drop(while: { $0 == " " })
            let unit = rest.prefix(while: { $0.isLetter })
            rest = rest.dropFirst(unit.count).drop(while: { $0 == " " })
            // A bare number only last: the whole text ("90"), or trailing minutes after a unit ("1h30").
            guard let scale = unit.isEmpty && rest.isEmpty ? 1 : unitMinutes[String(unit)] else { return nil }
            // More than 7 digits is past any cap; saturating parsers clamp instead of overflowing.
            guard digits.count <= 7, let n = Int(digits) else {
                if saturating { total = cap; continue } else { return nil }
            }
            total += n * scale
            if total > cap {
                guard saturating else { return nil }
                total = cap
            }
        }
        return total > 0 ? total : nil
    }

    private static let unitMinutes: [String: Int] = [
        "m": 1, "min": 1, "mins": 1, "minute": 1, "minutes": 1,
        "h": 60, "hr": 60, "hrs": 60, "hour": 60, "hours": 60,
        "d": 1440, "day": 1440, "days": 1440,
    ]

    /// "17:30", "7:05", "0730" → (17, 30). 24-hour clock.
    static func clock(_ text: String) -> (hour: Int, minute: Int)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let parts: [Substring] = t.count == 4 && !t.contains(":")
            ? [t.prefix(2), t.suffix(2)]
            : t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Paths

enum ControlPaths {
    /// ~/Library/Application Support/Insomnia (0700; shared with the lid marker).
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Insomnia", isDirectory: true)
    }

    /// ~/Library/Application Support/Insomnia/control.sock (0600).
    static var socket: URL { directory.appendingPathComponent("control.sock", isDirectory: false) }
}

// MARK: - Unix socket helpers (both ends)

enum ControlSocket {
    /// Longest request line the server accepts.
    static let maxLineBytes = 64 * 1024

    /// A `sockaddr_un` for `path`, or nil when it doesn't fit in `sun_path` (103 bytes + NUL).
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity, !bytes.contains(0) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return addr
    }

    /// A new AF_UNIX stream socket with close-on-exec and SO_NOSIGPIPE set, or -1 (errno set).
    static func make() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        configure(fd)
        return fd
    }

    /// Close-on-exec (no child the app spawns inherits it) and no SIGPIPE on a dead peer.
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    /// 0 on success, else errno.
    static func connect(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var addr = address
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return r == 0 ? 0 : errno
    }

    /// 0 on success, else errno.
    static func bind(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var addr = address
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return r == 0 ? 0 : errno
    }

    /// Send and receive timeouts for the CLI's blocking requests.
    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    }

    /// The peer's pid (LOCAL_PEERPID), for logs only. Never used for trust: that's the uid check.
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0 ? pid : nil
    }
}
