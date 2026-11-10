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
    the lid open continues. If the lid is already shut when the power goes, the Mac sleeps, unless someone is using an
    external display. This choice is offered
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
  Mac. Try Again*, *Your Mac got hot. Try Again* (the helper's heat backstop), *Couldn't turn off sleep. Try Again*,
  *Lost contact with the lid helper. Try Again* and *Something else turned sleep back on. Try Again* (all warnings,
  one per `LidController.Failure`)
- While Insomnia is on: *Paused while your Mac is hot*, *Paused while the battery is low* (warnings) and *Paused while
  on battery* (the *Sleep with lid closed* rule)

The captions are static values on `PanelState`, and `make snapshot` renders those same values, so the pictures always
show the app's real text.

### Safety

There are two protections and neither has a threshold to set.

**Shut in, and unattended.** The closed-lid rules key on two conditions (`PowerState`).

*Shut in* means the lid is closed and only lid mode is keeping the Mac awake. That is the case with no external display
at all, or with one the kernel doesn't count as clamshell mode: IOPMrootDomain's `AppleClamshellCausesSleep` is true.
Clamshell mode (a real display on power) sets it false, and macOS keeps such a Mac awake without lid mode. A virtual
display doesn't: on this Mac a `CGVirtualDisplay` left it Yes. So `isShutIn = lidClosed && (externalDisplays == 0 ||
causesSleep == true)`. The kernel's answer can only add "shut in" when CoreGraphics reports a display. It can never
remove it when there is none, so a missing or stale value leaves the old rule.

The app used to stop at "no external display", and any app can add a virtual display (BetterDisplay, DeskPad, AirPlay,
Sidecar, or malware through `CGVirtualDisplay`). One display was enough to silently switch off every closed-lid rule
while the Mac sat in a bag.

*Unattended* means shut in, and either no external display at all or nobody has touched the keyboard, mouse or
trackpad for 2 minutes (`PowerState.unattendedAfter`, HID idle time). A DisplayLink dock, Sidecar or an AirPlay screen
with the lid closed is shut in, because macOS doesn't do clamshell mode for those. That is exactly why people use lid
mode with them. Someone typing at one is not a bag. A bag has no input, and same-user code can't fake HID input without
Accessibility (`caffeinate -u` didn't reset the idle time on this Mac). Watching a video on an AirPlay screen with the
lid shut and no input for 2 minutes does count as unattended; that is the trade-off.

The display count alone still decides `displaysleepnow`: it runs only with no external display at all, so it can never
blank a screen someone is looking at.

**Overheat.** The Mac counts as hot when macOS reports `.critical`, or `.serious` for 60 s while shut in (5 minutes
otherwise), or `.fair` for 5 minutes while lid mode is engaged and the Mac is unattended. The last one is the bag rule.
Its window starts when the unattended condition starts. Overheat protection applies when *Turn Insomnia off if your Mac
gets hot* is on. It always applies, whatever the switch says, when lid mode is on (engaged, or wanted with the helper
ready) and the Mac is shut in. Without lid mode a closed lid sleeps the Mac anyway, so the switch decides.

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
- The helper's own backstops are not settings, and they hold whatever the app does (see Security):
  - **Battery.** At 10% or less on battery with the flag set, whoever set it, it resets the flag and sleeps the Mac
    regardless of the lid. The app's 12% rule fires first.
  - **Heat** (its own flag only). It trips on `.critical` with any lid state, because while the flag is 1 macOS's own
    thermal emergency sleep is blocked too, even in clamshell mode. It also trips on `.serious` for 2 minutes
    (`HelperInfo.thermalSeriousWindow`) while the Mac is shut in; the app's 60 s rule fires first. The helper tracks
    the thermal state itself (ProcessInfo's thermal notification) and checks on every change, on every engage and
    heartbeat, and at the end of the 2-minute window (a one-shot timer while a session exists). No client message is
    needed to trigger it. A trip drops every session (heartbeat reply `.hot`, sent before the reset), resets the flag,
    and sleeps the Mac if it is shut in. While the condition holds, engage is refused with `.hot`. The helper has no
    bag rule; that stays the app's, because only the app can see displays and input.
  - **Sleep after its own resets.** Clearing the flag with the lid shut doesn't reliably sleep the Mac. So when the
    helper resets the flag for a reason the app can't follow up on, it sleeps the Mac if it is shut in. Those reasons
    are: the app crashed, was killed or quit without releasing (connection lost); no heartbeat for 45 s (a hang, or
    `kill -STOP`); the heat backstop; and the restart reset after the helper itself died holding the flag. For the
    battery backstop it always sleeps. Without this, a stopped app left a Mac in a bag awake, still holding its
    idle-sleep assertion, with no safety logic running. The helper's shut-in test is `AppleClamshellState &&
    AppleClamshellCausesSleep != false`: it can't see displays or input, so it treats an unknown answer as shut in.
    Each reset carries what to do after it (`HelperPolicy.AfterReset`: nothing, sleep if shut in, sleep), and a failed
    reset keeps that for its 5 s retry, so a retry that succeeds still sleeps. Adding a session, an override or SIGTERM
    clears it. An explicit release doesn't sleep, nor do a failed engage, SIGTERM (shutdown, logout, unregister) or the
    boot reset. After an explicit release the app follows up itself, because only it knows whether someone is using an
    external display. Trade-off: if the app crashes while someone types at a DisplayLink screen with the lid shut, the
    helper sleeps the Mac.
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
Sources/Insomnia/                    (3,048 lines)
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
Sources/InsomniaHelper/   root daemon: the flag, its resets, the battery and heat backstops (see Security)
Sources/InsomniaShared/   XPC protocol, identifiers, requirements, the installed-app pin, helper policy, IOPS/IORegistry reads
Tests/InsomniaTests/      Engine (fakes), LidController (fake helper), helper policy, the pin, power parsing
```

