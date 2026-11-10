import Foundation
import IOKit
import IOKit.pwr_mgt
import EyelidShared

/// Read-only access to IOPMrootDomain. No privileges, never parses `pmset`.
/// Every IOKit object obtained here is released before returning.
enum RootDomain {
    /// `kIOPMMessageClamshellStateChange` is a function-like macro Swift can't import:
    /// `iokit_family_msg(sub_iokit_powermanagement, 0x100)` = sys_iokit | err_sub(13) | 0x100.
    static let clamshellStateChangeMessage: UInt32 = 0xE003_4100
    /// `kClamshellStateBit` / `kClamshellSleepBit` (IOPM.h), spelled out so the decoding never depends on an import.
    static let clamshellStateBit: UInt = 1 << 0
    static let clamshellSleepBit: UInt = 1 << 1

    /// IOPMrootDomain "SleepDisabled". nil if unreadable.
    static func sleepDisabled() -> Bool? { RootDomainRegistry.bool(HelperInfo.sleepDisabledKey) }

    /// IOPMrootDomain "AppleClamshellState"; true = lid closed. nil on desktops (no lid).
    static func clamshellClosed() -> Bool? { RootDomainRegistry.lidClosed() }

    /// IOPMrootDomain "AppleClamshellCausesSleep": macOS would sleep the Mac when its lid closes (PowerState.isShutIn).
    static func clamshellCausesSleep() -> Bool? { RootDomainRegistry.lidCloseSleeps() }

    /// Decodes a clamshell interest message argument. Pure; unit-tested.
    static func decodeClamshell(_ bits: UInt) -> (closed: Bool, causesSleep: Bool) {
        (bits & clamshellStateBit != 0, bits & clamshellSleepBit != 0)
    }

    /// IOServiceAddInterestNotification(kIOGeneralInterest) on the main run loop. The handler runs on the main actor,
    /// in order, for every clamshell change. Keep the returned token alive; releasing it stops the observation.
    /// Returns a token that observes nothing if the root domain can't be found (desktops still have one; this is a
    /// belt-and-braces path, never a crash).
    @MainActor
    static func observeClamshell(_ handler: @escaping @MainActor (_ closed: Bool, _ causesSleep: Bool) -> Void) -> AnyObject {
        ClamshellObservation(handler: handler)
    }
}

/// Owns the IONotificationPort + interest notification; tears both down on deinit.
private final class ClamshellObservation: @unchecked Sendable {
    /// Boxed so the C callback can reach it through `refcon` without capturing context.
    private final class Box {
        let handler: @MainActor (Bool, Bool) -> Void
        init(_ handler: @escaping @MainActor (Bool, Bool) -> Void) { self.handler = handler }
    }

    private var port: IONotificationPortRef?
    private var notification: io_object_t = IO_OBJECT_NULL
    private let box: Box

    @MainActor
    init(handler: @escaping @MainActor (Bool, Bool) -> Void) {
        box = Box(handler)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            IONotificationPortDestroy(port)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let refcon = Unmanaged.passUnretained(box).toOpaque()
        var note: io_object_t = IO_OBJECT_NULL
        let kr = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { refcon, _, messageType, argument in
            guard messageType == RootDomain.clamshellStateChangeMessage, let refcon else { return }
            let decoded = RootDomain.decodeClamshell(UInt(bitPattern: argument))
            // Registered on the main run loop, so this always runs on the main thread.
            MainActor.assumeIsolated {
                let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
                box.handler(decoded.closed, decoded.causesSleep)
            }
        }, refcon, &note)
        guard kr == KERN_SUCCESS else {
            IONotificationPortDestroy(port)   // also removes the run loop source
            return
        }
        self.port = port
        self.notification = note
    }

    deinit {
        if notification != IO_OBJECT_NULL { IOObjectRelease(notification) }
        if let port { IONotificationPortDestroy(port) }
    }
}
