# Insomnia: Architecture & Module Contracts

Insomnia is a native macOS (14+) **menu bar app with an optional live Dock tile** that keeps the Mac awake. It works like Caffeine, with more control: closed-lid mode, babysitting a process, rules, a CLI, and a personality. The mascot is a pair of eyes: **open** while the Mac is held awake, **closed with a "z"** when sleep is allowed.

Read these first. They are the product and UX source of truth, and this file implements them:

| Doc | Covers |
|---|---|
| `docs/PRODUCT.md` | Principles, tiers, non-goals, voice, naming |
| `docs/UX.md` | Every surface, states, copy, accessibility |
| `docs/CLOSED_LID.md` | Privilege model, install script, watchdog, safety daemon, guards, lid state machine, release blockers |

**The one model:** every reason to stay awake is a **Hold**. **Guards** (safety) cap what holds can do. The engine derives one **`AwakeStatus`** and one **`LidStatus`**, plus an `EyeMood`. Every surface renders from these three values: menu bar, panel, Dock, VoiceOver, CLI and notifications.

```
 Panel / menu bar / hotkey / Dock / URL / CLI ──► AwakeEngine ◄── WatchMonitor (rules, babysit targets)
                                                    │   ▲
                         Policy.evaluate (pure) ◄───┘   └── PowerMonitor (battery, AC, thermal, LPM, lid, displays)
                                │
          ┌─────────────────────┼─────────────────────────┐
   PowerAssertions        ClosedLidController         Narrator / Notifier / Stats
   (IOPM assertions)      (sudo -n pmset, watchdog)   (copy, notifications, milestones)
```

## Build model

- **Package:** SwiftPM, `swift-tools-version:6.0`, **Swift 6 language mode**, a single `executableTarget` named `Insomnia`, macOS 14 minimum. Built on Xcode 27 / Swift 6.4 / arm64.
- **No Xcode project, no app extensions, no third-party dependencies.**
- **Frameworks:** AppKit, SwiftUI, IOKit, Carbon (hotkey), ServiceManagement (launch at login), UserNotifications.
- **`scripts/build.sh`:**
  - runs `swift build -c release`;
  - assembles `build/Insomnia.app` (`Contents/MacOS/Insomnia`, and `Contents/Info.plist` from `Resources/Info.plist`);
  - generates `AppIcon.icns` by running the built binary with `--export-icon <dir>.iconset`, then `iconutil -c icns`;
  - signs ad hoc with `codesign --force --sign - --options runtime --timestamp=none`.
- **`Makefile`:** `make` (build the app), `make run`, `make install` (copies to `/Applications`), `make clean`.
- **Identifiers:**
  - bundle id `com.gdeml.Insomnia`
  - URL scheme `insomnia://`
  - safety daemon label `com.gdeml.insomnia.safety`; sudoers file `/etc/sudoers.d/zz_insomnia`
- **`LSUIElement = YES`.** The Dock icon is toggled at runtime with the activation policy.
- **No SwiftPM resources.** `Bundle.module` breaks in a hand-assembled `.app`, so all copy and art lives in Swift source, and icons are drawn in code.
- **Concurrency:**
  - UI and engine code is `@MainActor`.
  - Privileged work and **every child-process spawn** (sudo, pmset, osascript, watchdog) run on `actor LidReconciler`, so no fork can inherit the watchdog pipe. Results hop back to the main actor.
  - `main.swift` starts with `signal(SIGPIPE, SIG_IGN)`; sockets also set `SO_NOSIGPIPE` and the watchdog pipe `F_SETNOSIGPIPE`.
  - C callbacks (IOKit, IOPS, Carbon) re-enter with `MainActor.assumeIsolated { }`. Use this **not** `Task { }`, so events stay ordered. The callbacks are registered on the main run loop.
- **Tests (optional, encouraged):** a `Tests/InsomniaTests` target using `@testable import Insomnia` for `Policy`, `Narrator`, `URLCommand` and `ControlProtocol` parsing. These are pure, so they need no AppKit runtime.

## Shared files (WRITTEN; code against them, don't change signatures without updating the docs)

| File | Contents |
|---|---|
| `Sources/Insomnia/Core/Models.swift` | `AwakeDuration` (presets 30m/1h/2h/4h/8h/∞, `nextOccurrence`), `SessionSource`, `WatchTarget`, `AwakeOptions`, `HoldOwner`, `Hold`, `RuleCondition`, `Rule`, `GuardReason`, `HelperStatus`, `LidError`, `LidSetupError`, `LidStatus`, `AwakeStatus`, `EyeMood(status:lid:)`, `DeactivationReason`, `Moment`, `Personality`, `ClickAction`, `MenuBarTimerStyle`, `SettingsTab`, `Notification.Name.insomnia*`, `AppRouter`, `TimeFormat` |
| `Sources/Insomnia/Core/Settings.swift` | `Settings.shared`: `@Observable`, backed by UserDefaults, posts `.insomniaSettingsDidChange` with `userInfo["key"]` = the UserDefaults key. Clamps the battery floor to 10–50 and snaps the lid cap to 30/60/120/240/480 in setters (no `didSet` recursion). |

Everything is `@MainActor` unless noted. SwiftUI observes `@Observable` objects directly. AppKit controllers observe the `Notification.Name` events.

---

## Core

### `Core/RootDomain.swift`: IORegistry reader (no privileges)
```swift
enum RootDomain {
    /// IOPMrootDomain "SleepDisabled". nil if unreadable.
    static func sleepDisabled() -> Bool?
    /// IOPMrootDomain kAppleClamshellStateKey ("AppleClamshellState"); true = lid closed. nil on desktops.
    static func clamshellClosed() -> Bool?
    static func clamshellCausesSleep() -> Bool?
    /// IOServiceAddInterestNotification(kIOGeneralInterest) → message 0xE003_4100 (kIOPMMessageClamshellStateChange is a
    /// function-like macro Swift can't import). bits = UInt(bitPattern: messageArgument); closed = bits & kClamshellStateBit.
    @MainActor static func observeClamshell(_ handler: @escaping @MainActor (_ closed: Bool, _ causesSleep: Bool) -> Void) -> AnyObject  // token; release to stop
}
```
Service lookup: `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))`. Release every IOKit object.

### `Core/PowerAssertions.swift`
```swift
/// Thin IOKit wrapper. Idempotent: creates/releases only when the desired set changes.
@MainActor final class PowerAssertions {
    init()
    /// system → kIOPMAssertionTypePreventUserIdleSystemSleep; display → kIOPMAssertionTypePreventUserIdleDisplaySleep.
    /// `reason` shows in `pmset -g assertions`, e.g. "Insomnia: 1h timer" / "Insomnia: watching ffmpeg".
    func update(system: Bool, display: Bool, reason: String)
    func releaseAll()
    var hasSystemAssertion: Bool { get }
    var hasDisplayAssertion: Bool { get }
}
```
There is no `declareUserActivity`; "Look busy" is cut (see the Decisions log). When the reason string changes, re-create the assertion so `pmset -g assertions` stays accurate.

