import Foundation
import InsomniaShared

/// The one privileged surface lid mode uses (ARCHITECTURE.md "Core/Privileged", docs/CLOSED_LID.md §2).
/// Implementations are called only from `LidReconciler` (one call at a time) except `abandon()`, which the quit path
/// may call concurrently, so both keep their mutable state behind a lock.
protocol PrivilegedBackend: Sendable {
    var kind: PrivilegeBackendKind { get }
    /// CLOSED_LID.md §2.6 (helper) / §2.7 (sudoers). Never on the main thread (SMAppService.status blocks).
    func status() async -> HelperStatus
    /// Helper: refuses (.unsafeLocation) unless InstallLocation.check passes; SMAppService register() (unregister first
    /// on .versionMismatch / .unreachable); saves Settings.helperRegisteredCDHash; usually returns .requiresApproval.
    /// Sudoers: inline install script, one admin prompt. Returns the status afterwards.
    func install() async throws(LidSetupError) -> HelperStatus
    /// Caller has already released. Helper: unregister(), then require .notRegistered/.notFound (else
    /// .unregisterIncomplete; resetFlag ignored, the helper knows ownership). Sudoers: §2.7 script; on .leftoverHelper:
    /// unregister the old helper.
    func uninstall(resetFlag: Bool) async throws(LidSetupError)
    /// Arm the safety net, then set SleepDisabled = 1 (5 s timeout). 0 = ok, else a HelperResult raw value / sudo exit
    /// status / -1. `onLost` fires once if the safety net dies while engaged.
    func engage(onLost: @escaping @Sendable () -> Void) async -> Int32
    /// Set SleepDisabled = 0, then disarm. On failure the safety net stays armed. Helper reply .notEngaged + readback
    /// 0 = success (the caller reads back).
    func release() async -> Int32
    /// Drop the safety net WITHOUT disarming so it resets the flag itself (helper: invalidate the connection;
    /// sudoers: close the pipe).
    func abandon() async
    /// Every 10 s while engaged. nil = fine; .overridden / .safetyNetLost = lid mode is gone (CLOSED_LID.md §4.1).
    func heartbeat() async -> LidError?
    /// Flag ours? Helper: status().ownsFlag. Sudoers: the marker file exists.
    func ownsFlag() async -> Bool
    /// .stuck recovery, both backends: osascript admin prompt running `/usr/bin/pmset -a disablesleep 0`.
    func resetWithPassword() async throws(LidSetupError)
}

enum PrivilegedBackends {
    /// HelperBackend(teamID:) if our own signature has a Team ID, else SudoersBackend(). Reads certificates, so it
    /// must run off the main thread (LidReconciler calls it once per launch and keeps the result).
    static func makeDefault() async -> any PrivilegedBackend {
        if let team = CodeSignature.currentTeamID(), !team.isEmpty {
            return HelperBackend(teamID: team)
        }
        return SudoersBackend()
    }
}

/// `~/Library/Application Support/Insomnia/lid-engaged` (CLOSED_LID.md §4.2): our pid and an ISO date, written with
/// fsync BEFORE engaging, deleted after a verified release. Present at launch == the last run ended uncleanly.
struct LidMarker: Sendable {
    let url: URL

    static let standard: LidMarker = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return LidMarker(url: base.appendingPathComponent("Insomnia/lid-engaged"))
    }()

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func write() -> Bool {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return false }
        let text = "\(getpid()) \(ISO8601DateFormatter().string(from: Date()))\n"
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        return n == bytes.count && fsync(fd) == 0
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Admin-prompt plumbing shared by both backends (Reset with password…) and the sudoers install/uninstall.
enum AdminScript {
    /// `do shell script "<script>" with administrator privileges with prompt "<prompt>"` via /usr/bin/osascript
    /// (argv array, never a shell). osascript exits 1 for every failure; the script's own exit code (or -128 for
    /// Cancel) is the trailing "(N)" on stderr.
    static func run(_ script: String, prompt: String) -> (code: Int32, detail: String) {
        let source = "do shell script \"\(appleScriptEscaped(script))\" with administrator privileges with prompt \"\(appleScriptEscaped(prompt))\""
        let result = Spawn.run("/usr/bin/osascript", ["-e", source],
                               environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"],
                               timeout: 600, captureStderr: true)
        if result.status == 0 { return (0, "") }
        if result.status == -1 { return (-1, result.stderr.isEmpty ? "osascript didn't finish" : result.stderr) }
        return (trailingCode(result.stderr) ?? result.status, result.stderr)
    }

    /// AppleScript string literal: `\` → `\\`, `"` → `\"`, newline → `\n` (CLOSED_LID.md §2.7).
    static func appleScriptEscaped(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }

    /// `… execution error: … (-128)` → -128. Matches `/\((-?\d+)\)\s*$/`.
    static func trailingCode(_ stderr: String) -> Int32? {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return nil }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        guard !inner.isEmpty, inner.dropFirst(inner.first == "-" ? 1 : 0).allSatisfy(\.isASCII),
              inner.dropFirst(inner.first == "-" ? 1 : 0).allSatisfy(\.isNumber) else { return nil }
        return Int32(inner)
    }

    static let resetScript = "/usr/bin/pmset -a disablesleep 0"
    static let resetPrompt = "Insomnia needs your password to turn sleep back on."

    /// Reset with password… (both backends).
    static func resetFlag() throws(LidSetupError) {
        let r = run(resetScript, prompt: resetPrompt)
        switch r.code {
        case 0: return
        case -128: throw .cancelled
        default: throw .scriptFailed(code: r.code, detail: r.detail)
        }
    }
}
