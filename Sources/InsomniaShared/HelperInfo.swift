import Darwin
import Foundation
import Security

/// Identifiers and constants shared by the app and the helper. docs/CLOSED_LID.md §2.
public enum HelperInfo {
    /// launchd Label == MachServices key == helper code-signing identifier.
    public static let label = "com.gdeml.Insomnia.helper"
    public static let machServiceName = label
    /// File name inside Contents/Library/LaunchDaemons/ (SMAppService.daemon(plistName:)).
    public static let plistName = "com.gdeml.Insomnia.helper.plist"
    public static let appBundleID = "com.gdeml.Insomnia"
    /// The only location the helper may be registered from or run out of (CLOSED_LID.md §2.3): installed by
    /// `make install`, owned by root, not group/other-writable.
    public static let installedAppPath = "/Applications/Insomnia.app"
    /// Bundle-relative paths that must exist for setup (otherwise HelperStatus.notFound).
    public static let bundledHelperPath = "Contents/MacOS/InsomniaHelper"
    public static let bundledPlistPath = "Contents/Library/LaunchDaemons/" + plistName
    /// Human-readable, for Diagnostics only. Upgrade detection uses the cdhash, not this string.
    public static let version = "1.0.0"

    /// IOPMrootDomain property and PowerManagement setting key. No SDK constant exists (kIOPMSleepDisabledKey is absent).
    public static let sleepDisabledKey = "SleepDisabled"

    /// Client sends a heartbeat this often while engaged.
    public static let heartbeatInterval: TimeInterval = 10
    /// Per-session one-shot deadline, re-armed on every heartbeat (DispatchTime: uptime, so system sleep never counts).
    public static let heartbeatTimeout: TimeInterval = 45
    /// Root battery backstop: on battery at or below this percent with SleepDisabled = 1 → reset + sleep.
    public static let backstopPercent = 10
    /// On battery at or below this percent the helper also re-checks the flag every `backstopPollInterval`
    /// (catches a foreign setter while the percentage holds steady). No timer above it or on AC.
    public static let backstopPollPercent = 15
    public static let backstopPollInterval: TimeInterval = 60

    /// What the helper requires of every client connection (NSXPCListener.setConnectionCodeSigningRequirement).
    public static func clientRequirement(teamID: String) -> String {
        requirement(identifier: appBundleID, teamID: teamID)
    }

    /// What the app requires of the helper's side of the connection (NSXPCConnection.setCodeSigningRequirement).
    public static func helperRequirement(teamID: String) -> String {
        requirement(identifier: label, teamID: teamID)
    }

    /// Both setters raise an uncatchable ObjC exception on a malformed string: check with this first and refuse
    /// (accept no connections / don't connect) if it fails.
    public static func isValidRequirement(_ text: String) -> Bool {
        var req: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess && req != nil
    }

    /// Apple-issued certificate of our team, our identifier, and not debuggable (an Xcode-style build with
    /// get-task-allow could be driven by same-user code through task_for_pid). Verified on this Mac: a team-signed
    /// copy with get-task-allow fails this requirement; the plain build passes (CLOSED_LID.md "Verified on this Mac").
    private static func requirement(identifier: String, teamID: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
    }
}

/// Facts about the running process's own code signature. The Team ID is never hard-coded: whoever signs the build
/// owns the trust relationship (docs/CLOSED_LID.md §2.2). Read once, off the main thread, and cache the result.
public enum CodeSignature {
    public struct SelfInfo: Sendable, Equatable {
        /// Team ID from our signature; nil for ad-hoc / unsigned builds (→ sudoers backend).
        public let teamID: String?
        /// Hex cdhash of the code the kernel is running (csops CS_OPS_CDHASH); the on-disk value only if csops is
        /// unavailable. This is what the helper reports in status().
        public let cdhash: String?
        /// false when the file at our path is no longer the code we are running (replaced since launch).
        /// The helper then logs and exits non-zero so launchd starts the new binary (CLOSED_LID.md §2.5).
        public let matchesDisk: Bool
    }

    /// Reads our own signature. The helper calls this once at start-up before resuming its listener and keeps the
    /// result in a `let` for its whole life, so a binary swapped on disk can never change whom it trusts.
    public static func readSelf() -> SelfInfo {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return SelfInfo(teamID: nil, cdhash: kernelCDHash(), matchesDisk: false)
        }
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            _ = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        }
        let dict = info as? [String: Any]
        let team = dict?[kSecCodeInfoTeamIdentifier as String] as? String
        let onDisk = (dict?[kSecCodeInfoUnique as String] as? Data).map(hex)
        if let running = kernelCDHash() {
            return SelfInfo(teamID: team, cdhash: running, matchesDisk: running == onDisk)
        }
        // No csops: fall back to the public check, which reports errSecCSStaticCodeChanged (-67034) after a swap.
        let unchanged = SecCodeCheckValidity(code, [], nil) != errSecCSStaticCodeChanged
        return SelfInfo(teamID: team, cdhash: onDisk, matchesDisk: unchanged && onDisk != nil)
    }

    /// Convenience for the app's backend choice (PrivilegedBackends.makeDefault). Call off the main thread.
    public static func currentTeamID() -> String? { readSelf().teamID }

    /// Hex cdhash of a binary on disk (app → the bundled helper, for versionMismatch).
    public static func cdhash(ofFileAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return ((info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data).map(hex)
    }

    /// csops(getpid(), CS_OPS_CDHASH = 5, buf, 20): the kernel's cdhash for our own process. Resolved with dlsym
    /// (no header in the SDK) so a missing symbol can never stop the binary from loading.
    private static func kernelCDHash() -> String? {
        typealias Csops = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else { return nil }   // RTLD_DEFAULT
        let csops = unsafeBitCast(sym, to: Csops.self)
        var buf = [UInt8](repeating: 0, count: 20)
        let rc = buf.withUnsafeMutableBytes { csops(getpid(), 5, $0.baseAddress, 20) }
        return rc == 0 ? hex(Data(buf)) : nil
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// Install-location safety (CLOSED_LID.md §2.3). launchd runs the helper as root straight out of the bundle, so the
/// bundle must not be writable by anyone but root. Used by the app before register() and by the helper at start-up.
public enum InstallLocation {
    public enum Problem: Equatable, Sendable {
        /// Not at HelperInfo.installedAppPath (e.g. build/, ~/Applications, a second copy).
        case wrongPath(String)
        /// Some item in the bundle (or the bundle itself) is not owned by root, or is group/other-writable, or the
        /// bundle root is a symlink.
        case unsafeItem(String)
    }

    /// nil = safe. Walks the whole bundle with lstat (symlinks are not followed).
    public static func check(bundle: URL) -> Problem? {
        let path = bundle.standardizedFileURL.path
        guard path == HelperInfo.installedAppPath else { return .wrongPath(path) }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return .unsafeItem(path) }
        guard isSafe(st) else { return .unsafeItem(path) }
        guard let walker = FileManager.default.enumerator(atPath: path) else { return .unsafeItem(path) }
        while let rel = walker.nextObject() as? String {
            let item = path + "/" + rel
            guard lstat(item, &st) == 0, isSafe(st) else { return .unsafeItem(item) }
        }
        return nil
    }

    private static func isSafe(_ st: stat) -> Bool {
        st.st_uid == 0 && (st.st_mode & (S_IWGRP | S_IWOTH)) == 0
    }
}
