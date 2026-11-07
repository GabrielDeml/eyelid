# Insomnia

Insomnia is a menu bar app that keeps your Mac awake, even with the lid closed.

Its menu bar icon is a moon. Click it to open the panel, or right-click it to turn Insomnia on or off. You can swap
the two in Settings.

The switch at the top of the panel turns Insomnia on. It stays on until you turn it off, unless you pick a time for
*Turn Insomnia off after* in Settings. *Keep screen on* stops the display from sleeping too.

On a MacBook, *Stay awake with lid closed* (lid mode) keeps your Mac running with the lid shut. *When unplugged*
decides what happens on battery: *Stay awake* changes nothing; *Sleep with lid closed* pauses lid mode until you plug
back in, so closing the lid puts your Mac to sleep; and *Turn Insomnia off* turns Insomnia off as soon as you unplug.

## The icon

| Icon | Meaning |
|---|---|
| Outline, eye closed, small z | Off. Your Mac sleeps as usual. |
| Outline, eye open | Awake. The screen can still sleep. |
| Outline, eye open, sparkle | Awake, and the screen stays on. |
| Solid, small laptop | Awake in lid mode. You can close the lid. |
| Small ! added to any of these | Something needs your attention. Open the panel to see what. |

## Safety

If your Mac gets hot, or its battery drops to 12% while it's unplugged, Insomnia stops keeping it awake. With the lid
closed and no external display, it puts your Mac to sleep. Otherwise it puts your Mac to sleep if nobody has used it
for two minutes, and turns itself off if someone has.

"Hot" means macOS reports a critical thermal state, or a serious one that lasts a minute with the lid closed and no
external display, or five minutes otherwise. In lid mode with the lid closed and no external display, five minutes at
the level below that also counts, because that usually means your Mac is in a bag.

You can switch off the heat check in Settings for long jobs with the lid open. With the lid closed and no external
display it always applies. The battery check can't be switched off.

Each check acts once, when its condition starts, so you can turn Insomnia back on afterwards if you mean to. The panel
shows a short note saying what happened, and the icon shows a ! until you open the panel.

Lid mode has one more safeguard. The lid helper puts your Mac to sleep at 10% battery, and turns sleep back on if
Insomnia quits, crashes or hangs, or your Mac restarts.

## Building and installing

You need Xcode 27 (macOS 27 SDK) and an *Apple Development* signing identity. Insomnia runs on macOS 14 or later.

```sh
make            # build/Insomnia.app, signed and verified
make test
make snapshot   # panel, Settings and icons in build/snapshots/
make install    # root-owned copy in /Applications; asks for your password
make uninstall
```

Lid mode needs `make install`. It sets the system's `SleepDisabled` flag, which is what `sudo pmset -a disablesleep 1`
does, and that needs root. Insomnia includes a small helper, the lid helper, that does only this. launchd runs it as
root straight out of the app bundle, so Insomnia sets it up only from a root-owned copy in `/Applications`. The first
time you turn on lid mode, macOS asks you to allow it in System Settings > General > Login Items & Extensions. A
"Background Items Added" notification is expected.

While lid mode is on, Sleep in the Apple menu doesn't work. Turn Insomnia off first.

To uninstall by hand, run `/Applications/Insomnia.app/Contents/MacOS/Insomnia --unregister-helper` (it quits Insomnia
first), then `sudo rm -rf /Applications/Insomnia.app`. If `pmset -g` still shows `SleepDisabled 1`, run
`sudo pmset -a disablesleep 0`.

Design notes are in [docs/DESIGN.md](docs/DESIGN.md).

## License

MIT © 2026 Gabriel Deml. See [LICENSE](LICENSE).
