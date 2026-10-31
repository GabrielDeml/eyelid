# Insomnia

**A pair of eyes in your menu bar.** They stay open while your Mac stays awake, for exactly as long as you meant, lid open or shut. They tell you the truth about it, and they're funny a few times a day, never on every click.

Insomnia is a native macOS menu bar app (with an optional live Dock tile) that keeps your Mac awake, like Caffeine, with more control: closed-lid mode with real safety guards, "stay awake while this app runs", rules, a CLI and a URL scheme.

<!-- Screenshots: run `make snapshot` and pick from build/snapshots/ -->

## Features

- **One click.** Click the eyes to keep your Mac awake; click again to let it sleep. Right-click the menu bar eyes to toggle without opening anything.
- **Presets:** 30m · 1h · 2h · 4h · 8h · ∞, plus **Until…** a clock time. Pick a chip again to extend; `+` adds 15 minutes.
- **Keep screen on**, as a sticky switch.
- **Stay awake with lid closed** (MacBooks). Run in a bag or under a desk with the lid shut, on power or battery, with guards that can't be switched off (see below).
- **While…** keep awake until an app, a process name or a PID exits (`claude`, `codex`, `xcodebuild`, `ffmpeg`…), with a 5 s grace period.
- **Rules:** *keep awake while Xcode is running*, *…while on power adapter*, *…while an external display is connected*.
- **Why awake?** ⌥-click the menu bar eyes: Insomnia's own holds, active guards, other apps' sleep blockers and the system's sleep flag.
- **Live Dock tile** with the remaining time drawn in (optional), plus a Dock menu.
- **CLI** (`insomnia run -- make`), **URL scheme** (`insomnia://on?for=45m`) and one **global hotkey** (⌃⌥⌘I).
- **Personality:** Professional (zero jokes), **Cheeky** (default) or Unhinged. Safety copy is plain in every tier.
- Light and dark mode, VoiceOver labels everywhere, Reduce Motion and Increase Contrast respected. No timers run while it's idle.

| Input | Does |
|---|---|
| Click the menu bar eyes | Open the panel (swap with right-click in Settings) |
| Right-click / ⌃-click | Toggle with the default duration |
| ⌥-click | Why is my Mac awake? |
| In the panel | Return toggles · 1–6 presets · U Until… · W While… · = extend · S screen · L lid · Esc close |

## Build and install

Requirements: runs on macOS 14 or later (built and tested on macOS 27, Apple Silicon). Building needs Xcode 27 or later (macOS 27 SDK) with Swift 6.4: the code uses macOS 26/27 APIs behind runtime availability checks, and those only compile against the new SDK. No third-party dependencies.

```sh
make            # scripts/build.sh: release build, assemble, sign, verify → build/Insomnia.app
make run        # build and open it
make snapshot   # debug build; render the panel (light + dark), menu bar glyphs and icons → build/snapshots/
make install    # signed builds: root-owned copy in /Applications (asks for your password; lid mode needs it)
make uninstall  # remove the lid helper registration, then the app
make clean
```

**Signing.** `scripts/build.sh` signs with your first *Apple Development* identity (hardened runtime, no entitlements) and verifies the result. Pick another identity with `INSOMNIA_SIGN_IDENTITY="Apple Development: …"`. For a build without an Apple account, use `INSOMNIA_SIGN_IDENTITY=- make`; lid mode then uses the password-based fallback described below. Optional: `INSOMNIA_SIGN_KEYCHAIN=<path>` signs from a keychain that stays locked between builds.

**Why `make install`?** On signed builds, lid mode's helper runs as root, straight out of the app bundle. So it is only ever set up from `/Applications/Insomnia.app` owned by root, which `make install` creates (and verifies before it moves it into place); a signed copy in `build/` or one you dragged somewhere can keep you awake but can't turn on lid mode. Unsigned builds (`=-`) set up lid mode from wherever they run, and `make install` refuses them.

## Closed-lid mode, explained

macOS sleeps when you close the lid, even with "prevent sleep" assertions held, unless an external display is attached. Insomnia's lid mode sets the system's `SleepDisabled` flag (the same thing `sudo pmset -a disablesleep 1` does), reads it back from the IORegistry, and turns the internal display off so the shut panel doesn't stay lit.

**Setup (signed builds).** Turn on *Stay awake with lid closed*. Insomnia registers a tiny privileged helper (`SMAppService`), and macOS asks you once to allow it in **System Settings ▸ General ▸ Login Items & Extensions** (you'll also see a "Background Items Added" notification; that's expected). The helper does exactly one job: turn sleep off and back on. It only talks to this Insomnia, pinned by code signature (bundle id + Team ID).

**It always gives sleep back.** If Insomnia quits, crashes, hangs for 45 s, or the Mac restarts, the helper resets the flag. At 10% battery it resets it and sleeps the Mac. At launch Insomnia also checks for an unclean exit and restores normal sleep. If every reset fails, the eyes turn to `×` and the panel offers **Reset with password…**.