**The helper is the root-owned safety code; change it only with this document.** The security pass (see Security)
changed it: the installed-app pin, the heat backstop, sleeping after its own resets, and atomic writes in /var/run. Any
change gives the helper a new cdhash, so on its next launch the installed app sees the mismatch and re-registers it
(the silent upgrade below). macOS may ask for approval again in Login Items. The helper's symbol table holds absolute
object paths, so its cdhash depends on the checkout path, the toolchain and the signing identity. Release builds come
from CI on the `xcode-27` runner (docs/RELEASE.md). To compare cdhashes locally, **always build from the same checkout
path**. App version stays `1.0.0` (build.sh ties it to `HelperInfo.version`;
upgrades are detected by cdhash, not by this string). UserDefaults keys kept from the
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
3. Safety, as described under Safety. Overheat is checked when its switch is on, or lid mode is on and the Mac is shut
   in (`PowerState.isShutIn`); low battery is always checked. Each trips on entry and acts only while `isOn` or lid
   engaged. Timers are armed for the 60 s and 5 minute windows. The bag rule uses *unattended*. While lid mode is
   engaged the 5 s lid poll also re-runs the pass, so idle time crossing 2 minutes is noticed. A trip sleeps the Mac
   if it is closed with no external display at all, or if nobody has used it for 2 minutes (checked once, at the
   trip). Otherwise it turns Insomnia off. The release that follows then sleeps only an unattended Mac, so the notice
   tells the truth.
4. Unplugged edge with *Turn Insomnia off* → off, with the unplugged notice.
5. Lid wanted = `isOn && closedLidMode && hasLid && helperReady && !hotEpisode && !lowEpisode && !latched
   && !(onBattery && whenUnplugged == .sleepWhenLidCloses)`. If lid mode drops for a guard or the unplugged rule
   while the lid is shut, the Mac sleeps if unattended (the follow-up `sleepnow` after the release, or the safety
   action), and
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
  engage/release) and resumes once. A release answered with a drop reason (`.notEngaged`, `.backstop`, `.hot`: the helper dropped the session just before and reset the flag itself) counts as done. Any other engage or release that isn't `.ok`, or times out → invalidate the connection
  (the helper resets on invalidation), then poll the flag.
- **Heartbeat** every 10 s (`.common` mode) + an App Nap activity while engaged. Any reply other than `.ok`, or a lost
  connection → invalidate, read back, `.failed`.
- **`.failed` is sticky** until a user action (toggling the lid switch or the main switch, a right-click on the moon,
  or a caption's *Try Again*). The reasons are a foreign flag (*Another app has already turned off sleep*; retried
  automatically when the flag reads 0, checked every 10 s), another user, the helper's battery backstop, the helper's
  heat backstop (heartbeat reply `.hot`), a failed set, a lost helper, and an override. A user's
  `sudo pmset -a disablesleep 0` is never re-applied.
- **Lid shut, no external display, engaged** → `pmset displaysleepnow` (the cached `update(closedWithoutDisplay:)`
  value; it can never blank another screen).
