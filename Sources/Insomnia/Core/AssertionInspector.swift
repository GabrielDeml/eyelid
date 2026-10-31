import Darwin
import Foundation
import IOKit.pwr_mgt

/// Another process's power assertion (Why awake? ▸ Other apps).
struct ForeignAssertion: Identifiable, Equatable, Sendable {
    /// Stable per assertion: "<pid>:<AssertionId>" (falls back to pid + type + name).
    let id: String
    let pid: Int32
    /// The owning process ("zoom.us", "caffeinate", "coreaudiod").
    let process: String
    /// The assertion type that applies (`AssertionTrueType` when powerd reports one, else `AssertType`).
    let type: String
    /// The assertion's own name ("Playing audio", "caffeinate command-line tool"). Shown as a tooltip / in Diagnostics.
    let name: String
    let since: Date?
    /// Daemons such as coreaudiod create assertions for another process (`AssertionOnBehalfOfPID`).
    var onBehalfOfPID: Int32? = nil
    var onBehalfOfName: String? = nil

    /// "caffeinate (61150)", "coreaudiod for Music (808)". Apps get their name only when `isApp` says so.
    func displayName(isApp: (Int32) -> Bool = { _ in false }) -> String {
        let owner = isApp(pid) ? process : "\(process) (\(pid))"
        guard let behalf = onBehalfOfPID else { return owner }
        let target = onBehalfOfName.map { isApp(behalf) ? $0 : "\($0) (\(behalf))" } ?? "pid \(behalf)"
        return "\(process) for \(target)"
    }
}

/// Who else is keeping the Mac awake. Public IOKit API only (`IOPMCopyAssertionsByProcess`); never parses `pmset` text.
/// Called on demand only: the ⌥-click menu, the Diagnostics tab and `insomnia why`. ARCHITECTURE.md
/// "Core/AssertionInspector.swift".
enum AssertionInspector {
    /// Assertions that are on (level 255), affect sleep, and are not ours. Sorted by process name, then start date.
    static func foreignAssertions() -> [ForeignAssertion] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byPID = unmanaged?.takeRetainedValue() as? [AnyHashable: Any] else { return [] }
        var raw: [[String: Any]] = []
        for case let list as [[String: Any]] in byPID.values { raw += list }
        return parse(raw, ownPID: getpid(), processName: Self.processName(pid:))
    }

    /// Pure parsing of the per-assertion dictionaries (unit-tested with fixtures).
    static func parse(_ assertions: [[String: Any]], ownPID: Int32,
                      processName: (Int32) -> String?) -> [ForeignAssertion] {
        var seen = Set<String>()
        var result: [ForeignAssertion] = []
        for a in assertions {
            guard let pid = int32(a[Key.pid]), pid != ownPID else { continue }
            if let level = int32(a[Key.level]), level == 0 { continue }   // 0 = off; absent = on
            let type = (a[Key.trueType] as? String) ?? (a[Key.type] as? String) ?? ""
            guard affectsSleep(type) else { continue }
            let name = (a[Key.name] as? String) ?? ""
            let process = (a[Key.processName] as? String) ?? processName(pid) ?? "pid \(pid)"
            if isSystemNoise(process: process, name: name) { continue }
            let behalf = int32(a[Key.onBehalfOf]).flatMap { $0 > 0 ? $0 : nil }
            let id = int32(a[Key.assertionID]).map { "\(pid):\($0)" } ?? "\(pid):\(type):\(name)"
            guard seen.insert(id).inserted else { continue }
            result.append(ForeignAssertion(
                id: id, pid: pid, process: process, type: type, name: name,
                since: a[Key.start] as? Date,
                onBehalfOfPID: behalf, onBehalfOfName: behalf.flatMap(processName)))
        }
        return result.sorted {
            let l = $0.process.localizedLowercase, r = $1.process.localizedLowercase
            if l != r { return l < r }
            return ($0.since ?? .distantPast) < ($1.since ?? .distantPast)
        }
    }

    /// Human type (plain, every tier): "Preventing idle sleep" / "Preventing display sleep" / "Preventing system sleep"
    /// / the raw type.
    static func describe(type: String) -> String {
        switch type {
        case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "InternalPreventSleep", "SystemIsActive":
            return "Preventing idle sleep"
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion", "InternalPreventDisplaySleep":
            return "Preventing display sleep"
        case "PreventSystemSleep", "DenySystemSleep":
            return "Preventing system sleep"
        case "UserIsActive":
            return "Preventing display sleep (user activity)"
        case "BackgroundTask", "ApplePushServiceTask", "InteractivePushServiceTask", "SoftwareUpdateTask":
            return "Preventing idle sleep (background task)"
        case "NetworkClientActive":
            return "Preventing idle sleep (network client)"
        default:
            return type
        }
    }

    /// Types that don't keep the Mac (or its display) awake are left out of Why awake?.
    static func affectsSleep(_ type: String) -> Bool {
        !type.isEmpty && !nonSleepTypes.contains(type)
    }

    // MARK: Private

    private enum Key {
        static let pid = "AssertPID"
        static let type = "AssertType"
        static let trueType = "AssertionTrueType"
        static let name = "AssertName"
        static let level = "AssertLevel"
        static let start = "AssertStartWhen"
        static let processName = "Process Name"
        static let onBehalfOf = "AssertionOnBehalfOfPID"
        static let assertionID = "AssertionId"
    }

    private static let nonSleepTypes: Set<String> = [
        "ExternalMedia", "PreventDiskIdle", "EnableIdleSleep", "DisableInflow", "ChargeInhibit", "DisableLowPowerBatteryWarnings",
        "PreventSystemSleepSecurityIndicator",
    ]

    /// powerd always holds "Prevent sleep while display is on" while the display is lit: true, but it says nothing.
    private static func isSystemNoise(process: String, name: String) -> Bool {
        process == "powerd" && name.hasPrefix("Powerd - Prevent sleep while display is on")
    }

    private static func int32(_ value: Any?) -> Int32? {
        (value as? NSNumber).map { $0.int32Value }
    }

    /// proc_name; nil if the process is gone.
    static func processName(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
