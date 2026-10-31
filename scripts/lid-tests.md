# Lid mode: release test runner notes (M2)

How to run the `docs/CLOSED_LID.md` §8 tests by hand. M2 ships only when every test passes for both backends.
Lines marked **sudo** or **changes power settings** are for the person at the Mac. Automated agents never run them.

## 0. Before anything: the register spike (§10 #6, Decision 42)

1. `make && make install` (**sudo**): puts a root-owned copy at `/Applications/Insomnia.app`.
2. `make lid-verify`: every line must be ✓ (signatures, pinned helper cdhash, root-owned bundle).
3. Open `/Applications/Insomnia.app`, then go to Settings ▸ Lid & Safety ▸ **Set Up…**. This calls `register()`.
4. Expect the "Background Items Added" notification and the approval step. Allow Insomnia in System Settings ▸
   General ▸ Login Items & Extensions.
5. `/Applications/Insomnia.app/Contents/MacOS/Insomnia --helper-status` should print `enabled` and exit 0.
   `sudo launchctl print system/com.gdeml.Insomnia.helper | grep -E 'state|pid'` (**sudo**) should show it running.
6. **If macOS refuses** an Apple Development–signed daemon (register throws, or it never runs), STOP. Record it in
   CLOSED_LID.md §10 #6 and get a Developer ID certificate + notarization. Don't promote the sudoers fallback.

Keep these running in a second terminal for every test:

```sh
log stream --style compact --predicate 'subsystem BEGINSWITH "com.gdeml.Insomnia"'
while :; do printf '%s ' "$(date +%T)"; ioreg -r -c IOPMrootDomain -d 1 | grep -E '"SleepDisabled"'; sleep 1; done
```

"Engaged" below means: the lid switch is on, a hold is running, and H′ says "Ready · close the lid anytime".

## Helper backend

