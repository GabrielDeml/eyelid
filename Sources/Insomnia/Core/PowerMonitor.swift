import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import Observation

/// Read-only view of the power situation. `PowerMonitor` is the real one; tests inject a fake.
@MainActor
protocol PowerReading: AnyObject {
    var hasBattery: Bool { get }
    var batteryPercent: Int? { get }
    var isOnAC: Bool { get }
    var isCharging: Bool { get }
    var thermalState: ProcessInfo.ThermalState { get }
    var isLowPowerMode: Bool { get }
    var hasLid: Bool { get }
    var isLidClosed: Bool { get }
    var externalDisplayCount: Int { get }
}

extension PowerReading {
    /// Lid closed and no external display (CLOSED_LID.md §5 `closedNoExt`).
    var isClosedWithoutExternalDisplay: Bool { isLidClosed && externalDisplayCount == 0 }
    /// The "bag" condition: closed, no external display, on battery.
    var isBag: Bool { isClosedWithoutExternalDisplay && !isOnAC }
}

/// Battery, AC, thermal, Low Power Mode, lid and display state. Event-driven only: no polling timers
/// (ClosedLidController adds a 5 s clamshell poll while engaged). Posts `.insomniaPowerDidChange` only when a value
/// actually changes. ARCHITECTURE.md "Core/PowerMonitor.swift".
@MainActor
@Observable
final class PowerMonitor: PowerReading {
    static let shared = PowerMonitor()

    private(set) var hasBattery = false
    /// nil when there is no battery (or IOPS doesn't report a capacity).
    private(set) var batteryPercent: Int?
    /// true on desktops.
    private(set) var isOnAC = true
    private(set) var isCharging = false
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var isLowPowerMode = false
    /// AppleClamshellState present. false on desktops → no lid UI at all.
    private(set) var hasLid = false
    /// false on desktops.
    private(set) var isLidClosed = false
    /// Online displays where !CGDisplayIsBuiltin.
    private(set) var externalDisplayCount = 0

    @ObservationIgnored private var started = false
    @ObservationIgnored private var clamshellToken: AnyObject?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var powerSourceLoopSource: CFRunLoopSource?

    init() {}

    /// Reads everything once and subscribes to changes. Idempotent.
    func start() {
        guard !started else { return }
        started = true

        refreshAll(post: false)

        // Battery / AC / charging: IOPS run loop source on the main run loop. The C callback can't capture context,
        // so it reaches the singleton (the only instance that ever starts).
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { PowerMonitor.shared.refreshPowerSources() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceLoopSource = source
        }

        // Lid: clamshell interest notifications (no 2 s poll).
        if hasLid {
            clamshellToken = RootDomain.observeClamshell { [weak self] closed, _ in
                self?.set(\.isLidClosed, closed)
            }
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { PowerMonitor.shared.refreshThermalAndLPM() }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { PowerMonitor.shared.refreshThermalAndLPM() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { PowerMonitor.shared.refreshDisplays() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PowerMonitor.shared.refreshAll(post: true) }
            })
        }
    }

    /// Re-reads the lid from IORegistry. ClosedLidController's 5 s engaged-only poll calls this.
    func refreshLid() {
        let closed = RootDomain.clamshellClosed()
        set(\.hasLid, closed != nil)
        set(\.isLidClosed, closed ?? false)
    }

    // MARK: Refresh

    private func refreshAll(post: Bool) {
        let before = snapshot
        suppressPosting = true
        refreshPowerSources()
        refreshThermalAndLPM()
        refreshLid()
        refreshDisplays()
        suppressPosting = false
        if post, snapshot != before { postChange() }
    }

    private func refreshPowerSources() {
        let reading = PowerSourceReading.current()
        set(\.hasBattery, reading.hasBattery)
        set(\.batteryPercent, reading.percent)
        set(\.isOnAC, reading.isOnAC)
        set(\.isCharging, reading.isCharging)
    }

    private func refreshThermalAndLPM() {
        let info = ProcessInfo.processInfo
        set(\.thermalState, info.thermalState)
        set(\.isLowPowerMode, info.isLowPowerModeEnabled)
    }

    private func refreshDisplays() {
        set(\.externalDisplayCount, Self.countExternalDisplays())
    }

    private static func countExternalDisplays() -> Int {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return 0 }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    // MARK: Change tracking

    @ObservationIgnored private var suppressPosting = false

    private struct Snapshot: Equatable {
        var hasBattery: Bool, percent: Int?, isOnAC: Bool, isCharging: Bool
        var thermal: ProcessInfo.ThermalState, lpm: Bool, hasLid: Bool, lidClosed: Bool, ext: Int
    }

    private var snapshot: Snapshot {
        Snapshot(hasBattery: hasBattery, percent: batteryPercent, isOnAC: isOnAC, isCharging: isCharging,
                 thermal: thermalState, lpm: isLowPowerMode, hasLid: hasLid, lidClosed: isLidClosed,
                 ext: externalDisplayCount)
    }

    /// Assigns only real changes (so @Observable doesn't churn SwiftUI) and posts once per change.
    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<PowerMonitor, T>, _ value: T) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
        if !suppressPosting { postChange() }
    }

    private func postChange() {
        NotificationCenter.default.post(name: .insomniaPowerDidChange, object: self)
    }
}

/// One IOPS read. Separate from the monitor so the parsing is easy to follow (and to test with a fixture).
struct PowerSourceReading: Equatable, Sendable {
    var hasBattery: Bool
    var percent: Int?
    var isOnAC: Bool
    var isCharging: Bool

    static let desktop = PowerSourceReading(hasBattery: false, percent: nil, isOnAC: true, isCharging: false)

    static func current() -> PowerSourceReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .desktop }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let list = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let descriptions: [[String: Any]] = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return parse(providingType: providing, descriptions: descriptions)
    }

    /// Keys are the IOPSKeys.h string values (kIOPSTypeKey, kIOPSInternalBatteryType, …).
    static func parse(providingType: String?, descriptions: [[String: Any]]) -> PowerSourceReading {
        let battery = descriptions.first {
            ($0["Type"] as? String) == "InternalBattery" && (($0["Is Present"] as? Bool) ?? true)
        }
        guard let battery else { return .desktop }

        var percent: Int?
        if let current = battery["Current Capacity"] as? Int, let max = battery["Max Capacity"] as? Int, max > 0 {
            percent = Swift.min(100, Swift.max(0, Int((Double(current) / Double(max) * 100).rounded())))
        }
        // "AC Power" / "Battery Power" / "UPS Power". Prefer the system-wide providing type; fall back to the battery's state.
        let state = providingType ?? (battery["Power Source State"] as? String)
        let onAC = state.map { $0 != "Battery Power" } ?? true
        let charging = (battery["Is Charging"] as? Bool) ?? false
        return PowerSourceReading(hasBattery: true, percent: percent, isOnAC: onAC, isCharging: charging)
    }
}