### `Core/PowerMonitor.swift`
```swift
@MainActor @Observable final class PowerMonitor {
    static let shared: PowerMonitor
    private(set) var hasBattery: Bool
    private(set) var batteryPercent: Int?        // nil when no battery
    private(set) var isOnAC: Bool                 // true on desktops
    private(set) var isCharging: Bool
    private(set) var thermalState: ProcessInfo.ThermalState
    private(set) var isLowPowerMode: Bool
    private(set) var hasLid: Bool                 // AppleClamshellState present; false on desktops → no lid UI at all
    private(set) var isLidClosed: Bool            // RootDomain; false on desktops
    private(set) var externalDisplayCount: Int    // online displays where !CGDisplayIsBuiltin
    func start()                                  // idempotent
}
```
| Value | Source | Refreshed by |
|---|---|---|
| Battery, AC, charging | `IOPSCopyPowerSourcesInfo` / `List` / `GetPowerSourceDescription` | `IOPSNotificationCreateRunLoopSource` |
| Thermal state | `ProcessInfo` | `thermalStateDidChangeNotification` |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` | `.NSProcessInfoPowerStateDidChange` |
| Lid | `RootDomain.observeClamshell` | Clamshell notifications; also re-read on `NSWorkspace.didWakeNotification` / `screensDidWakeNotification`. **No 2 s poll.** `ClosedLidController` adds a 5 s poll only while engaged. |
| External displays | Online display list | `NSApplication.didChangeScreenParametersNotification` (while engaged and closed, dropping to 0 triggers `displaysleepnow`) |

Post `.insomniaPowerDidChange` only when a value actually changes.

### `Core/Privileged/PrivilegedBackend.swift`, `SudoersBackend.swift`, `Watchdog.swift`
```swift
protocol PrivilegedBackend: Sendable {
    func status() async -> HelperStatus
    func install() async throws(LidSetupError)                 // one admin prompt (docs/CLOSED_LID.md §2.3)
    func uninstall(resetFlag: Bool) async throws(LidSetupError) // one admin prompt (§2.5); resetFlag = marker exists
    /// Runs `sudo -n /usr/bin/pmset -a disablesleep 0|1` (5 s timeout). Returns exit status.
    func setSleepDisabled(_ on: Bool) async -> Int32
    /// .stuck recovery: osascript admin prompt running `pmset -a disablesleep 0`.
    func resetWithPassword() async throws(LidSetupError)
}
struct SudoersBackend: PrivilegedBackend { init(userName: String = NSUserName()) }   // validates ^[A-Za-z0-9._][A-Za-z0-9._-]*$

/// Watchdog (docs/CLOSED_LID.md §4.1): /bin/bash, pipe EOF + 90 s heartbeat timeout + TERM/HUP/INT trap. Owned by LidReconciler.
final class Watchdog {
    /// posix_spawn with POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT; stdin = pipe; F_SETNOSIGPIPE on the write end.
    /// `onExit` fires (via DispatchSource process source) if the child exits without a disarm.
    static func arm(onExit: @escaping @Sendable () -> Void) throws -> Watchdog
    func heartbeat() -> Bool   // write "h\n"; false on EPIPE (watchdog gone)
    func disarm()              // write "disarm\n" (EPIPE = already gone), close, reap
    func abandon()             // close WITHOUT disarm → watchdog resets the flag (retry path)
}
```
- The install, uninstall and reset scripts are **inline strings passed to `/usr/bin/osascript -e`**, escaped as an AppleScript literal (`\` → `\\`, then `"` → `\"`, then newline → `\n`).
- **Result mapping:** osascript exits 1 for every failure; parse the trailing `(N)` from stderr (`CLOSED_LID.md` §2.3).
- **`status()`:** rule-file + real no-op probe + daemon file + `SMAppService.statusForLegacyPlist(at:)` (§2.4).

### `Core/ClosedLidController.swift`
```swift
@MainActor @Observable final class ClosedLidController {
    static let shared: ClosedLidController
    init(backend: PrivilegedBackend = SudoersBackend())
    private(set) var helper: HelperStatus
    private(set) var status: LidStatus             // .off / .engaging / .engaged / .error / .stuck (guards, latch, needsSetup applied by the engine)
    private(set) var foreignSleepDisabled: Bool     // SleepDisabled==1 at launch without our marker
    private(set) var reopenReport: ReopenReport?    // set on lid open after ≥5 min engaged-closed; engine consumes it

    func refreshHelper() async
    func install() async throws(LidSetupError)
    func uninstall() async throws(LidSetupError)    // Release → disarm → script → delete marker → Settings.closedLidMode = false
    /// Engine publishes the desired flag; reconciler converges (serial, coalescing). Idempotent.
    func setDesired(_ engaged: Bool)
    func retry()                                    // from .error
    func resetWithPassword() async                  // from .stuck
    /// Launch: marker present && SleepDisabled==true → reset, delete marker, return true (engine shows "recovered").
    func recoverIfNeeded() async -> Bool
    /// applicationShouldTerminate (.terminateLater): cancel pending desired state, run Release; on timeout abandon().
    func releaseForQuit(timeout: Duration) async
    /// Sleep Now: release the flag (await), then `/usr/bin/pmset sleepnow`.
    func sleepNow() async
}
struct ReopenReport: Equatable { var closedFor: TimeInterval; var batteryStart: Int?; var batteryEnd: Int?; var worstThermal: ProcessInfo.ThermalState }
```

**Internal `actor LidReconciler`.** It owns the `Watchdog` and runs the **Engage**, **Release**, **Drift** and **Quit** sequences from `docs/CLOSED_LID.md` §4.3. The marker file is `~/Library/Application Support/Insomnia/lid-engaged`. While engaged: a 20 s main-actor heartbeat timer and `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` (no App Nap).

**On lid events while engaged:**

- **Lid closes, or the last external display goes away while closed:** if `externalDisplayCount == 0`, run `/usr/bin/pmset displaysleepnow`, and tell the engine to drop the display assertion. On close, record the start of the reopen report.
- **Released while the lid is closed** with no external display: run `/usr/bin/pmset sleepnow`.

**Drift checks** run every 60 s while engaged, on wake, and on each power-source change. The 5 s clamshell poll runs only while engaged.

