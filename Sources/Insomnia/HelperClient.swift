import AppKit
import Foundation
import InsomniaShared
import os
import ServiceManagement

/// Whether lid mode can be used from this copy of the app.
enum LidSetup: Equatable, Sendable {
    /// Desktop Mac: no lid UI at all.
    case noLid
    /// Not the root-owned copy in /Applications that the installer package or `make install` puts there (e.g. build/).
    case notInApplications
    /// Ad-hoc / unsigned build: there is no helper requirement to pin.
    case unsigned
    /// The helper or its launchd plist is missing from the bundle.
    case missingFiles
    case notRegistered
    /// Registered; waiting for System Settings ▸ General ▸ Login Items & Extensions.
    case needsApproval
    case ready
}

/// What one XPC `status()` call returned.
struct HelperAnswer: Equatable, Sendable {
    var version: String
    var cdhash: String
    var sleepDisabled: Bool
    var ownsFlag: Bool
}

/// The app's side of the root helper (unchanged `InsomniaHelper`), plus the unprivileged system calls lid mode needs.
/// Everything here may block (SMAppService, signatures, pmset), so it is called off the main actor.
protocol HelperClienting: Sendable {
    func setup(hasLid: Bool) async -> LidSetup
    /// register() (a throw that leaves `.requiresApproval` is the normal path). Returns the new setup, or an error.
    func install() async -> (setup: LidSetup, error: String?)
    /// Re-registers a changed helper (only call while not engaged). Returns the newly registered cdhash, if it did.
    func upgradeIfNeeded(savedCDHash: String?) async -> String?
    func bundledCDHash() async -> String?
    /// A new session. `onLost` fires once if the connection drops while engaged. Returns a `HelperResult` raw value,
    /// or -1 if the helper didn't answer (the connection is then invalidated: the helper resets on invalidation).
    func engage(onLost: @escaping @Sendable () -> Void) async -> Int32
    func release() async -> Int32
    /// Drops the session's connection without asking: the helper resets the flag when it sees the invalidation.
    func abandon() async
    func heartbeat() async -> Int32
    func query() async -> HelperAnswer?
    /// IOPMrootDomain SleepDisabled; nil if unreadable.
    func flag() async -> Bool?
    /// Read now: the Mac is shut in, with no external display at all or no input for PowerState.unattendedAfter
    /// (PowerState.isUnattended). Every follow-up `sleepnow` asks this first; a cached lid state can be stale.
    func isUnattendedNow() async -> Bool
    /// `/usr/bin/pmset sleepnow` / `displaysleepnow` (no root needed).
    func pmset(_ verb: String) async
    /// Admin prompt running `pmset -a disablesleep 0`. true on success.
    func resetWithPassword() async -> Bool
}

final class HelperClient: HelperClienting {
    private struct Session {
        var connection: NSXPCConnection?
        var onLost: (@Sendable () -> Void)?
    }

    private let session = OSAllocatedUnfairLock(uncheckedState: Session())
    /// The Team ID from our own signature, read once (off the main thread). Empty string = unsigned.
    private let team = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let bundleURL: URL
    private let log = Logger(subsystem: "com.gdeml.Insomnia", category: "helper")

    init(bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL
    }

    private var service: SMAppService { SMAppService.daemon(plistName: HelperInfo.plistName) }
    private var helperURL: URL { bundleURL.appendingPathComponent(HelperInfo.bundledHelperPath) }
    private var plistURL: URL { bundleURL.appendingPathComponent(HelperInfo.bundledPlistPath) }

    private func teamID() -> String? {
        if let cached = team.withLock({ $0 }) { return cached.isEmpty ? nil : cached }
        let read = CodeSignature.currentTeamID() ?? ""
        team.withLock { $0 = read }
        return read.isEmpty ? nil : read
    }

    // MARK: Setup

    func setup(hasLid: Bool) async -> LidSetup {
        guard hasLid else { return .noLid }
        guard InstallLocation.check(bundle: bundleURL) == nil else { return .notInApplications }
        let fm = FileManager.default
        guard fm.fileExists(atPath: helperURL.path), fm.fileExists(atPath: plistURL.path) else { return .missingFiles }
        guard teamID() != nil else { return .unsigned }
        return Self.map(service.status)
    }

    /// Shown under the lid switch when registering the lid helper fails.
    static func registerError(code: Int) -> String { "Couldn't set up the lid helper (error \(code))." }

