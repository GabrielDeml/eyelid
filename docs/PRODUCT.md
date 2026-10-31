# Insomnia: Product Design

> A pair of eyes in your menu bar. They stay open while your Mac stays awake, for exactly as long as you meant, lid open or shut. They tell you the truth about it, and they're funny a few times a day, never on every click.

Status: **v1 design, approved for build.** This file and `UX.md`, `CLOSED_LID.md` and `../ARCHITECTURE.md` are the source of truth. If code and docs disagree, fix the docs first, then the code.

---

## 1. Principles

| # | Principle | What it means in practice |
|---|---|---|
| 1 | **Simple surface** | Reading the panel takes 2 seconds and starting a session takes one click. Rare actions sit behind `⋯`, ⌥-click or Settings. Nothing scrolls. |
| 2 | **Powerful depth** | One model sits underneath everything: **holds → guards → effective state**. A hold can come from the panel, a rule, the CLI, the URL scheme, the hotkey or the Dock, and every source goes through the same path. |
| 3 | **Funny, not annoying** | The eyes show the state and the words carry the jokes. Jokes appear only at state changes and milestones. There are no sounds, no bouncing and no looping animation in the menu bar. **Professional mode has zero jokes.** |
| 4 | **Safe by default** | Lid mode has four independent ways of restoring sleep (normal path, crash/hang watchdog, root safety daemon, launch recovery). Its battery floor and heat guard **can't be turned off**. Closed in a bag, it always has a time cap. Plain keep-awake behaves like Caffeine and never stops on its own. Safety copy is plain in every personality. |
| 5 | **Honest state** | State is read back from the system, never assumed. *Why awake?* also lists other apps' sleep blockers. The app never promises something it can't do (see the "Look busy" cut). |

## 2. Target users

| User | Job to be done | What they reach for |
|---|---|---|
| **Caffeine refugee** | "Don't sleep for the next hour." | One click on the eyes, or a chip. |
| **Agent / build runner** (the 2026 wedge) | "Stay awake while `claude`, `codex`, `xcodebuild` or `ffmpeg` runs, then sleep." | **While…** (babysit), rules, `insomnia run -- …` |
| **Lid-closed worker** | "Keep running in my bag or under the desk with the lid shut." | The "Stay awake with lid closed" toggle and its guards. |
| **Presenter / reader** | "Keep the screen on." | The "Keep screen on" toggle. |
| **Tinkerer** | "Script it." | CLI, URL scheme, hotkey, Shortcuts (via URL or shell). |

## 3. Feature tiers

### v1 (build now)

| Area | Feature |
|---|---|
| Core | Toggle. Presets **30m · 1h · 2h · 4h · 8h · ∞**. **Until…** (a clock time; a past time means tomorrow). **Extend** +15m (key, Dock menu, notification). Clicking the open eyes also pauses active rules until each re-triggers. |
| Core | **Keep screen on** (display assertion) as a sticky preference. |
| Core | **While…** (babysit): hold until a chosen app, process name or PID exits, with a 5 s grace period. |
| Closed lid | **Stay awake with lid closed** (`pmset -a disablesleep`), MacBooks only: one-time setup with one password prompt, a narrow sudoers rule, a heartbeat watchdog, a root safety daemon (boot reset + 10% battery backstop), launch recovery, IORegistry readback, display off when shut, and a **mission report** on reopen. The switch applies to every hold except fixed CLI/URL ones. |
| Safety | Lid battery floor (always on, default 20%, min 10%), plus opt-in "Also stop keeping awake" at that floor. Heat guard (always on; pauses lid mode at `.serious`, or at `.fair` for 5 min in a bag). Low Power Mode pauses lid mode. Optional "Lid only on power adapter". Bag time cap (default 1 h). A guard that fires with the lid shut stays off until the lid opens. |
| Automations | **Rules**, written as sentences: *Keep awake while [app / process] is running*, *…while on power adapter*, *…while an external display is connected*. Each rule has "screen on" and "allow lid closed" options; both default to off. |
| Insight | **Why awake?** (⌥-click on the menu bar item, plus Settings ▸ Diagnostics): our holds, guards, other processes' assertions (`IOPMCopyAssertionsByProcess`), and `SleepDisabled` / clamshell readback. |
| Scripting | `insomnia://` URL scheme. **CLI** (`insomnia on/off/extend/status/why/run/watch`) over a local socket. One global hotkey (toggle). |
| Surfaces | Menu bar item (template glyph). **Live Dock tile** (on by default, chosen on the welcome card) with time drawn in, a Dock menu and click-to-toggle. Panel. Four-tab Settings (three on desktops). |
| Personality | Professional / **Cheeky** (default) / Unhinged. Shuffle-bag copy with a quip budget. Poke egg. Milestones. Date-aware lines (copy only). Four **epic moments** (§4 rule 10). |
| Other | Launch at login (`SMAppService.mainApp`). Sleep Now. Stats in About. First-run card. Detection of "macOS hid my menu bar item". |

