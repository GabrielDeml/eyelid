import AppKit
import Foundation
import InsomniaShared
import ServiceManagement

/// Headless helper maintenance (docs/CLOSED_LID.md §2.6, §9). Routed from main.swift before any NSApplication exists:
///
///     case "--helper-status":     exit(MainActor.assumeIsolated { HelperCommands.status() })
///     case "--unregister-helper": exit(MainActor.assumeIsolated { HelperCommands.unregister() })
///
/// Both act on the daemon bundled with *this* copy of the app (SMAppService resolves the plist inside Bundle.main),
/// so run them from /Applications/Insomnia.app/Contents/MacOS/Insomnia.
@MainActor
enum HelperCommands {
    /// `--helper-status`: prints the SMAppService status; exit 0 if registered (enabled or awaiting approval), 1 if
    /// not. scripts/build.sh uses the exit code to refuse an ad-hoc build over a registered helper (Decision 38).
    static func status() -> Int32 {
        let status = SMAppService.daemon(plistName: HelperInfo.plistName).status
        print(describe(status))
        return isRegistered(status) ? 0 : 1
    }

    /// `--unregister-helper`: asks a running GUI instance to quit (its Release runs) and waits up to 5 s, then
    /// unregister(), and confirms `.notRegistered` / `.notFound`. Exit 0 = nothing registered any more.
    static func unregister() -> Int32 {
        let service = SMAppService.daemon(plistName: HelperInfo.plistName)
        guard isRegistered(service.status) else {
            print("No lid-mode helper is registered.")
            forgetRegistration()
            return 0
        }

        quitRunningApp(timeout: 5)

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
            print("Removed the lid-mode helper (\(describe(after))).")
            return 0
        }
        printError("The helper is still registered (\(describe(after)))\(failure.map { ": \($0)" } ?? "").")
        printError("Switch Insomnia off in System Settings ▸ General ▸ Login Items & Extensions, then try again.")
        return 1
    }

    // MARK: Private

    static func isRegistered(_ s: SMAppService.Status) -> Bool { s == .enabled || s == .requiresApproval }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "not registered: lid mode isn't set up"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval: System Settings ▸ General ▸ Login Items & Extensions"
        case .notFound: return "not found: lid mode was never set up from this copy"
        @unknown default: return "unknown (\(s.rawValue))"
        }
    }

    /// Sends the quit Apple Event (applicationShouldTerminate releases lid mode first) and waits for the process.
    private static func quitRunningApp(timeout: TimeInterval) {
        let me = getpid()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: HelperInfo.appBundleID)
            .filter { $0.processIdentifier != me }
        guard !running.isEmpty else { return }
        print("Quitting Insomnia so it can release lid mode…")
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && running.contains(where: { kill($0.processIdentifier, 0) == 0 }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if running.contains(where: { kill($0.processIdentifier, 0) == 0 }) {
            printError("Insomnia didn't quit within \(Int(timeout)) s; removing the helper anyway (it resets its own flag on stop).")
        }
    }

    /// Same as ClosedLidController.uninstall's bookkeeping (CLOSED_LID.md §2.6 Remove step 4), written straight to
    /// the app's defaults domain because there's no Settings object in a headless run.
    private static func forgetRegistration() {
        guard Bundle.main.bundleIdentifier == HelperInfo.appBundleID else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "helperRegisteredCDHash")
        if defaults.bool(forKey: "closedLidMode") { defaults.set(false, forKey: "closedLidMode") }
    }

    private static func printError(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
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
