import Darwin
import Foundation
import EyelidShared

// EyelidHelper: the root launchd daemon behind lid mode (SMAppService.daemon). docs/DESIGN.md "Security".
//
// It does exactly one job: set SleepDisabled = 1 while a verified Eyelid.app session wants it, and put it back to 0
// whenever that stops being true (release, crash, hang, SIGTERM, restart, boot, 10% battery, heat), sleeping a shut-in
// Mac when nobody else can follow up (docs/DESIGN.md "Safety"). It never re-reads its
// own signature or trust settings after start-up, accepts no arguments from clients, and never exits on a failed
// safety check (KeepAlive { SuccessfulExit = false } would turn that into a respawn loop): it drops to reset-only mode.

signal(SIGPIPE, SIG_IGN)

/// Security framework reads log a runtime issue on the main thread: run them once on a background queue and wait.
final class OffMainResult<T>: @unchecked Sendable {
    var value: T?
}

func offMain<T>(fallback: T, _ work: @escaping @Sendable () -> T) -> T {
    let box = OffMainResult<T>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        box.value = work()
        done.signal()
    }
    done.wait()
    return box.value ?? fallback
}

// 1. Who are we? The kernel's cdhash for this process, compared with the file at our path, once, for life.
let me = offMain(fallback: .unreadable) { CodeSignature.readSelf() }
let daemon = HelperDaemon(selfInfo: me)
if me.cdhash != nil && !me.matchesDisk {
    // The binary was replaced since launch (an upgrade), or the file can't be read. Run the boot / restart reset first
    // (it only ever clears the flag), so even a persistent mismatch, respawned by launchd again and again, never
    // leaves a flag at 1 behind. Then exit non-zero: launchd starts the binary that is on disk now.
    daemon.resetBeforeSelfCheckExit()
    HelperLog.main.notice("the helper binary changed on disk since launch; exiting so launchd starts the new one")
    exit(75)
}

// 2. Boot / restart reset, SIGTERM handling and the battery backstop: in every mode.
daemon.startUp()

// 3. Serve only from a safe install with a well-formed client requirement that pins the installed app's code;
//    otherwise reset-only (docs/DESIGN.md "Security").
func serveRequirement(_ me: CodeSignature.SelfInfo) -> (requirement: String, app: String)? {
    guard let running = me.cdhash else {
        HelperLog.main.error("couldn't read our own code signature; reset-only mode")
        return nil
    }
    let bundle = HelperBundle.url()
    if let problem = InstallLocation.check(bundle: bundle) {
        HelperLog.main.error("unsafe install location (\(String(describing: problem), privacy: .public)); reset-only mode")
        return nil
    }
    guard let team = me.teamID, !team.isEmpty else {
        HelperLog.main.error("no Team ID in our signature; reset-only mode")
        return nil
    }
    // Read once, through descriptors, from the bundle this helper runs from: never re-read for the life of the process.
    guard let app = CodeSignature.installedAppCDHash(runningHelperCDHash: running) else {
        HelperLog.main.error("couldn't pin the installed app (unsafe item, or not the bundle we run from); reset-only mode")
        return nil
    }
    guard let requirement = HelperInfo.clientRequirement(teamID: team, appCDHash: app),
          HelperInfo.isValidRequirement(requirement) else {
        HelperLog.main.error("client requirement doesn't parse; reset-only mode")
        return nil
    }
    return (requirement, app)
}

let listener = NSXPCListener(machServiceName: HelperInfo.machServiceName)
let delegate = HelperListenerDelegate(daemon: daemon)
if let serving = offMain(fallback: nil, { [me] in serveRequirement(me) }) {
    // Set ONCE, before resume(): a peer that fails it is rejected before the delegate ever runs.
    listener.setConnectionCodeSigningRequirement(serving.requirement)
    listener.delegate = delegate
    listener.resume()
    HelperLog.main.notice("\(HelperInfo.label, privacy: .public) \(HelperInfo.version, privacy: .public) serving (cdhash \(me.cdhash ?? "?", privacy: .public), team \(me.teamID ?? "?", privacy: .public), app \(serving.app, privacy: .public))")
} else {
    HelperLog.main.notice("\(HelperInfo.label, privacy: .public) \(HelperInfo.version, privacy: .public) running reset-only")
}

// The main run loop carries the IOPS notification source; dispatch queues carry XPC, timers and signals.
withExtendedLifetime((listener, delegate, daemon)) {
    RunLoop.main.run()
}