- **Every follow-up `sleepnow` reads fresh.** That covers releasing lid mode, quitting, a stuck flag that clears, and a
  lost session. Each one runs after the flag reads 0 and asks `HelperClienting.isUnattendedNow()`, which re-reads the
  lid, `AppleClamshellCausesSleep`, the display count and HID idle time at that moment. A cached value can be seconds
  old, because a dock unplug changes AC, the displays and the kernel's answer in some order. It can also be a whole
  sleep old, if this app was the one that hung.
- **After a lost session** the app sleeps an unattended Mac once the flag reads 0, unless the helper's battery or heat
  backstop already did. It also skips the sleep if the Mac has slept since the loss was noticed
  (`mach_continuous_time − mach_absolute_time` grew). Both sides react to the same loss within ~200 ms, so this stops
  a `sleepnow` from reaching powerd after the helper's sleep and putting the Mac back to sleep once the lid opens.
  A stuck flag left by a loss sleeps when it clears, even while lid mode is still wanted.
- **Power-off.** After `NSWorkspace.willPowerOffNotification` (logout, restart, shutdown) the quit-time `sleepnow` is
  skipped, so an overnight update restart with the lid shut isn't put to sleep halfway. The helper can still sleep
  the Mac if loginwindow kills the app without a release (connection lost), and that is the safe outcome.
- **Approval after a silent upgrade.** If re-registering a changed helper leaves it waiting for approval, the 2 s
  approval poll starts, as it does after `install()`.
- 5 s clamshell poll while engaged as a fallback for a missed interest notification. It re-reads the lid,
  `AppleClamshellCausesSleep` and the display count, and re-runs the pass.
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
- Clamshell message `0xE0034100` (bit 0 = closed, bit 1 = closing sleeps) doesn't import into Swift; missing
  `AppleClamshellState` = desktop.
- `AppleClamshellCausesSleep` is published by `sendClientClamshellNotification()` from xnu's
  `shouldSleepOnClamshellClosed()`: `!clamshellDisabled && !(desktopMode && acAdaptorConnected) &&
  !clamshellSleepDisableMask`. It is republished, along with the clamshell message, on lid open/close, AC, desktop mode
  and clamshell enable/disable changes, but not when the disable mask changes (for example briefly after a dark wake).
  So it can be stale, and the app uses it only to *add* "shut in" when a display is present. On this Mac it read Yes
  with `SleepDisabled` = 1 and the lid open, and stayed Yes with a `CGVirtualDisplay` attached. Still to check (see
  Verify): with the lid closed, in clamshell mode on AC and on battery, and with DisplayLink, Sidecar and AirPlay.
- `SecStaticCodeCreateWithPath` on `/dev/fd/N` reads the signature of the already-open file (checked on this Mac: the
  same cdhash as `codesign -dvvv`). The installed-app pin depends on it.
- Run-loop timers count uptime: re-arm from wall-clock deadlines on wake/clock change; `.common` mode.
- IOPS callback is a C pointer; source on the main run loop in `.commonModes`. Thermal notes arrive on any thread.
- Quit: `.terminateLater`, release, reply; ignore a second quit while pending; SIGTERM through the same path;
  `NSSupportsSuddenTermination = false`. Single instance in `willFinishLaunching`.
- Reinstalling replaces the bundle under a running helper. Its code then no longer exists on disk, the app's peer
  requirement fails (`errSecCSNoSuchCode`, -67065) and every engage fails, even with an identical cdhash, because an
  identical cdhash skips the silent upgrade. `make install` and the installer package's postinstall therefore run
  `launchctl kickstart -k` on the helper after the swap (postinstall only for an identical cdhash; see Security).
- Accessory app: `NSApp.activate` before showing the popover; close it on `willSleep`; never set `statusItem.menu`;
  keep the item narrow (no permanent timer text).

### Build and install

- `scripts/build.sh` builds signed only. An ad-hoc build is refused, because lid mode needs a signed helper.
- `Makefile` targets are `app`, `run`, `snapshot`, `test`, `install`, `uninstall`, `lid-verify`, `release`, `pkg-dev`
  and `clean`. Only `install` and `uninstall` use sudo. `release` and `pkg-dev` build the installer package
  (`scripts/release.sh`, docs/RELEASE.md) and never install anything.
- `Info.plist` has no `CFBundleURLTypes`; it keeps `LSUIElement` and the sudden/automatic-termination keys.
- `Package.swift` links IOKit, ServiceManagement and Security only (no Carbon, no UserNotifications).
- **Upgrading with lid mode engaged:** `make install` and the installer package both quit the running app, which
  releases the flag and, with the lid shut, sleeps the Mac. Install with the lid open.