### `Core/WatchMonitor.swift` (replaces the draft's TriggerMonitor)
```swift
@MainActor @Observable final class WatchMonitor {
    static let shared: WatchMonitor
    /// Enabled rules whose condition is currently true.
    private(set) var satisfiedRules: [Rule]
    func start()                                    // idempotent
    /// Babysit / CLI watch: calls `onExit` once (main actor) when the target is gone for 5 s (grace).
    func watch(_ target: WatchTarget, onExit: @escaping @MainActor () -> Void) -> UUID
    func cancelWatch(_ id: UUID)
    func isRunning(_ target: WatchTarget) -> Bool
    /// For the While… menu: running regular apps + running suggested processes.
    func runningApps() -> [(bundleID: String, name: String, icon: NSImage)]
    func runningSuggestedProcesses() -> [(name: String, pid: Int32)]  // only names the matcher finds: claude codex xcodebuild ffmpeg rsync make cargo npm python3
}
```
| Target or condition | How it's checked |
|---|---|
| `.app` | `NSWorkspace.runningApplications` (bundle id) and `didLaunch`/`didTerminateApplicationNotification` |
| `.process` | `proc_listallpids`; a pid matches if any of `proc_name`, `basename(proc_pidpath)`, `basename(argv[0])` (`KERN_PROCARGS2`) or, for interpreters, the first non-flag argument equals the name, case-insensitively (rule in `Models.swift`). Matched pid and real name are shown in the subline and Why awake. **Polled every 5 s, only while some rule or watch needs it.** |
| `.pid` | `DispatchSource.makeProcessSource(identifier:eventMask: .exit)`, no polling. If the PID is already gone, fire `onExit` immediately. |
| `.onAC` / `.externalDisplay` | `PowerMonitor` |

Re-evaluate on `.insomniaPowerDidChange` and `.insomniaSettingsDidChange` (key `rules.v1`). Post `.insomniaRulesDidChange` only when `satisfiedRules` changes. `satisfiedRules` includes paused rules; the engine filters them.

### `Core/AssertionInspector.swift`
```swift
struct ForeignAssertion: Identifiable, Equatable { let id: String; let pid: Int32; let process: String; let type: String; let name: String; let since: Date? }
enum AssertionInspector {
    /// IOPMCopyAssertionsByProcess (public IOKit API), excluding our own PID. Never parses `pmset` text.
    static func foreignAssertions() -> [ForeignAssertion]
    /// Human type: "Preventing idle sleep" / "Preventing display sleep" / "Preventing system sleep" / raw.
    static func describe(type: String) -> String
}
```
This is called only on demand: the ⌥-click menu, the Diagnostics tab and `insomnia why`.

### `Core/Policy.swift`: pure evaluation (unit-test this)
```swift
struct PolicyInput: Equatable {
    var holds: [Hold]
    var hasBattery: Bool; var batteryPercent: Int?; var isOnAC: Bool
    var thermal: ProcessInfo.ThermalState; var lowPowerMode: Bool
    var batteryFloor: Int; var awakeBatteryFloorEnabled: Bool; var lidRequiresAC: Bool
    var isBag: Bool                                // lid closed && no ext. display && !isOnAC
    var lidBagSeconds: TimeInterval; var lidCapMinutes: Int
    var previousGuards: Set<GuardReason>          // for hysteresis
    var thermalBagFairSince: Date?                 // ≥ .fair while isBag, since
    var thermalClearSince: Date?; var now: Date
}
struct PolicyOutput: Equatable {
    var guards: Set<GuardReason>
    var assertSystem: Bool; var assertDisplay: Bool
    var wantLid: Bool                              // some live hold asks for lid
    var lidAllowed: Bool                           // wantLid && no lid guards (helper, hasLid, latch checked by engine)
    var status: AwakeStatus
    var endManualForBatteryFloor: Bool
}
enum Policy { static func evaluate(_ input: PolicyInput) -> PolicyOutput }
```
- **Guard trip and clear rules:** exactly as in `docs/CLOSED_LID.md` §6. Hysteresis uses `previousGuards`: +3% on the battery floors; thermal clears after its trip condition is false for 60 s.
- **`status` priority:** `suspended(.awakeBatteryFloor)` > manual (`timed` / `indefinite`) > `watching` (babysit) > `client` > `automatic` > `asleep`. `endManualForBatteryFloor` only for `awakeBatteryFloor`.
- **Display assertion:** `assertDisplay` = any live hold has `options.screen`. The engine forces it to false while the lid is closed and engaged.

### `Core/AwakeEngine.swift`: the brain
```swift
@MainActor @Observable final class AwakeEngine {
    static let shared: AwakeEngine
    private(set) var holds: [Hold]                 // manual + babysit + client + derived rule holds
    private(set) var guards: Set<GuardReason>
    private(set) var status: AwakeStatus
    private(set) var lid: LidStatus                // ClosedLidController.status merged with needsSetup / suspended(guard) / latched
    private(set) var mood: EyeMood
    private(set) var now: Date                     // ticks (see Timers)
    private(set) var banner: Banner?               // replaces the panel quip row
    private(set) var quip: String?                 // Narrator line for the current state; nil = hide row
    var manualHold: Hold? { get }
    var babysitHold: Hold? { get }
    var isAwake: Bool { get }                      // status.isAwake
    var remaining: TimeInterval? { get }           // manual timed only
    var progress: Double? { get }                  // 0…1 elapsed of manual timed

    func start() async                             // recoverIfNeeded → refreshHelper → activateOnLaunch
    /// Replaces the manual hold. options == nil → followsSettings; non-nil (CLI flags, URL) → fixed. Never writes Settings.
    func activate(_ d: AwakeDuration, source: SessionSource, options: AwakeOptions? = nil)
    func deactivate(_ r: DeactivationReason)       // ends manual + babysit holds (rules/clients unaffected)
    /// isAwake → deactivate(.user) + pause satisfied rules until each goes false→true; else activate(default).
    /// Client-only → no-op (UI disables the control).
    func toggle(source: SessionSource)
    func extend(minutes: Int)                      // timed: push end; indefinite: no-op; none: activate(.minutes)
    func babysit(_ t: WatchTarget)                 // replaces babysit hold; followsSettings
    func releaseBabysit()
    func beginClientHold(connection: UUID, label: String, options: AwakeOptions)
    func endClientHold(connection: UUID)
    func sleepNow() async                          // deactivate(.sleepNow) → ClosedLidController.sleepNow()
    func setPanelVisible(_ v: Bool)                // 1 Hz ticks while visible
    func poke()                                    // panel eyes rapid-click counter (UX §9)
    func dismissBanner()
    func prepareForQuit() async                    // releaseAll + ClosedLidController.releaseForQuit(timeout: .seconds(2))
    private(set) var pausedRuleIDs: Set<Rule.ID>   // paused by the eyes; a rule unpauses once its condition is false
}
enum Banner: Equatable {
    case batteryFloor(percent: Int), guardTripped(GuardReason), recovered
    case reopen(ReopenReport), lidBatteryCallout, setupResult(String)
}
```

**Behaviour:**

