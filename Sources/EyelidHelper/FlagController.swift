import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import EyelidShared

/// Sets, clears and reads `SleepDisabled`, and keeps the ownership file. docs/DESIGN.md "Security".
/// Used only on the daemon's serial queue (every call blocks for up to ~5.6 s).
struct FlagController {
    /// IOPMrootDomain "SleepDisabled"; nil if unreadable.
    func read() -> Bool? { RootDomainRegistry.bool(HelperInfo.sleepDisabledKey) }

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

    /// O_NOFOLLOW: a symlink planted in /var/run (root:daemon 0775) reads as no marker, never as its target.
    func readBootMarker() -> String? {
        let fd = open(HelperPaths.bootMarker, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        let text = String(decoding: buf.prefix(n), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Written to `<path>.tmp`, created fresh with O_CREAT | O_EXCL | O_NOFOLLOW (never through a planted link or
    /// symlink), 0644, fsynced, then renamed over `path`. rename replaces whatever entry is there without following it,
    /// and the old file stays in place until then, so the ownership file is never missing mid-write.
    private func writeFile(_ path: String, _ contents: String) -> Bool {
        let tmp = path + ".tmp"
        _ = unlink(tmp)   // a leftover from a crash, or something planted
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        let bytes = Array(contents.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let durable = written == bytes.count && fchmod(fd, 0o644) == 0 && fsync(fd) == 0
        close(fd)
        guard durable, rename(tmp, path) == 0 else {
            _ = unlink(tmp)
            return false
        }
        return true
    }
}

/// Puts the Mac to sleep after a backstop reset or a reset nobody else can follow up (docs/DESIGN.md "Safety"):
/// IOPMSleepSystem, else `/usr/bin/pmset sleepnow`.
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
