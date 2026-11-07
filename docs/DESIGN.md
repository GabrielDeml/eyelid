# Insomnia design

Status: implemented. This document describes the app as it is now. Overheat and low-battery protection are fixed
rules rather than settings, and the few settings there are live in one Settings window.

## Why

Insomnia grew to ~30,400 lines: three personality tiers, an 886-line eye renderer, a Dock tile, rules, "While…",
"Why awake?", a hotkey, stats, a socket CLI, a URL scheme, a 5-tab Settings window, two lid-mode backends and 30 test
files. What's wanted is an on/off switch and three settings. This rewrite gets back to that.

## The product

A menu bar moon. Clicking it opens a small panel, and right-clicking it turns Insomnia on or off. Settings can swap
the two.

```
╭──────────────────────────────────────╮
│ Awake                        (  ━━●) │   "Awake" or "Off", and the switch
│ Until 3:40 PM                        │   only for a timed session
│ ⚠ Your Mac got hot, so Insomnia   ✕  │   only after a safety action or an unplug
│   turned off                         │
│ ──────────────────────────────────── │
│ Keep screen on                 (━●)  │
│ Stay awake with lid closed     (━●)  │   MacBooks only
│ Needs your approval. Open System     │   a caption, only when needed
│ Settings                             │
│ When unplugged  Sleep with lid closed│   MacBooks only
├──────────────────────────────────────┤
│ Settings…              Quit Insomnia │
╰──────────────────────────────────────╯
```

On a desktop Mac the panel is just the header and *Keep screen on*.

- **The header** is the state word, *Awake* or *Off*, with the switch beside it. The line under it appears only when
  it adds something. A timed session shows *Until 3:40 PM*. If a release failed and sleep is still off, the header
  reads *Off* with *Your Mac still can't sleep* under it. There is no mode line and no countdown; the menu bar icon
  already shows the mode.
- **The switch** turns Insomnia on until you turn it off, or for the *Turn Insomnia off after* time in Settings.
  Return toggles it too, and so does a right-click on the moon. There are no timer buttons in the panel.
- **Keep screen on** (default on) also holds the display awake.
- **Stay awake with lid closed** (default off) sets the system's `SleepDisabled` flag while Insomnia is on. Turning it
  on while Insomnia is off also turns Insomnia on, with the same *Turn Insomnia off after* limit as the main switch,
  so the switch always means what it says. The first time, it registers the lid helper and opens System Settings ▸
  Login Items. The switch stays on with the caption *Needs your approval. Open System Settings*. The app re-checks
  every 2 s for 3 minutes, and whenever the panel or Settings opens, and lid mode engages once the helper is allowed.
- **When unplugged** (MacBooks only, default *Sleep with lid closed*):
  - *Stay awake*: nothing changes.
  - *Sleep with lid closed*: no lid mode while on battery, so closing the lid sleeps the Mac. Keeping it awake with
    the lid open continues. If the lid is already shut when the power goes, the Mac sleeps. This choice is offered
    only while the lid switch is on. Otherwise it would behave like *Stay awake*, and the picker shows it that way.
  - *Turn Insomnia off*: Insomnia turns off the moment the adapter is unplugged. Turning it on again on battery works.
- **No Sleep Now button.** While lid mode is engaged, macOS blocks Sleep in the Apple menu. Turn Insomnia off first,
  with one click or a right-click on the moon.

### Captions under the lid switch

A caption hangs under *Stay awake with lid closed* only when something needs saying. Some show whatever the switch
says, because the switch can't work or sleep is stuck:

- *Works only when installed in Applications* (the switch is disabled)
- *Needs a signed build* (disabled)
- *This build is missing the lid helper* (disabled, warning)
- *Couldn't turn sleep back on. Reset with Password…* (danger; runs `pmset -a disablesleep 0` through an admin prompt)
- *Couldn't set up the lid helper (error N). Try Again*

The rest show only while the switch is on:

- *Setting up the lid helper* while `install()` is registering it, then *The lid helper isn't set up. Set Up…* if it
  still isn't
- *Needs your approval. Open System Settings* (warning)
- *Another app has already turned off sleep*, *In use by another user on this Mac*, *Battery too low. Plug in your
  Mac. Try Again*, *Couldn't turn off sleep. Try Again*, *Lost contact with the lid helper. Try Again* and *Something
  else turned sleep back on. Try Again* (all warnings, one per `LidController.Failure`)
