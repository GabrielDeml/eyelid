import Foundation
import IOKit.pwr_mgt
import os

/// What the engine needs from the assertion layer. `PowerAssertions` is the real one; tests inject a fake so they
/// never create IOPM assertions on the machine running them.
@MainActor
protocol AssertionApplying: AnyObject {
    func update(system: Bool, display: Bool, reason: String)
    func releaseAll()
    var hasSystemAssertion: Bool { get }
    var hasDisplayAssertion: Bool { get }
}

/// Thin IOKit wrapper (docs/CLOSED_LID.md §1). Idempotent: creates/releases only when the desired set changes, and
/// re-creates an assertion when its reason string changes so `pmset -g assertions` stays accurate.
@MainActor
final class PowerAssertions: AssertionApplying {
    /// `kIOPMAssertionTypePreventUserIdleSystemSleep` / `…DisplaySleep`, spelled out (the SDK macros are CFSTR()).
    private static let systemType = "PreventUserIdleSystemSleep"
    private static let displayType = "PreventUserIdleDisplaySleep"
    private static let log = Logger(subsystem: "com.gdeml.Insomnia", category: "assertions")

    private struct Held {
        let id: IOPMAssertionID
        let reason: String
    }

    private var system: Held?
    private var display: Held?

    init() {}

    var hasSystemAssertion: Bool { system != nil }
    var hasDisplayAssertion: Bool { display != nil }

    /// system → PreventUserIdleSystemSleep; display → PreventUserIdleDisplaySleep.
    /// `reason` shows in `pmset -g assertions`, e.g. "Insomnia: 1h timer" / "Insomnia: watching ffmpeg".
    func update(system wantSystem: Bool, display wantDisplay: Bool, reason: String) {
        system = Self.reconcile(system, want: wantSystem, type: Self.systemType, reason: reason)
        display = Self.reconcile(display, want: wantDisplay, type: Self.displayType, reason: reason)
    }

    func releaseAll() {
        update(system: false, display: false, reason: "")
    }

    private static func reconcile(_ current: Held?, want: Bool, type: String, reason: String) -> Held? {
        if let current, want, current.reason == reason { return current }   // nothing changed
        // Create the replacement before releasing the old one so there is never a gap in coverage.
        let replacement = want ? create(type: type, reason: reason) : nil
        if want, replacement == nil, let current { return current }   // keep coverage (stale reason) over a gap
        if let current { release(current.id, type: type) }
        return replacement
    }

    private static func create(type: String, reason: String) -> Held? {
        var id = IOPMAssertionID(0)
        let kr = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             reason as CFString, &id)
        guard kr == kIOReturnSuccess else {
            log.error("IOPMAssertionCreateWithName(\(type, privacy: .public)) failed: \(kr)")
            return nil
        }
        log.debug("created \(type, privacy: .public) #\(id): \(reason, privacy: .public)")
        return Held(id: id, reason: reason)
    }

    private static func release(_ id: IOPMAssertionID, type: String) {
        let kr = IOPMAssertionRelease(id)
        if kr != kIOReturnSuccess { log.error("IOPMAssertionRelease(\(type, privacy: .public) #\(id)) failed: \(kr)") }
    }
}
