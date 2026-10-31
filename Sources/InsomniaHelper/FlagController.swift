import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import InsomniaShared

/// Sets, clears and reads `SleepDisabled`, and keeps the ownership file. docs/CLOSED_LID.md §2.5 "Set / clear".
/// Used only on the daemon's serial queue (every call blocks for up to ~5.6 s).
struct FlagController {
    /// IOPMrootDomain "SleepDisabled"; nil if unreadable.
    func read() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, HelperInfo.sleepDisabledKey as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// The saved setting from `IOPMCopySystemPowerSettings()` (no header; resolved with dlsym so a missing symbol
    /// can never stop the helper loading). `.unavailable` = the symbol is missing: IORegistry alone decides.
    enum Saved: Equatable { case value(Bool), unavailable }

    func readSaved() -> Saved {
        typealias CopySettings = @convention(c) () -> Unmanaged<CFDictionary>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPMCopySystemPowerSettings") else {
            return .unavailable
        }
        let copy = unsafeBitCast(sym, to: CopySettings.self)
        guard let dict = copy()?.takeRetainedValue() as? [String: Any] else { return .value(false) }
        // Absent == 0 (verified on 27.0.1: the key is present as a CFBoolean either way).
        return .value((dict[HelperInfo.sleepDisabledKey] as? NSNumber)?.boolValue ?? false)
    }

    /// `/usr/bin/pmset -a disablesleep 0|1` (fixed argv, empty environment, 5 s timeout), then reads back IORegistry
    /// and the saved setting, immediately and then up to 3 × 200 ms. true only if pmset exited 0 and both agree.
    func set(_ on: Bool) -> Bool {
        let result = Spawn.run("/usr/bin/pmset", ["-a", "disablesleep", on ? "1" : "0"], timeout: 5)
        guard result.succeeded else {
            HelperLog.flag.error("pmset disablesleep \(on ? 1 : 0, privacy: .public) exited \(result.status, privacy: .public)")
            return false
        }
        for attempt in 0...3 {
            if attempt > 0 { usleep(200_000) }
            let registry = read()
            let saved = readSaved()
            if registry == on && (saved == .unavailable || saved == .value(on)) { return true }
        }
        HelperLog.flag.error("readback mismatch after disablesleep \(on ? 1 : 0, privacy: .public): registry \(String(describing: read()), privacy: .public)")
        return false
    }

    // MARK: Ownership file (root, 0644, /var/run)

    var ownershipFileExists: Bool {
        var st = stat()
        return lstat(HelperPaths.ownershipFile, &st) == 0
    }

    /// Written and fsynced BEFORE the flag is set to 1.
    func writeOwnershipFile() -> Bool {
        writeFile(HelperPaths.ownershipFile, "\(getpid()) \(ISO8601DateFormatter().string(from: Date()))\n")
    }

    func deleteOwnershipFile() {
        if unlink(HelperPaths.ownershipFile) != 0 && errno != ENOENT {
            HelperLog.flag.error("couldn't delete the ownership file: errno \(errno, privacy: .public)")
        }
    }

    // MARK: Boot marker

    func readBootMarker() -> String? {
        guard let data = FileManager.default.contents(atPath: HelperPaths.bootMarker) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func writeBootMarker(_ uuid: String) {
        if !writeFile(HelperPaths.bootMarker, uuid + "\n") {
            HelperLog.main.error("couldn't write the boot marker")
        }
    }

    /// `kern.bootsessionuuid`: changes on every boot.
    static func bootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        let uuid = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return uuid.isEmpty ? nil : uuid
    }

    /// O_NOFOLLOW (never write through a symlink), 0644, fsync before close.
    private func writeFile(_ path: String, _ contents: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(contents.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { return false }
        _ = fchmod(fd, 0o644)
        return fsync(fd) == 0
    }
}

/// One IOPS read in the helper (it can't link the app's PowerMonitor). Same keys as PowerSourceReading.
struct BatteryReading: Equatable {
    var onBattery: Bool
    var percent: Int?

    static func current() -> BatteryReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return BatteryReading(onBattery: false) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let list = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let battery = list.lazy.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }.first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard let battery else { return BatteryReading(onBattery: false) }
        var percent: Int?
        if let current = battery[kIOPSCurrentCapacityKey] as? Int, let max = battery[kIOPSMaxCapacityKey] as? Int, max > 0 {
            percent = Swift.min(100, Swift.max(0, Int((Double(current) / Double(max) * 100).rounded())))
        }
        let state = providing ?? (battery[kIOPSPowerSourceStateKey] as? String)
        return BatteryReading(onBattery: state == kIOPSBatteryPowerValue, percent: percent)
    }

    init(onBattery: Bool, percent: Int? = nil) {
        self.onBattery = onBattery
        self.percent = percent
    }
}

/// Puts the Mac to sleep after a backstop reset: IOPMSleepSystem, else `/usr/bin/pmset sleepnow`.
enum SystemSleeper {
    static func sleepNow() {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        if port != IO_OBJECT_NULL {
            let kr = IOPMSleepSystem(port)
            IOServiceClose(port)
            if kr == kIOReturnSuccess { return }
            HelperLog.backstop.error("IOPMSleepSystem failed (\(kr, privacy: .public)); trying pmset sleepnow")
        }
        _ = Spawn.run("/usr/bin/pmset", ["sleepnow"], timeout: 5)
    }
}