- While Insomnia is on: *Paused while your Mac is hot*, *Paused while the battery is low* (warnings) and *Paused while
  on battery* (the *Sleep with lid closed* rule)

The captions are static values on `PanelState`, and `make snapshot` renders those same values, so the pictures always
show the app's real text.

### Safety

There are two protections and neither has a threshold to set.

**Overheat.** The Mac counts as hot when macOS reports `.critical`, or `.serious` for 60 s with the lid closed and no
external display (5 minutes otherwise), or `.fair` for 5 minutes while lid mode is engaged with the lid closed and no
external display. The last one is the bag rule. Overheat protection applies when *Turn Insomnia off if your Mac gets
hot* is on, and it always applies when lid mode is on (engaged, or wanted with the helper ready) with the lid closed and no
external display, whatever the switch says. Without lid mode a closed lid sleeps the Mac anyway, so the switch decides.

**Low battery.** On battery at or below 12% (`Engine.lowBatteryPercent`). It clears at 15% or on AC. An unknown
battery percentage never trips it. It can't be switched off.

Each protection trips once, when its condition starts, so you can turn Insomnia back on deliberately afterwards. It
acts only if Insomnia is holding the Mac awake (on, or lid mode engaged). With the lid closed and no external display
it sleeps the Mac at once. Otherwise it sleeps the Mac if nobody has used it for 2 minutes (HID idle time), and turns
Insomnia off if somebody has.

- "Sleep now" means drop the assertions, release the flag, read it back as 0, then run `pmset sleepnow` (which is
  blocked while the flag is 1).
- While a condition is still active, lid mode stays paused and the lid caption says *Paused while your Mac is hot* or
  *Paused while the battery is low*. Plain keep-awake can be turned on again.
- The Mac's firmware still shuts down at a critical temperature whatever Insomnia does.
- The helper's own backstop is not a setting. At 10% or less on battery with the flag set, it resets the flag and
  sleeps the Mac regardless of the lid. The app's 12% rule fires first.
- The signal is a one-line notice in the panel and a "!" on the moon until the panel is opened. There are no
  notifications. The notices are *Your Mac got hot, so Insomnia put it to sleep*, *Your Mac got hot, so Insomnia
  turned off*, *Your battery fell to 12%, so Insomnia put your Mac to sleep* and *Your battery fell to 12%, so
  Insomnia turned off*. Unplugging with *Turn Insomnia off* selected leaves the informational notice *Your Mac was
  unplugged, so Insomnia turned off*, which doesn't add the "!".

### Settings window

One window titled *Insomnia Settings*, 480 pt wide, holding a grouped `Form` with three groups and no section headers
or tabs. It opens from *Settings…* in the panel footer, or with ⌘, from the app menu. The panel's rows are the same
settings, so a change shows up in both places. Explanations are the control's own description line, not separate rows.

1. *Turn Insomnia off after* (Never, 1 hour, 2 hours, 4 hours or 8 hours). *Keep screen on*. *Click the menu bar icon
   to* (Open the panel, or Turn Insomnia on or off), described as *Right-click to turn Insomnia on or off.* or
   *Right-click to open the panel.*
2. MacBooks only. *Stay awake with lid closed*, described as *While Insomnia is on, Sleep in the Apple menu doesn't
   work.* Then *When unplugged* (on a Mac with a battery), described as *At 12% battery, Insomnia turns off or puts
   your Mac to sleep.* A *Lid helper* row appears only when the helper needs something, with its status in
   secondary text and a button where there is one: *Couldn't turn sleep back on* with **Reset with Password…**, *Not
   set up* with **Set Up…** (only while the lid switch is on; *Setting up* with no button while it registers), *Needs your approval* with **Open System Settings**,
   or *Works only when installed in Applications*, *Needs a signed build* or *Missing from this build*. A ready
   helper shows no row. A Mac with a battery but no lid gets a group with just *When unplugged*.
3. *Turn Insomnia off if your Mac gets hot*, described as *If no one is using your Mac, Insomnia puts it to sleep
   instead. While it stays awake with the lid closed, this can't be turned off.* The second sentence appears only on
   a Mac with a lid. Then *Open at
   login*, which shows *Couldn't add Insomnia to Login Items (error N).* under it if registering fails.

