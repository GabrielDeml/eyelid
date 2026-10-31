# Insomnia code review, 2026-10-31

Scope: the whole repo (Insomnia app and CLI, InsomniaHelper, InsomniaShared, tests, Makefile and scripts), checked against docs/PRODUCT.md, docs/UX.md, docs/CLOSED_LID.md and ARCHITECTURE.md. The review was read-only and probes ran only in the scratchpad. Every finding below went through a separate verification pass. IDs are the original verification IDs (R1–R100), so they are not sequential in the table.

## 1. Summary

**Counts.** 100 findings survived verification and 6 were rejected.

| Severity | CONFIRMED | PLAUSIBLE | Total |
|---|---|---|---|
| major | 13 | 0 | 13 |
| minor | 79 | 8 | 87 |
| **Total** | **92** | **8** | **100** |

Verifiers downgraded 21 findings from a claimed "major" to "minor". The usual reason was that the trace was right but the trigger is narrow or a backstop limits the damage. Of the 87 minors, 18 are simplification findings and 16 are test gaps (13 confirmed, 3 plausible).

**Overall health.** The design is solid. Holds, policy and the lid reconciler are cleanly separated, the lid safety model has three layers, and the 338-test suite covers the pure policy tables well. The app is not yet trustworthy in the places that matter most:

- **Safety.** Some paths leave the Mac unable to sleep, or start an indefinite awake session the user never asked for: uninstall, the setup test drive, finishing setup, and the sudoers boot reset.
- **Automations.** Process matching fails for the product's headline targets: `claude`, `python3`, `npm`, root processes and LSUIElement apps.
- **Panel on macOS 27.** Window-mode presentation has several bugs that make the panel vanish or clip.
- **Tests.** The safety-critical crash, quit and recovery paths in the helper, watchdog and controller are mostly untested.

Verdict: **a good foundation that is not ready to ship.** Fix batches 1–3 before anyone relies on lid mode or automations.

**Top 5 risks**
1. **R1:** `make uninstall` removes every safety net and the lid marker without resetting `SleepDisabled`, so the Mac can stay unable to sleep across reboots.
2. **R39 / R40:** the setup "Try it" drive and finishing setup from the welcome card leave lid mode on with an indefinite hold. A lid closed in a bag on AC never sleeps.
3. **R23 / R19–R22:** a `claude` rule or watch also matches Claude.app and never ends. `python3`, `npm`, root processes and LSUIElement apps (Docker, Ollama) never match or never update. The Mac either never sleeps or sleeps mid-job.
4. **R33 / R34 (= R72) / R6:** on macOS 27 the panel closes when Show in Dock changes, disappears when it is re-shown during its fade-out, and doesn't resize when the welcome card or row J appears.
5. **R30 / R31:** `insomnia run` undoes the caller's `nohup` and forwards SIGHUP to the child. A CLI-launched app applies "Start keeping awake at launch", which inverts `toggle` and makes `run` outlive its command.

**The reported symptom: "menu doesn't show after turning off Show in Dock".** Root cause found: **R33**, with **R34/R72** as an aggravating factor.

- `DockController.applyPresence()` calls `NSApp.setActivationPolicy(.accessory)` and does nothing else. The comment there claims frontmost windows stay frontmost, but no code does that.
- A probe on this Mac showed the switch deactivates the app synchronously, within about 4 ms. `PanelHost.windowDidResignKey` then finds no key window and closes the panel. The Settings window drops behind the newly active app, and with `.accessory` it has no Dock icon or ⌘Tab entry.
- When the switch comes from the welcome card's "Where should I live?" picker, the panel closes before "Got it" can be pressed. `hasCompletedOnboarding` stays unset, so the welcome panel reopens on every launch. The user's defaults match this exactly: `showInDock = 0` and no `hasCompletedOnboarding`.
- Separately, **R34/R72**: re-showing the panel during its 120 ms fade-out lets the stale fade-out completion order the new window out, while the app still thinks the panel is open.
- Both problems are transient: the next click opens the panel normally. That matches the user's follow-up that it "shows up now".
- Ruled out as the cause, though still worth fixing: R95 (the hidden-item card steals key on first launch) and R92 (Dock "Open Panel" anchors at the menu bar item).

## 2. Findings table

