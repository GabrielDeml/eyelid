# Insomnia, simplified: design

Status: **implemented** on branch `simplify`. Overheat and low-battery protection are switches; everything is configurable in one Settings window.

## Why

Insomnia grew to ~30,400 lines: three personality tiers, an 886-line eye renderer, a Dock tile, rules, "While…",
"Why awake?", a hotkey, stats, a socket CLI, a URL scheme, a 5-tab Settings window, two lid-mode backends and 30 test
files. What's wanted is an on/off switch and three settings. This rewrite gets back to that.

## The product

A menu bar moon. Click it and a small panel opens:

```
╭──────────────────────────────────────╮
│ Awake                        (  ━━●) │   the switch: on = until turned off (or Settings' duration)
│ 1h 42m left · until 3:40 PM          │   or "Until you turn it off" / "Your Mac sleeps normally"
│ Screen on · Lid can close            │   the mode in words (only while on)
│ ⚠ Slept because the Mac got hot   ✕  │   only after a safety action
│ ──────────────────────────────────── │
│ Keep screen on                 (━●)  │
│ Stay awake with lid closed     (━●)  │   MacBooks only
│ Waiting for approval in System Settings ›   (caption only when needed)
│ When unplugged  Sleep with lid closed ⌃⌄    MacBooks only
├──────────────────────────────────────┤
│ Settings…              Quit Insomnia │
╰──────────────────────────────────────╯
```

On a desktop Mac the panel is just the header and *Keep screen on*.

- **The switch** next to the state toggles: on = until turned off, or for Settings' *Turning on keeps awake* duration
  (Return toggles too). **Right-click the moon** toggles without opening the panel. No timer buttons in the panel.
- **Keep screen on** (default on): also hold the display awake.
- **Stay awake with lid closed** (default off): sets the system's `SleepDisabled` flag while Insomnia is on.
  Turning it on while Insomnia is off also turns Insomnia on, so the switch always means what it says.
  First time: registers the existing helper and opens System Settings ▸ Login Items. The switch stays on with the
  caption *Waiting for approval in System Settings ›*; the app re-checks every 2 s for 3 minutes and whenever the
  panel opens, and lid mode engages once allowed. Outside `/Applications`: *Needs the copy installed in Applications*.
- **When unplugged** (MacBooks only, default **Sleep with lid closed**):
  - *Keep going*: nothing changes.
  - *Sleep with lid closed*: no lid mode while on battery; keep-awake with the lid open continues. If the lid is
    already shut when the power goes, the Mac sleeps. Shown only while lid mode is on (otherwise it is the same as
    *Keep going*, and the picker displays it that way).
  - *Turn off*: the moment the adapter is unplugged, Insomnia turns off. Starting it again on battery works.
- **No Sleep Now button.** While lid mode is engaged, Apple menu ▸ Sleep is blocked by macOS; turn Insomnia off first
  (one click or a right-click on the moon).

### Safety (switches in Settings, both on by default)

Each trips once on entering its condition (not continuously, so you can turn Insomnia back on deliberately):

| Condition | Lid closed, no external display | Otherwise (lid open, desktop, external display) |
|---|---|---|
| **Overheat protection:** `.critical`, or `.serious` for 60 s (lid closed) / 5 min (lid open), or `.fair` for 5 min with lid mode engaged and the lid closed (the bag rule) | **Sleep now** | per *When it triggers* (default: sleep if idle ≥ 2 min, else turn off) |
| **Low battery protection:** ≤ N% on battery (default 12%, 11–50; clears at N+3; unknown % never trips) | **Sleep now** | same |

- *When it triggers* (lid open): **Sleep if idle, otherwise turn off** (default) · **Always sleep** · **Turn off**.
- "Sleep now" = drop assertions, release the flag, read back 0, `pmset sleepnow` (blocked while the flag is 1).
- While a condition is still active, lid mode stays paused (caption: *Paused: Mac is hot* / *Paused: battery low*);
  plain keep-awake can be turned on again.
- With overheat protection off, Settings says so plainly: *Insomnia won't step in if your Mac gets hot. With the lid
  closed, macOS may not either.* The Mac's firmware still shuts down at a critical temperature.
- The helper's own backstop is not a setting: at ≤ 10% on battery with the flag set it resets and sleeps the Mac
  regardless of the lid. The app's rule (minimum 11%) fires first.
