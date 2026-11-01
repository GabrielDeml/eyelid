# Insomnia: UX Specification

This file specifies every surface for v1. Behaviour lives in `../ARCHITECTURE.md`, and closed-lid internals live in `CLOSED_LID.md`. All sizes are in points.

---

## 1. Menu bar item

### 1.1 Glyph: the wide-awake moon (template image, drawn in code)

The menu bar item is a **moon with one eye**, not the panel's pair of eyes: a fat crescent tilted so it opens up and to the right, with one round eye in its belly. Every mood except `.awake` adds a small **badge** in one fixed slot at the upper right. The panel eyes, the Dock tile and the app icon keep the pair of eyes (§2.4, §3).

- **Canvas:** 22 × 16 pt inside the 22 pt bar, the same for every mood, so the status item never changes width. The moon is the outer disc (centre 8, 8; radius 6.5, extremes on half points 1.5…14.5) minus a bite disc (radius 4.4) offset 5.0 pt up and to the right along a ≈ 20° axis: the belly is 7.1 pt thick. The badge slot is centred at (18.6, 3.6).
- **Stroke:** 1.5 pt (2.0 under Increase Contrast), drawn 10% heavier at 2x (1.65 / 2.2) so it sits with SF Symbols such as Wi-Fi. Round caps and joins.
- **Eye:** a solid disc 3.8 pt across (radius 1.9, centre 5.25, 9.0) with a knocked-out catch-light up and to the right, at least 0.8 pt clear of the outline. Big enough to read as an open, friendly eye at 1x and 2x, not a speck.
- **Format:** `isTemplate = true`, alpha only, crisp at 1x and 2x. Knock-outs are path subtractions or even-odd fills (never a clear blend).
- **Colour:** never encodes state. Shape alone does.
- **1x rules:** stroke 1.0 pt (2.0 under Increase Contrast). The eye is hand-placed pixels: a 4 × 4 px disc with its corners off and a 1 px catch-light (columns 3…6, rows 7…10), a 4 × 2 px slit mid-blink, and a 4 px "‿" when closed; badges sit on whole pixels (the slot centre snaps to 18.5, 3.5).

