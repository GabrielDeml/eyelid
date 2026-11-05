# Insomnia

A wide-awake moon in your menu bar that keeps your Mac awake, lid open or shut.

Click the moon to open the panel, or right-click to turn Insomnia on or off.

- **Power button**: keep awake until you turn it off. **1h · 2h · 4h · 8h**: keep awake that long.
- **Keep screen on**: hold the display awake too.
- **Stay awake with lid closed** (MacBooks): keep running with the lid shut, on power or battery.
- **When unplugged**: *Keep going*, *Sleep when lid closes* (no lid mode on battery), or *Turn off*.

Everything else is in **⋯ ▸ Settings…**: what the power button does, the four timer buttons, what clicking the
moon does, overheat and low-battery protection, and Open at login.

## The moon shows the mode

| Moon | Mode |
|---|---|
| outline, closed eye, **z** | Off: your Mac sleeps normally |
| outline, open eye | Awake (the screen may sleep) |
| outline, open eye, **sparkle** | Awake, screen on |
| **solid**, **laptop** | Awake, even with the lid closed |
| **!** | Something needs a look: open the panel |

## Safety

Both are on by default and can be switched off in Settings.

- **Overheat protection.** If your Mac gets hot while Insomnia keeps it awake, Insomnia lets go. With the lid closed
  it sleeps the Mac. With the lid open it sleeps the Mac if nobody has touched it for 2 minutes, and otherwise turns
  itself off (configurable). "Hot" means critical, or serious for 1 minute (lid closed) / 5 minutes (lid open), or
  warm for 5 minutes with the lid shut in lid mode.
- **Low battery protection.** The same, on battery at or below 12% (11–50%).

Lid mode's helper also always resets sleep and sleeps the Mac at 10% battery, and gives sleep back if Insomnia quits,
crashes, hangs or the Mac restarts.

## Build and install

Needs Xcode 27 (macOS 27 SDK) and an *Apple Development* signing identity. Runs on macOS 14 or later.

```sh
make            # build/Insomnia.app (signed, verified)
make test
make snapshot   # panel states and icons → build/snapshots/
make install    # root-owned copy in /Applications (asks for your password; lid mode needs it)
make uninstall
```

**Why `make install`?** Lid mode sets the system's `SleepDisabled` flag (what `sudo pmset -a disablesleep 1` does),
which needs root. A tiny helper does exactly that job, run by launchd as root straight out of the app bundle, so it is
only set up from a root-owned `/Applications/Insomnia.app`. The first time you turn on lid mode, macOS asks you to
allow it in **System Settings ▸ General ▸ Login Items & Extensions** ("Background Items Added" is expected).

While lid mode is on, the Apple menu's Sleep is blocked by macOS: turn Insomnia off first.

**Uninstall by hand:** `/Applications/Insomnia.app/Contents/MacOS/Insomnia --unregister-helper`, then
`sudo rm -rf /Applications/Insomnia.app`. If `pmset -g` still shows `SleepDisabled 1`, run `sudo pmset -a disablesleep 0`.

Design notes: [`docs/DESIGN.md`](docs/DESIGN.md).

## License

MIT © 2026 Gabriel Deml. See [LICENSE](LICENSE).
