import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import EyelidShared

/// One consistent reading of everything the engine decides on.
struct PowerState: Equatable, Sendable {
    var hasBattery = false
    /// nil when unknown (or no battery).
    var batteryPercent: Int?
    /// true on desktops.
    var isOnAC = true
    var thermal: ProcessInfo.ThermalState = .nominal
    /// false on desktops: no lid UI at all.
    var hasLid = false
    var isLidClosed = false
    /// Online displays that aren't built in (CoreGraphics), virtual ones included.
    var externalDisplays = 0
    /// IOPMrootDomain "AppleClamshellCausesSleep": macOS would sleep the Mac when its lid closes. False in clamshell
    /// mode (a real display on power); a virtual, DisplayLink or AirPlay display leaves it true. nil if unreadable.
    var lidCloseSleeps: Bool?

    /// HID idle time after which a shut-in Mac with a display counts as unattended (docs/DESIGN.md "Shut in, and
    /// unattended"); also the safety trip's "nobody is using it" test.
    static let unattendedAfter: TimeInterval = 120

    var isOnBattery: Bool { hasBattery && !isOnAC }
    /// Lid shut with no external display at all: `displaysleepnow` can't blank another screen.
    var isClosedWithoutDisplay: Bool { hasLid && isLidClosed && externalDisplays == 0 }
    /// Lid shut and only lid mode keeps the Mac awake: no external display, or one the kernel doesn't count as
    /// clamshell mode. The kernel's answer only ever adds "shut in" when a display is present.
    var isShutIn: Bool { hasLid && isLidClosed && (externalDisplays == 0 || lidCloseSleeps == true) }
    /// Shut in, and no external display at all or nobody has used the Mac for `unattendedAfter`: the "in a bag" case.
    func isUnattended(idleSeconds: TimeInterval) -> Bool {
        isShutIn && (externalDisplays == 0 || idleSeconds >= Self.unattendedAfter)
    }
}

@MainActor
protocol PowerSource: AnyObject {
    var state: PowerState { get }
    /// Called once per refresh, after every field of it is written, and only if something changed.
    var onChange: (() -> Void)? { get set }
    /// Seconds since the last keyboard / mouse / trackpad input.
    var idleSeconds: TimeInterval { get }
    /// Re-reads the lid, the kernel's clamshell answer and the displays (the engine's 5 s poll while lid mode is engaged).
    func refreshLid()
}

/// Battery, AC, thermal, lid and displays. Event-driven: IOPS run-loop source, the clamshell interest notification,
/// ProcessInfo thermal notifications, screen-parameter changes, and a full re-read on wake.
@MainActor
final class Power: PowerSource {
    static let shared = Power()

    private(set) var state = PowerState()
    var onChange: (() -> Void)?

    private var started = false
    private var clamshell: AnyObject?
    private var observers: [NSObjectProtocol] = []
    private var ipsSource: CFRunLoopSource?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        refreshAll()

        // The IOPS callback is a C function pointer: it can't capture, so it reaches the singleton.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { Power.shared.update { $0.applyPowerSources() } }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            ipsSource = source
        }
        if state.hasLid {
            clamshell = RootDomain.observeClamshell { closed, causesSleep in
                Power.shared.update {
                    $0.isLidClosed = closed
                    $0.lidCloseSleeps = causesSleep
                }
            }
        }
        let center = NotificationCenter.default
        // Thermal notifications can arrive on any thread: hop to main and re-read.
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { Power.shared.update { $0.thermal = ProcessInfo.processInfo.thermalState } }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated {
                Power.shared.update {
                    $0.externalDisplays = Power.countExternalDisplays()
                    $0.lidCloseSleeps = RootDomain.clamshellCausesSleep()
                }
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Power.shared.refreshAll() }
            })
        }
    }

    var idleSeconds: TimeInterval { Self.hidIdleSeconds() }

    /// Seconds since the last keyboard / mouse / trackpad input. kCGAnyInputEventType (~0): any HID event.
    nonisolated static func hidIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    func refreshLid() {
        update { s in s.applyLid() }
    }

    private func refreshAll() {
        update { s in
            s.applyPowerSources()
            s.thermal = ProcessInfo.processInfo.thermalState
            s.applyLid()
        }
    }

    /// Everything a follow-up sleep decides on, read now (HelperClient.isUnattendedNow; off the main actor).
    nonisolated static func lidSnapshot() -> PowerState {
        var s = PowerState()
        s.applyLid()
        return s
    }

    private func update(_ body: (inout PowerState) -> Void) {
        var next = state
        body(&next)
        guard next != state else { return }
        state = next
        onChange?()
    }

    nonisolated static func countExternalDisplays() -> Int {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return 0 }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }
}

private extension PowerState {
    mutating func applyPowerSources() {
        let r = PowerSourceReading.current()
        hasBattery = r.hasBattery
        batteryPercent = r.percent
        isOnAC = r.isOnAC
        // AC changes clamshell mode; the kernel also sends a clamshell message, this catches a missed one.
        lidCloseSleeps = RootDomain.clamshellCausesSleep()
    }

    mutating func applyLid() {
        let closed = RootDomain.clamshellClosed()
        hasLid = closed != nil
        isLidClosed = closed ?? false
        lidCloseSleeps = RootDomain.clamshellCausesSleep()
        externalDisplays = Power.countExternalDisplays()
    }
}