| Mood (`EyeMood`) | Moon | Eye | Badge | When |
|---|---|---|---|---|
| `.asleep` | Outline | Closed: a "‿" lid line, stroked at moon weight | "z" | Nothing is holding the Mac awake |
| `.awake` | Outline | Open, round, with a catch-light | none | Manual hold (timed or indefinite) |
| `.watching` | Outline | Open, glancing up and to the right (0.4 pt; 1 px up at 1x) | 4-point sparkle | Only babysit, CLI or rule holds are active |
| `.lid` | **Solid** (the outline's outer size) | **Knocked out**: a clear ring around a solid pupil ("night vision") | Closed laptop (lid and base joined by a hinge on the left, open at the front) | Lid mode engaged (flag read back as 1) |
| `.squint` | Outline | Heavy-lidded: the lower half of the eye under a lid line tilted up at the outer corner | Sweat drop | An alarm guard: `thermal`, `lowPowerMode`, `batteryFloor`, `awakeBatteryFloor`. (`acRequired` and the two time caps keep the normal mood; H′ explains.) |
| `.alarmed` | Outline | Wider open (radius + 0.35 pt; 4 × 5 px at 1x) | Full-height "!" | Lid error or stuck |

**Lid is never a plain filled crescent.** That silhouette is SF Symbol `moon.fill`, which macOS shows in the menu bar while Focus / Do Not Disturb is on, so a solid crescent would read as "Focus is on". Lid mode stays the boldest state (the only solid one), and two things break the `moon.fill` silhouette: the large knocked-out eye with its pupil, and the laptop badge beside it.

**Blink** (§1.2): `blink` 0…1 closes the eye as a lens whose upper lid falls onto the lower one, drifting slightly down and right, and ends exactly on the asleep eye, so the toggle-off blink lands without a jump. Mid-blink is a level, symmetric lens, so no frame looks like the tilted squint. In lid mode the knocked-out eye closes the same way.

When several apply, the first one wins: `alarmed > squint > lid > awake > watching > asleep` (`EyeMood(status:lid:)` in `Models.swift`). `make snapshot` renders all six side by side at 1x and 2x, light and dark (`build/snapshots/menubar-glyphs.png`); check them there after any change.

### 1.2 Motion (the only motion the menu bar ever shows)

| Event | Animation |
|---|---|
| Toggle via the menu bar, hotkey or Dock | One blink, about 180 ms in total (3 frames: half, closed, half). |
| Final 60 s of a timed hold | One slow blink every 10 s. |
| Anything else | Static. **No idle blink or glance loops.** |

Under Reduce Motion, nothing animates: the glyph swaps instantly.

### 1.3 Timer text (optional)

`Settings.menuBarTimer` takes one of three values:

- `off`
- `lastTenMinutes` (the default)
- `always`

Rules for the text:

- **Format:** `TimeFormat.compact` (for example "42m", "1h 5m", "<1m"), set in SF Pro 11 with monospaced digits, 3 pt after the glyph.
- **When it shows:** only for timed holds. It never shows for ∞ or rule holds, which keeps the item narrow so macOS 27 doesn't eject it.
- **Refresh rate:** once a minute, or once a second during the final minute. The engine changes the string; the status item redraws only when the string changes.

### 1.4 Click model

| Input | Default action | Swappable? |
|---|---|---|
| Left-click | Open/close the **panel** | Yes: `Settings.leftClickAction` swaps it with right-click |
| Right-click / ctrl-click | **Toggle** (default duration), with one blink | Yes (it's the other action) |
| ⌥-click | **Why awake?** native menu (§1.5) | No |

Implementation:

- **Never assign `statusItem.menu`.** On 27.0.1 it drops clicks on multi-display setups.
- **macOS 27+:** set `statusItem.expandedInterfaceDelegate` (inside `if #available(macOS 27, *)`; the property is weak, so the controller owns itself). In `statusItem(_:didBegin:)`, read `NSApp.currentEvent`:
  - right-click, ctrl-click or ⌥-click: call `session.cancel()` and perform that action instead;
  - otherwise: show the panel below the item. When the panel closes, call `statusItem.expandedInterfaceSession?.cancel()`.
  - If the panel is already open without a session (Dock menu, Spotlight, `insomnia://panel`), cancel the session and close the panel: a click toggles, as on 14–26.
  - In `statusItemDidEndExpandedInterfaceSession(_:animated:)`, **close the panel** (keyboard menu navigation, a click on another extra).

  **Spike this first.** If right-click doesn't reach the delegate, fall back to the 14–26 path on 27 as well.
- **macOS 14–26:** `button.sendAction(on: [.leftMouseUp, .rightMouseUp])` with target/action, and an `NSPopover(.transient)` for the panel.
- **Focus:** call `NSApp.activate()` before showing any panel host, or an accessory app gets no keyboard focus.
- **Native menus** (the Why awake menu) open with `NSMenu.popUp(positioning:at:in:)` relative to the button.

### 1.5 Why awake? menu (⌥-click)

```
Why is my Mac awake?                         (disabled header)
──────────────────────────────
Insomnia
  You · 1h timer · screen on · lid
  Rule · Xcode is running
  Watching · ffmpeg (4411)
Guards
  Paused lid mode · running hot
Other apps
  zoom.us · Preventing display sleep
  caffeinate (61150) · Preventing idle sleep
System
  SleepDisabled: Yes (set by Insomnia)
  Lid: open · Thermal: nominal · AC · 95%
──────────────────────────────
Open Diagnostics…
Copy Report
```

- Sections with no rows are omitted. With nothing at all, it shows "Nothing. Your Mac is free to sleep."
- On macOS 27, items carry no images (`preferredImageVisibility` stays at default). Meaning lives in the text.

### 1.6 Tooltip and accessibility

| Property | Value |
|---|---|
| Tooltip | `Headline · subline` (e.g. "Wide awake · 42 min left") plus "\nClick: panel · Right-click: toggle · ⌥-click: why awake" |
| `accessibilityLabel` | "Insomnia" |
| `accessibilityValue` | A plain sentence in every tier, e.g. "Awake, 42 minutes left, lid mode on". Updated only on state change, never every second. |

### 1.7 Hidden by macOS

Tahoe+ has "Allow in the Menu Bar", and macOS 27 has overflow and ejection, so our item can be hidden. To detect it:

- 2 s after install, on `NSWindow.didChangeOcclusionStateNotification` of the button's window, and on `didChangeScreenParametersNotification`, check: `occlusionState` lacks `.visible`, **or** `window.screen == nil`, **or** the button's frame intersects `screen.auxiliaryTopLeftArea`/`auxiliaryTopRightArea` (behind the notch).
- If the item stays hidden for more than 3 s, treat it as hidden. This is a heuristic.

What to do when it's hidden:

- The first time, show the **Hidden card** (§7.2). If the panel is open (the first-run welcome), the card waits until the panel closes.
- Afterwards, the hotkey keeps working, and opening Insomnia from Spotlight/Finder (or "Open Panel" in the Dock menu) opens the panel as a floating window (§2.6).

---

## 2. Panel

### 2.1 Wireframe (320 wide, ≤ 340 tall, fixed regions, no scroll)

```
┌────────────────────────────────────────────────┐
│ ╭──────────╮                                   │
│ │  ◉    ◉  │  Wide awake                    ⋯  │  A B C
│ │  ‿‿‿‿‿‿  │  42 min left · until 15:12        │  D
│ ╰──────────╯                                   │
├────────────────────────────────────────────────┤
│  30m   1h   2h  [4h]  8h   ∞                   │  E
│  Until…   While…                               │  F
├────────────────────────────────────────────────┤
│  Keep screen on                         [●━━]  │  G
│  Stay awake with lid closed             [━━○]  │  H  (MacBooks only)
│     Ready · close the lid anytime              │  H' (fixed 14 pt slot)
├────────────────────────────────────────────────┤
│  "I've seen things. Mostly your tabs."         │  J  (quip or banner)
└────────────────────────────────────────────────┘
```

Height budget: header 96 · chips 28 · F 28 · G+H+H′ 72 · J 34, plus separators and padding. Every region is fixed, so the panel never changes size between states (the first-run card is the one exception). In **Professional**, which has no quips, row J and its separator collapse unless a safety banner or the mission report needs them: the size is fixed per tier and grows only for those. About 13 targets.

Variants:

- **Asleep:** the eyes are closed with a floating "z", the headline is "Sleep allowed", and the subline is "Click the eyes to stay awake".
- **Safety banner** (battery floor, heat, crash recovery, mission report): **replaces row J** with an icon, plain text and a ✕. Stays until dismissed or the next state change (the lid opening or closing while lid mode stays engaged isn't one, and neither is lid mode re-engaging right after the mission report, off → engaging → engaged, when a guard had released it while the lid was shut). The crash-recovery banner stays until dismissed.
- **First-run card** (§7.1): shown above row E on first launch only.

### 2.2 Element specs

| Id | Element | Size / type | Behaviour |
|---|---|---|---|
| A | **Eyes button** (mascot = toggle) | 72 × 72 circle. Eyes 44 wide. Progress ring 3 pt, inset 2. | State = `status.isAwake`. **Off → on:** a manual hold with the default duration. **On → off:** ends manual and babysit holds and **pauses every satisfied rule until its condition goes false and true again** (subline "Xcode rule paused until Xcode quits"). If only client holds remain, the button is disabled with tooltip "Held by a command" and subline "Held by `make` (CLI)". The ring traces elapsed/total for timed holds. Hover: 1.03 scale, tooltip "Keep awake" / "Allow sleep". Rapid clicks feed the **poke egg** (§9). |
| B | Headline | SF Pro 17 semibold, primary | The plain headline from §8. |
| C | `⋯` menu button | 22 × 22, borderless, `ellipsis.circle` | Menu: **Sleep Now**, Why awake?…, Settings… ⌘,, About Insomnia, Quit ⌘Q. |
| D | Subline | SF Pro 12, secondary, monospaced digits | timed: "42 min left · until 15:12" (last hour: `TimeFormat.countdown`, "41:07 left"). End times more than 20 h away name the day, "until Sat 7:13", and more than 6 days away the date, "until Nov 9 at 7:13" (`TimeFormat.endTime`, shared by the panel, status item, Dock menu, CLI, Why awake and notifications). ∞: "Until you say so". Non-manual primary hold: "While ffmpeg (4411) runs · **Stop**" (Stop releases the babysit hold; CLI holds show "Held by `make` (CLI)" and rules show "Rule", neither with Stop). More holds: "· 2 more ›" (opens Why awake). Suspended: the reason in orange. This replaces the old holds list. |
| E | Duration chips | Capsules 28 tall, SF Pro 12 medium, 8 pt gap | Clicking starts a manual hold right away (replacing any manual hold, which also serves as "extend"). The running preset's chip is filled amber with dark text and is `.isSelected` for VoiceOver. Tooltip: duration name (Cheeky and Unhinged). |
| F | `Until…` / `While…` | Same capsule style | **Until…** opens an inline popover with an hour:minute `DatePicker` (step 5 min) and **Start**; a past time means tomorrow ("tomorrow 07:00"). **While…** opens a menu: *Running apps ▸*, *Suggested ▸* (only names from `claude, codex, xcodebuild, ffmpeg, rsync, make, cargo, npm, python3` that the matcher in `Models.swift` `WatchTarget.process` actually finds, shown with pid), *Process name…*, *PID…*. Extend is not a chip: use `+`, the Dock menu, the notification action or the VoiceOver action. |
| G | Keep screen on | Row 28 tall, SF Pro 13, trailing `Toggle(.switch)`, mini | Binds `Settings.keepScreenOn`; applies live to manual and babysit holds (rules have their own box). |
| H | Lid toggle | Same style. Hidden when `!hasLid`. | Binds `Settings.closedLidMode`; applies to **every** hold except fixed CLI/URL ones (`CLOSED_LID.md` §5). Helper missing: turning it on opens **Lid setup** (§6) instead (VoiceOver value "Off", hint "Requires one-time setup. Opens setup."). Turning it on while nothing holds the Mac **also starts a manual hold** (default duration) with one blink. Turning it off never ends a hold. |
| H' | Lid sublabel | SF Pro 11, fixed 14 pt slot (empty when silent) | Wording per `LidStatus` in §5. |
| J | Quip / banner | SF Pro 12, secondary, 2 lines max, fixed 34 pt | `Narrator.line(...)` within the quip budget (`PRODUCT.md` §4 rule 11), crossfading 200 ms. Empty in Professional and when the line is nil. |

**Spacing:**

- Outer padding: 14.
- Section separators: 1 px `separatorColor`.
- Vertical rhythm: 10 between rows, 12 around separators.

**Window:**

- **macOS 27 (and the floating fallback on any version):** `PanelWindow`, a borderless `NSPanel` subclass with `canBecomeKey == true`. Material: `NSGlassEffectView` (`cornerRadius = 12`, hosting view as `contentView`) on macOS 26+, else `NSVisualEffectView(.popover)`. `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`, `level = .popUpMenu`. Anchored to `button.window.screen` at click time.
- **macOS 14–26 from the menu bar:** `NSPopover` supplies the material.

### 2.3 Colour tokens (defined once in `UI/Theme.swift`)

| Token | Light | Dark | Use |
|---|---|---|---|
| `accentAwake` | `#E8940C` (amber) | `#FFB547` | Ring, selected chip fill, irises |
| `onAccent` | `#1A1206` | `#1A1206` | Text on amber (white on amber fails 4.5:1) |
| `accentLid` | `systemIndigo` | `systemIndigo` | Lid toggle tint, night-vision glow (panel and Dock tile) |
| `sleepTone` | `secondaryLabelColor` | `secondaryLabelColor` | Closed eyes, "z" |
| `warning` | `systemOrange` | `systemOrange` | Banner icon and tint, other warning icons |
| `danger` | `systemRed` | `systemRed` | Error icons and tints |
| `warningText` | `#A84A00` | `#FF9F0A` | Small warning text (suspended subline, H′), ≥ 4.5:1 |
| `dangerText` | `#C0201A` | `#FF453A` | Small error text (lid error / stuck), ≥ 4.5:1 |
| `sclera` | `#FFFFFF` | `#F4F1EA` | Panel eyes (the menu bar glyph is a template) |

Colour is **never** the only signal. Every coloured state also changes text and shape.

### 2.4 Panel eyes motion (only while the panel is visible)

| Event | Animation | Reduce Motion |
|---|---|---|
| Idle, awake | Blink every 4–9 s (random). Pupils follow the cursor, up to ±2 pt, eased. | None |
| Idle, asleep | Closed lids. A "z" drifts up and fades every 6 s. | Static "z" |
| Toggle on | Lids snap open (120 ms spring), pupils dilate once (+20%, 200 ms), ring fades in | Crossfade 150 ms |
| Toggle off | Lids lower (350 ms ease-in), then the "z" fades in | Crossfade 150 ms |
| Extend | Double-take: two quick blinks | None |
| Lid engaged | Faint indigo glow under the lower lids (opacity 0.35) | Static glow |
| **First wake** (first launch) | Eyes open slowly (600 ms), blink twice, find the cursor; then the welcome card | Crossfade |
| **Night vision** (first lid engagement each day) | Indigo glow sweeps across the eyes (400 ms); the Dock tile pulses once | Static glow |
| **Mission report** (reopen after ≥ 5 min) | Banner grows into a card; numbers count up (600 ms) | Final numbers |
| **Eye bags** (≥ 24 h continuously awake) | Subtle bags under the eyes; ≥ 72 h adds thin amber veins | Same (static art) |
| Suspended (heat) | Squint, plus one sweat drop that slides once | Static squint |
| Error | Right eye shows "×" | Same |
| Final 60 s | Heavy lids (40% closed) | Same (it's a static pose) |

Animate **only while the panel window is key/visible** (≤ 30 fps, redrawing only frames that changed; the open, idle
panel stays under 2% of a core). No timers run when it's closed.

### 2.5 Keyboard (the panel is first responder when it opens)

| Key | Action |
|---|---|
| Space | Press the focused control |
| Return | Toggle (when the eyes or nothing is focused) |
| 1–6 | Presets 30m, 1h, 2h, 4h, 8h, ∞ |
| U / W | Until… / While… |
| `=` / `+` | Extend +15m |
| S | Toggle Keep screen on |
| L | Toggle lid mode |
| ⌘, / ⌘Q | Settings / Quit (via the app's main menu) |
| Esc / ⌘W | Close the panel |

Every control is reachable with Tab and shows a focus ring. Single-key shortcuts are off while a text field is first responder. The app installs a minimal main menu (App: About, Settings… ⌘,, Quit ⌘Q; File: Close ⌘W; Edit: Undo/Redo/Cut/Copy/Paste/Select All) so text fields get standard editing keys and ⌘W closes Settings, About and Lid Mode setup.

### 2.6 Floating panel fallback

This is used when the status item is hidden or when "Open Panel" or "Until…" is chosen from the Dock menu:

- The same `PanelView` in `PanelWindow` (§2.2 Window), shown after `NSApp.activate()`.
- Positioned top-centre of the screen under the mouse (`NSEvent.mouseLocation`), 80 pt below that screen's menu bar (`visibleFrame` top), so it's never under a full-screen auto-hidden bar.
- It closes on Esc or when it loses key status.

---

## 3. Dock (`Settings.showInDock`, default on; chosen on the welcome card)

| Aspect | Spec |
|---|---|
| Activation policy | Dock on: `.regular`. Dock off: `.accessory`. Switching never closes open windows: the switch deactivates the app for a moment, so the panel ignores that focus loss and, ~0.1 s later, Insomnia re-activates and brings the panel or Settings back to the front. |
| Tile | `NSApp.dockTile.contentView` is a custom view drawing `EyesRenderer.appIcon(size: 128, mood:)`: an indigo→violet squircle, large eyes with amber irises (awake) or closed arcs with "z z" (asleep), and night-vision eyes plus indigo glow when lid mode is engaged. |
| Time | A white rounded **pill drawn inside the tile** at the bottom centre (SF Pro Rounded 22 bold, monospaced digits): "42m", "1h 5m", "∞", the first 4 letters of a watched/CLI label ("ffmp…"), or nothing (asleep, rules). It's **not** `badgeLabel`, because a red badge means "needs attention". The Dock tile has no accessibility API; VoiceOver reads the app name, and the status item carries the state. |
| Badge | `dockTile.badgeLabel = "!"` **only** for lid `.error`/`.stuck`. Otherwise nil. |
| Redraw | `dockTile.display()` only when (mood, pill string) changes. Under 1 h that's at most once a minute, plus once a second in the last minute. |
| Click (`applicationShouldHandleReopen`) | Only a reopen **sent by the Dock** (sender PID == Dock's PID) with `showInDock` on **toggles** (eyes-button semantics, §2.2 A) with one tile blink. Any other reopen (Spotlight, Finder, `open`, the CLI) **opens the panel**. Never bounces. |
| Dock menu (`applicationDockMenu`) | Shown below. |

```
Wide awake · 42 min left            (disabled; the subline's text only, no links)
Reset Sleep with Password…          (lid stuck only)
Keep Awake For ▸   30m 1h 2h 4h 8h ∞ Until…
Extend +15m                         (timed only)
Allow Sleep                         (awake only)
──────────
✓ Keep Screen On
✓ Stay Awake With Lid Closed        (Set Up… if helper missing; hidden without a lid)
──────────
Open Panel
Why Awake?
Settings…
```

---

## 4. Settings (four toolbar tabs, `Form(.grouped)`, 540 wide)

### 4.1 General

```
Startup
  Launch at login                                    [✓]
  Start keeping awake at launch                      [ ]   (not when the command line or a link starts Insomnia)
Behaviour
  Default duration                        [Until I stop ▾]   (30m…8h, Until I stop)
  Clicking the moon in the menu bar      (•) Opens panel   ( ) Toggles
  Show timer in menu bar            [ Off | Last 10 min | Always ]
  Show in Dock                                       [✓]
  Notify before a timer ends and when it ends        [✓]
  Global hotkey (toggle)            [ ⌃⌥⌘I ]  [Clear]
     Include ⌘ or ⌃.                                   (recorder rejects ⌥/⌥⇧-only combos)
     ⚠ That shortcut is taken by another app.         (eventHotKeyExistsErr only; else "Couldn't register (code N)")
Personality
  [ Professional | Cheeky | Unhinged ]
  "Lid mode on. I'll watch through the lid. Don't ask."   ← live sample, reshuffles on change
```

### 4.2 Automations

```
Rules: keep awake automatically
  ┌───────────────────────────────────────────────────────────────┐
  │ [●] While [Xcode ▾] is running        ☐ screen  ☐ lid   ●  [−] │  ● = active now
  │ [●] While process [ffmpeg     ] runs  ☑ screen  ☐ lid   ○  [−] │
  │ [ ] While on power adapter            ☐ screen  ☐ lid   ○  [−] │
  │ [+ Add rule ▾]  App… · Running app ▸ · Process name… ·          │
  │                 On power adapter · External display connected   │
  └───────────────────────────────────────────────────────────────┘
  Rules never override a guard. The panel's lid switch applies to rules too;
  "lid" here means "even when the switch is off". It still needs lid mode set up.

Command line
  insomnia   ● Installed at ~/.local/bin/insomnia  [Reinstall] [Remove]
             ⚠ ~/.local/bin is not on your PATH. Add: export PATH="$HOME/.local/bin:$PATH"  [Copy] [Check Again]
  A PATH warning is re-checked on activation (at most every 20 s) and with Check Again.

URL scheme (works from Shortcuts → "Open URLs" or Terminal → open "…"; links can't turn lid mode on, so use the CLI for that)
  insomnia://on?for=45m            [⧉]
  insomnia://on?until=17:30&screen=1  [⧉]
  insomnia://off                   [⧉]
  insomnia://extend?by=15m         [⧉]
  insomnia://toggle  · insomnia://panel  · insomnia://sleep        [⧉]   (sleep: refused while a command, rule or While… watch holds; never asks)
```

Each rule is one sentence-shaped row; there's never a modal form. The `screen` and `lid` checkboxes are per rule and default to off.

### 4.3 Lid & Safety ("Safety" without a lid; hidden with neither lid nor battery)

```
Stay awake with lid closed                                   (MacBooks only)
  Status     ● Ready · helper allowed                        [Test…] [Remove…]
             ○ Not set up                                    [Set Up…]
             ◐ Waiting for your OK in System Settings         [Open System Settings]
             ◐ Helper isn't responding                       [Repair…]
             ⚠ Install Insomnia with make install to use lid mode  ⓘ
             ⚠ Helper missing from the app. Reinstall Insomnia.
  Turn the screen off when the lid closes                    always on ⓘ
  Only on power adapter                                      [ ]
  Time limit with the lid closed
    On battery                                  [ 1 hour ▾ ]   (15m, 30m, 1h, 2h, 4h, 8h)
    On power adapter                       [ ] [ 4 hours ▾ ]   (1h, 2h, 4h, 8h, 12h, 24h; picker disabled until checked)
    On battery there's always a limit; on power, lid mode runs until you stop it unless you set one.

Guards
  Turn off lid mode at battery                  ──●────────  20%   (10–50, always on)
  Also stop keeping awake at that level                      [ ]   (battery only)
  Pause lid mode when your Mac runs hot          ⓘ  (always on)
  Pause lid mode in Low Power Mode               ⓘ  (always on)

  ⓘ Lid mode disables macOS's own low-battery sleep, so its guards can't be switched off.
```

- `versionMismatch` never shows: the app re-registers silently at launch (`CLOSED_LID.md` §2.6) and lands on Ready or "Waiting for your OK".
- `.unsafeLocation` ⓘ: "The helper runs as root, so it only runs from /Applications/Insomnia.app owned by the system. `make install` puts it there." Set Up… is not offered from any other copy (e.g. `build/`).
- `.notFound` appears only when the helper or its plist is really missing from the bundle; a never-set-up helper shows "Not set up".
- **Unsigned builds (sudoers backend)** show the old rows instead: "● Ready (sudoers rule ✓ · safety daemon ✓)", "◐ Partly installed: safety daemon missing [Repair…]", "◐ Safety daemon is off in Login Items [Open Login Items]". If a helper from a signed build is still registered (`.leftoverHelper`), the only row is "◐ A helper from a signed build is still registered [Remove…]"; the sudoers setup isn't offered until it's gone.
- Signed build with leftover sudoers files: an extra row "Old password-based setup found [Remove old setup…]".
- The battery-floor slider moves in whole percents and saves when you let go (keyboard and VoiceOver changes save at once), so dragging past the current level can't end a session mid-drag.
- **Reset with password…** (when stuck) shows a failed reset inline like the other actions; a cancelled prompt says nothing. The panel's H′ link, the Dock menu item and the `lid-stuck` notification's **Reset…** have no inline row, so a failed reset there posts `lid-stuck` again: "Lid mode is still stuck on" / "The reset didn't work: {problem} Your Mac won't sleep until it's reset." A cancelled or failed Remove… leaves lid mode as it was (it re-engages if it's wanted).

### 4.4 Diagnostics

```
Live
  SleepDisabled  No          Lid  Open          Thermal  Nominal
  Power  AC · 95% · not charging          Low Power Mode  Off
  Helper  privileged helper 1.0.0 · team {teamID} · allowed · idle      (unsigned: sudoers ✓ · safety daemon ✓ · watchdog idle)
Why awake?                                                   [Refresh]
  (same sections as the ⌥-click menu, as a table: Who · What · Since)
Event log (last 200)                                         [Copy] [Clear]
  15:01:12  hold+ manual 1h screen
  15:01:12  lid  engaged (readback ✓)
  15:22:40  guard thermal → lid suspended
About                                                        [About Insomnia…]
```

The **About** sheet (from `⋯` or here) shows big panel eyes, the version, stats (total awake, sessions, longest, lid-closed time, ≈ cups of coffee at 1 per 45 min), milestones earned, [Reset Stats], and a GitHub link.

---

## 5. Lid states (sublabel H')

| `LidStatus` | Sublabel (all tiers) | Toggle | Glyph impact |
|---|---|---|---|
| `.off`, setting off | none | off | none |
| `.off`, setting on, Mac asleep | "Armed · applies whenever I'm awake" | on | none |
| `.off`, setting on, fixed CLI/URL hold without lid | "Off for this session" | on | none |
| `.needsSetup`, helper `.notInstalled` | "Setup needed ›" (opens §6) | off (it can't be on) | none |
| `.needsSetup`, helper `.requiresApproval` | "Allow in System Settings ›" (opens the approval step) | off | none |
| `.needsSetup`, helper `.unreachable` / `.notFound` | "Helper isn't responding · Fix ›" (opens Lid & Safety) | off | none |
| `.needsSetup`, helper `.unsafeLocation` | "Install in Applications to use · Why? ›" (opens Lid & Safety) | off | none |
| `.needsSetup`, sudoers `.leftoverHelper` | "Old helper still registered · Fix ›" (opens Lid & Safety) | off | none |
| `.needsSetup`, sudoers `.daemonDisabled` / `.partial` | "Safety daemon is off · Fix ›" | off | none |
| `.engaging` | "Applying…" plus a spinner | on | none |
| `.engaged(lidClosed: false)` | "Ready · close the lid anytime" | on | `.lid` |
| `.engaged(lidClosed: true)` | "Engaged · lid closed" | on | `.lid` |
| `.suspended(thermal / lowPowerMode / batteryFloor)` | "Paused · running hot / Low Power Mode / battery at {floor}%" (orange) | on | `.squint` |
| `.suspended(acRequired / lidBatteryCap / lidACCap)` | "Waiting for power adapter" / "Paused · {cap} limit on battery" / "Paused · {acCap} limit on power" (secondary) | on | normal |
| `.latched` | "Paused · open the lid to resume" (secondary) | on | normal |
| `.error(e)` | "Couldn't apply · Mac sleeps normally · Retry" / overridden: "Turned off by something else · Retry" (red) | on | `.alarmed` |
| `.error(.foreignFlag)` | "Another app already turned sleep off · Why? ›" (secondary) | on | normal |
| `.error(.otherUser)` | "Another user on this Mac is using lid mode" (secondary) | on | normal |
| `.stuck` | "Stuck on · Mac won't sleep · Reset with password…" (red) | on | `.alarmed` |

---

## 6. Lid mode onboarding flow

Signed builds (helper backend). Three steps, all inside one sheet (panel or Settings); never a modal alert.

```
[Lid toggle ON, helper .notInstalled]            ([Set Up…] in Lid & Safety starts here too; never from a copy outside
                                                  /Applications or not root-owned: .unsafeLocation, §4.3)
        │
        ▼
┌─ 1 · Explain ────────────────────────────────────────────────────────┐
│  Stay awake with the lid closed                                      │
│  • Your Mac won't sleep when you close the lid. The screen turns off. │
│  • Insomnia adds a small helper that does exactly one thing: turn     │
│    sleep off and back on. Only this Insomnia can talk to it.          │
│  • If Insomnia quits, crashes or freezes, the helper turns sleep back │
│    on. It also restores sleep after a restart and at 10% battery.     │
│  • Keep it out of bags. On battery it stops after {cap}, pauses when  │
│    hot or in Low Power Mode, and turns off at {floor}%.               │
│  • Apple menu ▸ Sleep is blocked while engaged. Use ⋯ ▸ Sleep Now.    │
│                                    [Not Now]  [Set Up…]               │
└──────────────────────────────────────────────────────────────────────┘
        │ Set Up… → SMAppService register() (no password here)
        ├── registrationFailed → inline red "Couldn't add the helper (code N)" + [Copy details]
        ▼
┌─ 2 · Approve (status .requiresApproval; re-checked every 1 s) ───────┐
│  One more step: allow Insomnia in System Settings                    │
│  General ▸ Login Items & Extensions ▸ turn on Insomnia.              │
│  macOS asks for Touch ID or your password there.                     │
│                         [Not Now]  [Open System Settings]            │
└──────────────────────────────────────────────────────────────────────┘
        │ user switches it on (app detects .enabled + XPC ✓, no relaunch)
        ├── enabled but no answer in 2 s → inline red "The helper isn't responding." [Repair…]
        ▼
┌─ 3 · Done ───────────────────────────────────────────────────────────┐
│  "Ready. Close the lid whenever."   [Try it: close the lid for 10 s] │
│   → on reopen: "Survived. Welcome to the night shift." / Prof.: "Verified." │
└──────────────────────────────────────────────────────────────────────┘
        │ if the lid switch asked for lid mode: switch it on and engage now (H′ "Applying…" → "Ready · close the lid
        │ anytime"). From the welcome card, the Dock or Lid & Safety, setup only sets up: the switch stays as it was.
```

- **Try it** runs on its own 2-minute hold with lid mode (never the lid switch), ended when the drive ends or the sheet closes. It never replaces a session you started; with one running, the drive works only if that session already has lid mode.
- **Not Now** (either step, also the close button or a cancelled password prompt): the toggle reverts (the lid setting is switched off while the helper isn't ready), quip `setup cancelled`, no error tone. A registered-but-unapproved helper stays that way; H′ and Lid & Safety then say "Allow in System Settings ›", which reopens step 2 directly.
- macOS shows its own "Background Items Added" notification during step 2. That's expected; step 2's copy matches it.
- **Approval switched off later** in System Settings: lid mode releases (the helper resets on stop), H′ shows "Allow in System Settings ›". No notification.
- **Unsigned builds (sudoers backend)** keep the original two-step flow: step 1 says instead "You'll type your password once. Insomnia adds a rule that allows exactly two commands (sleep off / sleep on), **usable by any app running as you**, and a tiny safety daemon that restores sleep after a restart and at 10% battery." → macOS admin prompt ("Insomnia needs your password once to keep your Mac awake with the lid closed.") → cancelled: as Not Now; script error: inline red text + [Copy details]; success: step 3. Safety daemon off in Login Items (`.daemonDisabled`): step 2, worded for the daemon and re-checked every 1 s. Partly installed (`.partial`): inline "Setup didn't finish" + [Repair…].

**Runtime moments:**

- **First engagement on battery** (once ever, `lidBatteryCalloutShown`): the banner says "Don't put me in a bag. Seriously." In Professional it says "Keep the Mac ventilated while the lid is closed."
- **Lid closes while engaged** (or the last external display is unplugged with the lid shut): if there's no external display, run `pmset displaysleepnow`. Show nothing (the user isn't looking).
- **Lid reopens** after at least 5 min closed and engaged: the **mission report** card (row J, §2.4): "While you were away: 1h 12m closed · battery 82→61% · stayed cool" (stayed cool / got warm / got hot). Plain in every tier, plus one line in Cheeky and Unhinged.
- **Launch recovery fired:** the banner states the plain fact, "Restored normal sleep after an unexpected quit."; the `recovered` notification carries the line.

---

## 7. First run

### 7.1 Welcome card (in the panel, opened automatically once)

```
Hi. I'm Insomnia. I keep your Mac awake.
• Click my eyes (or right-click the moon in the menu bar) to toggle. ⌥-click: why awake.
Where should I live?       ( ) Menu bar   (•) Menu bar + Dock
Awake with the lid closed? [Set up later]  [Set up now]     (MacBooks only)
                                                      [Got it]
```

"Got it" requests notification permission (§10).

### 7.2 Hidden card (floating panel, when §1.7 detects the item is hidden)

```
macOS hid me from the menu bar. I'm still here.
Open Insomnia from Spotlight to see this panel.
[        Show Me in the Dock        ]   (default; "Open Panel" when the Dock icon is already on)
[      Open Menu Bar Settings       ]
[            Keep Hidden            ]
```

Full-width buttons, stacked in this order (three side by side don't fit in 320 pt).

- **Open Menu Bar Settings** opens System Settings ▸ Menu Bar, best effort (`x-apple.systempreferences:com.apple.ControlCenter-Settings.extension`), and falls back to the System Settings app.

---

## 8. State × UI matrix

| State (`AwakeStatus` + `LidStatus`) | Menu bar glyph | Menu bar text | Panel headline / subline | Dock pill | VoiceOver value |
|---|---|---|---|---|---|
| asleep | asleep | none | Sleep allowed / Click the eyes to stay awake | none | "Sleep allowed" |
| timed | awake | per §1.3 | Wide awake / 42 min left · until 15:12 | 42m | "Awake, 42 minutes left" |
| indefinite | awake | none | Wide awake / Until you say so | ∞ | "Awake until you stop it" |
| watching | watching | none | Awake for ffmpeg / While ffmpeg (4411) runs · Stop | ffmp… | "Awake while ffmpeg runs" |
| client | watching | none | Awake for make / Held by `make` (CLI) | make | "Awake while make runs" |
| automatic | watching | none | Awake: Xcode is running / Rule · edit in Settings | none | "Awake, rule: Xcode is running" |
| rules paused by the eyes | asleep | none | Sleep allowed / Xcode rule paused until Xcode quits | none | "Sleep allowed, rules paused" |
| any awake + lid engaged | lid | as above | (headline as above) + H′ "Engaged…" | as above, night-vision eyes | "…, lid mode on" |
| any awake + lid paused (alarm guard) | squint | as above | headline as above, H′ orange | as above | "…, lid mode paused: running hot" |
| any awake + lid paused (AC-only, either cap, latched) or foreign flag | as without lid | as above | headline as above, H′ secondary | as above | "…, lid mode paused: {reason}" |
| suspended (opt-in awake floor) | squint | none | Paused: battery at {floor}% / Plug in to resume | none | "Paused, battery at {floor} percent" |
| lid error | alarmed | as above | Lid mode needs attention / Mac sleeps normally | as above + `!` badge | "Lid mode failed, sleep works normally" |
| lid stuck | alarmed | as above | Lid mode is stuck on / Your Mac won't sleep · Reset with password… | as above + `!` badge | "Lid mode stuck on, Mac won't sleep" |
| desktop Mac (no lid) | as above | as above | no H/H′, no lid menu items, no lid rule box; no battery UI without a battery | as above | as above |

---

## 9. Poke Easter egg

When the panel eyes get **5 or more clicks, each within 8 s of the last** (one counter, the engine's), each further click still toggles (we never block a toggle), and the quip row shows `Narrator.line(.poke(count))`:

| Clicks | Effect |
|---|---|
| 5 | First poke line |
| 10 | Second poke line |
| 20 | Eyes cross for 2 s (no Reduce Motion), plus a line |
| 50 | "Complaint filed." The **Poked 50×** badge appears in About |

The egg is off in Professional (the toggles still work).

---

## 10. Notifications (`UNUserNotificationCenter`, **never with sound**, banner style)

| Id | When | Gate | Title (all tiers, plain) | Body (personality) | Actions |
|---|---|---|---|---|---|
| `ending-soon` | 5 min before a timed manual hold ends | `sessionNotifications` | "Insomnia: 5 minutes left" | e.g. "Want a refill?" | **+15 min** (`EXTEND_15`), **Allow Sleep** |
| `ended` | Timed hold expired | `sessionNotifications` | "Your Mac can sleep again" | `deactivated(timer)` pool | none |
| `battery-floor` | Lid battery floor tripped | always | "Lid mode off at {floor}% battery" | `battery floor` pool | none |
| `battery-stop` | Opt-in awake floor tripped | always | "Stopped keeping awake at {floor}% battery" | plain | none |
| `lid-heat` | Lid suspended for thermal, once per engagement | always | "Lid mode paused: Mac is hot" | e.g. "Is it in a bag?" | **Allow Sleep** |
| `lid-lpm` | Lid suspended for Low Power Mode, once per engagement | always | "Lid mode paused: Low Power Mode" | plain | none |
| `lid-cap` | Lid suspended for a time cap | always | "Lid mode paused after {cap} closed on battery" / "Lid mode paused after {acCap} closed" | plain | none |
| `lid-error` | Apply/readback failed, safety net lost, or overridden (not `foreignFlag`) | always | "Lid mode couldn't be applied" / "Lid mode was turned off" | "Your Mac will sleep normally." | **Retry** |
| `lid-stuck` | Flag is 1 and every reset failed; again after a failed Reset with password… from the panel, Dock or this notification (§4.3) | always | "Lid mode is stuck on" | "Your Mac won't sleep until it's reset." | **Reset…** |
| `foreign-flag` | `SleepDisabled = 1` without our marker (once per boot) | always | "Something else turned off sleep" | "Another app or admin set it. Insomnia won't change it." | **Why Awake?** |
| `recovered` | Launch recovery reset the flag | always | "Normal sleep restored" | `recovered` pool | none |
| `target-exited` | Babysit target exited and the hold ended | `sessionNotifications` | "ffmpeg finished" | e.g. "Babysitting shift over." | none |

- **Authorization:** requested at welcome-card "Got it", at lid setup success (step 3), and when `sessionNotifications` is switched on. Posts made before the answer are queued, so the first safety notification is never lost. When the queue drains, the gate is checked again and session notifications (`ending-soon`, `ended`, `target-exited`) older than 5 minutes are dropped. A remembered denial never drops a post: macOS enforces it, so turning notifications on in System Settings takes effect without a relaunch.
- **Allow Sleep** does what clicking the eyes does: ends manual and While… holds and pauses satisfied rules.
- **While the app is frontmost:** `willPresent` returns `[.banner, .list]` (still no sound), so the notification also stays in Notification Center.

---

## 11. Copy deck (seed lines; full pools live in `Sources/Insomnia/Core/Copy/Copy+<Tier>.swift`)

Professional has no quip row: `Narrator.line` is `nil` for every moment. Its one or two lines per pool exist only for notification bodies (and `lid engaged` for the Settings sample); `nil` means no pool.

| Moment | Professional | Cheeky | Unhinged |
|---|---|---|---|
| **activated** | nil | Eyes open. Blinking is for quitters. | I have had eleven espressos and I can see sounds. |
|  |  | Wide awake. Coffee optional. | Sleep is a construct. Constructs are optional. |
|  |  | On it. Nobody naps on my watch. | I HAVE NOT BLINKED SINCE TUESDAY. |
| **deactivated** (user) | nil | Okay, okay. Resting my eyes. | Fine. FINE. Goodnight. (I'll be thinking.) |
|  |  | Clocking out. Sweet dreams, little Mac. | Closing my eyes. Not sleeping. Never sleeping. |
| **deactivated** (timer) | The timer ran out. | Timer's up. Goodnight, sweet Mac. | The prophecy is fulfilled. I may rest. |
| **idle** (panel opens while asleep, ≤ 1/day) | nil | Off duty. One eye open. Metaphorically. | zzz… (I am pretending. Click me.) |
|  |  | Napping permitted. I'll be over here. | Dreaming of electric sheep. They're also awake. |
| **awake 2h+** | nil | Two hours in. Still blinking manually. | I've counted every pixel. Twice. |
| **awake 8h+** | nil | A full workday. The owl union sends regards. | Eight hours. I've started naming the fans. |
| **awake 24h+** | nil | A whole day. I've seen things. Mostly your tabs. | 24 hours. The progress ring went all the way round. So did I. |
| **awake 72h+** | nil | Three days. Respectfully, have you tried rebooting? | I can see new colours. One of them is "uptime". |
| **watching** | nil | Watching ffmpeg like a hawk. A sleepy hawk. | Babysitting `claude`. We've agreed nobody naps. |
| **target exited** | Insomnia stopped keeping your Mac awake. | ffmpeg's done. Babysitting shift over. | The child has left the nest. I may now weep and nap. |
| **lid engaged** | Lid mode is on. | Lid mode on. I'll watch through the lid. Don't ask. | The lid is a suggestion. I reject suggestions. |
| **lid reopened** | (report only) | Welcome back. I kept the lights on in here. | You opened the lid. I never closed my eyes. One of us is a professional. |
| **thermal** | Make sure it has airflow and isn't in a bag. | Getting toasty in here. Is this a bag? | IT IS HOT IN HERE. Is there a bag involved? Pausing. |
| **low power mode** | nil | Low Power Mode. I'll keep it low-key. | Low Power Mode detected. Entering a whisper. |
| **battery floor** | Your Mac will sleep normally. | {floor}%. Lid mode's tapping out so your Mac doesn't. | Battery at {floor}%. I go down with the ship. Your Mac doesn't. |
| **recovered** | Restored normal sleep after an unexpected quit. | I left the lights on last time. Fixed. | Crashed last time. I cleaned up after myself. Sleep works normally. |
| **setup done** | nil | All set. Lid mode is standing by. | The ritual is complete. The lid holds no power over us now. |
| **setup cancelled** | nil | No worries. The lid wins this round. | Declined. Respect. I'll be here. Waiting. |
| **poke 5** | n/a | Ow. | You've poked me 5 times. HR has been notified. |
| **poke 10** | n/a | I'm going to need you to stop. | I'm calling my lawyer. My lawyer is also an app. |
| **poke 20** | n/a | Now I'm cross-eyed. Happy? | I CAN SEE MY OWN NOSE AND I DON'T HAVE ONE. |
| **milestone 100 h** | n/a | 100 hours awake. I've filed for a new eyelid warranty. | 100 hours. I have transcended the concept of a bedtime. |
| **milestone 500 h** | n/a | 500 hours. The coffee machine knows my name. | 500 hours. I am no longer tired. I am beyond tired. I am tired's landlord. |
| **milestone 1000 h** | n/a | 1,000 hours. I'd like to speak to your manager. Of sleep. | 1,000 hours awake. I am the uptime now. |
| **date: 3–5 AM** | nil | Small hours. Peak hours for both of us. | Small-hours club. Members: you, me, and the fridge hum. |
| **date: Oct 31** | nil | Boo. Your Mac is too awake to be scared. | Spooky season. The call is coming from inside the menu bar. |
| **date: New Year 00:00–00:10** | nil | You stayed up for this. So did I. | NEW YEAR. SAME EYES. |

**Escalation buckets:** `.awake(hours:)` fires on entering 2, 8, 24 and 72 h of continuous awake. Each bucket fires once per hold. **Quip budget** and Professional placement: `PRODUCT.md` §4 rules 7 and 11 (Professional lines appear only in notification bodies). `{floor}`, `{cap}` (battery cap) and `{acCap}` are filled from Settings; never hard-code them. There is no `{duration}`: a line can't know the hold's length.

**Date lines:** they replace an `activated` or `idle` line with 1-in-3 probability when their window matches, at most once per window. They are earned, so they neither wait for nor spend the quip budget, and a date line on panel open doesn't use up the day's `idle` line. Never in Professional.

---

## 12. Accessibility checklist

| Area | Requirement |
|---|---|
| Status item | Label "Insomnia". Value as in the §8 VoiceOver column, updated on state change only. Help text describes the clicks. |
| Eyes button | Role `.toggle`, label "Keep awake", value from `status.isAwake` ("On, 42 minutes left" / "On, rule: Xcode is running" / "Off"). Disabled with hint "Held by a command" when only client holds remain. Custom actions: "Extend 15 minutes", "Allow sleep". The ring is `accessibilityHidden`. |
| Panel eyes art | Decorative; the headline carries the meaning. |
| Chips | Label "1 hour", "Until a time", "While an app runs"; the running preset has `.isSelected`. Funny names go in `accessibilityHint` (Cheeky and Unhinged). |
| Subline Stop link | Label "Stop watching ffmpeg". |
| Lid switch | Helper missing: value "Off", hint "Requires one-time setup. Opens setup." |
| Contrast | Text on amber uses `onAccent` (≥ 4.5:1). |
| Announcements | `NSAccessibility.post(.announcementRequested)` with the **headline** (never the quip) for: timer end, guard stop, lid error, recovery. |
| Reduce Motion | No blinks, cursor tracking, sweat drop or cross-eyes. Crossfades are ≤ 150 ms. |
| Increase Contrast | Glyph stroke 2.0, ring 4 pt, chip borders on. |
| Reduce Transparency | The panel uses a solid `windowBackgroundColor`. |
| Colour | Never the sole signal (shapes and text always change too). |
| Menus on macOS 27 | No meaning in menu item images. |
| Keyboard | Full panel operation (§2.5). Settings are reachable with ⌘,. |