| ID | Sev | Verdict | File:line | Title |
|---|---|---|---|---|
| R1 | major | CONFIRMED | Makefile:46 | `make uninstall` never resets SleepDisabled, yet deletes the marker and the safety nets |
| R39 | major | CONFIRMED | Sources/Insomnia/UI/LidSetupView.swift:259 | "Try it" test drive permanently turns lid mode on and starts a hold it never ends |
| R40 | major | CONFIRMED | Sources/Insomnia/UI/LidSetupView.swift:250 | Finishing setup from the welcome card starts an indefinite awake session |
| R33 | major | CONFIRMED | Sources/Insomnia/UI/DockController.swift:61 | Turning off Show in Dock deactivates the app, which closes the panel and buries Settings |
| R34 | major | CONFIRMED | Sources/Insomnia/UI/PanelHost.swift:201 | Re-showing the panel during its fade-out leaves it invisible while the app thinks it is open |
| R6 | major | CONFIRMED | Sources/Insomnia/UI/PanelView.swift:37 | On macOS 27 the panel window doesn't resize when the welcome card or row J appears |
| R23 | major | CONFIRMED | Sources/Insomnia/Core/WatchMonitor.swift:232 | Process rule or watch for "claude" also matches Claude.app, so it never ends |
| R19 | major | CONFIRMED | Sources/Insomnia/Core/WatchMonitor.swift:573 | Process scan skips every process owned by another user |
| R20 | major | CONFIRMED | Sources/Insomnia/Core/WatchMonitor.swift:622 | "python3" never matches a `python3` command |
| R21 | major | CONFIRMED | Sources/Insomnia/Core/WatchMonitor.swift:627 | "npm" never matches, because npm's process.title overwrites argv[0] |
| R22 | major | CONFIRMED | Sources/Insomnia/Core/WatchMonitor.swift:405 | App rules for LSUIElement apps don't notice launch or quit |
| R12 | major | CONFIRMED | Sources/Insomnia/Core/AwakeEngine.swift:538 | Mission-report banner and lidReopened quip are wiped the moment they appear |
| R30 | major | CONFIRMED | Sources/Insomnia/App/CLI.swift:570 | `run` ignores nohup: resets the child's ignored SIGHUP and forwards SIGHUP to it |
| R7 | minor | CONFIRMED | Sources/Insomnia/App/AppDelegate.swift:127 | A second quit during terminateLater exits immediately and skips the lid release |
| R10 | minor | CONFIRMED | Sources/Insomnia/Core/Privileged/SudoersBackend.swift:224 | Sudoers safety daemon reads a missing SleepDisabled as 0 and skips the boot reset |
| R16 | minor | CONFIRMED | Sources/Insomnia/Core/Settings.swift:130 | An out-of-range stored hotkey value traps in Settings.init, so the app crashes at every launch |
| R47 | minor | CONFIRMED | Sources/Insomnia/Core/Notifier.swift:120 | A cached .denied lasts for the process lifetime and silently drops safety notifications |
| R74 | minor | CONFIRMED | Sources/Insomnia/Core/Privileged/SudoersBackend.swift:163 | A timed-out `sudo -n pmset … 1` can land after release disarms the watchdog |
| R90 | minor | CONFIRMED | Sources/Insomnia/Core/Privileged/LidReconciler.swift:190 | Sudoers launch recovery treats a stale marker as ownership and clears a foreign flag |
| R4 | minor | CONFIRMED | Sources/Insomnia/App/URLCommandHandler.swift:208 | Untrusted URL parameter names are written verbatim to the event log |
| R8 | minor | CONFIRMED | Sources/Insomnia/UI/Settings/HotKeyRecorder.swift:37 | Closing Settings mid-recording leaves the recorder running and the global hotkey off |
| R9 | minor | CONFIRMED | Sources/Insomnia/UI/PanelModel.swift:186 | Pokes are counted twice with different rules; the "cross-eyed" line can show without crossing |
| R13 | minor | CONFIRMED | Sources/Insomnia/Core/AwakeEngine.swift:874 | Wall-clock jumps count as awake time and permanently corrupt Stats and lid counters |
| R14 | minor | CONFIRMED | Sources/Insomnia/Core/AwakeEngine.swift:925 | The escalation quip after sleep uses the stale awakeSince from before sleep |
| R15 | minor | CONFIRMED | Sources/Insomnia/Core/PowerMonitor.swift:164 | Posting after each property change lets the engine read a half-updated power state |
| R17 | minor | CONFIRMED | Sources/Insomnia/Core/AwakeEngine.swift:510 | A user action while lid mode is in .error never retries (CLOSED_LID §7) |
| R24 | minor | CONFIRMED | Sources/Insomnia/Core/AssertionInspector.swift:118 | "Nothing. Your Mac is free to sleep." is unreachable because of WindowServer/powerd noise |
| R25 | minor | CONFIRMED | Sources/Insomnia/Core/WatchMonitor.swift:298 | Process rules have no grace period; a brief gap drops the hold and clears the eyes' pause |
| R26 | minor | CONFIRMED | Sources/Insomnia/UI/Settings/AutomationsTab.swift:260 | Running-app pickers in Automations show a stale list |
| R27 | minor | CONFIRMED | Sources/Insomnia/UI/WhileMenu.swift:194 | The PID… prompt names targets by proc_name ("2.1.310", "pid N (N)") |
| R31 | minor | CONFIRMED | Sources/Insomnia/App/CLI.swift:389 | A CLI-launched app applies "Start keeping awake at launch", inverting toggle and outliving run |
| R35 | minor | CONFIRMED | Sources/Insomnia/App/AppDelegate.swift:18 | Single-instance handover drops the URL command from a second copy |
| R37 | minor | CONFIRMED | Sources/Insomnia/UI/PanelComponents.swift:337 | Until… at 23:58/23:59 keeps the Mac awake 24 h from now |
| R38 | minor | CONFIRMED | Sources/Insomnia/UI/Settings/LidSafetyTab.swift:202 | The battery-floor slider writes on every drag tick and can end the session |
| R41 | minor | CONFIRMED | Sources/Insomnia/UI/LidSetupView.swift:224 | Sudoers setup ending in .partial/.daemonDisabled fails silently |
| R42 | minor | CONFIRMED | Sources/Insomnia/UI/Settings/LidSafetyTab.swift:68 | "Reset with password…" failures are silent; lastSetupError is never read |
| R43 | minor | CONFIRMED | Sources/Insomnia/UI/PanelModel.swift:538 | H′ "Off for this session" is missing for fixed CLI client holds |
| R44 | minor | CONFIRMED | Sources/Insomnia/UI/LidSetupView.swift:253 | The lid switch can't be turned off while setup is missing |
| R45 | minor | CONFIRMED | Sources/Insomnia/UI/Settings/GeneralTab.swift:179 | The launch-at-login error note never clears after the problem is fixed elsewhere |
| R48 | minor | CONFIRMED | Sources/Insomnia/Core/Notifier.swift:202 | The notification's "Allow Sleep" does nothing when a rule holds the Mac |
| R50 | minor | CONFIRMED | Sources/Insomnia/Core/Narrator.swift:133 | Date lines are budget-gated and spend the 4 h budget, contrary to rule 10 |
| R51 | minor | CONFIRMED | Sources/Insomnia/Core/Narrator.swift:131 | Professional draws spend the quip budget, and most Professional pools are never shown |
| R52 | minor | CONFIRMED | Sources/Insomnia/Core/Notifier.swift:137 | Queued notifications never expire and bypass later gating |
| R53 | minor | CONFIRMED | Sources/Insomnia/Core/AwakeEngine.swift:320 | The target-exited notification shows the PID in title and body |
| R54 | minor | CONFIRMED | Sources/Insomnia/Core/Narrator.swift:119 | Narrator snapshots Calendar.current, so date windows ignore time-zone changes |
| R71 | minor | CONFIRMED | Tests/InsomniaTests/ClosedLidControllerTests.swift:109 | Lid-controller tests leak a temp directory per test |
| R72 | minor | CONFIRMED | Sources/Insomnia/UI/PanelHost.swift:207 | Showing the panel while it is open hides it, and the engine keeps ticking (same root cause as R34) |
| R75 | minor | CONFIRMED | Sources/Insomnia/Core/Privileged/SudoersBackend.swift:58 | The "rule works" probe can clear a foreign flag set between read and probe |
| R76 | minor | CONFIRMED | Makefile:36 | `make install` leaves the old instance running; "Open it" reactivates stale code |
| R77 | minor | CONFIRMED | Sources/Insomnia/App/AppDelegate.swift:168 | The URL handler drops links with a capitalised scheme |
| R78 | minor | CONFIRMED | Sources/Insomnia/UI/PanelModel.swift:424 | The awake battery-floor banner says "Lid mode off" when keeping awake stopped |
| R87 | minor | CONFIRMED | Sources/Insomnia/App/AppDelegate.swift:169 | A URL that cold-launches the app runs before wiring; panel/settings links do nothing |
| R88 | minor | CONFIRMED | Sources/Insomnia/Core/ClosedLidController.swift:212 | A cancelled Remove… or a Reset with password leaves lid mode off while still wanted |
| R89 | minor | CONFIRMED | Sources/Insomnia/Core/ClosedLidController.swift:434 | .error(.otherUser) never resumes after the other user releases |
| R92 | minor | CONFIRMED | Sources/Insomnia/UI/DockController.swift:264 | Dock "Open Panel"/"Until…" anchor at the menu bar item, not floating |
| R93 | minor | CONFIRMED | Sources/Insomnia/UI/DockController.swift:273 | The Dock header shows a dead "Reset with password…"; no reset item when stuck |
| R94 | minor | CONFIRMED | Sources/Insomnia/UI/Settings/AboutView.swift:163 | ⌘W doesn't close About or the Lid Mode setup window |
| R95 | minor | CONFIRMED | Sources/Insomnia/UI/HiddenItemCard.swift:64 | On first launch the hidden-item card closes the welcome panel |
| R96 | minor | CONFIRMED | Sources/Insomnia/UI/PanelModel.swift:565 | Sleep Now leaves the panel open across sleep |
| R97 | minor | CONFIRMED | Sources/Insomnia/UI/Settings/CLIInstallView.swift:272 | The "Not on your PATH" warning never clears |
| R99 | minor | CONFIRMED | Sources/Insomnia/App/CLI.swift:483 | A symlinked CLI never launches its own copy; the `open -a` branch is dead |
| R2 | minor | CONFIRMED | Sources/Insomnia/Core/Privileged/SudoersBackend.swift:306 | Process spawning is duplicated four ways next to the shared Spawn helper |
| R3 | minor | CONFIRMED | Sources/Insomnia/Core/Control/ControlServer.swift:578 | `insomnia why` re-implements WhyAwakeReport and disagrees with it |
| R5 | minor | CONFIRMED | Sources/Insomnia/App/URLCommandHandler.swift:112 | The URL duration parser diverges from the CLI parser |
| R11 | minor | CONFIRMED | Sources/InsomniaHelper/FlagController.swift:12 | The SleepDisabled reader and key are duplicated across targets |
| R18 | minor | CONFIRMED | Sources/Insomnia/Core/Models.swift:358 | Dead DeactivationReason cases, a dead flush filter, and a misleading Rule.options |
| R28 | minor | CONFIRMED | Sources/Insomnia/Core/WatchMonitor.swift:165 | Dead helpers, including a synchronous main-thread process scan |
| R29 | minor | CONFIRMED | Sources/Insomnia/Core/WatchMonitor.swift:436 | Every watch event is written to the unified log twice |
| R36 | minor | CONFIRMED | Sources/Insomnia/UI/Settings/SettingsWindowController.swift:23 | Settings is re-centred on every reopen; frame autosave never takes effect |
| R55 | minor | CONFIRMED | Sources/Insomnia/Core/Narrator.swift:262 | Dead or duplicated code in Narrator and Notifier |
| R79 | minor | CONFIRMED | Sources/Insomnia/Core/AwakeEngine.swift:983 | Four cap/duration formatters; the lid-cap notification and banner disagree |
| R80 | minor | CONFIRMED | Sources/Insomnia/Core/EngineHooks.swift:117 | One headline reached four ways; Narrator plain-copy wrappers are test-only |
| R81 | minor | CONFIRMED | Sources/Insomnia/UI/PanelModel.swift:135 | Milestone scaffolding fallbacks are unreachable |
| R82 | minor | CONFIRMED | Sources/Insomnia/UI/WhyAwakeMenu.swift:213 | The guard phrase is written three times |
| R83 | minor | CONFIRMED | Sources/Insomnia/UI/Theme.swift:62 | Dead declarations with no references |
| R84 | minor | CONFIRMED | Sources/Insomnia/UI/EpicMoments.swift:263 | EyeBags duplicates PanelState.bags and is test-only |
| R85 | minor | CONFIRMED | Sources/Insomnia/App/CLI.swift:222 | Three "h / min" remaining-time formatters |
| R86 | minor | CONFIRMED | Sources/Insomnia/UI/WhyAwakeMenu.swift:429 | Two identical closure-backed NSMenuItem subclasses |
| R91 | minor | CONFIRMED | Sources/Insomnia/Core/Privileged/LidReconciler.swift:158 | Dead lid API: LidReconciler.abandon() and isWatchingApproval |
| R58 | minor | CONFIRMED | Tests/InsomniaTests/HelperPolicyTests.swift:107 | The XPC requirement test checks neither the team pin nor the get-task-allow negation |
| R59 | minor | CONFIRMED | Tests/InsomniaTests/AwakeEngineTests.swift:457 | Nothing verifies that engine quit releases lid mode |
| R61 | minor | CONFIRMED | Tests/InsomniaTests/ClosedLidControllerTests.swift:378 | Launch recovery's foreign and stuck outcomes are untested |
| R62 | minor | CONFIRMED | Tests/InsomniaTests/ClosedLidControllerTests.swift:251 | Drift detection and the stuck re-check are never exercised |
| R63 | minor | CONFIRMED | Tests/InsomniaTests/ClosedLidControllerTests.swift:113 | lostWait and abandonWait are never told apart (both .zero) |
| R64 | minor | CONFIRMED | Tests/InsomniaTests/ClosedLidControllerTests.swift:280 | heartbeatHelperNotEngagedIsNotAFailure tests release, not heartbeat |
| R65 | minor | CONFIRMED | Tests/InsomniaTests/ClosedLidControllerTests.swift:132 | Coalescing of rapid desire flips is never tested |
| R66 | minor | CONFIRMED | Tests/InsomniaTests/ReviewFixTests.swift:30 | The URL `on` never-lid rule (Decision 10) is untested at the perform level |
| R67 | minor | CONFIRMED | Tests/InsomniaTests/PersonalityPolishTests.swift:67 | nightVisionOncePerDay depends on the local time zone (fails in Asia/Tokyo) |
| R68 | minor | CONFIRMED | Tests/InsomniaTests/ClosedLidControllerTests.swift:341 | The displaySleepNow negative check after one yield proves little |
| R69 | minor | CONFIRMED | Sources/Insomnia/Core/AwakeEngine.swift:775 | The foreign-flag notification writes UserDefaults.standard, so it can't be tested |
| R70 | minor | CONFIRMED | Tests/InsomniaTests/ControlTests.swift:365 | Socket auth and abuse paths are untested; the symlink test accepts any error |
| R100 | minor | CONFIRMED | Tests/InsomniaTests/CLITests.swift:168 | The CLIRunner.run/watch hold lifecycle has no end-to-end test |
| R98 | minor | PLAUSIBLE | Sources/Insomnia/App/CLI.swift:697 | `run`/`watch` never re-take the hold after Insomnia restarts |
| R32 | minor | PLAUSIBLE | Sources/Insomnia/App/URLCommandHandler.swift:237 | Any web page can force sleep via insomnia://sleep, overriding run/rule holds |
| R46 | minor | PLAUSIBLE | Sources/Insomnia/UI/LidSetupView.swift:157 | Two setup views share one approval poll |
| R49 | minor | PLAUSIBLE | Sources/Insomnia/Core/Notifier.swift:231 | willPresent returns [.banner] without .list |
| R73 | minor | PLAUSIBLE | Sources/Insomnia/Core/ClosedLidController.swift:200 | A cancelled approval-watch task can clear its replacement's handle |
| R56 | minor | PLAUSIBLE | Sources/InsomniaHelper/HelperDaemon.swift:200 | The root helper's crash, hang and SIGTERM release paths have no tests |
| R57 | minor | PLAUSIBLE | Tests/InsomniaTests/SudoersBackendTests.swift:97 | The sudoers Watchdog script is only syntax-checked, never run |
| R60 | minor | PLAUSIBLE | Tests/InsomniaTests/ClosedLidControllerTests.swift:305 | The quit release-timeout → abandon path is untested |