### Later (in order of likely value)

| Feature | Why it waits |
|---|---|
| **App Intents / Shortcuts actions** | SwiftPM doesn't run `appintentsmetadataprocessor`, so it needs a build-script spike or an Xcode project. Until then Shortcuts can use the **Open URL** action (`insomnia://…`) and **Run Shell Script** (`insomnia …`). |
| Schedule rules ("weekdays 09–18") | Useful, but needs a time-range editor. |
| CPU > N% rule and "while a file or download grows" | Needs polling heuristics, and false positives would cost trust. |
| "Snooze all rules for 1h" | v1 already pauses rules from the eyes until they re-trigger; a timed snooze waits for demand. |
| Control Center control + desktop widget | Need an app extension, so an Xcode project and a Team ID. Spike alongside App Intents. |
| Mouse-jiggle "Look busy" | Needs Accessibility (TCC), and an ad-hoc signature breaks the grant on every rebuild. It can also defeat the screen lock. It would ship off by default, on a timer, with a disclaimer. |
| SMAppService privileged helper (XPC + heartbeat) | Better than sudoers, but needs a paid Team ID. `PrivilegedBackend` is the seam where it would plug in. |
| Seasonal visuals (pumpkin glow, snowflake) | Copy-only date lines ship in v1. Visuals come after the basics feel great. |
| Sparkle updates, notarization | Need a Developer ID. |

### Non-goals (cut, with reasons)

- **"Look busy" via `IOPMAssertionDeclareUserActivity`**: it doesn't reset HID idle time, so Slack and Teams don't see activity. A toggle that quietly does nothing costs trust.
- **Wi-Fi, VPN, DNS, USB, Bluetooth and audio-output triggers**: Wi-Fi SSID needs Location permission, and these are the clutter Amphetamine is known for.
- **Sounds, custom icons, coloured menu bar glyphs, idle blink or glance loops in the menu bar.**
- **A "Custom…" duration stepper.** Until… and the CLI cover it.
- **Things that aren't about sleep** (desktop hiding, focus dimming).
- **A sandbox or App Store build.** Lid mode can't work in the sandbox.
- **Editing `/etc/sudoers` directly.** We only ever add one file to `/etc/sudoers.d`.

## 4. Voice & humour guide

### Personality levels

| Level | Tone | Where jokes may appear | Example (lid engaged) |
|---|---|---|---|
| **Professional** | Calm, factual, short sentences. No jokes, emoji or exclamation marks. | Nowhere. The quip row is hidden; its plain lines appear only in notification bodies. | "Lid mode is on." |
| **Cheeky** (default) | Dry, warm, a wink. | Quip row, tooltips, notification bodies (not titles). | "Lid closed. I'm watching. Through the lid. Don't ask." |
| **Unhinged** | Over-caffeinated theatre, still kind. | Same places as Cheeky, plus the Easter-egg duration names. | "The lid is a suggestion. I reject suggestions." |

### Rules (enforced in code review)