| # | Do | Pass | Notes |
|---|---|---|---|
| T1 | `kill -9 $(pgrep -x Insomnia)` | `SleepDisabled = No` within 1 s | Connection invalidation → helper resets. Relaunch: "Restored normal sleep…" banner. |
| T2 | **sudo** `kill -TERM $(pgrep -x InsomniaHelper)`; re-engage; **sudo** `kill -9 $(pgrep -x InsomniaHelper)` | `No` within 1 s; after `-9`, `No` within 15 s; UI `.error(.safetyNetLost)` both times | After `-9`, launchd restarts the helper (KeepAlive) and its restart reset reads the ownership file `/var/run/com.gdeml.Insomnia.helper.engaged`. |
| T3 | `kill -STOP $(pgrep -x Insomnia)`, wait 50 s, `kill -CONT …`. Separately, hold a menu open for 60 s while engaged | `No` within 50 s; the held menu causes no `.safetyNetLost` | The heartbeat timer is in `.common` run-loop mode, so menu tracking doesn't stop it. |
| T4 | Reboot (and separately, cut power) while engaged | `No` at the login window | Boot reset: `/var/run/com.gdeml.Insomnia.helper.booted` holds `kern.bootsessionuuid`. |
| T5 | Switch Insomnia off in Login Items while engaged | `No` within 2 s; H′ "Allow in System Settings ›" | launchd SIGTERMs the helper, which resets and exits 0. The app sees `.requiresApproval`. |
| T6 | Build three test clients that call `engage`: (a) ad hoc, (b) our team + another identifier, (c) our team + identifier + `get-task-allow` | Each connection is rejected before any method runs; the flag doesn't change | The listener requirement rejects inside NSXPC, so the helper never sees these peers. Look for the rejection in the **system** log (`log stream --predicate 'eventMessage CONTAINS "com.gdeml.Insomnia.helper"'`), not the helper's own subsystem. |
| T7 | Dev build with `lidMaxOnBatteryMinutes` forced to 1 min. Close the lid on battery, let it sleep, then trigger a wake (Bluetooth, Power Nap) | Stays `.latched`, flag `No`; re-engages only when the lid opens | |
| T8 | Dev build with `HelperInfo.backstopPercent` at 95 (battery below it). On AC, **changes power settings** `sudo pmset -a disablesleep 1`, then unplug | Mac sleeps within 5 s | Exercises the IOPS-driven backstop. Afterwards: `sudo pmset -a disablesleep 0`. |
| T9 | Clamshell with an external display: unplug it with the lid shut | Internal panel goes dark (check with a phone camera at the hinge) | `pmset displaysleepnow` runs on the display-count drop. |
| T10 | Log out while engaged | `No` at the login window | |
| T11 | Set up with build A. Change helper code, `make install` build B while A's helper runs, launch | Old helper reports A's cdhash; silent re-register; then `status().cdhash` = B's; `.installed` or the approval step. With A's helper refusing to start: `.versionMismatch`, not "Repair" | Silent upgrade is tried once per bundled cdhash per launch. |
| T12 | Remove… while engaged; separately `make uninstall` (**sudo**) | `No`; status `.notRegistered`/`.notFound`; `sudo launchctl print system/com.gdeml.Insomnia.helper` fails, also after a reboot; Login Items entry gone | `make uninstall` first runs `Insomnia --unregister-helper`. |
| T13 | Fresh user: Set Up… → approve in System Settings | Panel reaches `.engaged` within 2 s of approval, without a relaunch | The approval step polls every 1 s. |
| T14 | AC cap enabled at 1 h (dev: 1 min); lid closed on AC | `.suspended(.lidACCap)`, latched, flag `No`; with the AC cap off it never trips on AC | |
| T15 | In a VM snapshot: (a) replace the installed helper with a different team-signed binary, reboot; (b) edit the bundled plist in place, reboot; (c) `chown -R $USER` the bundle, reboot | (a) launchd refuses it; (b) ignored or refused; (c) helper runs reset-only (boot reset still happens), UI `.unsafeLocation` | §10 #9 / #10. |
| T16 | Run the signed `build/Insomnia.app` | Set Up… disabled with "Install Insomnia with make install…"; `register()` never called | `InstallLocation.check` runs before `register()`. |
| T17 | Fast user switching: user A engaged; user B engages | B gets `.error(.otherUser)`; A releases → `No` | |
| T18 | Only with a dedicated signing keychain: from an unrelated process, `codesign -s "Apple Development: …" ./x` | A keychain prompt appears; no silent signature | Decision 43 keeps the login keychain, so this is N/A by default. |
| T19 | `INSOMNIA_SIGN_IDENTITY` unset with no usable identity; and `INSOMNIA_SIGN_IDENTITY=- scripts/build.sh` while a helper is registered | build.sh exits non-zero both times | |

## Sudoers fallback (`INSOMNIA_SIGN_IDENTITY=- make`)

Run T1, T3, T4, T7 and T10 as above, plus:

- A registered signed helper shows `.leftoverHelper`, and no sudoers install is offered.
- `kill -TERM <watchdog pid>`: find it with `pgrep -f 'read -r -t 45'`. Expect `No` within 1 s and `.error(.safetyNetLost)`.
- With the safety daemon switched off in Login Items: `.daemonDisabled`, and engage is refused.
- **sudo** `rm /etc/sudoers.d/zz_insomnia`, then Stop: `.stuck`. Reset with password… clears it.

## Open questions to record in CLOSED_LID.md §10 while testing

- **#2:** Do IORegistry `SleepDisabled` and `IOPMCopySystemPowerSettings()` agree within 600 ms after the helper's
  `pmset`? A disagreement shows up as `HelperResult.setFailed`, and the helper log says "readback mismatch".
- **#4:** Does macOS clear the flag on an AC plug or unplug while the lid is closed? Today that reads as
  `.error(.overridden)`.
- **#5:** Does a release with the lid shut sleep the Mac? We also run `pmset sleepnow`.
- **#7:** After unregister + register, is the approval kept?
- **#9:** Is `SpawnConstraint` enforced, and is `cdhash` the 20-byte value? build.sh pins the 20-byte
  `CodeDirectory` hash that `codesign -dvvv` prints.