**Guards (can't be switched off):** lid mode turns off at your battery floor (default 20%, minimum 10%), pauses when the Mac runs hot or in Low Power Mode, and on battery always has a time limit with the lid closed (default 1 h). A guard that fires while the lid is shut stays off until you open it, so a Mac in a bag never re-arms itself. Optional: lid mode only on the power adapter, and a time limit on power too.

**Unsigned builds** (`INSOMNIA_SIGN_IDENTITY=-`) use a narrow sudoers rule instead, installed with one password prompt. It allows exactly two commands, and any app running as you can use them:

```
#<your uid> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

plus a watchdog and a small safety daemon that restores sleep after a restart and at 10% battery. Full design and threat model: [`docs/CLOSED_LID.md`](docs/CLOSED_LID.md).

## Uninstall

```sh
make uninstall
```

`make uninstall` also removes the leftovers of an unsigned (sudoers) setup if it finds any.

By hand: run `/Applications/Insomnia.app/Contents/MacOS/Insomnia --unregister-helper` first (it removes the helper registration), then `sudo pmset -a disablesleep 0` and `sudo rm -rf /Applications/Insomnia.app`. Leftovers from an unsigned build, if any:

```sh
sudo launchctl bootout system/com.gdeml.insomnia.safety 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist /etc/sudoers.d/zz_insomnia
rm -f ~/Library/Application\ Support/Insomnia/lid-engaged
```

Details in [`docs/CLOSED_LID.md` §9](docs/CLOSED_LID.md).

## URL scheme

Works from Terminal (`open "insomnia://…"`) and from Shortcuts (**Open URLs**). Links can never turn on lid mode; use the CLI for that.

| URL | Does |
|---|---|
| `insomnia://on?for=45m` | Keep awake for 45 minutes (`2h`, `90`, `forever`) |
| `insomnia://on?until=17:30&screen=1` | Until 17:30 (tomorrow if it's past), screen on |
| `insomnia://off` | Allow sleep |
| `insomnia://toggle` | Toggle with the default duration |
| `insomnia://extend?by=15m` | Extend a timed session |
| `insomnia://sleep` | Sleep now |
| `insomnia://panel` · `insomnia://settings?tab=general` | Open the panel / Settings |

## Command line

Settings ▸ Automations ▸ Command line ▸ **Install** links `~/.local/bin/insomnia` to the app (no sudo).
If `~/.local/bin` isn't on your PATH, add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile.

```sh
insomnia on [45m|2h|1h30m|90|forever] [--until 17:30] [--screen|--no-screen] [--lid|--no-lid]
insomnia off | toggle | extend [15m]
insomnia status [--json]          # exit 0 awake, 1 asleep
insomnia why [--json]             # what keeps the Mac awake, and what's holding back
insomnia run [--screen] [--lid] -- make -j8    # awake for exactly this command; exits with its status
insomnia watch --pid 4411 [--screen] [--lid]   # awake until that process exits
insomnia --why
```

- `run` and `watch` hold only while their connection lives. If the command or the CLI dies, the hold goes with it.
- Flags apply to that one session and never change your settings. Every safety guard still applies.
- `--lid` needs lid mode set up first (Settings ▸ Lid & Safety). The URL scheme can never turn lid mode on; the CLI can, because it is local and runs as you.
- The CLI talks to the running app over a private socket: `~/Library/Application Support/Insomnia/control.sock`, mode 0600 in a 0700 folder, same user only. `on`, `toggle`, `extend`, `run` and `watch` start the app in the background if needed.
- Exit codes: 0 ok · 1 asleep (`status`) · 2 usage · 3 couldn't reach Insomnia · 4 refused (e.g. lid mode not set up). `run` returns the command's own exit status.

## FAQ

**Why not just `caffeinate`?** `caffeinate` is great, and Insomnia uses the same power assertions. It adds a visible state you can trust, closed-lid mode with safety guards, rules, babysitting a process, and a "why is my Mac awake?" view that includes other apps.

**Does it fake mouse or keyboard input?** No. It never moves your mouse or types. Assertions don't count as "user activity", so Slack or Teams may still show you as away. That's on purpose.

**Why does macOS say "Background Items Added"?** That's macOS announcing the lid-mode helper when you set it up. It runs only to turn sleep off and back on, and resets it if anything goes wrong.

**Will it drain my battery in a bag?** Lid mode on battery always has a time limit, pauses when hot or in Low Power Mode, and turns off at your battery floor. The helper itself steps in at 10%.

## Development status

Built milestone by milestone (see [`ARCHITECTURE.md`](ARCHITECTURE.md)); all five milestones (awake core, lid mode, automations, personality, CLI) are in the app. Lid mode ships only once every on-device test in [`docs/CLOSED_LID.md` §8](docs/CLOSED_LID.md) passes for both backends ([`scripts/lid-tests.md`](scripts/lid-tests.md) has the steps; `make lid-verify` checks an installed copy read-only). Design docs: [`docs/`](docs/README.md).

## License

MIT © 2026 Gabriel Deml. See [LICENSE](LICENSE).
