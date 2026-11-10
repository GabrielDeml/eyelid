# Eyelid

Eyelid is a menu bar app that keeps your Mac awake, even with the lid closed.

Its menu bar icon is a moon. Click it to open the panel, or right-click it to turn Eyelid on or off. You can swap
the two in Settings.

The switch at the top of the panel turns Eyelid on. It stays on until you turn it off, unless you pick a time for
*Turn Eyelid off after* in Settings. *Keep screen on* stops the display from sleeping too.

On a MacBook, *Stay awake with lid closed* (lid mode) keeps your Mac running with the lid shut. *When unplugged*
decides what happens on battery: *Stay awake* changes nothing; *Sleep with lid closed* pauses lid mode until you plug
back in, so closing the lid puts your Mac to sleep; and *Turn Eyelid off* turns Eyelid off as soon as you unplug.
While lid mode is on, Sleep in the Apple menu doesn't work. Turn Eyelid off first.

## The icon

| Icon | Meaning |
|---|---|
| Outline, eye closed, small z | Off. Your Mac sleeps as usual. |
| Outline, eye open | Awake. The screen can still sleep. |
| Outline, eye open, sparkle | Awake, and the screen stays on. |
| Solid, small laptop | Awake in lid mode. You can close the lid. |
| Small ! added to any of these | Something needs your attention. Open the panel to see what. |

## Safety

If your Mac gets hot, or its battery drops to 12% while it's unplugged, Eyelid stops keeping it awake. With the lid
closed and no external display, it puts your Mac to sleep. Otherwise it puts your Mac to sleep if nobody has used it
for two minutes, and turns itself off if someone has.

"Hot" means macOS reports a critical thermal state, or a serious one that lasts a minute while lid mode is what keeps
your closed Mac awake, or five minutes otherwise. While lid mode is what keeps your closed Mac awake, five minutes at
the level below that also counts if there's no external display, or nobody has used your Mac for two minutes, because
that usually means it's in a bag.

"Lid mode is what keeps it awake" means the lid is closed and macOS wouldn't keep your Mac awake by itself. macOS does
that only for a real display on power (clamshell mode). A virtual, DisplayLink, Sidecar or AirPlay screen doesn't
count, because any app can add one.

You can switch off the heat check in Settings for long jobs with the lid open. While Eyelid keeps your Mac awake with
the lid closed, it always applies. The battery check can't be switched off.

Each check acts once, when its condition starts, so you can turn Eyelid back on afterwards if you mean to. The panel
shows a short note saying what happened, and the icon shows a ! until you open the panel.

The lid helper has its own safeguards, which hold whatever the app does:
- it puts your Mac to sleep at 10% battery
- it turns lid mode off if your Mac gets very hot, and puts it to sleep if lid mode was what kept it awake with the
  lid closed
- it turns sleep back on if Eyelid quits, crashes or hangs, or your Mac restarts, and in the same case puts it to
  sleep when Eyelid can't

Only the root-owned copy in `/Applications`, put there by the installer package or by `make install`, can use the lid
helper. Installing this version either way removes the first version's old password-free `pmset` rule.

## Installing

Download `Eyelid-<version>.pkg` from the [Releases page](https://github.com/GabrielDeml/eyelid/releases/latest)
and open it. You need an Apple silicon Mac with macOS 14 or later, and an administrator password. Eyelid comes as an
installer package, not an app you drag to Applications, because lid mode needs a copy in `/Applications` that only
the system can change.

Until shortly before its first release this app was called Insomnia. If you built that version from source, the
installer stops before changing anything and tells you to remove it first (see
[Building from source](#building-from-source)).

Then open Eyelid from Applications. The first time you turn on lid mode, macOS shows "Background Items Added". Allow
Eyelid in System Settings > General > Login Items & Extensions. An administrator has to approve it.

### Updating

Open the newer package with the lid open. It quits Eyelid, which turns lid mode off, so with the lid closed your Mac
may go to sleep partway through the install. It then replaces the app and reopens Eyelid if it was running. If it
wasn't, open Eyelid once afterwards so it can set up the lid helper again. If macOS asks you to allow Eyelid
again, allow it as above.

If more than one person on this Mac uses Eyelid, the one who set up lid mode should open it first after an update.
Until they do, lid mode may not work for the others.

The package won't replace a newer version with an older one; the installer says so and stops. To go back to an older
version, uninstall first.

### Checking the download

This is optional. Download `SHA256SUMS.txt` from the same release, then run these in the folder that holds both
files. The second command needs the [GitHub CLI](https://cli.github.com), signed in with `gh auth login`, and checks
that the package was built by this repository's release workflow from that version's tag.

```sh
shasum -a 256 -c SHA256SUMS.txt
gh attestation verify Eyelid-<version>.pkg --repo GabrielDeml/eyelid \
    --signer-workflow GabrielDeml/eyelid/.github/workflows/release.yml --source-ref refs/tags/v<version>
spctl -a -vvv -t install Eyelid-<version>.pkg   # should say "accepted" and "Notarized Developer ID"
```

### Uninstalling

Don't just drag Eyelid to the Trash: the lid helper would stay registered. Run these instead:

```sh
/Applications/Eyelid.app/Contents/MacOS/Eyelid --unregister-helper   # quits Eyelid first
sudo rm -rf /Applications/Eyelid.app
sudo pkgutil --forget com.gdeml.Eyelid.pkg                          # only if you installed the package
```

If `pmset -g` still shows `SleepDisabled 1`, run `sudo pmset -a disablesleep 0`. If you installed with `make install`,
you can run `make uninstall` instead.

Installing this version, with the package or `make install`, already removed the first version's password-free
`pmset` rule and safety daemon. If you used the first version and never installed a newer one over it, remove them
yourself:

```sh
sudo launchctl bootout system/com.gdeml.insomnia.safety
sudo rm -f /etc/sudoers.d/zz_insomnia /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist
```

## Building from source

You need Xcode 27 (macOS 27 SDK) and an *Apple Development* signing identity. Eyelid runs on macOS 14 or later.

```sh
make            # build/Eyelid.app, signed and verified
make test
make snapshot   # panel, Settings and icons in build/snapshots/
make install    # root-owned copy in /Applications; asks for your password
make uninstall
```

If you build from source, lid mode needs `make install`. It sets the system's `SleepDisabled` flag, which is what
`sudo pmset -a disablesleep 1` does, and that needs root. Eyelid includes a small helper, the lid helper, that does
only this. launchd runs it as root straight out of the app bundle, so Eyelid sets it up only from a root-owned copy
in `/Applications`. The first time you turn on lid mode, macOS asks you to allow it in System Settings > General >
Login Items & Extensions. A "Background Items Added" notification is expected.

To uninstall, see [Uninstalling](#uninstalling).

Builds from before the rename were called Insomnia (`/Applications/Insomnia.app`, bundle ID `com.gdeml.Insomnia`).
`make install` and `make uninstall` remove such a copy: they unregister its lid helper, then delete the app and its
files in `~/Library/Application Support/Insomnia`. They leave any other app named Insomnia alone. Settings aren't
carried over, because Eyelid keeps them under its own bundle ID. To remove the old copy by hand, which the installer
package asks you to do:

```sh
/Applications/Insomnia.app/Contents/MacOS/Insomnia --unregister-helper   # quits Insomnia first
sudo rm -rf /Applications/Insomnia.app
```

Design notes are in [docs/DESIGN.md](docs/DESIGN.md). How releases are built is in [docs/RELEASE.md](docs/RELEASE.md).

## License

MIT © 2026 Gabriel Deml. See [LICENSE](LICENSE).