- **Single reconcile function** `reevaluate()`. It runs on any settings, power, rules or lid change, on wake, and on each tick that crosses an end time. Its steps:
  1. Drop paused rules that are no longer satisfied from `pausedRuleIDs`. Rebuild rule holds from `satisfiedRules` minus paused, keeping each rule hold's id and start date stable.
  2. Re-derive options **only for `followsSettings` holds**: manual/babysit = `Settings.manualOptions`; rule = `(rule.keepScreenOn, rule.allowLid || closedLidMode)`.
  3. Expire timed holds (`DeactivationReason.timerExpired`).
  4. Run `Policy.evaluate`. If `endManualForBatteryFloor`, call `deactivate(.batteryFloor)`.
  5. Apply the assertions.
  6. Update the latch (set when a lid guard trips while `isLidClosed`; cleared by a clamshell-open event or a user action). Call `ClosedLidController.setDesired(lidAllowed && hasLid && helper == .installed && !latched)`.
  7. Compute `lid`:
     - controller `.stuck` → `.stuck` (always shown);
     - `wantLid` false → `.off`;
     - helper not `.installed` → `.needsSetup`;
     - a lid guard is tripped → `.suspended(first)`;
     - latched → `.latched`;
     - otherwise the controller's status.
  8. Compute `mood = EyeMood(status:lid:)`.
  9. Diff against the previous state. Fire the `Moment`s through `Narrator`, set `quip`/`banner`, call `Notifier` and `Stats`, then post `.insomniaStateDidChange`.
- **Lid bag counter:** one engine-scoped `lidBagSeconds`, accumulated while engaged and `isBag`, for any hold type. Resets **only** on a clamshell-open event (not on AC, not on a new hold).
- **Lid switch turned on** (settings key `closedLidMode` false → true) while `!isAwake` and helper installed → `activate(defaultDuration, source: .panel)`.
- **Timers.** No timer runs while asleep and the panel is closed.
  - **1 Hz** while the panel is visible, or while a timed hold has ≤ 60 s left.
  - Otherwise **one-shot** timers at the next event: the end time, end − 5 min (the heads-up notification), end − 60 s, the next whole minute (only when the menu bar or Dock shows text), and the escalation thresholds (2/8/24/72 h).
  - Use wall-clock `Date`s, and re-evaluate on `didWakeNotification` and `NSSystemClockDidChange`.
- **Notifications** follow `UX.md` §10 (ids and gates). Guard notifications fire **once per engagement per guard**.
- **Quip budget:** at most one rotating `activated`/`deactivated` quip per 4 h (`PRODUCT.md` §4 rule 11); earned moments are exempt.
- **Rate limits:** `Stats.addAwakeTime` gets elapsed wall time on each re-evaluation, never per-second increments. The poke counter resets after 8 s idle.
- **First engagement on battery:** if `lidBatteryCalloutShown` is false, set `banner = .lidBatteryCallout` and set the flag.

### `Core/Narrator.swift` + `Core/Copy/Copy+Professional.swift`, `Copy+Cheeky.swift`, `Copy+Unhinged.swift`
```swift
@MainActor final class Narrator {
    static let shared: Narrator
    /// Shuffle bag per (moment kind, personality); never the same line twice in a row; bag empties before repeats.
    /// Returns nil for decorative moments in .professional (idle, awake, poke, milestone, date lines).
    func line(_ m: Moment, _ p: Personality, now: Date = Date()) -> String?
    /// Plain in every tier (docs/PRODUCT.md §5 headlines).
    func headline(status: AwakeStatus, lid: LidStatus) -> String
    func subline(status: AwakeStatus, lid: LidStatus, remaining: TimeInterval?, now: Date) -> String
    func lidSublabel(_ lid: LidStatus, settingOn: Bool, isAwake: Bool) -> String?
    func durationName(_ d: AwakeDuration, _ p: Personality) -> String?      // nil in .professional; 47 min → "One more episode" (unhinged)
    func notification(_ id: NotificationID, _ p: Personality, context: [String: String]) -> (title: String, body: String)
    func accessibilityValue(status: AwakeStatus, lid: LidStatus, remaining: TimeInterval?) -> String
}
enum NotificationID: String { case endingSoon = "ending-soon", ended, batteryFloor = "battery-floor", batteryStop = "battery-stop", lidHeat = "lid-heat", lidLPM = "lid-lpm", lidCap = "lid-cap", lidError = "lid-error", lidStuck = "lid-stuck", foreignFlag = "foreign-flag", recovered, targetExited = "target-exited" }
```
- **Pools:** `[MomentKind: [String]]` static arrays in the Copy files, with placeholders `{name}`, `{floor}`, `{cap}` and `{duration}`.
- **Pool sizes:** Cheeky and Unhinged each need **≥ 40 lines** in total, and **≥ 10** each for `activated`, `deactivated`, `idle` and `awake` (UX.md §11 has the seeds).
- **Date-aware lines** (3–5 AM, Oct 31, New Year): replace an `activated` or `idle` line with 1-in-3 probability. Never in Professional.
- **Never in titles:** notification titles and headlines contain no jokes.

### `Core/Stats.swift`
```swift
@MainActor @Observable final class Stats {
    static let shared: Stats
    private(set) var totalAwakeSeconds: TimeInterval
    private(set) var sessionCount: Int
    private(set) var longestSessionSeconds: TimeInterval
    private(set) var lidClosedSeconds: TimeInterval
    private(set) var lidCloseSurvivals: Int
    private(set) var milestonesShown: Set<Int>      // hours: 100, 500, 1000 — each shown once, ever
    private(set) var pokeBadge: Bool                // 50 pokes
    private(set) var firstLaunch: Date
    func recordSessionStarted()
    func recordSessionEnded(duration: TimeInterval)
    func addAwakeTime(_ s: TimeInterval) -> Int?    // returns a newly crossed milestone (hours) or nil
    func addLidClosedTime(_ s: TimeInterval)
    func recordLidCloseSurvival()
    func awardPokeBadge()
    func reset()
    var cupsOfCoffeeEquivalent: Int { get }        // 1 per 45 min
}
```
Backed by UserDefaults (`stats.*`). Saves at most every 30 s of added time, plus immediately on session end, reset or termination.

### `Core/Notifier.swift`
```swift
@MainActor enum Notifier {
    static func setUp()     // categories: SESSION_ENDING [EXTEND_15 "+15 min", STOP "Allow Sleep"], LID_HEAT [STOP], LID_ERROR [RETRY], LID_STUCK [RESET "Reset…"], FOREIGN_FLAG [WHY]
    static func requestAuthorization()             // welcome "Got it", lid setup success, sessionNotifications on
    static func post(_ id: NotificationID, title: String, body: String)   // sound = nil ALWAYS; replaces same id; queued until auth answers
    static func clear(_ id: NotificationID)
}
/// Strongly retained by AppDelegate; set as UNUserNotificationCenter.delegate in applicationWillFinishLaunching.
/// Uses completion-handler variants; calls the handler synchronously, then Task { @MainActor in … } with only
/// the actionIdentifier/requestIdentifier strings (UNUserNotificationCenter isn't Sendable).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {}
```
- **Gating:** `sessionNotifications` gates `ending-soon`, `ended` and `target-exited`. All other ids always post.
- **While frontmost:** `willPresent` returns `[.banner]`.
- **Actions** map to `extend(minutes: 15)`, `deactivate(.user(.notification))`, `ClosedLidController.retry()`, `resetWithPassword()` and `AppRouter.showWhyAwake()`.

