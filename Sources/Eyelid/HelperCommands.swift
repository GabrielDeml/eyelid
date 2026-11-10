import AppKit
import Foundation
import EyelidShared
import ServiceManagement

/// Headless lid helper maintenance (docs/DESIGN.md, LidController). Routed from main.swift before any NSApplication exists:
///
///     case "--helper-status":     exit(MainActor.assumeIsolated { HelperCommands.status() })
///     case "--unregister-helper": exit(MainActor.assumeIsolated { HelperCommands.unregister() })
///
/// Both act on the daemon bundled with *this* copy of the app (SMAppService resolves the plist inside Bundle.main),
/// so run them from /Applications/Eyelid.app/Contents/MacOS/Eyelid.
@MainActor
enum HelperCommands {
    /// `--helper-status`: prints the SMAppService status and, if registered, whether the helper answers this copy over
    /// XPC (it answers only the installed app it pinned: docs/DESIGN.md "Security"). Exit 0 if registered (enabled or
    /// awaiting approval), 1 if not; the XPC answer never changes the exit code.
    static func status() -> Int32 {
        let status = SMAppService.daemon(plistName: HelperInfo.plistName).status
        print(describe(status))
        if status == .requiresApproval { printError("Approve it in System Settings > General > Login Items & Extensions.") }
        if status == .enabled {
            if let answer = wait({ await HelperClient().query() }) {
                print("helper answered: version \(answer.version), cdhash \(answer.cdhash), sleep disabled: \(answer.sleepDisabled ? "yes" : "no")")
            } else {
                print("helper didn't answer (not running, or this isn't the installed copy it trusts)")
            }
        }
        return isRegistered(status) ? 0 : 1
    }

    /// Runs `work` off the main thread and blocks until it finishes. Headless only: the XPC replies and the call's
    /// timeout arrive on other queues, so nothing here needs the main thread.
    private static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T?) -> T? {
        let box = Waiter<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.set(await work())
            done.signal()
        }
        done.wait()
        return box.value
    }

    /// `--unregister-helper`: asks a running GUI instance to quit (its Release runs) and waits up to 5 s, then
    /// unregister(), and confirms `.notRegistered` / `.notFound`. Exit 0 = nothing registered any more. The quit comes
    /// first even when no helper is registered: a sudoers (unsigned) setup must release before its rule is removed.
    static func unregister() -> Int32 {
        quitRunningApp(timeout: 5)

        let service = SMAppService.daemon(plistName: HelperInfo.plistName)
        guard isRegistered(service.status) else {
            print("No lid helper is registered.")
            forgetRegistration()
            return 0
        }

        var failure: String?
        let done = Box()
        service.unregister { error in
            if let error { done.set("\((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)") }
            done.finish()
        }
        let deadline = Date().addingTimeInterval(15)
        while !done.isFinished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        failure = done.message

        let after = service.status
        if after == .notRegistered || after == .notFound {
            forgetRegistration()
            print("Removed the lid helper (\(describe(after))).")
            return 0
        }
        printError("The lid helper is still registered (\(describe(after)))\(failure.map { ": \($0)" } ?? "").")
        printError("In System Settings > General > Login Items & Extensions, turn off Eyelid under Allow in the Background, then try again.")
        return 1
    }

    // MARK: Private

    static func isRegistered(_ s: SMAppService.Status) -> Bool { s == .enabled || s == .requiresApproval }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "waiting for approval"
        case .notFound: return "not found"
        @unknown default: return "unknown (\(s.rawValue))"
        }
    }

    /// Sends the quit Apple Event (applicationShouldTerminate releases lid mode first) and waits for the process.
    private static func quitRunningApp(timeout: TimeInterval) {
        let me = getpid()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: HelperInfo.appBundleID)
            .filter { $0.processIdentifier != me }
        guard !running.isEmpty else { return }
        print("Quitting Eyelid…")
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && running.contains(where: { kill($0.processIdentifier, 0) == 0 }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if running.contains(where: { kill($0.processIdentifier, 0) == 0 }) {
            printError("Eyelid didn't quit within \(Int(timeout)) seconds. Unregistering the lid helper anyway; it turns sleep back on when it stops.")
        }
    }

    /// Clears what the app remembers about the registration, written straight to the app's defaults domain because
    /// there's no Preferences object in a headless run.
    private static func forgetRegistration() {
        guard Bundle.main.bundleIdentifier == HelperInfo.appBundleID else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "helperRegisteredCDHash")
        if defaults.bool(forKey: "closedLidMode") { defaults.set(false, forKey: "closedLidMode") }
    }

    private static func printError(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    private final class Waiter<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: T?
        func set(_ v: T?) { lock.lock(); result = v; lock.unlock() }
        var value: T? { lock.lock(); defer { lock.unlock() }; return result }
    }

    /// Completion state shared with SMAppService's callback queue.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var text: String?
        func set(_ m: String) { lock.lock(); text = m; lock.unlock() }
        func finish() { lock.lock(); finished = true; lock.unlock() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        var message: String? { lock.lock(); defer { lock.unlock() }; return text }
    }
}
