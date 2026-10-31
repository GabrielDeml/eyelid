import Foundation
import InsomniaShared
import os
import ServiceManagement

/// Primary backend for signed builds: the root `InsomniaHelper` daemon (SMAppService.daemon) over XPC, pinned both
/// ways by code-signing requirement. docs/CLOSED_LID.md §2.2–§2.6.
final class HelperBackend: PrivilegedBackend {
    let kind = PrivilegeBackendKind.helper
    let teamID: String

    /// Settings.helperRegisteredCDHash, behind closures so the backend never touches the main actor itself.
    private let savedCDHash: @Sendable () async -> String?
    private let saveCDHash: @Sendable (String?) async -> Void
    private let bundleURL: URL

    /// The engaged session's connection (one per engagement) and its lost-callback. Lock-protected: `abandon()` can
    /// arrive from the quit path while the reconciler is busy.
    private struct Session {
        var connection: NSXPCConnection?
        var onLost: (@Sendable () -> Void)?
    }
    private let session = OSAllocatedUnfairLock(uncheckedState: Session())
    private let log = Logger(subsystem: "com.gdeml.Insomnia", category: "helper")

    init(teamID: String,
         bundleURL: URL = Bundle.main.bundleURL,
         savedCDHash: @escaping @Sendable () async -> String? = { await MainActor.run { Settings.shared.helperRegisteredCDHash } },
         saveCDHash: @escaping @Sendable (String?) async -> Void = { v in await MainActor.run { Settings.shared.helperRegisteredCDHash = v } }) {
        self.teamID = teamID
        self.bundleURL = bundleURL
        self.savedCDHash = savedCDHash
        self.saveCDHash = saveCDHash
    }

    private var service: SMAppService { SMAppService.daemon(plistName: HelperInfo.plistName) }
    private var bundledHelperURL: URL { bundleURL.appendingPathComponent(HelperInfo.bundledHelperPath) }
    private var bundledPlistURL: URL { bundleURL.appendingPathComponent(HelperInfo.bundledPlistPath) }
    private var filesPresent: Bool {
        FileManager.default.fileExists(atPath: bundledHelperURL.path) && FileManager.default.fileExists(atPath: bundledPlistURL.path)
    }
    private var locationSafe: Bool { InstallLocation.check(bundle: bundleURL) == nil }

    // MARK: Status (§2.6)

    /// What one XPC `status()` call returned.
    struct Answer: Equatable, Sendable {
        var version: String
        var cdhash: String
        var sleepDisabled: Bool
        var ownsFlag: Bool
    }

    func status() async -> HelperStatus {
        let sm = service.status   // one blocking read per check
        let files = filesPresent
        let safe = files && locationSafe
        var answer: Answer?
        var bundled: String?
        var saved: String?
        if sm == .enabled && safe {
            answer = await queryStatus()
            bundled = CodeSignature.cdhash(ofFileAt: bundledHelperURL)
            if answer == nil { saved = await savedCDHash() }
        }
        return Self.mapStatus(service: sm, filesPresent: files, locationSafe: safe, answer: answer,
                              bundledCDHash: bundled, savedCDHash: saved)
    }

    /// Pure mapping of CLOSED_LID.md §2.6's table (unit-tested).
    static func mapStatus(service: SMAppService.Status, filesPresent: Bool, locationSafe: Bool, answer: Answer?,
                          bundledCDHash: String?, savedCDHash: String?) -> HelperStatus {
        switch service {
        case .requiresApproval:
            return .requiresApproval
        case .enabled:
            guard filesPresent else { return .notFound }
            guard locationSafe else { return .unsafeLocation }
            let bundled = bundledCDHash ?? ""
            if let answer {
                return answer.cdhash.lowercased() == bundled.lowercased() && !bundled.isEmpty
                    ? .installed
                    : .versionMismatch(running: answer.cdhash, bundled: bundled)
            }
            if let saved = savedCDHash, !bundled.isEmpty, saved.lowercased() != bundled.lowercased() {
                return .versionMismatch(running: saved, bundled: bundled)
            }
            return .unreachable
        case .notRegistered, .notFound:
            guard filesPresent else { return .notFound }
            return locationSafe ? .notInstalled : .unsafeLocation
        @unknown default:
            return .unreachable
        }
    }

    // MARK: Install / uninstall (§2.6)