- **v1 leftovers.** `make install`, `make uninstall` and the installer package's preinstall remove v1's sudoers rule and
  safety daemon if they are present, after the running app has quit (see Security).

### Verify

`swift build`, `swift test`, `make snapshot` (every panel state and the Settings window, light + dark), the helper
cdhash build.sh prints, `make install`, then:
- on/off → `pmset -g assertions`
- lid mode on → `ioreg -r -c IOPMrootDomain | grep SleepDisabled` = Yes; quit → No; `kill -9` → No within a second
- with the lid shut and no display: `kill -9` the app, and the Mac sleeps; `kill -STOP` it, and within ~45 s the flag
  is No and the Mac sleeps
- the pin: `/Applications/Insomnia.app/Contents/MacOS/Insomnia --helper-status` prints "helper answered" with its
  cdhash. A *different* signed build (`ditto build/Insomnia.app` into a scratch folder, change one byte of a resource,
  re-sign with `codesign -f -s "Apple Development: …" -o runtime`), run with `--helper-status`, prints "helper didn't
  answer". The helper logs "serving" with the pinned app cdhash
  (`log show --predicate 'subsystem == "com.gdeml.Insomnia.helper"' --last 5m`).
- the kernel's answer: lid mode engaged and no display, close the lid and read `AppleClamshellCausesSleep` over ssh
  (`ioreg -r -c IOPMrootDomain -d 1`): expect Yes. A real display in clamshell mode on AC: expect No. Also record the
  value on battery, and with DisplayLink, Sidecar and a BetterDisplay virtual screen.

## Security

The lid helper runs as root and is the only privileged code. The attacker that matters is other code running as the
user, with no admin password. That code can already run `caffeinate`, but it can't set `SleepDisabled`, which needs
root. So the helper must not let it hold that flag, and a flag it does hold must stay bounded.

**Who can drive the helper.** The listener's code-signing requirement is set once at start-up, before `resume()`, and
libxpc checks it against the caller's audit token, so PID reuse and exec races don't apply. It requires:
- our identifier (`com.gdeml.Insomnia`)
- an Apple-issued certificate whose OU is our Team ID
- no `get-task-allow`
- **the cdhash of the installed app**, `cdhash H"…"`

The helper reads that cdhash once at start-up, after `InstallLocation.check` passes
(`CodeSignature.installedAppCDHash`). /Applications itself is `root:admin 0775`: any admin process can rename the
entries in it, so a check by path followed by a read by path could see two different bundles. So the helper never
uses the path twice:
1. It opens `/Applications/Insomnia.app` once with `O_DIRECTORY | O_NOFOLLOW`. /Applications itself isn't checked;
   it is the system's own directory.
2. It opens `Contents` and then `MacOS` relative to that descriptor (`openat`, `O_NOFOLLOW`).
3. From the MacOS descriptor it opens both `Insomnia` and `InsomniaHelper`.
4. Each of the five must be root-owned, not group/other-writable and carry no ACL (`fstat` and `acl_get_fd_np`), and
   the two binaries must be regular files.
5. It reads both signatures through the open descriptors (`/dev/fd/N`).
6. The helper file's cdhash must equal the cdhash the kernel is running for this process. That ties the pinned app to
   the very bundle this helper was launched from.

If any step fails, or the cdhash isn't 40 hex digits, the helper runs reset-only. The cdhash goes into the requirement
text only after all that. What this proves is the content of a root-owned, non-writable file. That is all the pin needs.
Nothing but root can change such a file, and no other root-owned Insomnia bundle exists. `make install` moves the
previous one aside and deletes it. The installer package replaces `/Applications/Insomnia.app` itself: its payload is
root:wheel with no group/other write, and `relocatable="false"` (release.sh refuses a package without it) means
Installer never upgrades a copy anywhere else, so it leaves no second root-owned bundle behind.

Why it pins the cdhash: the Team ID isn't a secret on the developer's Mac. build.sh signs with the Apple Development
identity in the login keychain, which signs without a prompt. So any process running as the user could sign its own
client as `com.gdeml.Insomnia`, call `engage` and heartbeat forever, holding `SleepDisabled = 1` with none of the
app's overheat, bag, battery or unplug rules. With the pin, only the exact root-owned app that the installer package
or `make install` put in place can engage. That shuts out older signed builds too. Running the same code from
somewhere else is the same code. Consequences:
- A build that isn't the installed one can't talk to the helper. It couldn't use lid mode anyway (`.notInApplications`),
  and its launch check of a set flag now gets no answer, which it treats as unknown.
