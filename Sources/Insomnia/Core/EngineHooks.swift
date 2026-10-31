import Foundation

// MARK: - The engine's dependencies
//
// AwakeEngine treats every dependency below as optional, so tests run it with fakes (or none). AppDelegate assigns the
// real ones before `AwakeEngine.start()`:
//
//     AwakeEngine.shared.lidController = ClosedLidController.shared
//     AwakeEngine.shared.watchMonitor  = WatchMonitor.shared
//     AwakeEngine.shared.eventLog      = EventLog.shared
//     AwakeEngine.shared.narrator      = Narrator.shared
//     AwakeEngine.shared.notifier      = Notifier.self
//     AwakeEngine.shared.stats         = Stats.shared
//
// ControlServer needs no hook: it calls `beginClientHold` / `endClientHold` / `activate(_:source:.cli,options:)`.
// The requirement names match the ARCHITECTURE.md contracts, so conformance is a one-line `extension X: P {}`.

/// M2 — `ClosedLidController` conforms. The engine publishes the desired flag and merges the controller's status with
/// needsSetup / suspended(guard) / latched (`Policy.lidStatus`).
@MainActor
protocol LidControlling: AnyObject {
    var backendKind: PrivilegeBackendKind? { get }
    var helper: HelperStatus { get }
    /// .off / .engaging / .engaged / .error / .stuck (guards, latch, needsSetup are applied by the engine).
    var status: LidStatus { get }
    /// Set on lid open after ≥ 5 min engaged-closed. The engine shows each distinct report once.
    var reopenReport: ReopenReport? { get }
    /// The engine sets this when it attaches. The controller must call it (on the main actor, never synchronously
    /// from inside `setDesired`) whenever `status`, `helper` or `reopenReport` changes, so the engine re-evaluates.
    var onChange: (@MainActor () -> Void)? { get set }

    func start() async
    func recoverIfNeeded() async -> Bool
    func refreshHelper() async
    /// Idempotent; the engine calls it only when the desired value changes.
    func setDesired(_ engaged: Bool)
    /// From `.error`: try again if lid mode is still wanted. The engine calls it on a user action while lid mode is
    /// wanted and the controller is in an alarming error (CLOSED_LID.md §7 "Retry or user action → .engaging").
    func retry()
    func releaseForQuit(timeout: Duration) async
    /// Release the flag (await), then `/usr/bin/pmset sleepnow`.
    func sleepNow() async
}

/// M3 — `WatchMonitor` conforms. The engine re-evaluates on `.insomniaRulesDidChange`.
@MainActor
protocol WatchMonitoring: AnyObject {
    /// Enabled rules whose condition is currently true (including ones the engine has paused).
    var satisfiedRules: [Rule] { get }
    /// Calls `onExit` once, on the main actor, when the target has been gone for 5 s.
    func watch(_ target: WatchTarget, onExit: @escaping @MainActor () -> Void) -> UUID
    func cancelWatch(_ id: UUID)
}

/// M3 — `EventLog` conforms.
@MainActor
protocol EventLogging: AnyObject {
    func log(_ kind: String, _ message: String)
}

/// M4 — `Narrator` conforms (its `now:` default argument satisfies the requirement).
@MainActor
protocol Narrating: AnyObject {
    func line(_ m: Moment, _ p: Personality, now: Date) -> String?
    /// An earned date line to show instead of an `activated` / `idle` line, or nil (PRODUCT.md §4 rule 10).
    func dateLine(_ p: Personality, now: Date) -> String?
    func notification(_ id: NotificationID, _ p: Personality, context: [String: String]) -> (title: String, body: String)
}

extension Narrating {
    func dateLine(_ p: Personality, now: Date) -> String? { nil }
}

/// M4 — `Notifier` (a caseless enum with static methods) conforms; assign `Notifier.self`.
@MainActor
protocol NotificationPosting {
    static func post(_ id: NotificationID, title: String, body: String)
    static func clear(_ id: NotificationID)
}

/// M4 — `Stats` conforms.
@MainActor
protocol StatsRecording: AnyObject {
    func recordSessionStarted()
    func recordSessionEnded(duration: TimeInterval)
    /// Returns a newly crossed milestone (hours) or nil.
    func addAwakeTime(_ s: TimeInterval) -> Int?
    func addLidClosedTime(_ s: TimeInterval)
    func recordLidCloseSurvival()
    func awardPokeBadge()
}

// MARK: - Plain copy: the one headline and every notification's plain title and body

/// The engine's headline (`AwakeEngine.headline`, UX.md §8) and notification titles and plain bodies (UX.md §10).
/// Narrator draws personality bodies on top; without one (tests) these are posted as they are. No jokes here, ever.
enum FallbackCopy {
    static func notification(_ id: NotificationID, context: [String: String]) -> (title: String, body: String) {
        let floor = context["floor"] ?? "low"
        switch id {
        case .endingSoon:
            let minutes = context["minutes"].flatMap(Int.init) ?? 5
            return ("Insomnia: \(minutes) minute\(minutes == 1 ? "" : "s") left", "")
        case .ended: return ("Your Mac can sleep again", "")
        case .batteryFloor: return ("Lid mode off at \(floor)% battery", "Your Mac will sleep normally.")
        case .batteryStop: return ("Stopped keeping awake at \(floor)% battery", "Plug in to resume.")
        case .lidHeat: return ("Lid mode paused: Mac is hot", "")
        case .lidLPM: return ("Lid mode paused: Low Power Mode", "Lid mode resumes when Low Power Mode is off.")
        case .lidCap:
            let body = "Open the lid to reset the limit."
            if let acCap = context["acCap"] { return ("Lid mode paused after \(acCap) closed", body) }
            return ("Lid mode paused after \(context["cap"] ?? "the limit") closed on battery", body)
        case .lidError:
            return (context["overridden"] == "1" ? "Lid mode was turned off" : "Lid mode couldn't be applied",
                    "Your Mac will sleep normally.")
        case .lidStuck: return ("Lid mode is stuck on", "Your Mac won't sleep until it's reset.")
        case .foreignFlag:
            return ("Something else turned off sleep", "Another app or admin set it. Insomnia won't change it.")
        case .recovered: return ("Normal sleep restored", "")
        case .targetExited: return ("\(context["name"] ?? "It") finished", "")
        }
    }

    /// The one plain headline (UX.md §8), in every tier: the engine (`AwakeEngine.headline`: VoiceOver, the CLI,
    /// Why awake), the panel, status item and Dock (via `PlainCopy`) all say the same words.
    static func headline(status: AwakeStatus, lid: LidStatus, batteryFloor: Int? = nil) -> String {
        if lid == .stuck { return "Lid mode is stuck on" }
        if case .error(let e) = lid, e.alarms { return "Lid mode needs attention" }
        switch status {
        case .asleep: return "Sleep allowed"
        case .timed, .indefinite: return "Wide awake"
        case .watching(let target): return "Awake for \(shortName(target))"
        case .client(let label): return "Awake for \(label)"
        case .automatic(let conditions): return "Awake: " + (conditions.first?.phrase ?? "rule")
        case .suspended: return batteryFloor.map { "Paused: battery at \($0)%" } ?? "Paused: battery low"
        }
    }

    /// "ffmpeg", without the pid (the subline shows "ffmpeg (4411)").
    static func shortName(_ t: WatchTarget) -> String {
        switch t {
        case .app(_, let name), .process(let name), .pid(_, let name): return name
        }
    }
}