## 3. Findings

### Major

#### R1: `make uninstall` never resets SleepDisabled, yet deletes the marker and the safety nets (Makefile:46)
- **What's wrong.** CLOSED_LID.md §9 says uninstall runs `sudo pmset -a disablesleep 0`. The target never does. In the sudoers branch it boots out the safety daemon, deletes `/etc/sudoers.d/zz_insomnia` and deletes the `lid-engaged` marker, without first quitting the running app. `--unregister-helper` returns early when no helper is registered, which is always true for sudoers builds, and it only looks in /Applications anyway.
- **Failure scenario.** An ad-hoc build in build/ has lid mode engaged and the user runs `make uninstall`. The flag stays 1. The app's later release (`sudo -n`) fails because the rule is gone, and the watchdog's resets fail the same way, so the result is `.stuck` or a quit with the flag still 1. The next launch has no marker, so the flag is treated as "foreign". No boot reset or battery backstop remains, and the Mac never sleeps on lid close, across reboots.
- **Evidence.** Makefile:46-53 has no pmset step. HelperCommands.swift:25-33 returns before `quitRunningApp`. Watchdog.swift:14-15 depends on the rule that was just deleted. The safety daemon has no TERM trap.
- **Fix.**
  1. Quit every running Insomnia by bundle id (osascript quit plus a pgrep wait loop), and move `quitRunningApp` above the `.notRegistered` return.
  2. If the marker exists, run `sudo pmset -a disablesleep 0` before the bootout and the rule removal (this keeps Decision 23).
  3. Delete the marker only after a verified reset, and also remove `/var/run/com.gdeml.insomnia.booted` and the staging leftovers.
  4. Better: have the Makefile call a headless app verb that runs `SudoersBackend.uninstallScript(reset: marker.exists)`, so the two uninstall paths can't drift. Fix the §9 comment.

#### R39: "Try it" test drive permanently turns lid mode on and starts a hold it never ends (LidSetupView.swift:259)
- **What's wrong.** `startDrive()` sets `settings.closedLidMode = true`. The engine treats that as the switch being flipped and starts a `defaultDuration` hold, which is indefinite by default. Nothing is undone when the drive finishes or the sheet closes. This includes Lid & Safety ▸ Test…, which passes `requestedLid: false`.
- **Failure scenario.** With lid mode off, the user runs Test…, closes and opens the lid, and clicks Done. Lid mode is now on for good, with an indefinite engaged session running. On AC there is no cap, so a lid closed later never sleeps.
- **Evidence.** LidSafetyTab.swift:34/94 pass `requestedLid: false`. LidSetupView.swift:259-278 has no cleanup. AwakeEngine.swift:897-909 activates on the false→true flip. Settings.swift:111 defaults the duration to 0 (indefinite).
- **Fix.** Never write the setting. Run the drive on its own fixed hold: `activate(.minutes(2), source: .panel, options: AwakeOptions(screen:…, lid: true))`. Explicit options set `followsSettings` to false. Start it only if nothing is awake, remember that the drive started it, and end it (only if it is still the drive's own hold) on survived/tooShort/notEngaged and on the done step's onDisappear. Only `finish()` with `requestedLid == true` may set `closedLidMode`.

#### R40: Finishing setup from the welcome card starts an indefinite awake session (LidSetupView.swift:250)
- **What's wrong.** `startLidSetupHandler` always opens setup with `requestedLid: true`, including from the welcome card's "Set up now". `finish()` then writes `closedLidMode = true`, and the engine starts a default (indefinite) hold. The code comment says it "engages if something's awake", which is not what happens.
- **Failure scenario.** On first run the user clicks "Set up now", approves and clicks Done. The Mac is now held awake "until you say so" with lid mode engaged, which they never asked for.
- **Evidence.** WelcomeCard.swift:111 → AppDelegate.swift:74 → LidSetupView.swift:224-251 → AwakeEngine.swift:897-907 (`!isAwake && canEngageLid` → activate).
- **Fix.** Make `startLidSetup(requestedLid:)` take a Bool. Only PanelModel `.setLid(true)` (the switch itself) passes true; the welcome card, Dock and Lid & Safety pass false. Fix the comment, and add a test that `finish()` with requestedLid false leaves the status `.asleep`.

#### R33: Turning off Show in Dock deactivates the app, which closes the panel and buries Settings (DockController.swift:61)
- **What's wrong.** `applyPresence()` only calls `setActivationPolicy(.accessory)`. A probe on macOS 27 showed this deactivates the app synchronously, so `PanelHost.windowDidResignKey` sees no key window and closes the panel (the macOS 14–26 popover closes too). Settings drops behind the next app, with no Dock icon or ⌘Tab entry. From the welcome card's picker, the panel closes before "Got it", so onboarding never completes and the panel reopens on every launch. **This is the root cause of the reported symptom.**
- **Failure scenario.** The user unchecks Show in Dock, or picks "Menu bar" in the welcome card, and the panel vanishes or Settings is lost behind other windows. The user's defaults (`showInDock = 0`, no `hasCompletedOnboarding`) match this path.
- **Evidence.** Settings.swift:60,138 → DockController.swift:44-48,65. PanelHost.swift:260-268. WelcomeCard.swift:44. EpicMoments.swift:122-126. AppDelegate.swift:117-121. The probe (`v2/host`) showed resign-key/resign-active within about 4 ms. A naive synchronous re-activate loses the race with the async resign→close.
- **Fix.**
  1. Add a `presenceSwitchInProgress` flag that makes PanelHost's resign-key close (and the popover's close) a no-op during the switch.
  2. In `applyPresence`, capture `wasActive` and `keyWindow` before the switch. After `setActivationPolicy`, wait 0.1 s, then reactivate and run `makeKeyAndOrderFront` on the saved window if `wasActive`, and clear the flag. Probe `host2 fix2` confirmed the panel stays visible and key.
  3. Optionally, apply the welcome picker's choice only on "Got it".
  4. Fix the misleading comments on lines 6 and 64.