There is no glyph legend and no Quit button; *Quit Insomnia* is in the panel footer and the app menu.

A stored *Turn Insomnia off after* value that isn't one of the choices (an older version allowed any number of
minutes) rounds up to the next choice, or down to 8 hours if it is longer, so the picker always has a selection and a
timed session stays timed.

### Copy rules

One term per concept. The root daemon is "the lid helper" everywhere a user can see it. The feature is "Stay awake
with lid closed" in the app; "lid mode" is used only in the README, these docs and the code. The machine is "your Mac".
Caption fragments have no closing period, unless a link follows, in which case the sentence before the link ends with
one. Link actions are Title Case verbs (*Try Again*, *Set Up…*, *Open System Settings*, *Reset with Password…*), with
an ellipsis when they lead to another prompt. Notices take the form "<cause>, so Insomnia <result>". Error codes go in
parentheses as "(error N)". The state words "Awake" and "Off" are a deliberate pairing. "Awake" describes the Mac and "Off"
describes Insomnia, because "Asleep" would be wrong while the Mac is plainly running.

### Menu bar moon (template image)

Each mode has its own silhouette, so it reads at 16 pt without colour:

| Mode | Glyph |
|---|---|
| **Off** (Mac sleeps normally) | outlined crescent, eye **closed** (‿), **z** badge |
| **Awake** (screen may sleep) | outlined crescent, eye **open**, no badge |
| **Awake, screen on** | outlined crescent, eye open, **sparkle** badge |
| **Awake with lid closed** (lid mode engaged) | **solid** crescent with the eye knocked out, **open-laptop** badge |
| **Needs attention** (safety tripped, lid mode failed or stuck, waiting for approval) | a small **"!"** under the badge (the mode stays readable) |

The tooltip is the state in a sentence: *Insomnia is on until 3:40 PM*, *Insomnia is on*, *Insomnia is off*, or *Your
Mac still can't sleep* when a release failed. A second line adds the current notice, or, when the "!" is showing for
another reason, what needs attention: *The lid helper needs your approval in System Settings*, or the lid caption the
panel would show, without its final period. The same text is the button's accessibility value, and
the image's accessibility description names the mode ("Insomnia awake, screen on", plus ", needs attention").
A timer adds nothing to the glyph, and the panel doesn't repeat the glyph (the moon sits right above it). Geometry
starts from the old `MenuBarMoon` and is checked in `make snapshot` at 1×, 2× and 8×.

### Look

Quiet and typographic, with type, spacing and native controls and no decoration. `Theme.swift` holds every token. The
panel is 300 pt wide, and everything sits on one 16 pt leading and trailing edge.

