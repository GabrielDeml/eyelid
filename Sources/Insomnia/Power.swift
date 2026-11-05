import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import InsomniaShared

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
    var externalDisplays = 0

    var isOnBattery: Bool { hasBattery && !isOnAC }
    /// Lid shut with no external display: the "in a bag" case.
    var isClosedWithoutDisplay: Bool { hasLid && isLidClosed && externalDisplays == 0 }
}

@MainActor
protocol PowerSource: AnyObject {
    var state: PowerState { get }
    /// Called once per refresh, after every field of it is written, and only if something changed.
    var onChange: (() -> Void)? { get set }
    /// Seconds since the last keyboard / mouse / trackpad input.
    var idleSeconds: TimeInterval { get }
    /// Re-reads the lid from IORegistry (the engine's 5 s fallback poll while lid mode is engaged).
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
            clamshell = RootDomain.observeClamshell { closed, _ in
                Power.shared.update { $0.isLidClosed = closed }
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
            MainActor.assumeIsolated { Power.shared.update { $0.externalDisplays = Power.countExternalDisplays() } }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Power.shared.refreshAll() }
            })
        }
    }

    var idleSeconds: TimeInterval {
        // kCGAnyInputEventType (~0): any HID event.
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    func refreshLid() {
        update { s in
            let closed = RootDomain.clamshellClosed()
            s.hasLid = closed != nil
            s.isLidClosed = closed ?? false
        }
    }

    private func refreshAll() {
        update { s in
            s.applyPowerSources()
            s.thermal = ProcessInfo.processInfo.thermalState
            let closed = RootDomain.clamshellClosed()
            s.hasLid = closed != nil
            s.isLidClosed = closed ?? false
            s.externalDisplays = Power.countExternalDisplays()
        }
    }

    private func update(_ body: (inout PowerState) -> Void) {
        var next = state
        body(&next)
        guard next != state else { return }
        state = next
        onChange?()
    }

    private static func countExternalDisplays() -> Int {
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
    }
}