### `Core/HotKeyManager.swift`
```swift
@MainActor final class HotKeyManager {
    static let shared: HotKeyManager
    @discardableResult func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) -> Bool  // false if taken
    func unregister()
    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String     // "⌃⌥⌘I"
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32
}
```
- **Mechanism:** Carbon `RegisterEventHotKey` + `InstallEventHandler(GetApplicationEventTarget(), kEventHotKeyPressed)`. No Accessibility permission is needed.
- **Key names:** `UCKeyTranslate`, with a fallback table for special keys.
- **Scope:** a single hotkey, which toggles (eyes-button semantics).
- **Modifiers:** must include ⌘ or ⌃ (macOS 15+ rejects ⌥/⌥⇧-only). "That shortcut is taken" only for `eventHotKeyExistsErr`; any other `OSStatus` → "Couldn't register (code N)".

### `Core/Control/ControlProtocol.swift` + `Core/Control/ControlServer.swift`
```swift
/// JSON Lines over a Unix stream socket. One request per line; one response line per request.
enum ControlRequest: Codable, Equatable {
    case on(duration: String?, until: String?, screen: Bool?, lid: Bool?)  // "45m", "2h", "90", "forever"; until "HH:mm"
    case off
    case extend(by: String)
    case status
    case why
    case hold(label: String, screen: Bool, lid: Bool)   // connection-scoped client hold; released on EOF
}
struct ControlResponse: Codable, Equatable { var ok: Bool; var error: String?; var status: StatusPayload? ; var why: [WhyRow]? }
struct StatusPayload: Codable, Equatable { var state: String; var remainingSeconds: Int?; var endsAt: Date?; var screen: Bool; var lid: String; var guards: [String]; var holds: [String] }
// Encoder/decoder use dateEncodingStrategy/dateDecodingStrategy = .iso8601.
struct WhyRow: Codable, Equatable { var section: String; var who: String; var what: String }
enum ControlPaths { static var directory: URL; static var socket: URL }   // ~/Library/Application Support/Insomnia/control.sock

@MainActor final class ControlServer { static let shared: ControlServer; func start() throws; func stop() }
```
- **Socket permissions:** the directory is `0700` and the socket `0600`. Each connection is rejected unless `getpeereid` uid == `getuid()`. Every socket sets `SO_NOSIGPIPE`.
- **`start()`:** first `connect()` to an existing socket; if it answers, another instance owns it, so refuse. Only then unlink + bind.
- **I/O:** a `DispatchSource` read source per connection, with handling on the main actor.
- **Hold lifetime:** a `hold` request maps to `AwakeEngine.beginClientHold`. When the connection closes, the server calls `endClientHold`, the same way the watchdog works.
- **Options from the CLI:** `on` with `screen`/`lid` set calls `activate(_:source: .cli, options:)` with fixed options for that hold only (unset fields taken from Settings at start). It **never writes Settings**. Guards still apply. Lid requested with the helper missing → `ok:false, error:"lid mode not set up: open Insomnia ▸ Settings ▸ Lid & Safety"`.

---

## UI

### `UI/Theme.swift`
Colour tokens, fonts and metrics from `UX.md` §2.3 and §2.2: `accentAwake`, `accentLid`, `sleepTone`, `warning`, `danger`, `sclera`; panel width 320, padding 14, chip height 28. Light and dark variants are built with `NSColor(name:dynamicProvider:)`.

### `UI/EyesRenderer.swift`: the mascot, drawn in code
```swift
enum EyesRenderer {
    /// 22×16 pt template image. blink 0 (open)…1 (closed). Shapes per UX.md §1.1. stroke 1.5 (2.0 if increaseContrast).
    static func menuBarImage(mood: EyeMood, blink: CGFloat = 0, highContrast: Bool = false) -> NSImage
    /// Full-colour squircle icon (Dock tile + exported .icns). pill: optional time text drawn bottom-centre.
    static func appIcon(size: CGFloat, mood: EyeMood, pill: String? = nil) -> NSImage
}
```
- **Drawing:** must work headless (`NSBitmapImageRep` + `NSGraphicsContext`) for `--export-icon`.
- **App icon:** an indigo→violet gradient squircle with amber irises. When asleep it shows closed arcs and "z z". In the `.lid` mood it adds the lid bar and an indigo glow.

### `UI/EyesView.swift`
A SwiftUI view of the panel eyes, built on `TimelineView(.animation)` **only while it's visible**. It handles:

- blink every 4–9 s;
- cursor tracking ±2 pt, using `NSEvent.mouseLocation` relative to the window;
- the floating "z";
- the toggle animations, double-take, sweat drop, cross-eyes, heavy lids and the lid glow from `UX.md` §2.4.

All of it respects `accessibilityDisplayShouldReduceMotion`, and the view is `accessibilityHidden`.

### `UI/StatusItemController.swift`
```swift
@MainActor final class StatusItemController: NSObject {
    init(); func install()
    func showPanel(); func closePanel(); func togglePanel()
    var isItemVisible: Bool { get }          // UX §1.7 heuristic (occlusion, nil screen, notch areas)
    func blink()                             // one 180 ms blink (skipped under Reduce Motion)
}
```
- **Status item:** `NSStatusItem(variableLength)`, image from `EyesRenderer.menuBarImage(mood:)`, plus optional timer text per `Settings.menuBarTimer` (UX §1.3).
- **Never set `statusItem.menu`.**
- **macOS 27+:** `@available(macOS 27, *) extension StatusItemController: @preconcurrency NSStatusItemExpandedInterfaceDelegate`, assigned inside `if #available(macOS 27, *)` (weak property). In `statusItem(_:didBegin:)`, branch on `NSApp.currentEvent`:
  - right-click or ctrl-click → `session.cancel()`, then run the right-click action;
  - ⌥ → `session.cancel()` + Why-awake menu;
  - otherwise → show `PanelHost`; `PanelHost.onClose` calls `statusItem.expandedInterfaceSession?.cancel()`.
  - `statusItemDidEndExpandedInterfaceSession(_:animated:)` → close `PanelHost`.

  **Spike first.** If right-clicks don't arrive, use the 14–26 path everywhere.
- **macOS 14–26:** `button.sendAction(on: [.leftMouseUp, .rightMouseUp])` with target/action.
- **Why-awake menu:** `NSMenu.popUp(positioning:at:in:)`.
- **Redraws:** refresh on `.insomniaStateDidChange` / `.insomniaSettingsDidChange`, **only when (mood, text) changes**.
- **Tooltip and accessibility value:** from `Narrator`.
- **Final 60 s:** one blink every 10 s.
- **Hidden item:** if `!isItemVisible` and `!Settings.hiddenItemCardShown`, show the Hidden card via `PanelHost.floating`.