    static func map(_ status: SMAppService.Status) -> LidSetup {
        switch status {
        case .enabled: .ready
        case .requiresApproval: .needsApproval
        // A never-registered daemon reports .notFound on macOS 27, not .notRegistered.
        case .notRegistered, .notFound: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func install() async -> (setup: LidSetup, error: String?) {
        let current = await setup(hasLid: true)
        guard current == .notRegistered || current == .ready || current == .needsApproval else { return (current, nil) }
        let service = self.service
        do {
            try service.register()
        } catch {
            let status = service.status
            if status != .requiresApproval && status != .enabled {
                let ns = error as NSError
                log.error("register failed: \(ns.domain, privacy: .public) \(ns.code)")
                return (Self.map(status), Self.registerError(code: ns.code))
            }
        }
        return (Self.map(service.status), nil)
    }

    func upgradeIfNeeded(savedCDHash: String?) async -> String? {
        let service = self.service
        guard service.status == .enabled, let bundled = await bundledCDHash() else { return nil }
        // The running helper's own answer first; the saved value only if it doesn't answer. nil = unknown, not a mismatch.
        guard let running = await query()?.cdhash ?? savedCDHash,
              running.lowercased() != bundled.lowercased() else { return nil }
        log.notice("helper changed (\(running, privacy: .public) → \(bundled, privacy: .public)); re-registering")
        do { try await service.unregister() } catch {
            log.error("unregister before re-register failed: \(error.localizedDescription, privacy: .public)")
        }
        do { try service.register() } catch {
            log.notice("re-register: \(error.localizedDescription, privacy: .public)")
        }
        return bundled
    }

    func bundledCDHash() async -> String? { CodeSignature.cdhash(ofFileAt: helperURL) }

    // MARK: Session

    func engage(onLost: @escaping @Sendable () -> Void) async -> Int32 {
        guard let connection = makeConnection() else { return -1 }
        let id = ObjectIdentifier(connection)
        // Installed before the first message; they report a loss only for the session currently held.
        let lost: @Sendable () -> Void = { [session] in
            let (callback, dead) = session.withLockUnchecked { s -> ((@Sendable () -> Void)?, NSXPCConnection?) in
                guard let c = s.connection, ObjectIdentifier(c) == id else { return (nil, nil) }
                defer { s = Session() }
                return (s.onLost, s.connection)
            }
            dead?.invalidate()
            callback?()
        }
        connection.interruptionHandler = lost
        connection.invalidationHandler = lost
        connection.resume()
        let rc = await call(connection, timeout: 5, fallback: Int32(-1)) { helper, done in
            helper.engage { result, _ in done(result) }
        }
        if rc == HelperResult.ok.rawValue {
            let previous = session.withLockUnchecked { s -> NSXPCConnection? in
                defer { s = Session(connection: connection, onLost: onLost) }
                return s.connection
            }
            if let previous, previous !== connection { previous.invalidate() }
        } else {
            connection.invalidate()   // not engaged (or no answer): the helper drops whatever it may have added
        }
        return rc
    }

    func release() async -> Int32 {
        guard let connection = session.withLockUnchecked({ $0.connection }) else { return HelperResult.notEngaged.rawValue }
        let rc = await call(connection, timeout: 5, fallback: Int32(-1)) { helper, done in
            helper.release { result, _ in done(result) }
        }
        if rc == HelperResult.ok.rawValue || rc == HelperResult.notEngaged.rawValue {
            // Forget the session first, so invalidating it isn't reported as a loss.
            session.withLockUnchecked { s in if s.connection === connection { s = Session() } }
            connection.invalidate()
        }
        return rc
    }

    func abandon() async {
        let connection = session.withLockUnchecked { s -> NSXPCConnection? in
            defer { s = Session() }
            return s.connection
        }
        connection?.invalidate()
    }

    func heartbeat() async -> Int32 {
        guard let connection = session.withLockUnchecked({ $0.connection }) else { return HelperResult.notEngaged.rawValue }
        return await call(connection, timeout: 5, fallback: Int32(-1)) { helper, done in helper.heartbeat { done($0) } }
    }

    func query() async -> HelperAnswer? {
        guard let connection = makeConnection() else { return nil }
        connection.resume()
        defer { connection.invalidate() }
        return await call(connection, timeout: 2, fallback: nil as HelperAnswer?) { helper, done in
            helper.status { version, cdhash, sleepDisabled, ownsFlag in
                done(HelperAnswer(version: version, cdhash: cdhash, sleepDisabled: sleepDisabled, ownsFlag: ownsFlag))
            }
        }
    }

    // MARK: System

    func flag() async -> Bool? { RootDomain.sleepDisabled() }

    func isUnattendedNow() async -> Bool { Power.lidSnapshot().isUnattended(idleSeconds: Power.hidIdleSeconds()) }

    func pmset(_ verb: String) async {
        let r = Spawn.run("/usr/bin/pmset", [verb], timeout: 5)
        if !r.succeeded { log.error("pmset \(verb, privacy: .public) exited \(r.status)") }
    }

    func resetWithPassword() async -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges"
            + " with prompt \"Insomnia needs your password to turn sleep back on.\""
        let r = Spawn.run("/usr/bin/osascript", ["-e", script],
                          environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"], timeout: 600)
        return r.succeeded
    }

    // MARK: XPC plumbing

    /// `.privileged` Mach connection with the helper requirement set once, before resume() (the caller resumes).
    /// nil if unsigned or the requirement doesn't parse (the setter would raise an uncatchable exception).
    private func makeConnection() -> NSXPCConnection? {
        guard let teamID = teamID() else { return nil }
        let requirement = HelperInfo.helperRequirement(teamID: teamID)
        guard HelperInfo.isValidRequirement(requirement) else {
            log.fault("helper requirement doesn't parse; not connecting")
            return nil
        }
        let connection = NSXPCConnection(machServiceName: HelperInfo.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        return connection
    }

    /// One message; waits for exactly one of: the reply, the proxy error handler, or the timeout.
    private func call<T: Sendable>(_ connection: NSXPCConnection, timeout: TimeInterval, fallback: T,
                                   _ body: (HelperProtocol, @escaping @Sendable (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(fallback) }
            guard let helper = proxy as? HelperProtocol else {
                once.resume(fallback)
                return
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { once.resume(fallback) }
            body(helper) { once.resume($0) }
        }
    }
}

/// Resumes a continuation at most once (reply, error handler and timeout race).
final class ResumeOnce<T: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<T, Never>?>
    init(_ continuation: CheckedContinuation<T, Never>) { state = OSAllocatedUnfairLock(initialState: continuation) }
    func resume(_ value: T) {
        let c = state.withLock { c -> CheckedContinuation<T, Never>? in
            defer { c = nil }
            return c
        }
        c?.resume(returning: value)
    }
}
