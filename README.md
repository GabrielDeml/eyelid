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

"Hot" means macOS reports a critical thermal state, or a serious one that lasts a minute while lid mode is what keeps
your closed Mac awake, or five minutes otherwise. While lid mode is what keeps your closed Mac awake, five minutes at
the level below that also counts if there's no external display, or nobody has used your Mac for two minutes, because
that usually means it's in a bag.

"Lid mode is what keeps it awake" means the lid is closed and macOS wouldn't keep your Mac awake by itself. macOS does
that only for a real display on power (clamshell mode). A virtual, DisplayLink, Sidecar or AirPlay screen doesn't
count, because any app can add one.

You can switch off the heat check in Settings for long jobs with the lid open. While Insomnia keeps your Mac awake with
the lid closed, it always applies. The battery check can't be switched off.

Each check acts once, when its condition starts, so you can turn Insomnia back on afterwards if you mean to. The panel
shows a short note saying what happened, and the icon shows a ! until you open the panel.

The lid helper has its own safeguards, which hold whatever the app does:
- it puts your Mac to sleep at 10% battery
- it turns lid mode off if your Mac gets very hot, and puts it to sleep if lid mode was what kept it awake with the
  lid closed
- it turns sleep back on if Insomnia quits, crashes or hangs, or your Mac restarts, and in the same case puts it to
  sleep when Insomnia can't

Only the copy of Insomnia that `make install` put in Applications can use the lid helper. Upgrading from the first
version removes its old password-free `pmset` rule.

## Installing

Download `Insomnia-<version>.pkg` from the [Releases page](https://github.com/GabrielDeml/insomnia/releases/latest)
and open it. You need an Apple silicon Mac with macOS 14 or later, and an administrator password. Insomnia comes as an
installer package, not an app you drag to Applications, because lid mode needs a copy in `/Applications` that only
the system can change.

If another app named Insomnia is already in `/Applications` (Kong's API client has the same name), the installer
stops before changing anything. Move or rename that app first.

Then open Insomnia from Applications. The first time you turn on lid mode, macOS shows "Background Items Added". Allow
Insomnia in System Settings > General > Login Items & Extensions. An administrator has to approve it.

### Updating

Open the newer package. It quits Insomnia, which turns lid mode off, then replaces the app and reopens Insomnia if it
was running. If it wasn't, open Insomnia once afterwards so it can set up the lid helper again. If macOS asks you to
allow Insomnia again, allow it as above.

The package won't replace a newer version with an older one; the installer says so and stops. To go back to an older
version, uninstall first.

### Checking the download

This is optional. Download `SHA256SUMS.txt` from the same release, then run these in the folder that holds both
files. The second command needs the [GitHub CLI](https://cli.github.com), signed in with `gh auth login`, and checks
that the package was built by this repository's release workflow from that version's tag.

```sh
shasum -a 256 -c SHA256SUMS.txt
gh attestation verify Insomnia-<version>.pkg --repo GabrielDeml/insomnia \
    --signer-workflow GabrielDeml/insomnia/.github/workflows/release.yml --source-ref refs/tags/v<version>
spctl -a -vvv -t install Insomnia-<version>.pkg   # should say "accepted" and "Notarized Developer ID"
```

### Uninstalling

Don't just drag Insomnia to the Trash: the lid helper would stay registered. Run these instead:

```sh
/Applications/Insomnia.app/Contents/MacOS/Insomnia --unregister-helper   # quits Insomnia first
sudo rm -rf /Applications/Insomnia.app
sudo pkgutil --forget com.gdeml.Insomnia.pkg                            # only if you installed the package
```

If `pmset -g` still shows `SleepDisabled 1`, run `sudo pmset -a disablesleep 0`. If you installed with `make install`,
you can run `make uninstall` instead.

## Building from source

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

To uninstall, see [Uninstalling](#uninstalling).

Design notes are in [docs/DESIGN.md](docs/DESIGN.md). How releases are built is in [docs/RELEASE.md](docs/RELEASE.md).

## License

MIT © 2026 Gabriel Deml. See [LICENSE](LICENSE).