### `UI/PanelHost.swift`
```swift
@MainActor final class PanelHost {
    enum Anchor { case statusItem(NSStatusBarButton), floating }
    func show(anchor: Anchor); func close(); var isVisible: Bool { get }
    var onClose: (() -> Void)?
}
```
| Host | Used for |
|---|---|
| `PanelWindow: NSPanel` (borderless, `canBecomeKey = true`; `NSGlassEffectView` cornerRadius 12 on 26+, else `NSVisualEffectView(.popover)`; `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`, `level = .popUpMenu`) | macOS 27 expanded session (below the button, on `button.window.screen`), and floating mode (screen under the mouse) |
| `NSPopover(.transient)` | macOS 14–26 from the menu bar |

The content is `NSHostingController(rootView: PanelView())`. Call `NSApp.activate()` before showing. When the host appears or disappears, call `AwakeEngine.setPanelVisible`. Close on Esc or when focus is lost.

### `UI/PanelView.swift` + `UI/PanelComponents.swift` + `UI/LidSetupView.swift`
These implement `UX.md` §2 exactly: rows A–H′ and J (no holds list, no extend chips), the asleep variant, the banner replacing J, the first-run card, keyboard map §2.5, the Until… popover, the While… menu (§2.2 F), lid sublabels §5, the lid setup sheet §6, and the epic moments §2.4.

- **State:** read `@Bindable var settings = Settings.shared`, `AwakeEngine.shared`, `ClosedLidController.shared` and `PowerMonitor.shared`.
- **Lid toggle when the helper is missing:** turning it on presents `LidSetupView` instead.
- **Size:** ≤ 340 pt tall in fixed regions (UX §2.1), no scroll view, no size change between states. H/H′ hidden when `!PowerMonitor.hasLid`.

### `UI/WhyAwakeMenu.swift`
```swift
@MainActor enum WhyAwakeMenu { static func make() -> NSMenu; static func reportText() -> String }
```
The menu sections follow `UX.md` §1.5, built from `AwakeEngine.holds`, `guards`, `AssertionInspector.foreignAssertions()`, `RootDomain` and `ClosedLidController.foreignSleepDisabled`. **"Copy Report"** puts `reportText()` on the pasteboard.

### `UI/DockController.swift`
```swift
@MainActor final class DockController {
    static let shared: DockController
    func start()                    // applies Settings.showInDock (.regular / .accessory); observes changes
    func makeDockMenu() -> NSMenu   // UX §3
    func handleDockClick()          // AwakeEngine.toggle(source: .dock) + tile blink. Never bounces. Only for Dock-sent reopens.
}
```
- **Tile:** `dockTile.contentView` draws `EyesRenderer.appIcon(size:128, mood:, pill:)`, with the time drawn **into the tile**.
- **Badge:** `badgeLabel = "!"` only for `.error` / `.stuck`.
- **Redraws:** call `display()` only when (mood, pill) changes.

### `UI/Settings/SettingsWindowController.swift`, `SettingsView.swift`, `GeneralTab.swift`, `AutomationsTab.swift`, `LidSafetyTab.swift`, `DiagnosticsTab.swift`, `HotKeyRecorder.swift`, `AboutView.swift`
```swift
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared: SettingsWindowController
    func show(tab: SettingsTab)     // creates once; NSApp.activate(); front; selects tab
}
struct HotKeyRecorder: View        // click to record; next key whose modifiers include ⌘ or ⌃ (NSEvent local monitor); Esc cancels; ⌫ clears
```
- **Window:** a toolbar `TabView` of four tabs, 540 wide, using `Form(.grouped)`. Wireframes are in `UX.md` §4. Without a lid the third tab is "Safety"; with no lid and no battery it's hidden.
- **Launch at login:** `SMAppService.mainApp`. Reflect `.status`, and show the error text if it fails.
- **Automations tab:** rules as sentence rows. The CLI install/remove creates a symlink `~/.local/bin/insomnia` pointing to `Bundle.main.executableURL` and shows a PATH hint if needed. The tab also lists URL recipes with copy buttons.
- **Lid & Safety tab:** helper status with Set Up / Test / Repair / Open Login Items / Remove, a lid cap picker, an "Only on power adapter" toggle, the floor slider (10–50) and "Also stop keeping awake at that level".
- **Diagnostics tab:** live readouts, the Why-awake table, and the `EventLog` with Copy/Clear.
- **About:** a sheet (`AboutView`) with eyes, version, stats, milestones, Reset Stats and the GitHub link https://github.com/GabrielDeml/insomnia.

### `Core/EventLog.swift`
```swift
@MainActor @Observable final class EventLog { static let shared: EventLog; private(set) var entries: [Entry]; func log(_ kind: String, _ message: String); func clear(); func text() -> String }
```
An in-memory ring of 200 entries, also mirrored to `os.Logger(subsystem: "com.gdeml.Insomnia", category: kind)`. Engine, lid, guard, URL and CLI events all log here.

---

## App shell

### `App/main.swift`
0. `signal(SIGPIPE, SIG_IGN)`.
1. If `CommandLine.arguments` contains `--export-icon <dir>`, render `EyesRenderer.appIcon` at the standard `.iconset` sizes and names (16…1024, @1x and @2x), then `exit(0)`. No run loop.
2. If `arguments[1]` is a CLI command (`on off toggle extend status why run watch help --why --version`), run `CLI.main(args)` and `exit(code)`. **No NSApplication.** Any other argument except `--gui` → usage, exit 2.
3. No arguments and `getppid() != 1` (not launched by LaunchServices, e.g. typed in a terminal) → print help, exit 2.
4. Otherwise (LaunchServices or `--gui`): `let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.run()`, keeping a strong reference to the delegate.

### `App/CLI.swift`
```
insomnia on [30m|2h|90|forever] [--until HH:mm] [--screen|--no-screen] [--lid|--no-lid]
insomnia off | toggle | extend 15m
insomnia status [--json]          # exit 0 awake, 1 asleep (scriptable)
insomnia why                      # our holds + guards + foreign assertions + SleepDisabled
insomnia run [--screen] [--lid] -- <cmd…>   # client hold for exactly the command's lifetime; exits with its status
insomnia watch --pid N [--screen] [--lid]   # client hold until PID exits (DispatchSource proc exit)
insomnia --why                    # an existential answer, personality-aware
```
- **Connecting:** connect to `ControlPaths.socket`. If no `NSRunningApplication` has the bundle id, run `/usr/bin/open -g -b com.gdeml.Insomnia` and wait up to 5 s for the socket. If the app runs but the socket doesn't answer, exit 3 (never `open` a running app: that's a reopen).
- **`run` / `watch`:** send `hold` and keep the connection open. For `run`, spawn the child with `posix_spawn` (inheriting stdio), forward SIGINT/SIGTERM to it, and close the socket after it exits. `watch` closes the socket when the PID exits.
- **Exit codes:**
  - 0: ok
  - 1: asleep (`status` only)
  - 2: usage error
  - 3: couldn't reach the app
  - 4: request refused (e.g. lid mode not set up)

