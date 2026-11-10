# Releases

How Insomnia ships as a ready-to-install download on GitHub Releases. This is the design and the maintainer's runbook.
Building from source with `make install` stays as it is (README, docs/DESIGN.md).

## What ships

Each GitHub release has:

- `Insomnia-<version>.pkg`: a macOS installer package. It is signed with a *Developer ID Installer* certificate,
  notarized by Apple, and stapled, so Gatekeeper accepts it even offline. The app inside is signed with
  *Developer ID Application*, with the hardened runtime and a secure timestamp.
- `SHA256SUMS.txt`, computed after stapling.
- A build provenance attestation (`gh attestation verify`).

Apple silicon only, macOS 14 or later.

**Why a pkg and not a zip or DMG.** Lid mode only works from a root-owned `/Applications/Insomnia.app` with nothing
group- or other-writable (`InstallLocation` in `Sources/InsomniaShared/HelperInfo.swift`). An app dragged out of a DMG
or zip belongs to the user who copied it, so lid mode would refuse it. macOS Installer writes its payload as
root:wheel, so the pkg does what `make install` does. There is no zip or DMG download.

## Decisions

| Decision | Choice | Status |
|---|---|---|
| Package format | Signed, notarized, stapled product archive (`productbuild`) | Decided |
| Architectures | arm64 only (`hostArchitectures="arm64"`). A universal build compiles, but build.sh's rpath/otool steps break on fat binaries and the SpawnConstraint pins only one slice's cdhash, so the helper would be blocked on Intel. | Default, revisit later |
| Name | Keep *Insomnia*, with guards against Kong's API client of the same name (below) | **Open**: renaming is cheap now and expensive after v1.0.0 |
| Where releases are built | GitHub Actions on the `xcode-27` runner, triggered by a `v*` tag. `scripts/release.sh` runs the same steps locally. | Decided |
| Version | `CFBundleShortVersionString` and `HelperInfo.version` move together (build.sh already checks this); the tag must be `v` + that version | Default. Every bump changes the helper's cdhash, which re-registers the helper (only for the user who set it up; Not done yet). Splitting the two needs a Sources change; open (Not done yet). |
| Downgrades | Refused by the installation check with a message. (Installer alone would skip the app but still run the scripts and record the older version.) Uninstall first to roll back. | Default |
| Reopen after install | Only if Insomnia was running before the install | Default |
| Notarization login | CI: App Store Connect Team API key. Local: a `notarytool store-credentials` keychain profile. | Decided |
| Immutable releases | On. A published pkg is never replaced: re-uploading would break its checksum and its attestation. Timestamped signatures outlive the certificate, so expiry needs nothing; a revoked certificate or a change in Apple's trust rules means a new release. | Default |
| Homebrew | A personal tap after two clean pkg releases. Not homebrew/cask: it needs notability, and Kong's `insomnia` cask owns the name. | Later |
| Auto-update (Sparkle) | No. An app-only update can't restart the lid helper, and build.sh refuses non-system libraries. | Not planned |

## What the installer does

