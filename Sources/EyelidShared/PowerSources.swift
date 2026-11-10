import Foundation
import IOKit
import IOKit.ps

/// Read-only IOPMrootDomain properties, for both binaries (docs/DESIGN.md "Kept OS gotchas"). No privileges,
/// never parses `pmset`; the service object is released before returning.
public enum RootDomainRegistry {
    /// A Bool property of IOPMrootDomain ("SleepDisabled", "AppleClamshellState"). nil if absent or unreadable.
    public static func bool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        // CFBoolean bridges to NSNumber; some kernels publish these as numbers. Both read as Bool.
        return (value as? NSNumber)?.boolValue
    }

    /// `kAppleClamshellStateKey`: true = lid closed. nil on desktops (no lid).
    public static let clamshellStateKey = "AppleClamshellState"
    /// `kAppleClamshellCausesSleepKey`: xnu's shouldSleepOnClamshellClosed(), i.e. whether macOS would sleep the Mac
    /// when its lid closes. False in clamshell mode (a real display on power). Can be stale (docs/DESIGN.md gotchas).
    public static let clamshellCausesSleepKey = "AppleClamshellCausesSleep"

    public static func lidClosed() -> Bool? { bool(clamshellStateKey) }
    public static func lidCloseSleeps() -> Bool? { bool(clamshellCausesSleepKey) }
}

/// One IOPS read, for the app's PowerMonitor and the helper's battery backstop. The parsing is separate so it can
/// be tested with a fixture.
public struct PowerSourceReading: Equatable, Sendable {
    public var hasBattery: Bool
    public var percent: Int?
    public var isOnAC: Bool
    public var isCharging: Bool

    public init(hasBattery: Bool, percent: Int?, isOnAC: Bool, isCharging: Bool) {
        self.hasBattery = hasBattery
        self.percent = percent
        self.isOnAC = isOnAC
        self.isCharging = isCharging
    }

    public static let desktop = PowerSourceReading(hasBattery: false, percent: nil, isOnAC: true, isCharging: false)

    public static func current() -> PowerSourceReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .desktop }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let list = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let descriptions: [[String: Any]] = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return parse(providingType: providing, descriptions: descriptions)
    }

    /// Keys are the IOPSKeys.h string values (kIOPSTypeKey, kIOPSInternalBatteryType, …).
    public static func parse(providingType: String?, descriptions: [[String: Any]]) -> PowerSourceReading {
        let battery = descriptions.first {
            ($0["Type"] as? String) == "InternalBattery" && (($0["Is Present"] as? Bool) ?? true)
        }
        guard let battery else { return .desktop }

        var percent: Int?
        if let current = battery["Current Capacity"] as? Int, let max = battery["Max Capacity"] as? Int, max > 0 {
            // Clamp as a Double: Int(_:) traps on a value out of range, and the helper (root) reads this too.
            percent = Int(Swift.min(100, Swift.max(0, (Double(current) / Double(max) * 100).rounded())))
        }
        // "AC Power" / "Battery Power" / "UPS Power". Prefer the system-wide providing type; fall back to the battery's state.
        let state = providingType ?? (battery["Power Source State"] as? String)
        let onAC = state.map { $0 != "Battery Power" } ?? true
        let charging = (battery["Is Charging"] as? Bool) ?? false
        return PowerSourceReading(hasBattery: true, percent: percent, isOnAC: onAC, isCharging: charging)
    }
}
