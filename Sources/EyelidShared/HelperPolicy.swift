import Foundation

/// Files the root helper keeps in /var/run (root-owned, emptied at every boot). docs/DESIGN.md "Security".
public enum HelperPaths {
    /// Written + fsynced before SleepDisabled is set to 1, deleted after a verified 0. A restarted helper that finds it
    /// knows the flag it sees is its own (restart reset).
    public static let ownershipFile = "/var/run/com.gdeml.Eyelid.helper.engaged"
    /// Holds `kern.bootsessionuuid`. Missing or a different uuid at start-up == this is the first start since a boot.
    public static let bootMarker = "/var/run/com.gdeml.Eyelid.helper.booted"
}

/// The helper's decisions as pure functions, so the safety-critical branches are unit-tested without root, XPC or
/// IOKit (Tests/EyelidTests/HelperPolicyTests.swift): engage, heartbeat, status ownership, the reset after a session
/// is dropped (release, crash, hang), SIGTERM, and the start-up reset. The daemon (Sources/EyelidHelper) gathers
/// the inputs and carries out the result; its timers, XPC plumbing and pmset calls are covered by the device tests
/// (docs/DESIGN.md "Verify"). What it decides: docs/DESIGN.md "Safety" (the helper's backstops) and "Security".
public enum HelperPolicy {
    public enum EngageDecision: Equatable, Sendable {
        /// This connection is already in the engaged set: re-arm its deadline, reply `.ok`.
        case alreadyEngaged
        /// Another session of the same uid holds the flag (or the helper still owns a flag whose reset is being
        /// retried): add this session, reply `.ok`. Nothing is spawned.
        case join
        /// Idle and the flag is 0: write the ownership file, run `pmset -a disablesleep 1`, read back.
        case setFlag
        /// Reply with this code and change nothing.
        case refuse(HelperResult)
    }

    /// - Parameters:
    ///   - engagedUID: uid of the sessions currently holding the flag; nil when the engaged set is empty.
    ///   - flag: IOPMrootDomain SleepDisabled now; nil if unreadable.
    ///   - ownsFlag: the helper set the flag (sessions hold it, or its reset is pending a retry).
    /// The caller has already handled an external override (ownsFlag && flag == 0 → drop all `.overridden`).
    ///   - hot: the heat backstop's condition holds right now (`heatTrips`); the caller has already dropped any sessions.
    public static func engage(alreadyEngaged: Bool, engagedUID: UInt32?, requesterUID: UInt32,
                              onBattery: Bool, batteryPercent: Int?, flag: Bool?, ownsFlag: Bool,
                              hot: Bool = false) -> EngageDecision {
        if alreadyEngaged { return .alreadyEngaged }
        // Fast user switching: one uid owns the engaged set (Decision 39).
        if let engagedUID, engagedUID != requesterUID { return .refuse(.otherUser) }
        if backstopTrips(onBattery: onBattery, batteryPercent: batteryPercent, flag: true) { return .refuse(.backstop) }
        if hot { return .refuse(.hot) }
        if engagedUID != nil { return flag == false ? .setFlag : .join }
        switch flag {
        case .some(true): return ownsFlag ? .join : .refuse(.foreignFlag)
        case .some(false): return .setFlag
        case .none: return .refuse(.setFailed)   // can't read the flag: never write blind
        }
    }

    public enum HeartbeatDecision: Equatable, Sendable {
        /// Session alive and the flag is still ours: re-arm the deadline, reply `.ok`.
        case ok
        /// Someone cleared the flag while we owned it: drop every session (`.overridden`), forget ownership, delete the
        /// ownership file. Never re-applied.
        case overridden
        /// The session isn't engaged (dropped earlier): reply with its drop reason.
        case reply(HelperResult)
    }

    public static func heartbeat(sessionEngaged: Bool, dropReason: HelperResult?, flag: Bool?,
                                 ownsFlag: Bool) -> HeartbeatDecision {
        guard sessionEngaged else { return .reply(dropReason ?? .notEngaged) }
        if ownsFlag && flag == false { return .overridden }
        return .ok
    }

    /// Root battery backstop (§2.5): on battery, at or below HelperInfo.backstopPercent, with the flag at 1 (whoever
    /// set it). An unknown percentage never trips it.
    public static func backstopTrips(onBattery: Bool, batteryPercent: Int?, flag: Bool?) -> Bool {
        guard onBattery, flag == true, let p = batteryPercent else { return false }
        return p <= HelperInfo.backstopPercent
    }

    /// Shut in, as the helper sees it (docs/DESIGN.md "Shut in, and unattended"): lid closed and macOS would sleep the
    /// Mac if not for the flag. The helper can't see displays or input, so an unknown kernel answer counts as yes.
    public static func isShutIn(lidClosed: Bool?, lidCloseSleeps: Bool?) -> Bool {
        lidClosed == true && lidCloseSleeps != false
    }