    func install() async throws(LidSetupError) -> HelperStatus {
        guard filesPresent else {
            throw .registrationFailed(code: -1, detail: "The helper or its launchd plist is missing from the app bundle.")
        }
        guard locationSafe else { throw .unsafeLocation }
        let service = self.service
        if service.status == .enabled {
            // Upgrade or repair: a changed (or unanswering) helper is re-registered so launchd runs the new binary.
            do { try await service.unregister() } catch {
                log.error("unregister before re-register failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try service.register()
        } catch {
            // For a daemon, register() commonly "fails" with needs-approval: that is the expected path.
            if service.status != .requiresApproval && service.status != .enabled {
                let ns = error as NSError
                log.error("register failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
                throw .registrationFailed(code: ns.code, detail: "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
            }
        }
        await saveCDHash(CodeSignature.cdhash(ofFileAt: bundledHelperURL))
        return await status()
    }

    func uninstall(resetFlag: Bool) async throws(LidSetupError) {
        _ = resetFlag   // the helper resets its own flag on SIGTERM; it knows ownership
        await abandonSilently()
        let service = self.service
        do {
            try await service.unregister()
        } catch {
            log.error("unregister failed: \(error.localizedDescription, privacy: .public)")
        }
        let after = service.status
        guard after == .notRegistered || after == .notFound else { throw .unregisterIncomplete }
        await saveCDHash(nil)
    }

    // MARK: Session (§2.4)

    func engage(onLost: @escaping @Sendable () -> Void) async -> Int32 {
        guard let connection = makeConnection() else { return -1 }
        // Install the handlers before the first message; they report a loss only while this session is engaged.
        let connectionID = ObjectIdentifier(connection)
        let lost: @Sendable () -> Void = { [session] in
            // Interrupted (helper crashed: its restart reset ran) or invalidated (helper stopped, or dropped us after
            // a heartbeat timeout). Either way the flag was reset by root: forget the session and report it once.
            let (callback, dead) = session.withLockUnchecked { s -> ((@Sendable () -> Void)?, NSXPCConnection?) in
                guard let c = s.connection, ObjectIdentifier(c) == connectionID else { return (nil, nil) }
                let result = (s.onLost, s.connection)
                s = Session()
                return result
            }
            dead?.invalidate()
            callback?()
        }
        connection.interruptionHandler = lost
        connection.invalidationHandler = lost
        connection.resume()

        let reply = await call(connection, timeout: 5, fallback: (Int32(-1), false)) { helper, done in
            helper.engage { result, sleepDisabled in done((result, sleepDisabled)) }
        }
        if reply.0 == HelperResult.ok.rawValue {
            let previous = session.withLockUnchecked { s -> NSXPCConnection? in
                let old = s.connection
                s = Session(connection: connection, onLost: onLost)
                return old
            }
            if let previous, previous !== connection { previous.invalidate() }
        } else {
            // Not engaged: drop this connection quietly (the helper drops anything it may have added).
            connection.invalidate()
        }
        return reply.0
    }

    func release() async -> Int32 {
        guard let connection = session.withLockUnchecked({ $0.connection }) else {
            return HelperResult.notEngaged.rawValue
        }
        let reply = await call(connection, timeout: 5, fallback: (Int32(-1), true)) { helper, done in
            helper.release { result, sleepDisabled in done((result, sleepDisabled)) }
        }
        let released = reply.0 == HelperResult.ok.rawValue || reply.0 == HelperResult.notEngaged.rawValue
        if released {
            // Disarm: forget the session first so invalidating it isn't reported as a loss.
            session.withLockUnchecked { s in if s.connection === connection { s = Session() } }
            connection.invalidate()
        }
        // On failure the session stays armed; the caller abandons it if the readback still says 1.
        return reply.0
    }

    func abandon() async {
        await abandonSilently()
    }

    private func abandonSilently() async {
        let connection = session.withLockUnchecked { s -> NSXPCConnection? in
            let c = s.connection
            s = Session()
            return c
        }
        connection?.invalidate()   // the helper sees the invalidation and resets if it was the last session
    }

    func heartbeat() async -> LidError? {
        guard let connection = session.withLockUnchecked({ $0.connection }) else { return .safetyNetLost }
        let result = await call(connection, timeout: 5, fallback: Int32(-1)) { helper, done in
            helper.heartbeat { done($0) }
        }
        switch result {
        case HelperResult.ok.rawValue: return nil
        case HelperResult.overridden.rawValue: return .overridden
        default: return .safetyNetLost
        }
    }

    func ownsFlag() async -> Bool {
        await queryStatus()?.ownsFlag ?? false
    }

    func resetWithPassword() async throws(LidSetupError) {
        try AdminScript.resetFlag()
    }

    // MARK: XPC plumbing

    /// One-shot status on its own short-lived connection (2 s).
    func queryStatus() async -> Answer? {
        guard let connection = makeConnection() else { return nil }
        connection.resume()
        defer { connection.invalidate() }
        return await call(connection, timeout: 2, fallback: nil as Answer?) { helper, done in
            helper.status { version, cdhash, sleepDisabled, ownsFlag in
                done(Answer(version: version, cdhash: cdhash, sleepDisabled: sleepDisabled, ownsFlag: ownsFlag))
            }
        }
    }

    /// `.privileged` Mach connection with the helper requirement set once, before resume() (the caller resumes).
    /// nil if the requirement doesn't parse (the setter would raise an uncatchable exception).
    private func makeConnection() -> NSXPCConnection? {
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

    /// Sends one message and waits for exactly one of: the reply, the proxy error handler, or the timeout.
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