1. **Never mean or crude.** No insults aimed at the user, no swearing, no body or bodily-function jokes.
2. **No guilt trips.** "You should sleep" is out. The app is the insomniac, not the user.
3. **Safety is never a joke.** Battery-floor, heat and error *headlines and notification titles* are plain in every tier. A joke may follow in the body (Cheeky and Unhinged only), but the action must be clear without it.
4. **Copy never blocks.** No modal exists to deliver a joke, and a joke never delays a toggle.
5. **Rotation.** Lines come from a shuffle bag per (moment, personality). A line never shows twice in a row, and the bag empties before any line repeats. The same line never appears in the panel and a notification at once: the notification gets the line, the banner states the plain fact.
6. **Pool sizes.** Cheeky and Unhinged each have **≥ 40 lines** in total, with **≥ 10** for each of `activated`, `deactivated`, `idle` and `awake`. Rare moments have ≥ 3 each.
7. **Professional is really plain.** `Narrator.line()` returns `nil` for decorative moments (`idle`, `poke`, `milestone`, `awake`), and the UI hides the row.
8. **Labels are plain in every tier.** Control labels, VoiceOver labels and menu items never change with personality. Nicknames live only in tooltips and copy.
9. **Silence is a valid line.** Most state changes update only the headline. The quip row changes at most once per state change.
10. **Earned moments** (exempt from the budget): milestones (each once, ever), first lid engagement, the mission report, crash recovery, the poke egg, date lines. Four are **epic** (panel only; Reduce Motion crossfades, `UX.md` §2.4):
    - **First wake:** on first launch the eyes slowly open (600 ms), blink twice, find the cursor, then the welcome card appears.
    - **Night vision:** the first lid engagement each day sweeps an indigo glow across the eyes (400 ms); the Dock tile pulses once.
    - **Mission report:** reopening after ≥ 5 min closed turns the banner into a card with counting-up numbers and one line.
    - **Eye bags:** after 24 h continuously awake the panel eyes grow bags; after 72 h they're bloodshot. No words.
11. **Quip budget.** At most one rotating `activated`/`deactivated` quip per 4 h. Outside the budget the quip row stays empty. `idle` fires when the panel opens while asleep, at most once a day.
12. **Unhinged volume.** At most 2 ALL-CAPS lines per Unhinged pool.

## 5. Naming glossary

### Product nouns (plain, used in UI labels)

| Concept | UI label | Short form | Nickname (tooltips/copy, Cheeky & Unhinged) |
|---|---|---|---|
| Keep the Mac awake | **Keep Awake** | awake | n/a |
| Display assertion on | **Keep screen on** | screen | n/a |
| `disablesleep` mode | **Stay awake with lid closed** | **Lid mode** (the only name in copy) | n/a |
| Hold until a target exits | **While…** | watching | "Babysit" |
| Persistent conditions | **Rules** (Settings ▸ Automations) | rule | n/a |
| Safety conditions | **Guards** (docs/code only; UI says "Paused: …") | guard | n/a |
| Stop | **Allow Sleep** | stop | "Let it sleep" |
| Sleep immediately | **Sleep Now** | n/a | n/a |
| One-time privileged install | **Set Up…** / **Remove…** | helper | n/a |

### State headlines (plain, every tier; `UX.md` §8 is the full source of truth)

| State | Headline |
|---|---|
| asleep | Sleep allowed |
| timed | Wide awake |
| indefinite | Wide awake |
| watching | Awake for *ffmpeg* |
| client (CLI `run`/`watch`) | Awake for *make* |
| automatic (rule) | Awake: *Xcode is running* |
| suspended (opt-in awake floor) | Paused: battery at *{floor}*% |
| lid error / stuck | Lid mode needs attention / Lid mode is stuck on |

### Duration names (tooltips on chips; Cheeky & Unhinged only; Professional shows numbers)

| Chip | Name |
|---|---|
| 30m | A pomodoro with ambition |
| 1h | One meeting that could've been an email |
| 2h | A Nolan film |
| 4h | Render o'clock |
| 8h | Night shift |
| ∞ | Until the heat death of the universe |
| **47 min** (Until… or CLI, Unhinged only) | **One more episode** |

## 6. Success criteria for v1

- From a cold start, a first-time user keeps the Mac awake within one click, and sets up lid mode within one password prompt.
- Each lid-mode release blocker in `CLOSED_LID.md` §8 passes.
- If Insomnia is force-quit with lid mode engaged, `SleepDisabled` returns to `0` within 1 s (within 100 s if it hangs), and after a reboot it is `0` before login.
- The menu bar item is never wider than about 22 pt unless the user enables the timer text.
- Idle CPU is effectively zero: no timers run while asleep and the panel is closed.
- Every state can be told apart in monochrome, with VoiceOver, and with Reduce Motion on.
- **Naming risk:** "Insomniacs" (App Store) and `krishhgg/Insomnia` (GitHub) already exist. Re-check before a 1.0 announcement. The bundle id `com.gdeml.Insomnia` is ours.
