import Foundation

// MARK: - XPC contract between Insomnia.app (client) and InsomniaHelper (root launchd daemon).
// docs/CLOSED_LID.md §2. Change only together with the docs; any change here changes both binaries' cdhash,
// so an installed helper is re-registered automatically (HelperStatus.versionMismatch).

/// Exported by the helper on the Mach service `HelperInfo.machServiceName`.
/// One NSXPCConnection == one client session. All replies arrive on an XPC queue; hop to your own actor.
@objc(INSHelperProtocol)
public protocol HelperProtocol {
    /// Read-only. `version` = HelperInfo.version, `cdhash` = the cdhash the kernel is running (cached at start-up,
    /// CodeSignature.readSelf; never re-read from disk, so a stale helper after a rebuild is detected),
    /// `sleepDisabled` = IOPMrootDomain "SleepDisabled", `ownsFlag` = the helper set it and it is the caller's: no
    /// session holds it (its reset is pending a retry) or a session of the caller's uid does.
    func status(withReply reply: @escaping @Sendable (_ version: String, _ cdhash: String,
                                                      _ sleepDisabled: Bool, _ ownsFlag: Bool) -> Void)

    /// Adds this connection to the engaged set and starts its heartbeat deadline. The first session sets
    /// SleepDisabled = 1 and reads it back. `result` is a HelperResult raw value.
    func engage(withReply reply: @escaping @Sendable (_ result: Int32, _ sleepDisabled: Bool) -> Void)

    /// Removes this connection from the engaged set. When the set becomes empty and the helper owns the flag,
    /// sets SleepDisabled = 0 and reads it back. Idempotent. A session the helper already dropped gets its drop reason
    /// (`.notEngaged` after its deadline, `.backstop`, `.hot`, `.overridden`); with `sleepDisabled == false` that is
    /// success for the client.
    func release(withReply reply: @escaping @Sendable (_ result: Int32, _ sleepDisabled: Bool) -> Void)

    /// Proof of life, every HelperInfo.heartbeatInterval while engaged. `.ok` == this session is still engaged;
    /// anything else (`.notEngaged`, `.backstop`, `.overridden`, `.hot`) means the helper dropped it and lid mode is gone.
    func heartbeat(withReply reply: @escaping @Sendable (_ result: Int32) -> Void)
}

/// `result` codes in engage/release replies.
public enum HelperResult: Int32, Sendable {
    case ok = 0
    /// SleepDisabled was already 1 and not set by the helper (Amphetamine, an admin, MDM). Not taken over.
    case foreignFlag = 1
    /// On battery at or below HelperInfo.backstopPercent: engage refused (or the session was just dropped).
    case backstop = 2
    /// `/usr/bin/pmset -a disablesleep` failed or timed out, or readback (IORegistry + saved setting) disagreed.
    case setFailed = 3
    /// Heartbeat from a connection that is not in the engaged set (e.g. dropped after a heartbeat timeout).
    case notEngaged = 4
    /// The helper read SleepDisabled = 0 while it owned the flag: someone else cleared it. All sessions dropped;
    /// never re-applied without a new engage.
    case overridden = 5
    /// engage from a different uid while another user's sessions hold the flag (fast user switching). Refused so one
    /// user's session can't keep the flag at 1 after the other releases (CLOSED_LID.md §2.5).
    case otherUser = 6
    /// The helper's heat backstop (docs/DESIGN.md "Safety"): `.critical`, or `.serious` for
    /// HelperInfo.thermalSeriousWindow with the Mac shut in. Engage refused, or every session dropped, the flag reset,
    /// and a shut-in Mac put to sleep.
    case hot = 7
}
