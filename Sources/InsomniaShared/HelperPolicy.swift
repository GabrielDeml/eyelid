import Foundation

/// Files the root helper keeps in /var/run (root-owned, emptied at every boot). docs/CLOSED_LID.md §2.5.
public enum HelperPaths {
    /// Written + fsynced before SleepDisabled is set to 1, deleted after a verified 0. A restarted helper that finds it
    /// knows the flag it sees is its own (restart reset).
    public static let ownershipFile = "/var/run/com.gdeml.Insomnia.helper.engaged"
    /// Holds `kern.bootsessionuuid`. Missing or a different uuid at start-up == this is the first start since a boot.
    public static let bootMarker = "/var/run/com.gdeml.Insomnia.helper.booted"
}

/// The helper's decisions as pure functions, so the safety-critical branches are unit-tested without root, XPC or
/// IOKit (Tests/InsomniaTests/HelperPolicyTests.swift). The daemon (Sources/InsomniaHelper) only gathers the inputs
/// and carries out the result. docs/CLOSED_LID.md §2.5 state machine.
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
    public static func engage(alreadyEngaged: Bool, engagedUID: UInt32?, requesterUID: UInt32,
                              onBattery: Bool, batteryPercent: Int?, flag: Bool?, ownsFlag: Bool) -> EngageDecision {
        if alreadyEngaged { return .alreadyEngaged }
        // Fast user switching: one uid owns the engaged set (Decision 39).
        if let engagedUID, engagedUID != requesterUID { return .refuse(.otherUser) }
        if backstopTrips(onBattery: onBattery, batteryPercent: batteryPercent, flag: true) { return .refuse(.backstop) }
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

    /// The 60 s re-check timer runs only on battery at or below HelperInfo.backstopPollPercent (zero idle cost above).
    public static func needsBackstopPoll(onBattery: Bool, batteryPercent: Int?) -> Bool {
        guard onBattery, let p = batteryPercent else { return false }
        return p <= HelperInfo.backstopPollPercent
    }

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