- The helper must restart to pin a newly installed app. For an identical helper cdhash, both install paths restart it
  with `launchctl kickstart -k`. For a changed one, the silent upgrade re-registers it when the app next opens. If
  neither happens, engage fails until the helper restarts. Engage already failed in that case, because the old
  helper's code was no longer on disk.
- The two install paths differ for a changed helper. launchd still holds the old registration, whose spawn constraint
  pins the old cdhash, so a restarted new helper can't launch. The package's postinstall knows this and leaves the old
  helper running (it compares the cdhash preinstall noted with the new one). `make install` kickstarts whenever the
  helper is registered: its rule came first, to fix the identical-cdhash case, and was never narrowed. Either way no
  helper serves the new app until the app re-registers it: after postinstall the old helper still pins the old app,
  and after `make install` the kickstart has stopped the old helper and the new one can't start. Whether that
  kickstart then reports a failure, and `make install` prints its warning, hasn't been checked.
  Giving `make install` postinstall's rule is an open item (docs/RELEASE.md "Not done yet").
- The silent upgrade notices a changed helper only from the user's own settings (`helperRegisteredCDHash`), because
  the old helper doesn't answer the new app. Another macOS user on the same Mac doesn't re-register, and lid mode
  fails for them until the user who registered it opens the new version. Open item, to fix before v1.0.1
  (docs/RELEASE.md "Not done yet").

**Bounded even for a client that passes.** A session holds the flag only while it heartbeats (45 s deadline). The
helper's battery and heat backstops run on their own events, not on client messages. Its sleep after a lost session or
a hang doesn't depend on the client either. One thing does: following an explicit *release* with a sleep is the app's
job, because only the app can tell a bag from someone at an external display. A release that skips it leaves the flag
at 0, so the Mac is back to ordinary keep-awake, which any process can do with `caffeinate`.

**What this doesn't cover.** Running `make install` from a tree other same-user code can write is the same as handing
that code root. The Makefile, the scripts it runs with sudo warm on the same terminal, and the `build/` bundle it
copies are all owned by the user. The pin protects only between installs. If that matters:
- build and install from a clean checkout, or from a separate account
- check `git status` before installing

`make install` copies with `ditto --noacl` and strips ACLs (`chmod -RN`), release.sh builds the package from a
`ditto --noacl` copy, and `InstallLocation.check` and lid-verify reject any item that carries one. Otherwise an ACL
added to `build/` would survive into a root-owned bundle and leave it writable by the user while every mode-bit check
passed. A separate locked signing keychain (`INSOMNIA_SIGN_KEYCHAIN`) stops other code from signing a client
silently. build.sh unlocks it only around the `codesign` steps.

**Files the helper writes.** The ownership file and boot marker live in /var/run, which is `root:daemon 0775`, not
root-only. Each write goes to `<name>.tmp`: any leftover is unlinked, then the file is created with
`O_CREAT | O_EXCL | O_NOFOLLOW`, fsynced and renamed over the real name. rename replaces whatever directory entry is
there (a file, a hard link or a symlink) without following it, and the old file stays in place until the rename, so
ownership is never missing on disk mid-write. The boot marker is read with `O_NOFOLLOW`. Only root or group `daemon`
can plant anything there, so this is hardening, not a fix for a reachable attack.

**v1 leftovers.** v1's ad-hoc path installed `/etc/sudoers.d/zz_insomnia`, which grants the user
`NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1`. It also installed a root safety daemon,
`/Library/LaunchDaemons/com.gdeml.insomnia.safety.plist`. Left behind, the sudoers rule lets any process running as
that user set the flag with no session, no heartbeat and no app rules. The helper sees a foreign flag: it never takes
it over, and only the boot reset and the battery backstop ever clear it. `make install`, `make uninstall` and the
installer package's preinstall boot the daemon out and delete both, plus v1's staging leftovers and boot marker,
whenever either file exists. They do it after the running app has quit, so a v1 app holding the flag through the rule
can release it first. If `SleepDisabled` is still 1 afterwards and the helper doesn't own it (no ownership file), they
print the `sudo pmset -a disablesleep 0` hint (preinstall's goes to `/var/log/install.log`). In preinstall no step of
this can fail the install.

## Line budget

3,048 app + 1,456 helper/shared + 1,311 tests + 978 scripts, Makefile, README and this document ≈ **6,800**
(`wc -l`), down from ~30,400. The security pass added most of the growth: the pin, the heat backstop, sleeping after
the helper's own resets, the shut-in and unattended rules, their tests, and this document's Security section.