- Signal: a one-line notice in the panel (*Slept because the Mac got hot* / *Turned off: battery at 12%*) and a "!"
  on the moon until the panel is opened. No notifications.

### Settings window

One window, one scrolling grouped `Form` (no tabs), opened from *Settings…* in the panel footer or ⌘, while the panel is open.
The panel's three rows are the same settings, so changes show up in both places.

- **Keep awake:** Turning on keeps awake: *Until turned off* / 1h / 2h / 4h / 8h · Keep screen on · Clicking the
  moon: *Opens the panel* / *Turns Insomnia on or off* (right-click does the other).
- **Lid closed** (MacBooks): Stay awake with lid closed · helper status line (Ready / Waiting for approval › / Needs
  the copy in Applications / error) with **Set up…** or **Reset with password…** when relevant · When unplugged.
- **Safety:** Overheat protection · When it triggers · Low battery protection · Battery level (stepper, %).
- **General:** Open at login · Quit Insomnia.

### Menu bar moon: the mode at a glance (template image)

Each mode has its own silhouette, so it reads at 16 pt without colour:

| Mode | Glyph |
|---|---|
| **Off** (Mac sleeps normally) | outlined crescent, eye **closed** (‿), **z** badge |
| **Awake** (screen may sleep) | outlined crescent, eye **open**, no badge |
| **Awake, screen on** | outlined crescent, eye open, **sparkle** badge |
| **Awake, lid closed OK** (lid mode engaged) | **solid** crescent with the eye knocked out, **open-laptop** badge |
| **Needs attention** (safety tripped, lid mode failed/stuck, waiting for approval) | a small **"!"** under the badge (the mode stays readable) |

The panel header names the mode in a line of words (*Screen on · Lid can close*, *Screen may sleep*).
A timer adds nothing to the glyph (the tooltip says "Awake · 1h 12m left · screen on · lid closed OK"). The panel
doesn't repeat the glyph (the moon sits right above it); Settings shows a small legend of the glyphs.
Geometry starts from the current `MenuBarMoon`; checked in `make snapshot` at 1× and 2×.

### Look