### `App/AppDelegate.swift`
- **`applicationWillFinishLaunching`:** if another `NSRunningApplication` has our bundle id and a different pid, open `insomnia://panel` and `exit(0)` before touching the lid, socket or status item. Set the `NotificationDelegate`. Build `NSApp.mainMenu` (App: About, Settings… ⌘,, Quit ⌘Q; Edit: standard selectors).
- **`applicationDidFinishLaunching`:**
  1. `Notifier.setUp()`
  2. `PowerMonitor.shared.start()`
  3. `WatchMonitor.shared.start()`
  4. Install the `StatusItemController`.
  5. `DockController.shared.start()`
  6. Wire the `AppRouter` handlers.
  7. Register the hotkey, and re-register it when the `hotKey*` settings change.
  8. `ControlServer.shared.start()`
  9. `Task { await AwakeEngine.shared.start() }`
  10. Register the `kAEGetURL` Apple Event, routed to `URLCommandHandler.handle`.
- **`applicationShouldTerminate`:** if the lid marker exists or `lid != .off`, return `.terminateLater`, then `Task { await AwakeEngine.shared.prepareForQuit(); NSApp.reply(toApplicationShouldTerminate: true) }`. Logout, restart and shutdown arrive here too (quit Apple Event); there is no separate `willPowerOff` path.
- **`applicationWillTerminate`:** `ControlServer.shared.stop()`.
- **`applicationDockMenu`:** returns `DockController.shared.makeDockMenu()`.
- **`applicationShouldHandleReopen`:** if the current Apple Event's `keySenderPIDAttr` equals the Dock's pid (`NSRunningApplication` `com.apple.dock`) and `showInDock` → `handleDockClick()`; otherwise `AppRouter.showPanel()` (floating if the item is hidden). Return false.
- **`applicationShouldTerminateAfterLastWindowClosed`:** returns false.

### `App/URLCommandHandler.swift`
```swift
struct URLCommand: Equatable { /* parsed, pure */ static func parse(_ url: URL) -> URLCommand? }
@MainActor enum URLCommandHandler { static func handle(_ url: URL) }
```
| Host | Parameters |
|---|---|
| `toggle` | none |
| `on` | `for=45m\|2h\|90\|forever`, `until=HH:mm` (next occurrence), `screen=0\|1`. Always fixed options with `lid: false`. |
| `off` | none |
| `extend` | `by=15m` |
| `sleep` | none |
| `panel` | none |
| `settings` | `tab=` |

- **`lid` is ignored and logged.** URL holds always carry `lid: false` (`CLOSED_LID.md` §3, §5). The URL scheme never writes Settings.
- **Unknown hosts or parameters:** ignored and logged.

### `Resources/Info.plist`

| Key | Value |
|---|---|
| `CFBundleName` / `CFBundleDisplayName` | "Insomnia" |
| `CFBundleIdentifier` | `com.gdeml.Insomnia` |
| `CFBundleExecutable` | `Insomnia` |
| Version | 1.0.0, build 1 |
| `CFBundleIconFile` | `AppIcon` |
| `LSMinimumSystemVersion` | 14.0 |
| `LSUIElement` | true |
| `NSHighResolutionCapable` | true |
| `CFBundleURLTypes` | scheme `insomnia` |
| `LSApplicationCategoryType` | `public.app-category.utilities` |
| `NSHumanReadableCopyright` | "© 2026 Gabriel Deml. Sleep is for the weak (and for Macs, eventually)." |

### Docs
- **`README.md`:** hero line, feature list, screenshots placeholder, install/build (`make install`), how closed-lid mode works (link `docs/CLOSED_LID.md`, the exact sudoers line, manual uninstall), the safety guards, URL scheme and CLI references, hotkey, FAQ (Why not just `caffeinate`? Does it fake input? No. Why the password once?), MIT license.
- **`LICENSE`:** MIT, 2026, Gabriel Deml.
- **`.gitignore`:** `.build/`, `build/`, `.swiftpm/`, `*.xcodeproj/xcuserdata`, `.DS_Store`.
- **Design docs** live in `docs/` (index: `docs/README.md`).