#### R34: Re-showing the panel during its fade-out leaves it invisible while the app thinks it is open (PanelHost.swift:201) (R72 is the same bug)
- **What's wrong.** `show()` calls `close()` whenever `isVisible`, which is true for the whole 120 ms fade-out. close() starts fadeOut, then fadeIn on the same reused window sets alpha to 0. The interrupted fadeOut completion sees alpha < 0.01 and orders the window out. `setVisible(true)` has already run, so the model, the engine (1 Hz tick), EpicMoments and the key monitor all believe the panel is open. On macOS 27, close() inside `didBegin` also runs onClose, which cancels the session that just started. A close during the fade fires onClose and setVisible(false) twice.
- **Failure scenario.** The panel is open (welcome auto-open, hotkey, Dock, Spotlight reopen, insomnia://panel) and the user clicks the eyes on macOS 27. The panel blinks and vanishes, and the next click shows it. This matches the user's "briefly didn't appear, later it did".
- **Evidence.** PanelHost.swift:54,57,81-87,116,182-208. Probes `fadev3` and `fadeverify_ct` showed the ordered-out window at re-show delays of 0, 30 and 80 ms, every time.
- **Fix.**
  1. Add a `fadeGeneration` counter, incremented in both fades, and have fadeOut's completion orderOut only if the generation is unchanged.
  2. Add an `isOpen` flag, base `isVisible` on it, and make close() a no-op when it is not open.
  3. When re-showing an already-open window panel, reposition, re-key and fadeIn without calling close() or onClose. Call close() only when switching between popover and window.
  4. In `didBegin` on macOS 27, don't cancel the session that just began.

#### R6: On macOS 27 the panel window doesn't resize when the welcome card or row J appears (PanelView.swift:37)
- **What's wrong.** In window mode, `showWindow` sizes the window once from `hosting.fittingSize` and places the hosting view by frame inside an NSGlassEffectView. Content that changes later (the welcome card about 2.1 s after open, its dismissal, row J banners and reports in Professional) never resizes the window. A probe showed the window stays 320×80 while fittingSize reports 320×230. UX §2.1 says the panel grows for these.
- **Failure scenario.** On first launch, the welcome card slides in and the content overflows and is clipped at top and bottom. After "Got it", an empty glass gap remains.
- **Evidence.** StatusItemController.swift:47-51. PanelHost.swift:114-119,137,152-157. EpicMoments.swift:110-124.
- **Fix.** Host the panel with NSHostingController and `sizingOptions = [.preferredContentSize]`, or subclass NSHostingView. When the size changes, set the window frame with the top edge pinned (`y = oldMaxY - newH`), clamp it to `visibleFrame`, animate unless Reduce Motion is on, and resize the glass and hosting views with autoresizing or constraints. Route the Reduce Transparency `embed` branch through the same path, and check HiddenItemCard.swift:90-146.

#### R23: Process rule or watch for "claude" also matches Claude.app, so it never ends (WatchMonitor.swift:232)
- **What's wrong.** Claude.app's executable basename is `Claude`, which lowercases to "claude". Suggested filters GUI app PIDs, but `performScan`, `isRunning`'s fallback and `WhilePrompt.lookup` don't.
- **Failure scenario.** Claude.app is open and the user babysits "claude". The CLI exits, but the desktop app's PID keeps the watch alive, so the Mac never sleeps. A rule for "claude" stays on permanently.
- **Evidence.** A probe found pid 53135 `/Applications/Claude.app/Contents/MacOS/Claude` in `scan(["claude"])`. ProcessMatcher.candidateNames ~620-632. performScan line 228.
- **Fix.** On the main actor after the scan, drop hits whose PID belongs to an NSRunningApplication (the `apps` cache). Use one shared helper for performScan, isRunning and lookup. If every hit is an app, have the prompt say "That's an app, use Running apps". Don't rely on a `.app/Contents/MacOS` path heuristic. Add a WatchMonitor test, and note the tradeoff in ARCHITECTURE.md:261.

#### R19: Process scan skips every process owned by another user (WatchMonitor.swift:573)
- **What's wrong.** `ProcessTable.scan` skips any PID for which `proc_pidinfo(PROC_PIDTBSDINFO)` fails, and on macOS 27 it fails with EPERM for every other user's process. `PROC_PIDT_SHORTBSDINFO` and `proc_pidpath` both work. About 245 processes on this Mac are invisible to the scan, despite the doc comment and ARCHITECTURE.md:261.
- **Failure scenario.** "While process rsync runs" with `sudo rsync …` never turns on, and the Mac idle-sleeps mid-backup. Process name… says "No running process named rsync".
- **Evidence.** Probe `bsdv2/p.c`: TBSD r=0 errno=1 for launchd, powerd and WindowServer; shortok 245, pathok 245.
- **Fix.** Use SHORTBSDINFO as the per-PID gate (uid, status, skip SZOMB, comm). Call TBSDINFO only for your own uid. Candidates for other users' processes are {comm, basename(proc_pidpath)}. Key the cache by `PROC_PIDUNIQIDENTIFIERINFO` p_uniqueid, or by pid+path, never by pid alone. Add a live test that finds pid 1 "launchd", and fix the comment at :499-503.

#### R20: "python3" never matches a `python3` command (WatchMonitor.swift:622)
- **What's wrong.** Homebrew and /usr/bin `python3` re-exec into `…/Python.framework/Versions/3.x/…/Python.app/Contents/MacOS/Python`. proc_name, the path basename and argv[0] then all give "python", never "python3". So the Suggested "python3" entry is dead.
- **Failure scenario.** The user runs `python3 train.py` and a rule for "python3" never fires, so the Mac sleeps mid-job.
- **Evidence.** Probe `pn.c` against both installs. No aliasing anywhere in Sources. The existing test at WatchMonitorTests.swift:80-81 uses an unrealistic argv.
- **Fix.** In `candidateNames`, when the path or argv[0] matches `/Python3?\.framework/Versions/(\d+)\.(\d+)/`, add "python<maj>" and "python<maj>.<min>". Add tests using the real Homebrew and CLT paths.

#### R21: "npm" never matches, because npm's process.title overwrites argv[0] (WatchMonitor.swift:627)
- **What's wrong.** npm sets process.title, so argv becomes `["npm run build","","",""]`. The candidates are {node, "npm run build"}, never "npm".
- **Failure scenario.** `npm run build` is running, but Suggested never lists npm and a rule for "npm" never fires.
- **Evidence.** A KERN_PROCARGS2 probe on node v23.10/npm 10.9.2 returned argc 4 `["npm run build","","",""]`. The test at WatchMonitorTests.swift:78 uses the un-retitled argv.
- **Fix.** Only for retitled processes (an interpreter base, no script argument, argv[0] containing a space and no "/", or all remaining argv entries empty), also add the basename of argv[0]'s first whitespace token. Don't do this for every argv[0], or "Google Chrome" would yield "google". Add a positive test and a negative test with a space-containing path.

#### R22: App rules for LSUIElement apps don't notice launch or quit (WatchMonitor.swift:405)
- **What's wrong.** `apps` is refreshed only on the didLaunch/didTerminate notifications, on wake and on grace expiry. AppKit doesn't post those for LSUIElement apps such as Docker, Ollama and Google Drive. Only KVO on `runningApplications` sees them.
- **Failure scenario.** "While Docker is running": the user quits Docker and the hold stays all night. Launching Docker doesn't turn the rule on.
- **Evidence.** Probe `v4/o.swift`: the LSUIElement bundle produced only KVO changes. PlistBuddy confirms LSUIElement on the three apps.
- **Fix.** Store an `NSKeyValueObservation` on `NSWorkspace.shared.runningApplications` that calls `appsChanged()` (main-actor), replace the two notifications, coalesce bursts, invalidate it on teardown, and update the header table.

#### R12: Mission-report banner and lidReopened quip are wiped the moment they appear (AwakeEngine.swift:538)
- **What's wrong.** `ClosedLidController.powerChanged` calls `finishClosedRun()` (report → onChange → Banner.reopen plus the quip) before `setStatus(.engaged(lidClosed:false))`. The second pass sees a lid state change with `bannerIsFresh` already reset, so it clears the banner and the quip. `Banner.recovered` gets lost the same way when activateOnLaunch is on.
- **Failure scenario.** With an indefinite lid hold, closed for 10 minutes, opening the lid shows nothing. "While you were away…" never appears in its main use case.
- **Evidence.** ClosedLidController.swift:543-546,568-570. AwakeEngine.swift:538-539,690-694,737-738. An end-to-end probe with the real controller and reconciler showed banner .reopen and then nil.
- **Fix.**
  1. In powerChanged, call `setStatus(.engaged(lidClosed:))` before `finishClosedRun()`.
  2. In `start()`, show `.recovered` (and append the moment) after `refreshHelper()` and the activateOnLaunch activation, just before the final reevaluate. Alternatively, exempt `.recovered` from auto-clear.
  3. Add an engine test that copies the report→status order.

#### R30: `run` ignores nohup: resets the child's ignored SIGHUP and forwards SIGHUP to it (CLI.swift:570)
- **What's wrong.** `run` registers EVFILT_SIGNAL for INT, TERM, HUP and QUIT, sets them to SIG_IGN and forwards each one with kill(). kqueue still reports signals that are ignored. spawn() also SETSIGDEFs all four, so a caller's `nohup`, and the INT/QUIT a non-interactive shell ignores for background jobs, are undone twice.
- **Failure scenario.** `nohup insomnia run -- ./job &`, then close the terminal: the job dies. `nohup ./job &` would survive.
- **Evidence.** Probe `nohupprobe.c`: "entry SIGHUP ignored=1 / kqueue reported SIGHUP: 1 / child signaled=1 sig=1".
- **Fix.** Record the original dispositions at the top of main.swift, before `signal(SIGPIPE, SIG_IGN)`. Forward, ignore and SETSIGDEF only the signals that weren't SIG_IGN on entry (SIGPIPE likewise). restoreSignals() should restore the recorded disposition, not SIG_DFL. Pass the computed set to spawn(). Add a CLITests case.

### Minor: safety

#### R7: A second quit during terminateLater exits immediately and skips the lid release (AppDelegate.swift:127)
- **What's wrong.** While `.terminateLater` is pending (lid release, up to 2 s), a second `terminate:` skips the delegate and exits right away. The XPC release and readback haven't finished and the marker isn't deleted.
- **Failure scenario.** The user double-clicks Quit, or SIGTERM or `pkill` arrives during the pending quit. The verified release is skipped and the next launch shows a spurious "recovered" banner.
- **Evidence.** Probe `v2q/p.swift`: "shouldTerminate 1 … terminate; mode=NSModalPanelRunLoopMode … willTerminate", and the reply line never prints. There is no guard in AppRouter.quit, the ⌘Q binding, or the panel Quit button.
- **Fix.** Use an `NSApplication` subclass (main.swift) that overrides `terminate(_:)` to ignore calls while `terminationPending`, set in applicationShouldTerminate. That covers the Dock Quit, logout and `NSRunningApplication.terminate()` Apple-event paths that a caller-side guard would miss.

#### R10: Sudoers safety daemon reads a missing SleepDisabled as 0 and skips the boot reset (SudoersBackend.swift:224)
- **What's wrong.** `grep -q '"SleepDisabled" = Yes' || { touch $B; exit 0; }` treats empty or absent ioreg output as 0 and consumes the once-per-boot marker. The root helper does the opposite: it resets unless it reads a verified 0, as §2.5 requires.
- **Failure scenario.** The Mac crashes with lid mode engaged (saved flag = 1). At boot the daemon runs before powerd publishes SleepDisabled, touches B, and the flag stays 1 for the whole boot.
- **Evidence.** SudoersBackend.swift:224-229 versus HelperDaemon.swift:79 and FlagController.read() returning nil when absent. The race couldn't be tested on a real boot (read-only review), but nothing orders the daemon after powerd.
- **Fix.** At boot (B missing), reset unless ioreg shows `= No`, and touch B only after `pmset -a disablesleep 0` succeeds, so a failure retries in 60 s. After boot, only a verified `Yes` reaches the backstop. Update CLOSED_LID.md §2.7 and add a stub-ioreg test.

#### R16: An out-of-range stored hotkey value traps in Settings.init (Settings.swift:130)
- **What's wrong.** `UInt32(int(...))` traps on negative values or values above UInt32.max, and `Settings.shared` is the first thing launch touches.
- **Failure scenario.** After `defaults write com.gdeml.Insomnia hotKeyCode -int -1`, the app crashes at every launch.
- **Evidence.** A probe got "Negative value is not representable" (exit 133). The app's own writes are always in range, so only outside edits or imports trigger it.
- **Fix.** Use `UInt32(exactly:) ?? default` for both values. Don't use `clamping`, because -1 would become 0, the 'A' key.

#### R47: A cached .denied lasts for the process lifetime and silently drops safety notifications (Notifier.swift:120)
- **What's wrong.** `authorization` is read once at setUp. `post()` drops everything while the cache says `.denied`, and nothing re-reads the status after the user enables notifications in System Settings.
- **Failure scenario.** The user clicked Don't Allow, then later turned notifications on. lid-stuck ("Your Mac won't sleep…") and the battery-floor notifications are still dropped until relaunch.
- **Evidence.** Notifier.swift:52,76-111,120-124. requestAuthorization has only three call sites.
- **Fix.** For `.denied`, call deliver() anyway: macOS enforces permission itself, and deliver() already logs `notificationsNotAllowed`. Keep the queue only for `.unknown`/`.notDetermined`. Don't rely on didBecomeActive, which may not fire for an accessory app.

#### R74: A timed-out `sudo -n pmset … 1` can land after release disarms the watchdog (SudoersBackend.swift:163)
- **What's wrong.** After the 5 s timeout, Spawn SIGKILLs `sudo` only, and its root `pmset` child keeps running. engage returns -1, release resets, reads back 0, disarms the watchdog and deletes the marker. The orphaned `… 1` then lands with no watchdog and no marker.
- **Failure scenario.** Under heavy load, engage reports commandFailed, and later SleepDisabled=1 is treated as foreign and never reset until the next boot or the 10% backstop.
- **Evidence.** Spawn.swift:101-105. sudo 1.9.17p2 keeps the user's ruid, so the parent can be SIGKILLed while the child survives. SudoersBackend.release 175-187. LidReconciler 108-113,133-134.
- **Fix.** In engage, on rc -1 with an armed watchdog, move it to `abandoned` and call `abandon()` so its reset / sleep 6 / reset covers the late set. Optionally give `sudo` a graceful SIGTERM-then-wait timeout, so it reaps pmset before returning.

#### R90: Sudoers launch recovery treats a stale marker as ownership and clears a foreign flag (LidReconciler.swift:190)
- **What's wrong.** Sudoers `ownsFlag()` is just `marker.exists`. When the app dies, the watchdog resets the flag but never deletes the marker, so a later foreign `disablesleep 1` gets "recovered" (cleared) at the next launch. That breaks Decision 23.
- **Failure scenario.** Insomnia crashes and the watchdog resets the flag. The user then enables Amphetamine's closed-display mode. Insomnia relaunches, clears Amphetamine's flag, and the Mac sleeps in the bag.
- **Evidence.** LidMarker.delete is called only from LidReconciler. The Watchdog env is PATH only. SudoersBackend.swift:208. The quit-timeout abandon path leaves the same stale marker.
- **Fix.** Pass `M` (the marker path) and `P` (the app pid) in the watchdog env. After the second, verified reset (restructure the `exec`), delete the marker only if its first field still equals P, so a newer instance's marker is never removed. Don't treat "recorded pid dead" as foreign, because it always is at launch.

### Minor: security

#### R4: Untrusted URL parameter names are written verbatim to the event log (URLCommandHandler.swift:208)
- **What's wrong.** Ignored or redacted query names (percent-decoded, newlines included) go into EventLog and os_log `.public` without sanitising. `EventLog.text()` joins entries with "\n".
- **Failure scenario.** A web page opens `insomnia://on?for=1m&x%0A2026-10-31 15:01:12  lid  engaged (readback ✓)=1`, and a forged log line appears in Diagnostics ▸ Copy.
- **Evidence.** URLCommandHandler 55-58,104,207-208,247-255. EventLog 37-59. The CLI is already protected by `sanitizedLabel`.
- **Fix.** Move `sanitizedLabel` into a shared helper and apply it in `record()` (cap each name at about 40 characters, list at most 5 names with "+N more"). As defence in depth, have `EventLog.log` replace control and newline characters for every source.

### Minor: behaviour (correctness, UX, lifecycle, concurrency)

#### R8: Closing Settings mid-recording leaves the recorder running and the global hotkey off (HotKeyRecorder.swift:37)
- **What's wrong.** The session ends only on Esc, Delete, a combo, a click, or `onDisappear`. SwiftUI doesn't call onDisappear when a hide-only window closes (probe `rec/main.swift`). The app-wide key monitor never checks `event.window`.
- **Failure scenario.** The global hotkey stays off, and the next ⌘-combo in any Insomnia window (e.g. ⌘Q in the panel) becomes the new system-wide hotkey. Esc in the panel is swallowed.
- **Fix.** In `start()`, capture `NSApp.keyWindow`, observe its willClose and didResignKey and call `stop()` on either, remove those observers in `finish()`, and pass through events whose `event.window !==` the captured window.

#### R9: Pokes are counted twice with different rules (PanelModel.swift:186)
- **What's wrong.** The engine uses a gap chain (each click within 8 s of the last) for the quips and the 50× badge. PanelModel uses a rolling 8 s window and crosses the eyes only at exactly 20.
- **Failure scenario.** Clicking every 0.6 s gives "Now I'm cross-eyed" at 20 clicks, but the window holds at most 14, so the eyes never cross.
- **Fix.** Delete `PanelModel.pokes`/`countPoke()`. Add `pokeCount` to PanelState from the engine and bump `crossEyes` after the handler when it equals 20 (not in Professional). Keep the engine's gap chain (the 50× badge depends on it) and reword UX §9 to "each within 8 s of the last". Add a test.

#### R13: Wall-clock jumps count as awake time and permanently corrupt Stats and lid counters (AwakeEngine.swift:874)
- **What's wrong.** accountTime, LidCloseCounters.advance and the escalation use wall-clock deltas. The NSSystemClockDidChange handler just re-evaluates, which credits the whole jump. Milestones are spent permanently and `bagSeconds` can trip the lid cap.
- **Failure scenario.** A probe moved the clock forward 30 days: stats.awake = 2,592,000 s and the quip became awake(72 h). Backward jumps only lengthen `.minutes` holds.
- **Fix.** Record a monotonic anchor (`systemUptime`) with each evaluation. On clock change, compute the skew against the elapsed uptime and shift accountedUntil, awakeSince, counters.since and the quip anchors. Keep hold `end` as a wall-clock date. Backstop: cap each credit at the elapsed uptime. Don't just reset `accountedUntil`, which loses real time.

#### R14: The escalation quip after sleep uses the stale awakeSince (AwakeEngine.swift:925)
- **What's wrong.** Passes that arrive before the engine's didWake (PowerMonitor's observer, clamshell, DarkWake IOPS) run handleEscalation against the awakeSince from before sleep.
- **Failure scenario.** A lid-close sleep from 18:00 to 08:00 produces the quip "awake 8 hours".
- **Fix.** Add `guard accountedUntil != nil` at the top of `handleEscalation` (it is nil between willSleep and didWake), and add a regression test.

#### R15: Posting after each property change lets the engine read a half-updated power state (PowerMonitor.swift:164)
- **What's wrong.** refreshPowerSources/ThermalAndLPM/Lid post after each field, and queue:.main observers run inline (probe `nc_probe.swift`).
- **Failure scenario.** In a bag at 21% with a 20% floor, plugging in AC reads 20% with isOnAC still false. batteryFloor trips, the flag is released and latched, and the Mac sleeps on AC.
- **Fix.** Add a nestable `batched {}` helper (snapshot, depth counter, post once) and wrap every refresh entry point in it. That also removes `suppressPosting`.

#### R17: A user action while lid mode is in .error never retries (AwakeEngine.swift:510)
- **What's wrong.** setDesired is called only when the desired value changes, and the controller leaves .error only on `retryRequested`. `pendingUserLidAction` never reaches the controller. CLOSED_LID §7 says "Retry or user action → .engaging".
- **Failure scenario.** Lid mode is in .error(.overridden) and the user picks "2h". The hold is replaced, lid mode stays in error, and the Mac sleeps on lid close.
- **Fix.** Add `retry()` to LidControlling. In step 6, capture `userAction` and, when desired and the controller is in `.error(e)` with e not foreignFlag/otherUser, call `retry()`. Add an engine test.

#### R24: "Nothing. Your Mac is free to sleep." is unreachable (AssertionInspector.swift:118)
- **What's wrong.** `isSystemNoise` filters only one powerd name. WindowServer's UserIsActive (HID tickle) and powerd's delayDisplayOff are always present after input, including the ⌥-click itself.
- **Fix.** Filter by (process, type): WindowServer + UserIsActive, and powerd's internal display assertions. Keep UserIsActive from other processes. Add fixture tests using the real dictionaries.

#### R25: Process rules have no grace period (WatchMonitor.swift:298)
- **What's wrong.** One empty scan drops the rule. The engine then clears its pause, and the next scan recreates the hold with a new start time.
- **Failure scenario.** A `for f in *.mov; do ffmpeg …` loop silently ends the eyes' pause.
- **Fix.** Add a per-rule `unmatchedSince` and keep the rule satisfied for `grace`. Extend `scheduleGrace` and `graceExpired` to cover rules (rescan or recompute). Drop entries for removed rules. Add tests and update the docs.

#### R26: Running-app pickers in Automations show a stale list (AutomationsTab.swift:260)
- **What's wrong.** `runningApps()` reads NSWorkspace directly while the Menu content is built. SwiftUI caches Menu content until the parent re-renders (probe `menuprobe`), and every icon is loaded.
- **Fix.** Add an observed `regularApps` to WatchMonitor (regular apps only, excluding self, sorted, no icons, assigned only on change) and read it in RunningAppItems.

#### R27: The PID… prompt names targets by proc_name (WhileMenu.swift:194)
- **What's wrong.** claude's proc_name, and even its path basename, is "2.1.310". Root PIDs fall back to "pid N", which gives "pid N (N)".
- **Fix.** Add a shared resolver: basename(argv[0]) for your own uid, then basename(proc_pidpath), then proc_name. Use an empty name with displayName "pid N". Use it in WhilePrompt and in `insomnia watch --pid` (CLI.swift:627). Update WatchMonitorTests:342.

#### R31: A CLI-launched app applies "Start keeping awake at launch" (CLI.swift:389)
- **What's wrong.** `open -g` with no marker means `start()` activates the launch hold before the CLI's request is served.
- **Failure scenario.** `insomnia toggle` prints "Sleep allowed" (inverted), and `insomnia run -- make` leaves a forever hold behind after make exits.
- **Fix.** Launch with `open -g --env INSOMNIA_LAUNCHED_BY_CLI=1` (or `--args --from-cli` accepted by LaunchCommand), and have AppDelegate pass `skipActivateOnLaunch` to `AwakeEngine.start`. Update ARCHITECTURE.md and UX §4.1.

#### R35: Single-instance handover drops the URL command from a second copy (AppDelegate.swift:18)
- **What's wrong.** A second registered copy launched for a URL exits in willFinishLaunching before the GURL event is read, and forwards a fixed `insomnia://panel`. (The verifier showed the "relaunch while quitting" half is LaunchServices behaviour, not this code.)
- **Failure scenario.** A Shortcut opens `insomnia://activate?for=1h` through a non-running build copy, and nothing happens.
- **Fix.** Register the GURL handler first. In handover mode, forward the received URL with `NSWorkspace.open([url], withApplicationAt: other.bundleURL)`, otherwise forward `insomnia://panel`, then exit from didFinishLaunching without touching the lid, socket or status item.

#### R37: Until… at 23:58/23:59 keeps the Mac awake 24 h from now (PanelComponents.swift:337)
- **What's wrong.** Rounding up to 5 minutes gives hour 24. `Calendar.nextDate` returns nil, and the code falls back to `now + 86400`.
- **Failure scenario.** At 14:53, picking 23:59 ends the hold tomorrow at 14:53.
- **Fix.** Use `total = (h*60 + roundedMin) % 1440`. Also normalise inside `AwakeDuration.nextOccurrence`, and log instead of silently falling back.

#### R38: The battery-floor slider writes on every drag tick and can end the session (LidSafetyTab.swift:202)
- **What's wrong.** Every tick posts a settings change and re-evaluates. Passing the current battery level ends the manual hold permanently and latches the lid guard (hysteresis +3).
- **Fix.** Keep a draft `@State` value and commit it on `onEditingChanged(false)`, or immediately when not editing (keyboard/VoiceOver changes). Use `step: 1`. Optionally skip `store()` when the value is unchanged.

#### R41: Sudoers setup ending in .partial/.daemonDisabled fails silently (LidSetupView.swift:224)
- **What's wrong.** `advance()` has `default: break`, so the sheet stays on step 1 with no message and asks for the password again on each click.
- **Fix.** Map `.daemonDisabled` to the existing `.approve` step (Login Items copy and 1 s re-check), including from `initialStep`. Map `.partial` to "Setup didn't finish" with Repair. Replace the default with a generic problem message.

#### R42: "Reset with password…" failures are silent (LidSafetyTab.swift:68)
- **What's wrong.** All three callers discard the result. `lastSetupError` and `isWatchingApproval` are write-only, and there is no busy guard.
- **Fix.** Make `resetWithPassword()` throw `LidSetupError` (and return early if the flag is already 0). Route it through `run(.reset)` in LidSafetyTab, guard the panel and notification paths against repeated clicks, and surface failures. Delete the two dead properties.

#### R43: H′ "Off for this session" is missing for fixed CLI client holds (PanelModel.swift:538)
- **What's wrong.** `fixedHoldWithoutLid` looks only at the manual hold.
- **Failure scenario.** The lid switch is on and `insomnia run make` runs without --lid. The switch shows on, H′ is empty, and the Mac sleeps on lid close (UX §5 / UX.md:373).
- **Fix.** Use `!holds.isEmpty && !holds.contains { $0.options.lid }`, and add a test.

#### R44: The lid switch can't be turned off while setup is missing (LidSetupView.swift:253)
- **What's wrong.** `lidToggleOn` is false unless the helper is installed, so the switch and the L key only open setup. Not Now never clears `closedLidMode` (UX §6 says the toggle reverts).
- **Fix.** In `notNow()` (which also covers a cancelled prompt) and in the close-without-finish path, set `closedLidMode = false` when the helper isn't installed and the step isn't `.done`. Optionally offer Remove… for `.requiresApproval`.

#### R45: The launch-at-login error note never clears (GeneralTab.swift:179)
- **Fix.** Record `requested` in `set()`, and in `refresh()` clear the error once `isOn == requested`. Don't clear on `.enabled` alone, because a failed unregister also stays `.enabled`.

#### R48: The notification's "Allow Sleep" does nothing when a rule holds the Mac (Notifier.swift:202)
- **What's wrong.** `.stop` calls `deactivate()`, which returns early without a manual or babysit hold and never pauses rules.
- **Failure scenario.** In a bag, the lid-heat notification says "Allow Sleep", the user taps it, and nothing happens.
- **Fix.** Use `if engine.isAwake { engine.toggle(source: .notification) }`. The guard matters, because toggle while asleep would activate. A cleaner option is a shared `allowSleep(source:)`. Update ARCHITECTURE.md:468.

#### R50: Date lines are budget-gated and spend the 4 h budget (Narrator.swift:133)
- **Fix.** Move the date roll into `Narrating.dateLine(_:now:)`. Have flushMoments try it for `.activated` after the earned moments and before the budget, without touching `lastRotatingQuip`. Do the same for idle. Consider a once-per-window cap and record it in PRODUCT §4. Add a fixed-seed test on Oct 31.

#### R51: Professional draws spend the quip budget, and most Professional pools are never shown (Narrator.swift:131)
- **Fix.** Have `line()` return nil for every Professional moment. Keep `lidEngaged` (used by `sample`) and the six notification pools, and delete the rest along with `durationPhrase`. Update NarratorTests :63-72/:139, TimeTests :176, UX §11 and PRODUCT rule 7. Clear the quip when the personality changes.

#### R52: Queued notifications never expire and bypass later gating (Notifier.swift:137)
- **Fix.** Re-check the session gate at drain time (inject a `shouldDeliver`). Timestamp entries and drop `ended`/`target-exited` after a few minutes. Have the engine clear stale outcomes on a new hold or engagement. Keep lidStuck, lidError, foreignFlag and recovered queued.

#### R53: The target-exited notification shows the PID (AwakeEngine.swift:320)
- **Fix.** Pass `FallbackCopy.shortName(target)` and delete the no-op Narrator.swift:311. Add an engine test expecting "ffmpeg finished".

#### R54: Narrator snapshots Calendar.current (Narrator.swift:119)
- **Fix.** Default to `Calendar.autoupdatingCurrent`. A TZ probe confirmed the snapshot keeps the zone from launch.

#### R71: Lid-controller tests leak a temp directory per test (ClosedLidControllerTests.swift:109)
- **What's wrong.** There are 1,040 `insomnia-lid-*` directories in $TMPDIR, 233 of them holding a marker.
- **Fix.** Make the suite a `@MainActor final class` with a `deinit` that removes `dir`, and add a `defer` cleanup in the two sudoers tests, or use a shared helper.

#### R72: Showing the panel while it is open hides it, and the engine keeps ticking (PanelHost.swift:207)
Same root cause and fix as **R34**. The verifier added the ticking consequence: AwakeEngine.setPanelVisible stays true and the 1 Hz tick runs until the next open and close. It also suggested guarding the fadeOut completion on `self.window === w && !model.isVisible` and adopting the session in `didBegin` when the panel is already visible.

#### R75: The "rule works" probe can clear a foreign flag (SudoersBackend.swift:58)
- **What's wrong.** It reads the flag as 0, then runs `sudo -n pmset -a disablesleep 0` on every status refresh, including every activation. A foreign set landing in between gets cleared, which breaks Decision 23.
- **Fix.** Probe with `sudo -n -l /usr/bin/pmset -a disablesleep 0` (list mode, no state change) and drop the pre-read and the cached fallback. If `listpw=always` breaks that, run the real probe only after install or repair. Fix the comment at :59 and CLOSED_LID.md:280/296.

#### R76: `make install` leaves the old instance running (Makefile:36; the reported line 738 doesn't exist)
- **What's wrong.** The bundle is swapped under a running process and "Open it" just reactivates the old one (single-instance handover).
- **Fix.** After lid-verify and before the `mv`, quit as the user (osascript quit plus a pgrep wait, aborting the swap on timeout). Relaunch with `open` if it was running, and update the message.

#### R77: The URL handler drops links with a capitalised scheme (AppDelegate.swift:168)
- **Fix.** Remove the case-sensitive `url.scheme == "insomnia"` check and let `URLCommand.parse` (already case-insensitive, and it logs rejections) decide. Verified live: `Insomnia://…` got no log line.

#### R78: The awake battery-floor banner says "Lid mode off" (PanelModel.swift:424)
- **Fix.** Replace both `showBanner(.batteryFloor(...))` calls with `.guardTripped(.awakeBatteryFloor)`, delete the case and its copy arm, update AwakeEngineTests:282, and add a copy test against UX §10.

#### R87: A URL that cold-launches the app runs before wiring (AppDelegate.swift:169)
- **What's wrong.** A probe confirmed the order willFinish → GURL → didFinish. `.panel` and `.settings` hit nil router handlers, and `.on` loses its eventLog and stats entries.
- **Fix.** Queue URLs in `pendingURLs` until a `didLaunch` flag is set at the end of applicationDidFinishLaunching, then flush. A minimal alternative is `DispatchQueue.main.async { handle(url) }`.

#### R88: A cancelled Remove… or a Reset with password leaves lid mode off while still wanted (ClosedLidController.swift:212)
- **What's wrong.** `uninstall()` releases before the prompt. On `.cancelled`, `.scriptFailed` or `.unregisterIncomplete`, nothing re-converges and the engine's desired value is unchanged. `resetWithPassword()` moves .stuck to .off without re-converging. The panel shows the switch on with an empty H′.
- **Fix.** In uninstall's serialized closure, on error set `removing = false` and `await converge()`. In resetWithPassword, `await converge()` after `.off`, as stuckCheck does. Update `releaseThatCannotClearIsStuck` (expect re-engage), add tests, and fix LidSafetyTab's "changes nothing" comment.

#### R89: .error(.otherUser) never resumes after the other user releases (ClosedLidController.swift:434)
- **Fix.** Widen the auto-retry to `.foreignFlag || .otherUser` when `flag == false && wantsEngaged`. Optionally refresh on `sessionDidBecomeActiveNotification`. Add a test.

#### R92: Dock "Open Panel"/"Until…" anchor at the menu bar item (DockController.swift:264)
- **What's wrong.** UX §2.6/§1.7 say these use the floating panel. On macOS 27 the panel has no session, so a menu bar click re-shows it instead of closing it.
- **Fix.** Add `AppRouter.showPanel(floating:)` and use it for both items. In `didBegin`, if the panel is already visible, cancel the session and close it (toggle).

#### R93: The Dock header shows a dead "Reset with password…" (DockController.swift:273)
- **Fix.** Build the header from `PlainCopy.subline(state).text` (no links) and remove the string stripping. When `lid == .stuck`, add an enabled "Reset Sleep with Password…" item and document it in UX §3.

#### R94: ⌘W doesn't close About or the Lid Mode setup window (AboutView.swift:163)
- **Fix.** Add a "File" menu with Close (⌘W, `performClose:`, nil target) to `makeMainMenu` and delete the `SettingsWindow` subclass. Update UX §2.5.

#### R95: On first launch the hidden-item card closes the welcome panel (HiddenItemCard.swift:64)
- **Fix.** If the panel is visible when the hidden check fires, mark the card pending without setting `hiddenItemCardShown`, and show it from the panel's onClose when the item is still hidden. Alternatively, show the message inside the floating panel.

#### R96: Sleep Now leaves the panel open across sleep (PanelModel.swift:565)
- **Fix.** Call `AppRouter.shared.closePanel()` before `sleepNow()`, and also close the panel on `NSWorkspace.willSleepNotification` in StatusItemController.

#### R97: The "Not on your PATH" warning never clears (CLIInstallView.swift:272)
- **Fix.** Re-check on activation while the result isn't `.onPath`, with an in-flight flag and a 15–30 s debounce. Add a "Check again" button. Reset the cached result on install and remove.

#### R99: A symlinked CLI never launches its own copy (CLI.swift:483)
- **What's wrong.** `Bundle.main` doesn't resolve symlinks (probe `symprobe`: bundleID nil), so the CLI always uses `open -b`. LaunchServices has five registered copies, so this can start build/ or .stage copies.
- **Fix.** Use `Bundle.main.executableURL?.resolvingSymlinksInPath()`, walk up to the `.app`, check its bundle id, and pass it to `open -g -a`. Fall back to `-b`. Don't use argv[0]. Fix the comment.

### Minor: simplification

#### R2: Process spawning is duplicated four ways (SudoersBackend.swift:306)
`runCapturingStdout` (a Foundation Process that sends SIGTERM on timeout with no escalation; the "never reaps" claim was rejected), `ShellPATH.run`'s hand-built sigset, `SystemSleep` (unreachable) and `WaitStatus` all duplicate Spawn. **Fix:** add stdout capture to `Spawn.run` and delete `runCapturingStdout`. Have ShellPATH use `Spawn.configureAttributes(extraFlags: SETSID)` and `withCStrings`. Delete SystemSleep. Move WaitStatus to Shared and build `decode` on it.

#### R3: `insomnia why` re-implements WhyAwakeReport and disagrees with it (ControlServer.swift:578)
The CLI and the report differ in at least six strings, and the CLI omits paused rules, so `why` says "Nothing" while ⌥-click lists a paused rule. `cliRows` is used only by tests. **Fix:** add `WhyAwakeInput.make(engine:settings:power:sleepDisabled:foreign:appPIDs:)` and build `whyRows()` from `WhyAwakeReport.build(...).cliRows` using the responder's injected dependencies, plus a `foreignProvider` hook. Delete `describe`, `HoldLine`, `sleepDisabledText` and `powerText`. Decide whether to keep the stuck hint and display count. Add a paused-rule test.

#### R5: The URL duration parser diverges from the CLI parser (URLCommandHandler.swift:112)
`1d` works in the CLI but not in URLs. `1h30` works in URLs but not in the CLI. The forever-word lists differ. **Fix:** `ControlDuration.minutes(_:cap:saturating:)`, and make the URL parser a thin wrapper (7-day cap, saturating). Decide on `1h30` for both, delete the URL loop and helpers, fold in `parseClock`, and update the tests.

#### R11: The SleepDisabled reader and key are duplicated across targets (FlagController.swift:12)
**Fix:** add `RootDomainRegistry.bool(_:)` in InsomniaShared (link IOKit) for FlagController and all three RootDomain properties. Delete the local key copy. Share the IOPS parse as well, which removes the "Is Present" drift. Update ARCHITECTURE.md.

#### R18: Dead DeactivationReason cases and Rule.options (Models.swift:358)
**Fix:** remove `.replaced`, `.clientDisconnected` and `.appQuit`, the flush filter (AwakeEngine:719), the Narrator branch (:150) and NarratorTests:152-153, and fix the comments. Either delete `Rule.options` or turn it into `options(closedLidMode:)` and use it at AwakeEngine:446.

#### R28: Dead helpers, including a synchronous main-thread scan (WatchMonitor.swift:165)
**Fix:** delete `WatchMonitor.isRunning` and `WhyAwakeMenu.reportText`. Share one power formatter that takes plain values (not `.live()` in a SwiftUI body) across WhyAwakeReport, DiagnosticsTab and ControlServer. Replace `thermalName` with `thermalText`.

#### R29: Every watch event is written to the unified log twice (WatchMonitor.swift:436)
Five sites (Watch, Engine, ControlServer, URL, AppDelegate) log to their own Logger and then to EventLog, which mirrors again. **Fix:** `EventLog.shared = EventLog(mirrorsToSystemLog: false)` (one line), or log through EventLog only. Also handle the lid/engine double.

#### R36: Settings is re-centred on every reopen (SettingsWindowController.swift:23)
**Fix:** call `w.center()` before `setFrameAutosaveName` in `makeIfNeeded`, and delete the `center()` call in `show()`.

#### R55: Dead or duplicated code in Narrator and Notifier (Narrator.swift:262)
**Fix:** delete the test-only wrappers and the no-op :311. Move the minutes-aware endingSoon title and the lidLPM/lidCap bodies into `FallbackCopy.notification`. Collapse handleResponse to `foreignFlag ? showWhyAwake() : showPanel()`.

#### R79: Four cap formatters; the notification says "4h" and the banner says "4 h" (AwakeEngine.swift:983)
**Fix:** use `PlainCopy.capText` at AwakeEngine:663/665 and delete `capLabel`. Keep one long form (`PlainCopy.capLong`) for LidSetupView:101 and the LidSafetyTab pickers.

#### R80: One headline reached four ways (EngineHooks.swift:117)
**Fix:** add `AwakeEngine.headline` and remove it from `Narrating` and the test doubles. Delete the Narrator plain wrappers. Build the Dock header from `PlainCopy.subline(s).text` (this also fixes R93's header). Keep `CLIFormat.fallbackHeadline`.

#### R81: Milestone scaffolding fallbacks are unreachable (PanelModel.swift:135)
**Fix:** call the router methods unconditionally (they already no-op on nil). Delete `lidSetupNudge`/`nudge:`, `stubWhileMenu`, `canOpenSettings` and its checks, the untilHandler else branch and `SystemSleep` (`await lidController?.sleepNow()`). Keep `lidController` optional for tests, and fix the EngineHooks and comment text.

#### R82: The guard phrase is written three times (WhyAwakeMenu.swift:213)
**Fix:** add one `PlainCopy.guardPhrase(_:batteryFloor:batteryCap:acCap:spoken:)` used by WhyAwakeReport (including the inline :132 copy), ControlServer and `lidSublabel` ("Paused · " + phrase, with acRequired as a special case).

#### R83: Dead declarations (Theme.swift:62)
**Fix:** delete `panelMaxHeight`, `rowGap`, `eyesWidth` (or use it in `eyesWidthRatio`), `isLidEngaged`, `reportText`, `setWelcomeVisibleForPreview`, Narrator:311 and the `PlainCopy.shortName` forwarder. Update ARCHITECTURE.md:605-607, and enforce the 340 pt cap if UX §2.1 needs it.

#### R84: EyeBags duplicates PanelState.bags (EpicMoments.swift:263)
**Fix:** use `bags = isAwake ? EyeBags.level(awakeFor:) : 0`, and add a test for the not-awake gate.

#### R85: Three "h / min" formatters (CLI.swift:222)
**Fix:** add `TimeFormat.hoursMinutes(_:)` and do the rounding at the call sites. Decide what a 0-minute cap shows. Keep the CLITests:95-99 expectations.

#### R86: Two identical closure-backed NSMenuItem subclasses (WhyAwakeMenu.swift:429)
**Fix:** delete `WhyAwakeMenu.ActionItem` and use `ActionMenuItem` at its three call sites. Optionally move it to a shared file.

#### R91: Dead lid API (LidReconciler.swift:158)
**Fix:** delete `LidReconciler.abandon()`. Keep the direct `backend?.abandon()` call, because routing it through the actor would queue it behind a stuck release. Delete `isWatchingApproval` (see R73).

### Minor: test gaps

#### R58: The XPC requirement test checks neither the team pin nor the negation (HelperPolicyTests.swift:107)
**Fix:** assert the exact requirement strings for the client and the helper. Remove the hand-kept copies in scripts/build.sh:142 and lid-verify.sh:41 by printing the string from a CLI verb. Skip the ad-hoc SecStaticCode idea, which fails on `anchor apple` regardless.

#### R59: Nothing verifies that engine quit releases lid mode (AwakeEngineTests.swift:457)
**Fix:** FakeLid counts `releaseForQuit` calls. Add a test: closedLidMode, activate, converge(closed), prepareForQuit, then count == 1 and no assertions. A second prepareForQuit leaves the count at 1.

#### R61: Launch recovery's foreign and stuck outcomes are untested (ClosedLidControllerTests.swift:378)
**Fix:** change `ownsFlag()` to return `Bool?` (HelperBackend gives `queryStatus()?.ownsFlag`, sudoers gives `marker.exists`), remove the downcast, and add `ownsAnswer` to the fake. Test foreign, nil→stuck and owned-but-can't-clear→stuck, all with the `.helper` kind.

#### R62: Drift detection and the stuck re-check are never exercised (ClosedLidControllerTests.swift:251)
A mutation run showed both inverted guards survive all 338 tests. **Fix:** add drift tests through an AC flip plus `powerChanged()` (override → `.error(.overridden)`; healthy → no-op). Add `stuckCheckForTesting()` and test stuck → flag 0 → re-engaged (desired) or `.off`.

#### R63: lostWait and abandonWait are never told apart (ClosedLidControllerTests.swift:113)
**Fix:** add an `abandonClearsFlagAfter` delay to the fake and use distinct waits (20 ms / 2 s) with a 300 ms late reset. Expect heartbeat and fireLost to end in `.error(.safetyNetLost)` and a plain release to end in `.stuck`.

#### R64: heartbeatHelperNotEngagedIsNotAFailure tests release (ClosedLidControllerTests.swift:280)
**Fix:** rename it to `releaseAnsweredNotEngagedIsNotAFailure`. Extract `HelperBackend.heartbeatError(_ rc:)` as a pure function and unit-test its mapping.

#### R65: Coalescing of rapid desire flips is never tested (ClosedLidControllerTests.swift:132)
The current code is correct. **Fix:** add burst tests that assert on `backend.calls` (an even burst ends with no calls; an odd burst ends with `["engage"]`), plus a flip that arrives mid-engage, expecting `["engage","release"]`.

#### R66: The URL `on` never-lid rule is untested at the perform level (ReviewFixTests.swift:30)
**Fix:** add `perform(.on(.forever, screen: nil))` with closedLidMode on and expect lid false, followsSettings false and no lid desire. Also cover the `screen: true` variant, or reuse the `noLid` local.

#### R67: nightVisionOncePerDay fails in Asia/Tokyo (PersonalityPolishTests.swift:67)
Reproduced with `TZ=Asia/Tokyo swift test`. **Fix:** anchor the timestamp to 09:00 local with `Calendar.current.date(bySettingHour:)`, or inject a calendar.

#### R68: The displaySleepNow negative check proves little (ClosedLidControllerTests.swift:341)
With the guard removed, the test still passed 3 times out of 30. **Fix:** have `powerChanged()` return the Task (`@discardableResult`) and await it before both assertions. Don't route it through `enqueue`, which would delay the blank behind an in-flight engage.

#### R69: The foreign-flag notification writes UserDefaults.standard (AwakeEngine.swift:775)
**Fix:** add `Settings.foreignFlagNotifiedBoot`, inject a `bootID` provider, and add three tests (first posts, same boot doesn't, new boot does). Note that a nil boot time ("unknown") suppresses the notification permanently.

#### R70: Socket auth and abuse paths are untested (ControlTests.swift:365)
**Fix:** assert the exact `.unsafeDirectory(...)` case for the symlink test. Add a `/usr` uid test (skipped as root). Send a line over 200 KB so the discard path is forced, and expect exactly the replies "request too long" then ok. Optionally test a peer reset (SO_LINGER) and a slow reader.

#### R100: The CLIRunner.run/watch hold lifecycle has no end-to-end test (CLITests.swift:168)
**Fix:** inject a connector into run, watch and beginHold. Write a background-thread fake socket server (not the main-actor ControlServer). Assert the hold line arrives before the child runs, EOF comes only after `sh -c 'sleep 0.3; exit 7'` exits, and the exit code is 7. Add a server-closes-mid-run variant. Do signal tests in a subprocess.

### Minor: PLAUSIBLE

#### R98: `run`/`watch` never re-take the hold after Insomnia restarts (CLI.swift:697)
- **What's wrong.** On EOF the CLI prints one line and keeps running with no hold. This looks intentional, but it contradicts "client hold for exactly the command's lifetime".
- **Failure scenario.** `insomnia run -- claude`, then a quit and relaunch of Insomnia. The new instance has no hold and the Mac idle-sleeps mid-task.
- **Fix.** Retry with EVFILT_TIMER (2 s) using `ControlClient.connect(path:)` only, never launching the app. On success, re-send the hold with a 3 s timeout, re-add READ, close the old fd and print "back in touch". Stop retrying on a refusal. Use one helper for run and watch, with a TIMER case in watch's dispatch.

#### R32: Any web page can force sleep via insomnia://sleep (URLCommandHandler.swift:237)
- **What's wrong.** `sleep` is a documented URL verb (UX.md:310), but it is the only URL verb that can interrupt client or rule holds.
- **Fix.** Refuse `sleep` from URLs while client or rule holds exist (add an engine accessor), log or notify the refusal, add a test, and add a threat-model row to CLOSED_LID §5. Don't add a confirmation dialog, which would break Shortcuts.

#### R46: Two setup views share one approval poll (LidSetupView.swift:157)
Closing one view cancels the shared poll. The didBecomeActive refresh recovers once the user returns to Insomnia, so "never moves to Done" was rejected and the effect is cosmetic. **Fix:** per-watcher tokens in a Set, with onAppear and onDisappear as the only callers. Alternatively, route `LidSetupWindow.show` to the existing sheet.

#### R49: willPresent returns [.banner] without .list (Notifier.swift:231)
Foreground notifications never reach Notification Center. The code matches UX §10 literally, so this is a spec decision. **Fix:** use `[.banner, .list]` (still no sound) and update UX.md:531 and ARCHITECTURE.md:467 together.

#### R73: A cancelled approval-watch task can clear its replacement's handle (ClosedLidController.swift:200)
The window is narrow. **Fix:** add `guard !Task.isCancelled else { return }` before the epilogue, and delete the unused `isWatchingApproval`.

#### R56: The root helper's crash, hang and SIGTERM release paths have no tests (HelperDaemon.swift:200)
Every path traced correctly today. **Fix:** move the remaining decisions into pure `HelperPolicy` functions (`statusOwnsFlag`, `shouldResetAfterDrop`, `terminateOutcome`, `startUpResetAction`) with table tests. Rely on device tests T1–T3, T10 and T17 for the timers. Fix the HelperPolicy.swift:12 claim.

#### R57: The sudoers Watchdog script is only syntax-checked (SudoersBackend Tests:97)
The current script works (manual run: EOF→2, disarm→0, silence→2, TERM→2). A broken script fails loudly through `safetyNetLost`, so the impact is lower than claimed. **Fix:** a behavioural test that substitutes the reset command and timeouts into `Watchdog.script` via replacingOccurrences (asserting each substitution happened) and drives it with `/bin/bash -c`. Optionally add an `arm(script:onExit:)` overload to test `stopSuperseded`.

#### R60: The quit release-timeout → abandon path is untested (ClosedLidControllerTests.swift:305)
**Fix:** add a release gate to LidFakeBackend, then test engage, blocked release, `releaseForQuit(timeout: 50ms)`, a prompt return with "abandon" called, and no re-engage after the gate opens. Drop the proposed "status .off + marker → release" test, because converge returns early while quitting. Either simplify line :145 or test its real behaviour.

## 4. Rejected findings

The six rejected findings were not passed to this report step, so their exact titles can't be listed here. The verifier notes on the surviving findings show the themes that verification rejected:
- **Claims LaunchServices contradicts.** For example, that a relaunch during quit is lost because of the single-instance check (R35: LaunchServices actually routes the reopen to the dying instance).
- **Overstated consequences.** For example, "never reaps" (R2), a sheet that "never moves to Done" (R46), a Watchdog regression leaving the Mac unable to sleep (R57), and a reorder at quit leaking the flag (R59). In each case another layer (the Foundation Process reaper, didBecomeActive refresh, safetyNetLost, or the controller's `quitting` latch) already covers it.
- **Proposed tests or fixes that wouldn't work.** For example, R60's "status .off + marker → release", R61's sudoers-kind foreign test, R65's out-of-order scenario, R33's synchronous-only reactivation, and R13's "reset accountedUntil" minimum fix.

## 5. Recommended fix order

1. **Safety: never leave the Mac unable to sleep.** R1 + R76 (the Makefile install and uninstall paths together). R39 + R40 + R44 (LidSetupView intent and cleanup). R10 + R74 + R75 + R90 (sudoers script and watchdog, with the CLOSED_LID §2.7 text). R88 + R89 + R17 (controller re-converge and retry). R7 (terminate guard). R16. R47 + R52 (Notifier delivery and queue).
2. **Panel and Dock presentation, the reported symptom.** R33, R34/R72 (one fix), R6, R95, R96, R92 + R93 (Dock menu), R94, R36, R8.
3. **Process and app watching.** R19 + R20 + R21 + R23 (ProcessTable/ProcessMatcher plus the app-PID filter in one pass), R22 + R26 (KVO and an observed `regularApps`), R25, R27, R24.
4. **Engine state, time and copy correctness.** R12, R13 + R14 (monotonic anchor and the sleep guard), R15, R78, R9, R37, R38, R43, R48, R50 + R51 + R54 (Narrator), R53, R49.
5. **CLI and URL surface.** R30, R31 + R99 (CLI launch path), R98, R87 + R35 + R77 (GURL handling in AppDelegate), R4, R32, then R5 and R3 (shared parsers and report).
6. **Setup and Settings feedback.** R41, R42 + R91 + R73 (ClosedLidController setup state), R45, R46, R97.
7. **Simplification sweep, after the above so it doesn't churn fixes.** R2, R11, R18 + R81 + R83 + R28 + R55 (dead code), R80 + R82 + R79 + R85 + R84 + R86 (copy and formatter consolidation), R29.
8. **Tests.** Add regression tests alongside batches 1–5, then close the gaps: R56, R57, R59, R60, R61, R62, R63, R64, R65, R58, R66, R68, R69, R70, R100, and the hygiene items R67 and R71.