Quiet and typographic: type, spacing and native controls, no decoration. `Theme.swift` holds every token. 300 pt wide,
everything on one 16 pt leading/trailing edge. Header: the state word (20 pt semibold), the subtitle (SF Rounded
numerals) and the mode line, with a small switch tinted amber (the same size as the rows'). Then a hairline and 32 pt rows with no icons:
small switches (amber for the screen, indigo for the lid), and *When unplugged* as a borderless native pop-up (not a custom-label SwiftUI `Menu`: that didn't open in the popover)
that truncates rather than ever widening the panel. Captions hang under their row on the same edge, with a
triangle/octagon icon for warning/danger, and wrap to two lines. Notices sit inline under the status they explain. A
full-bleed hairline and a 36 pt footer with quiet text buttons (*Settings…*, *Quit Insomnia*) close it. Indigo text
uses `lidText` (system indigo fails 4.5:1 at 11 pt on dark glass); amber text sits on nothing. No `.glassEffect` or
materials on content: the `NSPopover` is the glass (Liquid Glass on macOS 26+, opaque under Reduce Transparency); fills
are `Color.primary` opacities so both look right. Countdown in minutes, no ticking seconds. Checked with
`make snapshot` (light and dark, every state; it fails if the content is ever wider than the panel).

### Removed

Personalities and quips, animated eyes, Dock tile, rules, While…, Until…, Why awake?, hotkey, stats, notifications,
welcome/epic cards, the 5-tab Settings window, About, Sleep Now, the ∞ chip, the timer chips and the big power button, CLI + control socket, URL scheme, sudoers fallback,
`docs/{PRODUCT,UX,CLOSED_LID,README}.md`, `ARCHITECTURE.md`, review logs, `scripts/lid-tests.md`. Raycast can come
later as a 3-verb `insomnia://on|off|toggle` scheme (never lid mode), ~30 lines.

## Architecture

```
Sources/Insomnia/                    (~1,700 lines, rewritten)
  main.swift          argv: --version, --helper-status, --unregister-helper, --export-icon, --snapshot (DEBUG).
                      Unknown flag or a terminal launch → usage, exit 2. Else run the app.
  AppDelegate.swift   single instance; SIGTERM → normal quit; .terminateLater quit that releases lid mode first
  Engine.swift        @Observable; the only policy: on/off, timer, settings, unplugged rule, safety
  Power.swift         battery %, AC, thermal, lid present/closed, external displays, HID idle time
  PowerAssertions.swift  kept verbatim (create-before-release)
  RootDomain.swift    kept: clamshell read + interest notification, SleepDisabled read
  LidController.swift @Observable; helper setup + engage/release/heartbeat over XPC
  HelperCommands.swift   kept, trimmed: --helper-status, --unregister-helper
  StatusItem.swift    NSStatusItem + NSPopover(.transient) hosting PanelView
  MoonGlyph.swift     4 glyph states + the app icon for --export-icon
  PanelView.swift     the panel; renders a PanelState, sends PanelAction
  Theme.swift         colour, type and metric tokens; QuietButtonStyle
  SettingsView.swift  the one-page Settings window
  Snapshot.swift      DEBUG: panel states + glyphs to PNG
Sources/InsomniaHelper/   UNCHANGED (root daemon)
Sources/InsomniaShared/   UNCHANGED
Tests/InsomniaTests/      ~700 lines: Engine (fakes), LidController (fake helper), helper policy, power parsing
```

**Helper and InsomniaShared stay byte-for-byte unchanged.** They are the root-owned safety code, proven on this Mac,
and an identical helper build keeps cdhash `414e57d4…`, so the existing registration and approval carry over with no
new prompt. That holds only when built from this checkout path with the current toolchain/SDK (the helper's symbol
table holds absolute object paths): **build in `/Users/gdeml/git/Insomnia`, not a worktree**, and check the cdhash before
`make install`. App version stays `1.0.0` (build.sh ties it to `HelperInfo.version`). UserDefaults keys stay
`keepScreenOn`, `closedLidMode`, `helperRegisteredCDHash` (new keys for the new settings) (`--unregister-helper` clears `closedLidMode`).

### Engine

State: `isOn`, `endsAt?`, `notice?`, `alert`, `latched`, per-condition trip state and "since" dates, edge trackers.
Settings read in `init` without writing. Every input (setting, power event, lid controller change, timer, wake, clock
change) calls `reconcile()`; re-entrant calls fold into one more pass.

Pass:
1. Edges: lid opened → clear `latched`; AC→battery → unplugged edge.
2. Expiry: `endsAt <= now` → off.
3. Safety, per the table, for each protection that is switched on (only while `isOn` or lid engaged; trips on entry;
   timers armed for the 60 s / 5 min windows).
4. Unplugged edge with *Turn off* → off.
5. Lid wanted = `isOn && closedLidMode && hasLid && helperReady && !hotOrLow && !latched
   && !(onBattery && rule == .sleepWhenLidCloses)`. If lid mode drops for a guard or the unplugged rule while the lid
   is shut: sleep now (rule) / per table (safety), and `latched = true` so a DarkWake or re-plug inside a bag can't re-arm
   it; cleared by opening the lid or any user action. Publish only on change.
6. Assertions: system = `isOn`; display = `isOn && keepScreenOn && !(lidEngaged && lidClosed && noExternalDisplay)`.
7. One one-shot `Timer` (RunLoop.main, `.common`) at the next deadline; re-armed on didWake and NSSystemClockDidChange.

### LidController (replaces ~1,700 lines)

- **Setup** `.unavailable` (no lid) · `.notInApplications` · `.notRegistered` · `.needsApproval` · `.ready`:
  `SMAppService.daemon(plistName:).status` read off the main thread (`.notFound` = not registered) +
  `InstallLocation.check`. `install()` = `register()` (a throw that leaves `.requiresApproval` is normal) +
  `openSystemSettingsLoginItems()`, then re-check as described above.
- **Silent upgrade** only when not engaged: compare the bundled helper's cdhash with `status().cdhash` from the running
  helper, falling back to `helperRegisteredCDHash`; nil = unknown, not a mismatch.
- **State** `.off` · `.engaging` · `.engaged` · `.failed(reason)` · `.stuck`. One serial task does all
  engage/release work. Engage = new `.privileged` connection + `engage`; release = `release` + readback of IORegistry
  `SleepDisabled`. Every XPC call races its reply against the error handler and a timeout (2 s status, 5 s
  engage/release) and resumes once. An engage or release that isn't `.ok` or times out → invalidate the connection
  (the helper resets on invalidation), then poll the flag.
- **Heartbeat** every 10 s (`.common` mode) + an App Nap activity while engaged. Any reply other than `.ok`, or a lost
  connection → invalidate, read back, `.failed`.
- **`.failed` is sticky** until a user action (toggle the lid switch or the keep-awake switch, or right-click the moon). Reasons: foreign flag
  (*Another app has turned off sleep*; auto-retried when the flag reads 0, checked every 10 s), other user, battery
  backstop, set failed, helper lost, overridden. A user's `sudo pmset -a disablesleep 0` is never re-applied.
- **Lid shut, no external display, engaged** → `pmset displaysleepnow`. 5 s clamshell poll while engaged as a fallback
  for a missed interest notification.
- **`sleepNow()`**: release, read back 0, `/usr/bin/pmset sleepnow`.
- **`.stuck`** (flag still 1 after 2 s, 15 s after a lost helper): red caption + **Reset with password…** (osascript
  admin prompt running `pmset -a disablesleep 0`). Re-checked every 10 s; clears itself when the flag reads 0.
- **Launch**: delete stale `~/Library/Application Support/Insomnia/{lid-engaged,control.sock}`. If the flag reads 1 and
  `status()` says the helper owns it (its reset is pending), poll up to 15 s, then `.stuck`. A foreign flag is left alone.
- **Quit**: release with a 2 s timeout; on timeout invalidate and let the helper reset.

### Kept OS gotchas (all load-bearing)

- `PreventUserIdleSystemSleep` doesn't survive lid close; only `SleepDisabled` does. Lid mode adds the flag on top.
- While the flag is 1, macOS's own low-battery (and probably thermal) sleep and `pmset sleepnow` are disabled:
  release and read back 0 before sleeping. Releasing with the lid shut doesn't reliably sleep: follow with `sleepnow`.
- Apple Silicon panel can stay lit with the lid shut → `displaysleepnow`, never with an external display.
- Clamshell message `0xE0034100` (bit 0 = closed) doesn't import into Swift; missing `AppleClamshellState` = desktop.
- Run-loop timers count uptime: re-arm from wall-clock deadlines on wake/clock change; `.common` mode.
- IOPS callback is a C pointer; source on the main run loop in `.commonModes`. Thermal notes arrive on any thread.
- Quit: `.terminateLater`, release, reply; ignore a second quit while pending; SIGTERM through the same path;
  `NSSupportsSuddenTermination = false`. Single instance in `willFinishLaunching`.
- Reinstalling replaces the bundle under a running helper. Its code then no longer exists on disk, the app's peer
  requirement fails (`errSecCSNoSuchCode`, -67065) and every engage fails, even with an identical cdhash, because an
  identical cdhash skips the silent upgrade. `make install` therefore runs `launchctl kickstart -k` on the helper after the swap.
- Accessory app: `NSApp.activate` before showing the popover; close it on `willSleep`; never set `statusItem.menu`;
  keep the item narrow (no permanent timer text).

### Build and install

- `scripts/build.sh`: signed only (drop the ad-hoc branch and sudoers wording); otherwise unchanged.
- `Makefile`: `app`, `run`, `snapshot`, `test`, `install`, `uninstall`, `lid-verify`, `clean`; drop the sudoers cleanup.
- `Info.plist`: drop `CFBundleURLTypes`; keep `LSUIElement` and the sudden/automatic-termination keys.
- `Package.swift`: drop Carbon and UserNotifications.
- **Migration on this Mac:** lid mode is engaged right now. `make install` quits the old app, which releases the flag
  and, with the lid shut, sleeps the Mac. Install with the lid open.

### Verify

`swift build`, `swift test`, `make snapshot` (every state, light + dark), helper cdhash = `414e57d4…`, `make install`,
then: on/off → `pmset -g assertions`; lid mode on → `ioreg -r -c IOPMrootDomain | grep SleepDisabled` = Yes; quit →
No; `kill -9` → No within a second.

## Line budget

~1,700 app + ~1,220 helper/shared (unchanged) + ~700 tests + ~350 scripts/docs ≈ **4,000**, down from ~30,400.