### Build order (milestones; each one ships a runnable app)
| # | Milestone | Modules |
|---|---|---|
| M1 | Awake core | Models/Settings, PowerAssertions, PowerMonitor, Policy, AwakeEngine (manual holds), Theme, EyesRenderer, StatusItemController, PanelHost, PanelView (A–G, J), main/AppDelegate, build.sh/Makefile/Info.plist |
| M2 | Lid mode | RootDomain, Privileged/*, ClosedLidController, LidSetupView, guards + latch in Policy/engine, lid rows H/H′, Lid & Safety tab. **Ships only when `CLOSED_LID.md` §8 T1–T10 pass.** |
| M3 | Automations & insight | WatchMonitor, While… / babysit, rules UI, AssertionInspector, WhyAwakeMenu, Diagnostics tab, EventLog |
| M4 | Personality & polish | Narrator + Copy pools, Notifier, DockController, Stats/About, poke and milestones, epic moments, onboarding/hidden cards, HotKeyManager, URLCommandHandler |
| M5 | CLI | ControlProtocol/Server, CLI.swift, CLI install in Automations, README |

---

## Decisions log

### Proposal scorecard (1–5)

| Proposal | Elegance | Power | Delight | Feasibility | Safety | Verdict |
|---|---|---|---|---|---|---|
| P1 Minimal | **5** | 3 | 3 | **5** | 4 | Best surface. Grafted: eyes as the toggle, 2-switch rows, `⋯` menu, plain labels, the guards that can't be disabled. |
| P2 Power | 3 | **5** | 2 | 3 | **5** | Best model. Grafted: holds/guards, Why awake, CLI over a socket, `PrivilegedBackend`, lid cap, typed guards. |
| P3 Delight | 3 | 4 | **5** | 4 | 4 | Best soul. Grafted: babysit (While…), reopen report, test drive, panel micro-motion, escalation and date lines, glance glyph. |

### Decisions

| # | Decision | Alternatives considered | Why |
|---|---|---|---|
| 1 | **Holds → guards → derived status** is the single model (`Policy.evaluate` is pure) | Draft: one manual session plus `[String]` triggers. P3: `SessionKind` | Every source (panel, rule, CLI, babysit) goes through one path, guards always win, and every surface renders one value so they can't drift apart. Testable. |
| 2 | **The eyes are the toggle** (72 pt), and the mascot is the main control | Draft and P3: a separate 120 pt ring button | Removes a redundant element. The ring around the eyes shows progress. |
| 3 | **Lid mode is a sticky setting applied to every settings-following hold** (manual, babysit, rules). Turning it on while asleep starts a hold. CLI flags and URL holds carry fixed per-hold options and never write Settings; URL holds never get lid. "Keep screen on" stays manual/babysit only. | Manual + babysit only (draft); per-hold "level" (P2) | The user asked for "a setting", and a switch that silently does nothing under a rule reads as broken. Screen-on stays off rules, because an "on power adapter" rule would keep displays lit all day. The "forgot it was armed" risk is handled by the solid `.lid` glyph, the bag time cap, the latch and the mandatory guards. |
| 4 | **Sudoers rule (2 commands, `#uid`, `zz_` file) + bash watchdog (EOF, 90 s heartbeat, signal trap) + root safety daemon (boot reset, 10% backstop) + marker recovery; `.stuck` when all fail** | SMAppService + XPC (needs a Team ID), osascript per toggle, `kill -0` polling, a pure boot-reset daemon | Works ad-hoc signed with one password prompt. Crashes, hangs, signals, reboots and foreign setters each hit a different layer, and the one floor that matters most is enforced by root, not by our process. `PrivilegedBackend` keeps the SMAppService path open. |
| 5 | **Inline root install script**: temp files with dotted names inside root-owned directories, `visudo -cf` + `visudo -c`, atomic `mv`, `#includedir` check | Draft: script in a user `mkdtemp` directory | Fixes a TOCTOU bug that let same-user code grant itself `ALL`. Never edits `/etc/sudoers`. |
| 6 | **Read state from IORegistry** (`SleepDisabled`, `AppleClamshellState`) with clamshell interest notifications | Parsing `pmset -g`, a 2 s lid poll | Structured, cheaper and event-driven. `pmset` text is undocumented and can change. |
| 7 | **`displaysleepnow` on lid close only without an external display. `sleepnow` after a release while the lid is closed.** | Do nothing | The Apple Silicon panel can stay lit when shut. With an external display it would blank the display the user is looking at. |
| 8 | **Cut "Look busy"** | `DeclareUserActivity` (draft), jiggle via Accessibility | Assertions don't reset HID idle, so the feature would be a false promise. Jiggle loses its TCC grant on every ad-hoc rebuild and defeats the screen lock. Moved to Later. |
| 9 | **Lid guards (battery floor, heat, LPM) can't be disabled; the bag cap (default 1 h) has no "unlimited"; a guard that fires with the lid shut latches until the lid opens. Plain keep-awake has only an opt-in floor.** | Toggles for each (draft); one floor that ended every session | `disablesleep` turns off macOS's own low-battery sleep; plain assertions don't, so stopping a Caffeine-style session at 20% would be a regression. The latch stops DarkWakes re-arming a Mac in a bag. |
| 10 | **The URL scheme can't turn lid mode on** | Allow it with confirmation | Any web page can open `insomnia://`. Scripted lid mode goes through the CLI, which is local and same-user. |
| 11 | **CLI in v1** (the app binary dispatches on argv, JSON Lines over a 0600 socket, holds scoped to the connection) | URL-only scripting. P1 put the CLI in v1.1 | `insomnia run -- make` is the agent-era feature, and connection-scoped holds can't leak. |
| 12 | **App Intents → Later** | Ship them in v1 | SwiftPM doesn't run `appintentsmetadataprocessor`. URL and shell actions cover Shortcuts for now. Spike in a build script later. |
| 13 | **Dock on by default (welcome card chooses); time drawn inside the tile, `badgeLabel` only for errors. A Dock-sent reopen toggles; any other reopen opens the panel.** | Dock off by default; every reopen toggles | The user asked for a Dock widget. Spotlight/Finder relaunches also send reopen and must never silently change sleep state. |
| 14 | **Menu bar: never `statusItem.menu`. Expanded-interface delegate on 27 (after a spike). Timer text defaults to "Last 10 min".** | Always-on timer (draft), `statusItem.menu` | 27.0.1 drops clicks on multi-display setups with `statusItem.menu`, and macOS 27 ejects wide items. |
| 15 | **No idle animation in the menu bar.** Panel eyes animate only while visible. | Draft blinked or glanced every 6–14 s | Motion in the menu bar wears thin after a week and costs CPU. The panel is where the fun lives. |
| 16 | **`Narrator` is separate from the engine.** Shuffle-bag pools live in Swift source. Professional returns nil for decorative lines. | `Quips` owned by the engine. JSON resources | Keeps the engine testable and copy swappable. `Bundle.module` breaks in hand-assembled bundles. |
| 17 | **Typed `GuardReason` / `LidError`**, with no user-facing strings in models | `.suspended("Too hot 🔥")` (draft) | Copy changes by personality, VoiceOver needs stable values, and hysteresis needs typed reasons. |
| 18 | **Four settings tabs** (General, Automations, Lid & Safety, Diagnostics). About is a sheet. | Five tabs (draft and P2), three tabs (P1) | Diagnostics earns a tab because it holds Why awake and the event log. Shortcuts folds into Automations. |
| 19 | **Presets 30m/1h/2h/4h/8h/∞ plus Until…, with no Custom stepper.** Default duration is ∞. | P3 default of 60 min, a 15m preset | ∞ matches what Caffeine users expect, and the lid cap covers the bag case. Until… and the CLI cover any odd duration. |
| 20 | **Rule conditions: app, process, on AC, external display only** | Wi-Fi/USB/BT/VPN/audio (Amphetamine) | Cheap and clearly useful. Wi-Fi needs Location, and the rest is clutter. |
| 21 | **One global hotkey (toggle)** | Two hotkeys (P2) | The panel is one click away, and a second default combo risks conflicts. |
| 22 | **Swift 6 language mode, tools 6.0. C callbacks use `MainActor.assumeIsolated`.** | Tools 5.10 / Swift 5 (draft) | Data-race safety for a privileged, callback-heavy app, and events stay in order. |
| 23 | **The app never touches a foreign `SleepDisabled = 1` (no marker)**; only the root boot reset and 10% backstop do | Always reset; reset whenever Insomnia isn't running | Don't fight Amphetamine or MDM. Reported in Diagnostics and one `foreign-flag` notification per boot. |
| 24 | **Name stays "Insomnia" for now** | Rename | "Insomniacs" (App Store) and `krishhgg/Insomnia` exist. Re-check before a 1.0 announcement. |
| 25 | **Clicking the open eyes pauses satisfied rules until they re-trigger; client holds can't be released from the eyes** | Eyes only end manual holds (draft); a timed "snooze rules" | Open eyes promise "click to let it sleep". A CLI hold belongs to a running command. |
| 26 | **Panel: no extend chips, no holds list, fixed regions ≤ 340 pt** | 21 targets, ~490 pt, size jumps | "Clean, simple, elegant". Chips double as extend; the subline names the primary hold with Stop. |
| 27 | **Quip budget (1 per 4 h) + four epic moments** | A quip on every toggle; only micro-motion | Funny a few times a day stays funny; "Make it epic!" needs moments worth a screenshot. |
| 28 | **Desktop Macs get no lid UI** (`hasLid`), no battery UI without a battery | Show and grey out | A sudoers rule that does nothing is clutter and needless privilege. |
| 29 | **Single instance; GUI only from LaunchServices or `--gui`** | Allow duplicates | Two `LidReconciler`s would fight over the flag and marker. |