The header is the state word (20 pt semibold) and, when there is one, a 12 pt secondary line under it in the system
font. The switch beside it is small and tinted amber, the same size as the rows' switches. Then a hairline and 32 pt
rows with no icons. Their switches are small, amber for the screen and indigo for the lid. *When unplugged* is a
borderless native pop-up (a SwiftUI `Menu` with a custom label didn't open in the popover) that truncates rather than
ever widening the panel.

Captions are 11 pt and hang under their row on the same edge, wrapping to at most two lines. Warning and danger
captions get a triangle or octagon icon. A caption's action is part of the same text, in the system link colour, so it
wraps with the message; non-breaking spaces keep the link's own words together, and the pointer becomes a hand on
macOS 15 and later. A notice sits under the header with an info or warning icon and a ✕ to dismiss it. A full-bleed
hairline and a 36 pt footer with quiet text buttons (*Settings…*, *Quit Insomnia*) close the panel.

Amber and indigo only tint switches and are never used as text. Warning and danger text use `warningText` and
`dangerText`, which hold 4.5:1 at 11 pt in light and dark. There is no `.glassEffect` and no material on content. The
`NSPopover` is the glass (Liquid Glass on macOS 26 and later, opaque under Reduce Transparency), and fills are
`Color.primary` opacities so both look right. `make snapshot` renders every panel state and the Settings window in
light and dark, and fails if the panel's content is ever wider than the panel.

### Removed

Personalities and quips, animated eyes, Dock tile, rules, While…, Until…, Why awake?, hotkey, stats, notifications,
welcome/epic cards, the 5-tab Settings window, About, Sleep Now, the ∞ chip, the timer chips and the big power button, CLI + control socket, URL scheme, sudoers fallback,
`docs/{PRODUCT,UX,CLOSED_LID,README}.md`, `ARCHITECTURE.md`, review logs, `scripts/lid-tests.md`, the safety
trip-action picker, the low-battery threshold and its switch, the panel's mode line and countdown, and the Settings
glyph legend and Quit button. Raycast can come later as a 3-verb `insomnia://on|off|toggle` scheme (never lid mode),
~30 lines.

## Architecture

```
Sources/Insomnia/                    (2,926 lines, rewritten)
  main.swift          argv: --gui, --version, --helper-status, --unregister-helper, --export-icon, --snapshot (DEBUG).
                      Unknown flag or a terminal launch → usage, exit 2. Else run the app.
  AppDelegate.swift   single instance; SIGTERM → normal quit; .terminateLater quit that releases lid mode first
  Engine.swift        @Observable; the only policy: on/off, time limit, unplugged rule, safety
  Preferences.swift   the settings in UserDefaults; When unplugged and click-action choices; duration text
  Power.swift         battery %, AC, thermal, lid present/closed, external displays, HID idle time
  PowerAssertions.swift  kept verbatim (create-before-release)
  RootDomain.swift    kept: clamshell read + interest notification, SleepDisabled read
  HelperClient.swift  the app's side of the helper: SMAppService setup, XPC calls, signatures, pmset
  LidController.swift @Observable; helper setup + engage/release/heartbeat over XPC
  HelperCommands.swift   kept, trimmed: --helper-status, --unregister-helper
  StatusItem.swift    NSStatusItem + NSPopover(.transient) hosting the panel; glyph and tooltip
  MoonGlyph.swift     4 glyph states and the "!", plus the app icon for --export-icon
  PanelView.swift     PanelState (derived from the engine, including every caption), PanelView, PanelAction
  Theme.swift         colour, type and metric tokens; QuietButtonStyle
  SettingsView.swift  the one-page Settings window
  Snapshot.swift      DEBUG: panel states, the Settings window, glyphs and app icon to PNG
Sources/InsomniaHelper/   UNCHANGED (root daemon)
Sources/InsomniaShared/   UNCHANGED
Tests/InsomniaTests/      967 lines: Engine (fakes), LidController (fake helper), helper policy, power parsing
```

**Helper and InsomniaShared stay byte-for-byte unchanged.** They are the root-owned safety code, proven on this Mac,
and an identical helper build keeps cdhash `414e57d4…`, so the existing registration and approval carry over with no
new prompt. That holds only when built from this checkout path with the current toolchain/SDK (the helper's symbol
table holds absolute object paths): **build in `/Users/gdeml/git/Insomnia`, not a worktree**, and check the cdhash before
`make install`. App version stays `1.0.0` (build.sh ties it to `HelperInfo.version`). UserDefaults keys kept from the
old app are `keepScreenOn`, `closedLidMode` and `helperRegisteredCDHash` (`--unregister-helper` clears `closedLidMode`).
The new settings use `whenUnplugged`, `powerButtonMinutes` (the name predates the switch), `clickAction` and
`overheatProtection`. Values left behind by earlier builds under `lowBatteryProtection`, `lowBatteryPercent` and
`tripAction` are ignored.

### Engine

State: `isOn`, `endsAt?`, `notice?`, `unseenAlert`, `latched`, the hot and low-battery episodes and their "since"
dates, and edge trackers. Settings are read in `init` without writing. Every input (setting, power event, lid
controller change, timer, wake, clock change) calls `reconcile()`; re-entrant calls fold into one more pass.

`toggle()` and `setLidMode(true)` while off both start a session with `powerButtonMinutes` as the limit (0 means until
turned off).

Pass:
1. Edges: lid opened → clear `latched`; AC→battery → unplugged edge.
2. Expiry: `endsAt <= now` → off.
3. Safety, as described under Safety. Overheat is checked when its switch is on, or lid mode is on with the lid closed and
   no external display; low battery is always checked. Each trips on entry and acts only while `isOn` or lid engaged. Timers are
   armed for the 60 s and 5 minute windows.
4. Unplugged edge with *Turn Insomnia off* → off, with the unplugged notice.
5. Lid wanted = `isOn && closedLidMode && hasLid && helperReady && !hotEpisode && !lowEpisode && !latched
   && !(onBattery && whenUnplugged == .sleepWhenLidCloses)`. If lid mode drops for a guard or the unplugged rule
   while the lid is shut, the Mac sleeps (the helper's release does it, or the safety action does), and
   `latched = true` so a DarkWake or re-plug inside a bag can't re-arm it. Opening the lid or any user action clears
   it. Publish only on change.
6. Assertions: system = `isOn`; display = `isOn && keepScreenOn && !(lidEngaged && lidClosed && noExternalDisplay)`.
   The assertion reason is "Insomnia is keeping your Mac awake".
7. A pending safety sleep runs after the lid release queued above.
8. One one-shot `Timer` (RunLoop.main, `.common`) at the next deadline; re-armed on didWake and NSSystemClockDidChange.

### LidController (427 lines, replacing ~1,700)

- **Setup** is one of `.noLid`, `.notInApplications`, `.unsigned`, `.missingFiles`, `.notRegistered`,
  `.needsApproval` or `.ready`, from `SMAppService.daemon(plistName:).status` read off the main thread (`.notFound`
  means not registered) and `InstallLocation.check`. `install()` calls `register()` (a throw that leaves
  `.requiresApproval` is normal) and `openSystemSettingsLoginItems()`, then re-checks as described above.
- **Silent upgrade** only when not engaged: compare the bundled helper's cdhash with `status().cdhash` from the running
  helper, falling back to `helperRegisteredCDHash`; nil = unknown, not a mismatch.
- **State** is one of `.off`, `.engaging`, `.engaged`, `.releasing`, `.failed(reason)` or `.stuck`. One serial task
  does all engage/release work. Engage = new `.privileged` connection + `engage`; release = `release` + readback of
  IORegistry `SleepDisabled`. Every XPC call races its reply against the error handler and a timeout (2 s status, 5 s
  engage/release) and resumes once. An engage or release that isn't `.ok` or times out → invalidate the connection
  (the helper resets on invalidation), then poll the flag.
- **Heartbeat** every 10 s (`.common` mode) + an App Nap activity while engaged. Any reply other than `.ok`, or a lost
  connection → invalidate, read back, `.failed`.
- **`.failed` is sticky** until a user action (toggling the lid switch or the main switch, a right-click on the moon,
  or a caption's *Try Again*). The reasons are a foreign flag (*Another app has already turned off sleep*; retried
  automatically when the flag reads 0, checked every 10 s), another user, the helper's battery backstop, a failed set,
  a lost helper, and an override. A user's `sudo pmset -a disablesleep 0` is never re-applied.
- **Lid shut, no external display, engaged** → `pmset displaysleepnow`. 5 s clamshell poll while engaged as a fallback
  for a missed interest notification.
- **`sleepNow()`**: release, read back 0, `/usr/bin/pmset sleepnow`.
- **`.stuck`** (flag still 1 after 2 s, 15 s after a lost helper): danger caption with **Reset with Password…** (an
  osascript admin prompt running `pmset -a disablesleep 0`). Re-checked every 10 s; clears itself when the flag reads 0.
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

- `scripts/build.sh` builds signed only. An ad-hoc build is refused, because lid mode needs a signed helper.
- `Makefile` targets are `app`, `run`, `snapshot`, `test`, `install`, `uninstall`, `lid-verify` and `clean`. Only
  `install` and `uninstall` use sudo.
- `Info.plist` has no `CFBundleURLTypes`; it keeps `LSUIElement` and the sudden/automatic-termination keys.
- `Package.swift` links IOKit, ServiceManagement and Security only (no Carbon, no UserNotifications).
- **Upgrading with lid mode engaged:** `make install` quits the running app, which releases the flag and, with the lid
  shut, sleeps the Mac. Install with the lid open.

### Verify

`swift build`, `swift test`, `make snapshot` (every panel state and the Settings window, light + dark), helper cdhash
= `414e57d4…`, `make install`, then: on/off → `pmset -g assertions`; lid mode on →
`ioreg -r -c IOPMrootDomain | grep SleepDisabled` = Yes; quit → No; `kill -9` → No within a second.

## Line budget

2,926 app + 1,222 helper/shared (unchanged) + 967 tests + 761 scripts, Makefile, README and this document ≈
**5,900** (`wc -l`), down from ~30,400.