    /// Heat backstop (its own flag only). `.critical` trips with any lid state: while the flag is 1, macOS's own
    /// thermal emergency sleep is blocked too. `.serious` trips after HelperInfo.thermalSeriousWindow, only shut in.
    /// - Parameter seriousFor: how long the state has been `.serious` or worse (uptime); nil if it isn't.
    public static func heatTrips(thermal: ProcessInfo.ThermalState, seriousFor: TimeInterval?, shutIn: Bool) -> Bool {
        if thermal.rawValue >= ProcessInfo.ThermalState.critical.rawValue { return true }
        guard shutIn, let seriousFor else { return false }
        return seriousFor >= HelperInfo.thermalSeriousWindow
    }

    /// What follows a successful reset of the helper's own flag. Kept for the 5 s retry if the reset fails, so a retry
    /// that succeeds still does it; cleared by a new session, an override or SIGTERM.
    public enum AfterReset: Equatable, Sendable {
        /// Explicit release (the app follows up itself), failed engage, boot reset.
        case nothing
        /// Connection lost, heartbeat deadline, heat backstop, restart reset: nobody else can follow up.
        case sleepIfShutIn
        /// Battery backstop: sleep regardless of the lid.
        case sleep
    }

    /// Whether to put the Mac to sleep now, after a reset that succeeded.
    public static func sleeps(after: AfterReset, shutIn: Bool) -> Bool {
        switch after {
        case .nothing: false
        case .sleepIfShutIn: shutIn
        case .sleep: true
        }
    }

    /// The 60 s re-check timer runs only on battery at or below HelperInfo.backstopPollPercent (zero idle cost above).
    public static func needsBackstopPoll(onBattery: Bool, batteryPercent: Int?) -> Bool {
        guard onBattery, let p = batteryPercent else { return false }
        return p <= HelperInfo.backstopPollPercent
    }

    /// status(): is the flag the caller's? We set it and either no session holds it (a reset is pending a retry: the
    /// caller's recovery should treat it as its own and say `.stuck` if it stays) or a session of the caller's uid
    /// does. Another user's sessions read as foreign, so that user's flag is never touched from the caller's side.
    public static func statusOwnsFlag(ownsFlag: Bool, sessionUIDs: [UInt32], callerUID: UInt32) -> Bool {
        ownsFlag && (sessionUIDs.isEmpty || sessionUIDs.contains(callerUID))
    }

    /// A session left the engaged set (release, connection lost = crash / Force Quit, heartbeat deadline = hang):
    /// reset the flag once the last one is gone, if we set it. Another session of the same user keeps it.
    public static func resetsAfterDrop(remainingSessions: Int, ownsFlag: Bool) -> Bool {
        remainingSessions == 0 && ownsFlag
    }

    /// SIGTERM (unregister, Login Items switched off, shutdown): exit 0 (launchd leaves us down) unless we own the flag
    /// and couldn't clear it; then 75, keeping the ownership file, so a restart retries the reset.
    public static func terminateExitCode(ownsFlag: Bool, resetSucceeded: Bool) -> Int32 {
        !ownsFlag || resetSucceeded ? 0 : 75
    }

    /// Boot / restart reset: anything but a verified 0 (1, or unreadable) is reset; `pmset -a disablesleep 0` is always
    /// safe. A verified 0 only drops a stale ownership file.
    public static func startUpResets(flag: Bool?) -> Bool { flag != false }

    public enum StartReset: Equatable, Sendable {
        /// First start since a boot: write the marker; if SleepDisabled == 1 reset it whoever set it (the setting
        /// persists across reboots). Any ownership file is stale.
        case bootReset
        /// Same boot, the previous helper instance died holding the flag: reset it, delete the ownership file.
        case restartReset
        case none
    }

    /// - Parameters:
    ///   - savedBootUUID: contents of HelperPaths.bootMarker, nil if missing (/var/run is emptied at boot).
    ///   - currentBootUUID: `kern.bootsessionuuid`; nil if unreadable.
    public static func startReset(savedBootUUID: String?, currentBootUUID: String?,
                                  ownershipFileExists: Bool) -> StartReset {
        let isBoot: Bool
        switch (savedBootUUID, currentBootUUID) {
        case (nil, _): isBoot = true                         // marker gone: /var/run was emptied by a boot
        case let (saved?, current?): isBoot = saved != current
        case (_?, nil): isBoot = false                        // can't tell: never clear a foreign flag on a guess
        }
        if isBoot { return .bootReset }
        return ownershipFileExists ? .restartReset : .none
    }
}