**Before anything is copied** (`pkg/Distribution.xml.in`, installation check; it runs for the Installer app and for
`installer -pkg`). The installer stops with a message when `/Applications/Insomnia.app`:
- has a bundle ID other than `com.gdeml.Insomnia` (Kong's API client *Insomnia* installs to the same path), or
- is a newer Insomnia (`system.compareVersions`). Installer alone would skip the app but still run the scripts and
  record the older version in the receipt.

Because the distribution runs JavaScript, the Installer app may first show "This package will run a program to
determine if the software can be installed". To be confirmed on a VM.

**preinstall** (`pkg/scripts/preinstall`, as root):
1. The bundle-ID guard again, for installs that bypass the distribution. Its message only reaches
   `/var/log/install.log`.
2. Quit running copies with `quit-running.sh` (shipped inside the pkg). Its quit releases lid mode first. Exit 0
   (nothing was running) and 3 (it quit) are success. Anything else aborts the install, as `make install` does.
   Copies are matched with or without arguments (a copy started from a terminal runs as `Insomnia --gui`). As root,
   `quit-running.sh` trusts nothing other users control: a process counts only if `lsof` shows
   `/Applications/Insomnia.app/Contents/MacOS/Insomnia` mapped as its executable (argv can name any path), it opens no
   path taken from argv, it sends no Apple Events, and if `lsof` can't answer for a live process it gives up (the
   install stops). If a copy won't quit, the error names the user it belongs to. As a user (`make install`), it skips a
   process whose bundle ID reads as someone else's. With the lid shut, the quit puts an unattended Mac to sleep
   partway through the install (the app's quit-time `sleepnow`), so install with the lid open (README "Updating");
   preinstall doesn't check.
3. v1 leftovers (docs/DESIGN.md "Security"): if `/etc/sudoers.d/zz_insomnia` or
   `/Library/LaunchDaemons/com.gdeml.insomnia.safety.plist` exists, remove exactly what the Makefile's
   `REMOVE_LEGACY` removes: boot out `com.gdeml.insomnia.safety`, delete both files, v1's staging leftovers
   (`/etc/sudoers.d/.insomnia.*`, `/Library/LaunchDaemons/.insomnia.*`, `/private/var/root/insomnia.*`) and its boot
   marker (`/var/run/com.gdeml.insomnia.booted`). After the quit, so a v1 app holding the flag through the rule has
   released it. Every step ignores its own failure: a cleanup that fails never stops the install. If `SleepDisabled`
   is still 1 and the helper doesn't own it, the `sudo pmset -a disablesleep 0` hint goes to the install log.
4. Notes for postinstall in `$INSTALLER_TEMP`: a marker holding the logged-in user's uid if they had a copy running,
   and the helper's cdhash, but only while the helper launchd runs is still the code on disk (`codesign -v <pid>`).
   After an update that nobody followed by opening Insomnia, launchd still runs and pins an older helper than the
   bundle's.

**Payload.** Built with `pkgbuild --component` on an attribute-free copy of `build/Insomnia.app` (step 4 below),
`--install-location /Applications`:
- Every item is recorded as root:wheel with the build's modes (755/644, no group/other write).
- The payload root (`.`, which is `/Applications`) has no recorded mode, so Installer leaves `/Applications` alone. A
  `--root` package records `.` as `drwxr-xr-x root:wheel`, which could reset `/Applications` (normally
  `drwxrwxr-x root:admin`). That is why the pkg uses `--component`.
- `relocatable="false"`: Installer must never "upgrade" a stray copy elsewhere (for example `build/Insomnia.app`).
  pkgbuild on macOS 27 defaults to this for `--component`; older hosts don't, so `scripts/release.sh` fails the build
  unless `PackageInfo` says `relocatable="false"`.
- `strict-identifier` and `upgrade-bundle` (the `--component` defaults): only a bundle with our ID is replaced.

**postinstall** (`pkg/scripts/postinstall`, as root, always exits 0 because the payload is already in place):
1. If the lid helper is registered (`launchctl print system/com.gdeml.Insomnia.helper`):
   - Same helper cdhash as the one noted by preinstall: restart it with `launchctl kickstart -k`. This is required,
     not tidying: the install removed the code the running helper was started from, and the app sees nothing to
     re-register, so every engage would fail until the helper restarts.
   - Different cdhash, or none noted: leave it. launchd still holds the old registration, whose spawn constraint pins
     the old cdhash, so a restarted new helper couldn't launch. The app registers the helper again when it next opens,
     but only for the macOS user whose settings remember the helper they registered (`helperRegisteredCDHash`): the
     old helper pins the old app, so it doesn't answer the new one. For any other user lid mode fails until that user
     opens the new version (Not done yet). Every version bump takes this branch.
   Failures and the decision are logged to `/var/log/install.log`.
   `make install` differs here: it kickstarts whenever the helper is registered, changed or not (docs/DESIGN.md
   "Security"; Not done yet).
2. If the marker exists, reopen Insomnia for the console user (`launchctl asuser` + `sudo -u`), but only if the uid in
   the marker is all digits, not 0, and still the uid that owns `/dev/console`. Otherwise it is skipped and logged:
   nobody is logged in, or a fast user switch happened during the install. Copies other users had open (fast user
   switching) are quit but not reopened, and Insomnia is never opened for someone who wasn't running it.

**The user then** opens Insomnia (first install) and turns on lid mode. macOS shows "Background Items Added" and asks
for approval in System Settings > General > Login Items & Extensions, as it does today. A pkg can't pre-approve this;
only MDM can. Installing and approving both need an admin.

**Uninstall** (README): `Insomnia --unregister-helper`, `sudo rm -rf /Applications/Insomnia.app`,
`sudo pkgutil --forget com.gdeml.Insomnia.pkg`, then check `SleepDisabled`. `make uninstall` also forgets the receipt.
The README also lists how to remove v1's leftovers by hand, for a Mac that never installed a newer version over v1.

## Building a release: `scripts/release.sh`

```
scripts/release.sh                 sign, notarize, staple, verify → dist/Insomnia-<version>.pkg
scripts/release.sh --dry-run       all the same steps and checks → dist/Insomnia-<version>-dryrun.pkg (CI)
scripts/release.sh --no-notarize   Developer ID signed, not notarized → dist/Insomnia-<version>-unnotarized.pkg
scripts/release.sh --dev           Apple Development app, unsigned pkg → dist/Insomnia-<version>-dev.pkg (test Macs)
```

Only the default mode's package gets the plain name. `--dry-run` is the default mode in every step and check, signed,
notarized and stapled; only its name differs, so a dry run's package can never pass for the published one. CI uses it
for `workflow_dispatch`. Each run first empties `dist/` of packages and checksums.

Environment:

| Variable | Meaning |
|---|---|
| `INSOMNIA_SIGN_IDENTITY` | Passed to build.sh. Release mode auto-picks the first `Developer ID Application:` identity. |
| `INSOMNIA_INSTALLER_IDENTITY` | Pkg signing identity. Default: the first `Developer ID Installer:` identity. |
| `INSOMNIA_SIGN_KEYCHAIN` | Optional separate keychain holding the Developer ID identities (recommended locally). |
| `NOTARY_PROFILE` | A `notarytool store-credentials` profile (local). |
| `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` | App Store Connect API key: path to the `.p8`, key ID, issuer ID (CI). |
| `RELEASE_TAG` | If set (CI sets it from the tag), it must equal `v` + `CFBundleShortVersionString`. |

Steps, each a hard gate:

1. Read the version from `Resources/Info.plist`; check `RELEASE_TAG` if set. Check every precondition before the
   build: tools, identities, notary credentials, and, in the default and `--dry-run` modes, a working tree without
   uncommitted changes.
2. `INSOMNIA_RELEASE=1 scripts/build.sh`; in `--dev`, a plain build that must come out Apple Development signed.
3. Copy the pkg scripts and `scripts/quit-running.sh` into `build/pkg/scripts`, executable, nothing else.
4. Copy the app without extended attributes (`ditto --noextattr --noqtn …`), check its signature, and run
   `pkgbuild --component <copy> --install-location /Applications --identifier com.gdeml.Insomnia.pkg
   --version <version> --scripts build/pkg/scripts --ownership recommended`. pkgbuild archives extended attributes as
   AppleDouble `._` entries and Installer puts them back on users' Macs; the build's are machine-local
   (`com.apple.provenance`, `com.apple.macl`).
5. Check the component package: `relocatable="false"` with an empty `<relocate>`, `install-location="/Applications"`;
   every payload item root:wheel with mode 755 or 644 (`lsbom`); the payload root `.` has no mode. Any `._` entry
   fails a signed build. (The kernel adds `com.apple.provenance` to new files when the build runs under an app macOS
   tracks, such as an AI agent's shell; build releases from Terminal or CI.) `--dev` only warns.
6. Fill `pkg/Distribution.xml.in` and run `productbuild --distribution … --package-path build/pkg`, with
   `--sign "<installer identity>" --timestamp` unless `--dev`.
7. Unless `--dev`/`--no-notarize`: `xcrun notarytool submit --wait --output-format json`. Judge by the `status` field,
   always fetch and print `notarytool log`, require `Accepted`. Then `xcrun stapler staple` and `stapler validate`.
8. Verify the product: its Distribution (arm64, local system only, the installation check, the pkg-ref version), that
   it embeds exactly the component package checked in step 5, `pkgutil --check-signature` (Developer ID Installer,
   trusted timestamp), except in `--dev`, and `spctl -a -vvv -t install` (`Notarized Developer ID`) in the default and
   `--dry-run` modes only. Gatekeeper always rejects a pkg that isn't notarized, so `--no-notarize` only prints its
   verdict.
9. Only now move the product (built as `build/pkg/unverified.pkg`) to `dist/` under its name, and write
   `dist/SHA256SUMS.txt`.

`make release` runs `scripts/release.sh` (locally: `NOTARY_PROFILE=insomnia make release`); `make pkg-dev` runs
`scripts/release.sh --dev`.

### build.sh release mode

With `INSOMNIA_RELEASE=1`, build.sh:
- auto-picks the first `Developer ID Application:` identity, and refuses any identity that isn't one;
- signs the helper and the app with `--timestamp` (Apple's timestamp server, needs network) instead of
  `--timestamp=none`;
- checks that both signatures carry a `Timestamp=`.

Everything else is unchanged. The XPC requirement (`anchor apple generic` + team OU + no `get-task-allow`) matches a
Developer ID certificate of the same team. The cdhash pin is read after signing, so it stays correct. The cdhash does
change with the identity (the designated requirement is hashed into the signature), so a release build and a
`make install` build of the same source always differ, and switching between them re-registers the helper.

## CI: `.github/workflows/release.yml`

- **Triggers:** a pushed `v*` tag builds and publishes. `workflow_dispatch` is a dry run: `scripts/release.sh
  --dry-run` builds, signs and notarizes `Insomnia-<version>-dryrun.pkg`, which is only uploaded as a workflow
  artifact.
- **Job `build`** on `runs-on: xcode-27` (macOS 27, arm64, free on public repos; `macos-latest` only has Xcode 26),
  `environment: release`:
  1. Checkout with `persist-credentials: false`.
  2. `sudo xcode-select -s /Applications/Xcode_27.2.app`, then fail unless `xcodebuild -version` reports build
     `27B52`, the build the developer tests with. (The image default is 27.1, and the image with the final 27.2 was
     still rolling out in November 2026. If a job lands on the old image, re-run it.)
  3. `swift test`.
  4. Write the `.p12` and the `.p8` from the secrets with `umask 077` to `$RUNNER_TEMP` (passed to the import action as
     a file, so the action leaves no copy of its own), then import the `.p12` into a temporary keychain with
     `apple-actions/import-codesign-certs` (pinned by SHA). `INSOMNIA_SIGN_KEYCHAIN` stays unset: the keychain is
     already unlocked and on the search list.
  5. `scripts/release.sh` for a tag push, with `RELEASE_TAG`; `scripts/release.sh --dry-run` for `workflow_dispatch`
     (`RELEASE_TAG` empty).
  6. An `if: always()` step deletes both files and locks the keychain: nothing after this signs.
  7. Smoke test on the throwaway runner: take the one package in `dist/` (the step fails unless exactly one
     `dist/Insomnia-*.pkg` exists, so it doesn't hard-code the mode's name), `sudo installer -pkg <it> -target /`, then
     `scripts/lid-verify.sh --staged /Applications/Insomnia.app` (signatures, daemon plist, root ownership), and fail if
     the install changed the owner or mode of `/Applications` (warn if the image's isn't `root:admin drwxrwxr-x`).
  8. Tag builds only: attest the stapled pkg (`actions/attest`, which makes the same SLSA build provenance that
     `actions/attest-build-provenance` v4 now wraps). A dry run's package must not verify as a release. Upload
     `dist/` as an artifact, kept 14 days for a tag and 3 days for a dry run. The repo is public, so anyone signed in
     to GitHub can download a run's artifacts.
- **Job `publish`** (tags only) on `ubuntu-latest` with `contents: write` and no Apple secrets: fail unless the
  artifact holds `Insomnia-<version>.pkg` under its plain name, check `SHA256SUMS.txt`, then
  `gh release create "$TAG" --verify-tag --generate-notes` with the pkg and `SHA256SUMS.txt`.
- **Hardening:** top-level `permissions: {}`; every action pinned to a full commit SHA; no caches; never
  `pull_request_target` or `workflow_run`; secrets only in the `release` environment.

`.github/workflows/ci.yml` runs `swift build -c release` and `swift test` on pushes to `main` and on pull requests,
with no secrets and no signing.

## One-time setup (maintainer)

Apple (developer.apple.com, Account Holder):
1. Confirm the Apple Developer Program membership is active (team `38Z68N4XM3`).
2. Create a **Developer ID Application** and a **Developer ID Installer** certificate. Choose the **G2 Sub-CA**:
   certificates from the original Developer ID CA stop working on 2027-02-01. G2 certificates seen on this Mac (issued
   up to August 2026) are valid for five years, but none can outlive the G2 CA itself (2031-09-17), and an October 2026
   report says new ones may last only one year. Check: `openssl x509 -noout -enddate` on the exported certificate.
3. Export both (with their private keys) into one `.p12` with a strong password. Only the current pair: two
   certificates with the same name make codesign fail as ambiguous. Keep an offline backup. Don't leave
   them in the login keychain, which signs without asking: any process running as you could sign malware under your
   name. Keep them in CI secrets, or locally in a separate locked keychain (`INSOMNIA_SIGN_KEYCHAIN`).
4. In App Store Connect > Users and Access > Integrations, create a **Team API key** with the Developer role. The
   `.p8` downloads only once.
5. Local notarization (optional): `xcrun notarytool store-credentials insomnia --key … --key-id … --issuer …`, then
   `NOTARY_PROFILE=insomnia make release`.

GitHub (repo settings):
1. Environment `release`: you as required reviewer, deployment limited to tags matching `v*` and the `main` branch
   (the `workflow_dispatch` dry run runs from `main`; with tags only, the environment refuses it before it starts).
2. Environment secrets: `DEVELOPER_ID_P12_BASE64` (`base64 -i certs.p12`), `DEVELOPER_ID_P12_PASSWORD`,
   `ASC_API_KEY_P8_BASE64` (`base64 -i AuthKey_XXXX.p8`), `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`.
3. A tag ruleset so only you can create `v*` tags.
4. Keep the default workflow token read-only.
5. Turn on immutable releases (Settings > General > Releases).

## Cutting a release

1. Land everything that changes the helper first, so the public helper stays put.
2. Set the version in `Resources/Info.plist` (`CFBundleShortVersionString`, and bump `CFBundleVersion`) and in
   `HelperInfo.version`; commit to `main`.
3. Optional dry run: run the workflow by hand (`workflow_dispatch`) and install the artifact on a test Mac. Its
   package is `Insomnia-<version>-dryrun.pkg`, notarized like a release. Anyone signed in to GitHub can download it
   for 3 days, so never pass it around as the release.
4. `git tag v1.0.0 && git push origin v1.0.0`, then approve the `release` environment when asked.

Before the certificates expire (their `notAfter`, see one-time setup step 2): renew both and replace the `.p12` secrets
with the new pair. Published releases need nothing: their signatures are timestamped.

## Test before v1.0.0

On macOS VMs (14, 15, 26, 27), with the pkg downloaded in a browser:
- Fresh install, then approval; install offline (stapled ticket). Does Installer show "will run a program to
  determine if the software can be installed"?
- Upgrade with the same helper (kickstart makes engage work) and with a changed helper (no kickstart; the app
  re-registers when opened; does approval come back?), each with Insomnia running and not running.
- Upgrade from a `make install` build; downgrade (refused); uninstall; install with Kong's Insomnia present (refused),
  in the Installer app and with `installer -pkg`.
- Upgrade over a v1 ad-hoc install with `/etc/sudoers.d/zz_insomnia` and the `com.gdeml.insomnia.safety` daemon
  present: both are gone afterwards, `SleepDisabled` is 0, and the install log has the removal line.
- Two users with fast user switching, both running Insomnia.
- Second user after a changed helper: user A sets up lid mode, then user B upgrades to a version with a new helper
  and opens it before A does. Expected today: lid mode fails for B until A opens the new version (Not done yet).
  Then A opens it, and lid mode works for both.
- `ls -ld /Applications` before and after.

Lid mode itself needs a real MacBook.

## Not done yet

- **Fix before v1.0.1:** after an upgrade that changes the helper's cdhash, only the macOS user whose settings hold
  `helperRegisteredCDHash` re-registers the helper (postinstall step 1). Another user's copy sees `.enabled`, gets no
  answer from the old helper and has no saved value, so it treats the change as unknown and lid mode fails for them
  until that user opens the new version. The fix belongs in the app (`HelperClient.upgradeIfNeeded`). This only
  happens on an upgrade, and it is the newly installed app that re-registers, so a fix shipped in v1.0.1 already
  covers the upgrade from v1.0.0.
- Rename (open decision above).
- Splitting the app version from `HelperInfo.version`.
- `make install` restarts the helper even when its cdhash changed, which postinstall avoids (docs/DESIGN.md
  "Security" says why they differ). Give `make install` postinstall's rule, or record that the kickstart is harmless.
- Homebrew tap.
