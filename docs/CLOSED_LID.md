# Insomnia: Closed-Lid Mode (technical design)

Goal: a MacBook keeps running with the **lid closed, on AC or battery, without an external display**. When anything goes wrong (crash, hang, Force Quit, reboot, heat, low battery), it **returns to normal sleep**, and when it can't, it says so loudly (`.stuck`).

Verified on macOS 27.0.1 (arm64) with read-only probes. `pmset disablesleep` is **undocumented** (absent from `man pmset` on 27.0.1), so readback is load-bearing: a mismatch goes to `.error`, never a retry loop. Release blockers are in §8, open questions in §10. Lid mode exists only when `PowerMonitor.hasLid`; on desktops none of this is offered.

---

## 1. Mechanism

| Mechanism | Lid closed, no ext. display | Used for |
|---|---|---|
| `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` | ✗ (the header says lid close still sleeps) | Normal keep-awake (every hold) |
| `kIOPMAssertionTypePreventUserIdleDisplaySleep` | ✗ | "Keep screen on" |
| `kIOPMAssertionTypePreventSystemSleep` | ✗ (deprecated since 10.9, AC only) | Not used |
| Official clamshell (ext. display + input + power) | ✓ | Works without us |
| **`pmset -a disablesleep 1`** (kernel/powerd `SleepDisabled`) | **✓ on AC and battery** | **Lid mode** |

**Decision:** lid mode **adds** `SleepDisabled = 1` on top of the normal assertions. It never replaces them.

**Side effects we must own:**

1. **macOS low-battery sleep is disabled**, and probably thermal-emergency sleep too (§10 #1; assume yes). Hence the mandatory lid battery floor, the stricter bag-condition thermal guard (§6) and the root battery backstop (§2.2).
2. **Apple menu ▸ Sleep and `pmset sleepnow` are blocked** while the flag is 1. Our **Sleep Now** releases the flag first, then runs `/usr/bin/pmset sleepnow` (no root needed).
3. **The internal panel may stay lit with the lid shut** on Apple Silicon. Run `/usr/bin/pmset displaysleepnow` (no root) and drop our display assertion when, while engaged, `isLidClosed && externalDisplayCount == 0` becomes true: on lid close **and** on `didChangeScreenParametersNotification` (the last external display unplugged with the lid shut). Never with an external display attached; it would blank that too.
4. **Releasing the flag while the lid is shut doesn't reliably sleep the Mac.** After a release while `isLidClosed && externalDisplayCount == 0`, run `/usr/bin/pmset sleepnow`.

**State readback:** from IORegistry, never by parsing `pmset -g` text.

- **Service:** `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))`.
- **Properties:** `"SleepDisabled"` (CFBoolean), `"AppleClamshellState"` (`kAppleClamshellStateKey`, CFBoolean; absent on desktops → `hasLid = false`). `"AppleClamshellCausesSleep"` is diagnostics only.
- **Events:** `IOServiceAddInterestNotification(rootDomain, kIOGeneralInterest, cb)`. The message macro doesn't import into Swift, so define `let kIOPMMessageClamshellStateChange: UInt32 = 0xE003_4100` (`sys_iokit | err_sub(13) | 0x100`). Decode `let bits = UInt(bitPattern: messageArgument)`; `closed = bits & UInt(kClamshellStateBit) != 0` (`kClamshellSleepBit` likewise).
- **Fallback:** a 5 s poll, **only while engaged**.

---

## 2. Privilege model

**Decision:** a **narrow sudoers rule** installed once through an admin prompt; afterwards the app calls `sudo -n` silently. It sits behind `PrivilegedBackend` so an SMAppService/XPC helper can replace it.

| Option | Verdict | Why |
|---|---|---|
| **Sudoers rule in `/etc/sudoers.d/zz_insomnia`** | **Chosen** | One password prompt, ever. Works ad-hoc signed, no Team ID. Same approach as Sleepless and (by inference) Amphetamine Power Protect. Unattended reset works, which the watchdog needs. |
| `SMAppService.daemon` + XPC helper | Later | App and helper must share an Apple-issued signing identity; ad-hoc fails with "Operation not permitted". Better once a Developer ID exists. |
| `osascript … with administrator privileges` per toggle | Install/uninstall and **Reset with password…** only | A password per toggle, and no unattended watchdog. |
| `AuthorizationExecuteWithPrivileges` | Rejected | Deprecated since 10.7. |
| A setuid helper | Rejected | Same-user code could swap or abuse it. |
| `/usr/bin/pmset` without arguments | **Forbidden** | `pmset -a hibernatefile <path>` = root writes an arbitrary path. |

### 2.1 Exact sudoers content

File `/etc/sudoers.d/zz_insomnia`, `root:wheel`, `0440`. No dot or `~` in the name (sudo skips those), and the `zz_` prefix sorts it last, because **the last matching sudoers entry wins** (a later `%admin ALL=(ALL) ALL` would otherwise re-impose a password).

```
# Installed by Insomnia.app. Allows exactly two commands. Remove: Insomnia > Settings > Lid & Safety > Remove, or: sudo rm /etc/sudoers.d/zz_insomnia
#<uid> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

- **`#<uid>`:** the numeric uid, computed by the root script from `NSUserName()`. A uid can't collide with `ALL` or a `User_Alias`. Swift first validates the name against `^[A-Za-z0-9._][A-Za-z0-9._-]*$` (`LidSetupError.invalidUser`).
- **Argument matching:** sudo glob-matches the arguments as one space-joined string. Never add `*`; if a variant is ever needed, use an anchored `^…$` regex. `/usr/bin/pmset` is SIP-protected and `env_reset` is on.

### 2.2 Safety daemon (boot reset + root battery backstop)

File `/Library/LaunchDaemons/com.gdeml.insomnia.safety.plist`, `root:wheel`, `0644`. `ProgramArguments` = `/bin/sh`, `-c`, and this fixed script (no `<` or `&`, so it embeds in the XML unescaped):

```sh
B=/var/run/com.gdeml.insomnia.booted
/usr/sbin/ioreg -r -c IOPMrootDomain -d 1 | /usr/bin/grep -q '"SleepDisabled" = Yes' || { /usr/bin/touch $B; exit 0; }
if [ ! -e $B ]; then /usr/bin/touch $B; /usr/bin/pmset -a disablesleep 0; exit 0; fi
b=$(/usr/sbin/ioreg -r -c AppleSmartBattery -d 1)
case $b in *'"ExternalConnected" = No'*) ;; *) exit 0 ;; esac
c=$(echo "$b" | /usr/bin/sed -n 's/^ *"CurrentCapacity" = \([0-9]*\)$/\1/p')
m=$(echo "$b" | /usr/bin/sed -n 's/^ *"MaxCapacity" = \([0-9]*\)$/\1/p')
if [ -n "$c" ] && [ -n "$m" ] && [ $((c * 100)) -le $((m * 10)) ]; then /usr/bin/pmset -a disablesleep 0; /usr/bin/pmset sleepnow; fi
```

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.gdeml.insomnia.safety</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>SCRIPT_ABOVE</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
</dict></plist>
```

- **Boot reset:** `/var/run` is emptied at boot, so the first run with the flag at 1 is a boot run and resets it **before login**, whoever set it (accepted: Amphetamine and MDM re-apply their own). `SleepDisabled` persists across reboots (it's stored in `/Library/Preferences/com.apple.PowerManagement.plist`), so this layer is required.
- **Battery backstop:** every 60 s, if the flag is 1, on battery, at ≤ 10%, it resets and sleeps, **whoever set the flag and whether or not the app is alive or hung**.
- It takes no input and runs only SIP-protected binaries, so it adds no escalation path. macOS shows "Background Items Added"; the setup sheet explains it.

### 2.3 Install script (run once, as root, **inline**)

No user-writable file anywhere in the chain, so same-user code can't swap the script or temp files.

**How Swift invokes it** (on `LidReconciler`, see §4.3):

1. Build `script` (below), substituting the validated `<user>` and the §2.2 plist.
2. Escape for an AppleScript literal: `\` → `\\`, then `"` → `\"`, then newline → `\n`.
3. `Process`: `/usr/bin/osascript`, `-e`, `do shell script "<escaped>" with administrator privileges with prompt "Insomnia needs your password once to keep your Mac awake with the lid closed."` (argv array, never a shell).
4. Map the result. osascript exits **1** for any script failure and for cancel; the code is only at the end of stderr:
   - exit 0 → success;
   - else match stderr against `/\((-?\d+)\)\s*$/`: `-128` → `.cancelled`; `10` → `.invalidUser`; `11` → `.includedirMissing`; other N → `.scriptFailed(code: N, detail: stderr)`;
   - no match → `.scriptFailed(code: terminationStatus, detail: stderr)`.

```sh
set -eu
umask 077
U='<user>'
SD=/etc/sudoers.d
LD=/Library/LaunchDaemons
LABEL=com.gdeml.insomnia.safety
UID_N=$(/usr/bin/id -u "$U") || exit 10
case $UID_N in ''|*[!0-9]*) exit 10;; esac
[ -d "$SD" ] && [ ! -L "$SD" ] || exit 16
/usr/bin/grep -Eq '^[#@]includedir[[:space:]]+(/private)?/etc/sudoers\.d[[:space:]]*$' /etc/sudoers || exit 11
/bin/rm -f "$SD"/.insomnia.* "$LD"/.insomnia.*
t=$(/usr/bin/mktemp "$SD/.insomnia.XXXXXX")
p=$(/usr/bin/mktemp "$LD/.insomnia.XXXXXX")
trap '/bin/rm -f "$t" "$p"' EXIT
/bin/cat > "$p" <<'PLIST'
<PLIST_XML_FROM_2.2>
PLIST
/usr/sbin/chown root:wheel "$p"; /bin/chmod 0644 "$p"
/usr/bin/plutil -lint -s "$p" || exit 13
/usr/bin/touch /var/run/com.gdeml.insomnia.booted
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/mv -f "$p" "$LD/$LABEL.plist"
/bin/launchctl bootstrap system "$LD/$LABEL.plist" || exit 17
/usr/bin/printf '%s\n' '# Installed by Insomnia.app. Allows exactly two commands. Remove: Insomnia > Settings > Lid & Safety > Remove, or: sudo rm /etc/sudoers.d/zz_insomnia' "#$UID_N ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" > "$t"
/usr/sbin/chown root:wheel "$t"; /bin/chmod 0440 "$t"
/usr/sbin/visudo -cqf "$t" || exit 12
/bin/mv -f "$t" "$SD/zz_insomnia"
/usr/sbin/visudo -cq || { /bin/rm -f "$SD/zz_insomnia"; exit 14; }
trap - EXIT
if /usr/sbin/ioreg -r -c IOPMrootDomain -d 1 | /usr/bin/grep -q '"SleepDisabled" = No'; then
  /usr/bin/sudo -u "#$UID_N" /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 || exit 15
fi
exit 0
```

| Step | Why |
|---|---|
| uid check (10), dir check (16), `#includedir` check (11) | We **never edit `/etc/sudoers`**; if the stock include is missing we abort and explain. |
| `mktemp` in **root-owned** dirs, **dotted** names; stale `.insomnia.*` removed first | Half-written files are inert (sudo ignores dotted names, launchd ignores non-`.plist`). |
| **Daemon before rule** | A daemon alone is harmless; a rule without its safety net is not. |
| `touch …booted` before `bootstrap` | The immediate `RunAtLoad` run must not reset a foreign flag. |
| `visudo -cqf` file, then `visudo -cq` full config | Never a broken sudo; roll back our file if the full check fails. |
| Final probe as the user (15) | Proves `sudo -n` works for *that user* (no later rule overrides us). It's a no-op, and skipped if the flag is already 1. **Install never resets the flag.** |

| Exit | `LidSetupError` | UI copy (all tiers) |
|---|---|---|
| -128 | `.cancelled` | "Setup skipped." (gentle, no error tone) |
| 10 | `.invalidUser` | "Couldn't identify your user account." |
| 11 | `.includedirMissing` | "Your sudoers file doesn't include /etc/sudoers.d, so Insomnia won't touch it." |
| 12–17, other | `.scriptFailed(code, detail)` | "Setup failed (code N)." + [Copy details] |

### 2.4 Detecting the install (`HelperStatus`)

| Check | How (no root needed) |
|---|---|
| Rule file present | `fileExists("/etc/sudoers.d/zz_insomnia")` |
| Rule **works** | Only while IORegistry `SleepDisabled == false`: `sudo -n /usr/bin/pmset -a disablesleep 0` exits 0 (a real no-op). While the flag is 1, keep the last result. (`sudo -l` is not used: it reports *permitted*, not *passwordless*.) |
| Daemon present | `fileExists("/Library/LaunchDaemons/com.gdeml.insomnia.safety.plist")` |
| Daemon enabled | `SMAppService.statusForLegacyPlist(at:) == .enabled`, cross-checked with `launchctl print-disabled system` (§10 #6) |

- `.installed`: rule works, daemon present and enabled.
- `.daemonDisabled`: both present, daemon off in Login Items. **Refuse to engage**; UI: "Enable Insomnia in Login Items" + button to System Settings.
- `.partial(sudoers:safetyDaemon:)`: one is missing or the rule doesn't work. **Repair…** re-runs the install.
- `.notInstalled`: neither.

Re-check at launch, after install/uninstall, on `didBecomeActive`, and when Settings ▸ Lid & Safety opens.

### 2.5 Uninstall (`uninstall()`)

1. Run the **Release** sequence (§4.3) and disarm the watchdog.
2. Run this inline (one admin prompt). `<reset>` is `1` only if the marker still exists, so a foreign flag is never touched:

```sh
L=com.gdeml.insomnia.safety
[ '<reset>' = 1 ] && /usr/bin/pmset -a disablesleep 0
/bin/launchctl bootout "system/$L" 2>/dev/null || true
/bin/rm -f "/Library/LaunchDaemons/$L.plist" /etc/sudoers.d/zz_insomnia /etc/sudoers.d/.insomnia.* /Library/LaunchDaemons/.insomnia.* /var/run/com.gdeml.insomnia.booted
[ ! -e /etc/sudoers.d/zz_insomnia ] && [ ! -e "/Library/LaunchDaemons/$L.plist" ] || exit 20
```

3. Delete the marker; set `Settings.closedLidMode = false`.

---

## 3. Threat model

| Threat | Mitigation | Residual risk |
|---|---|---|
| Same-user code uses the rule | Only `disablesleep 0/1`, no wildcard, SIP-protected `pmset`. The root backstop (§2.2) enforces the 10% floor **whoever set the flag**. A flag at 1 without our marker shows "set by something else" in Diagnostics and posts `foreign-flag` once per boot. | **Allows silent bypass of lid-close and low-battery sleep** with none of our in-app guards (heat in a bag, discharge to 10%). Accepted and stated in the setup sheet. |
| Escalation via other pmset sub-commands | Plain `/usr/bin/pmset` is never granted. | None |
| TOCTOU on install | Inline script; temp files only in root-owned dirs; atomic `mv`. | None known |
| Username injection / alias collision | Regex, `id -u`, numeric `#uid`, `visudo -cf`. | None |
| A later sudoers file overrides ours | `zz_` filename; install-time and status probes run the real command. | A file named after `zz_insomnia` |
| Broken sudoers locks out admin | `visudo -cqf` + `visudo -cq`, with rollback. | None known |
| Malicious app uses our CLI socket | Socket `0600` in a `0700` dir, `getpeereid` check. CLI lid is per hold and guarded. | Same as row 1 |
| A web page opens an `insomnia://` link | **URL holds never get lid** (`lid` param ignored and logged). | A page can keep the Mac awake with the lid open. Low impact. |
| User disables the daemon in Login Items | `HelperStatus.daemonDisabled` refuses to engage. | None while the app runs |
| App moved to the Trash without Remove | Rule + daemon stay; backstop still enforced. Remove instructions are in the sudoers comment and README. | Leftover rule |

Rejected: a daemon that resets the flag whenever no `Insomnia` process runs. It would fight foreign setters (Decision 23) for friction, not security.

---

## 4. Layered failure safety

Invariant: **if no live, responsive Insomnia process wants lid mode, `SleepDisabled` is 0**; if it can't be made 0, the UI is `.stuck`.

| Layer | Covers | Mechanism |
|---|---|---|
| **1. Normal path** | Stop, timer, guards, Sleep Now, Quit, logout, restart, shutdown | Release sequence (§4.3). Quit, logout and shutdown all arrive as a quit Apple Event: `applicationShouldTerminate` returns `.terminateLater` when the marker exists or lid ≠ `.off`, awaits `releaseForQuit(timeout: 2)`, then replies `true`. |
| **2. Watchdog** | Crash, Force Quit, `kill -9`, **app hang > 90 s**, watchdog killed by TERM/HUP/INT | Pipe EOF, heartbeat timeout or signal trap (§4.1) |
| **3. Safety daemon** | Reboot, power loss, panic; flag at 1 on battery ≤ 10% for any reason | §2.2 |
| **4. Launch recovery** | Any gap | At launch, marker exists **and** `SleepDisabled == true` → reset, delete the marker, `recovered` notification + banner. |

### 4.1 Watchdog (spawned **before** the flag is set to 1)

```
pipe(fds); fcntl(fds[1], F_SETFD, FD_CLOEXEC); fcntl(fds[1], F_SETNOSIGPIPE, 1)
file actions: adddup2(fds[0] → 0); addopen(1 and 2, "/dev/null", O_WRONLY)
attr flags:   POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
argv: /bin/bash -c 'r(){ exec /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; }; trap r TERM HUP INT; while IFS= read -r -t 90 l; do [ "$l" = disarm ] && exit 0; done; r'
parent: close(fds[0]); keep fds[1]; DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)
```

- `/bin/bash` explicitly (not `/bin/sh`, which a user can point at dash): `read -t` and the trap need bash.
- **Heartbeat:** while engaged, a main-actor timer asks the reconciler to write `"h\n"` every 20 s. A hung main actor or reconciler stops it, and the watchdog resets within 90 s.
- **App Nap:** while engaged, hold `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Insomnia lid mode safety guards")`; end it on release.
- **fd hygiene:** the pipe is created and every child process in the app (watchdog, `sudo`, `pmset`, `osascript`) is spawned **only on `LidReconciler`**, so no other fork can inherit `fds[1]` in the `pipe`→`fcntl` window. `main.swift` sets `signal(SIGPIPE, SIG_IGN)`.

| Event | What happens |
|---|---|
| App dies, or stops heartbeating for 90 s | EOF or `read` timeout → reset |
| Watchdog gets TERM/HUP/INT (logout, `pkill`) | Trap → reset |
| Normal disable | App resets, reads back 0, writes `"disarm\n"`, closes. Watchdog exits **without** resetting. |
| App's reset failed | Close **without** disarm (`abandon()`): the watchdog retries. |
| Watchdog exits while engaged (process source fires, or a write returns `EPIPE`) | It has reset the flag (or was SIGKILLed). Run Release; end in `.error(.watchdogLost)`, or `.stuck` if the flag reads 1 and can't be reset. **No silent re-arm.** |

One watchdog at a time; reap it with `waitpid` after disarm or exit. If `posix_spawn` fails, refuse to engage (`.error(.commandFailed(-1))`). **Lid mode never runs without a live watchdog.**

### 4.2 Marker file

- `~/Library/Application Support/Insomnia/lid-engaged`: our PID and an ISO date. Written (with `fsync`) **before** spawning the watchdog; deleted after a verified release. A file, because a crashing process's writes are unambiguous.
- **Foreign flag:** `SleepDisabled == true` with no marker means something else set it (Amphetamine, an admin, MDM). The app **never touches it** (only the boot reset and the 10% backstop do).

### 4.3 Sequences (all on `actor LidReconciler`, one at a time)

The engine publishes a *desired* boolean; the reconciler converges on the latest value and coalesces changes that arrive mid-call.

**Engage:** (1) `helper == .installed`, else `.needsSetup`. (2) Write the marker. (3) Arm the watchdog. (4) `sudo -n /usr/bin/pmset -a disablesleep 1`, 5 s timeout. (5) Read back, up to 3 × 200 ms. (6) `true` → `.engaged(lidClosed:)` and start the heartbeat. Otherwise Release, then `.error(.readbackMismatch)`.

**Release:** (1) `sudo -n … disablesleep 0`. (2) Read back `false`. (3) Disarm. (4) Delete the marker. (5) Lid closed and no external display → `pmset sleepnow`. (6) `.off`. If (1) or (2) fails: `abandon()`, wait 2 s, read again: `false` → `.error(.commandFailed(status))`; still `true` → **`.stuck`**.

**`.stuck`:** red and persistent; `lid-stuck` notification; the panel offers **Reset with password…** (`osascript … do shell script "/usr/bin/pmset -a disablesleep 0" with administrator privileges`). Guards keep evaluating and notifying, and the root backstop still applies.

**Drift:** while engaged, re-read every 60 s, on `didWakeNotification` and on power-source changes. An unexpected `false` while the watchdog is alive is an **intentional external override**: disarm, delete the marker, `.error(.overridden)`. Never re-applied without a user action.

**Quit:** `releaseForQuit(timeout:)` cancels any pending desired state and runs Release. On timeout or failure it calls `abandon()` so the watchdog finishes the job.

---

## 5. Engagement condition

```
bag       = isLidClosed && externalDisplayCount == 0 && !isOnAC
wantLid   = any live, non-suspended hold has options.lid
lidGuards = tripped of [batteryFloor, thermal, lowPowerMode, acRequired, lidBatteryCap]
desired   = wantLid && hasLid && helper == .installed && lidGuards.isEmpty && !latched
```

| Hold | `screen` | `lid` |
|---|---|---|
| Manual from panel, hotkey, Dock, menu bar; babysit (`followsSettings`) | `keepScreenOn` | `closedLidMode` |
| Rule (`followsSettings`) | `rule.keepScreenOn` | `rule.allowLid \|\| closedLidMode` |
| CLI `on` with flags (fixed) | flag, else `keepScreenOn` at start | flag, else `closedLidMode` at start |
| URL `on` (fixed) | `screen=` param, else `keepScreenOn` | **always false** |
| Client `run`/`watch` (fixed) | flag | flag |

The CLI and URL scheme **never write Settings**.

**Latch.** If a lid guard trips while `isLidClosed`, set `latched`. Re-engaging then needs a clamshell-open event or a user action (panel, hotkey, Dock, lid switch). Never go `.off`/`.suspended` → `.engaging` while latched, so a DarkWake (Power Nap, Bluetooth) can't re-arm a Mac in a bag.

**Lid battery counter.** One engine-scoped `lidBagSeconds`, which accumulates while engaged in the bag condition, for any hold type. It resets **only when the lid opens**; new holds and plugging in AC don't reset it. It feeds `PolicyInput.lidBagSeconds`.

---

## 6. Safety guards

| Guard (`GuardReason`) | Trips when | Clears when | Affects | Configurable |
|---|---|---|---|---|
| `batteryFloor` | `hasBattery && !isOnAC && percent <= floor` | `isOnAC \|\| percent >= floor + 3` | Lid only | Floor 10–50%, default 20. **Mandatory.** |
| `awakeBatteryFloor` | Same, and `awakeBatteryFloorEnabled` | Same | **Everything**: ends manual holds (`DeactivationReason.batteryFloor`), suspends the rest | Opt-in, default off |
| `thermal` | `>= .serious`; **or** `>= .fair` for 5 min in the bag condition | Trip condition false for 60 s | Lid only | Always on |
| `lowPowerMode` | `isLowPowerModeEnabled` | It turns off | Lid only | Always on |
| `acRequired` | `lidRequiresAC && hasBattery && !isOnAC` | `isOnAC` | Lid only | Default off |
| `lidBatteryCap` | `lidBagSeconds >= lidMaxOnBatteryMinutes × 60` | The lid opens (counter resets) | Lid only | 30 min – 8 h, **default 1 h**, no "unlimited" |
| *(root backstop)* | Flag 1, on battery, ≤ 10% | n/a | Resets + sleeps, any setter | No |

Guard notifications fire once per engagement per guard, always on and silent (`UX.md` §10). Sensors: `IOPSCopyPowerSourcesInfo` + `IOPSNotificationCreateRunLoopSource`; `thermalStateDidChangeNotification`; `.NSProcessInfoPowerStateDidChange`; lid per §1.

---

## 7. State machine (`LidStatus`)

| From | Event | To |
|---|---|---|
| any | `wantLid` and `helper != .installed` | `.needsSetup` |
| `.off` / `.suspended` (not latched) | `desired` becomes true | `.engaging` |
| `.engaging` | readback ✓ | `.engaged(lidClosed:)` |
| `.engaging` | failure, flag verified 0 | `.error(e)` |
| `.engaged` | clamshell change | `.engaged(lidClosed: !old)` |
| `.engaged` | lid guard trips | release → `.suspended(g)`; latched if the lid is closed |
| `.suspended(g)` | guard clears, latched | `.latched` |
| `.latched` | lid opens or user action | `.engaging` (if desired) |
| `.engaged` | watchdog exits / drift sees 0 | `.error(.watchdogLost)` / `.error(.overridden)` |
| `.error` | Retry or user action | `.engaging` |
| any | `wantLid` false | release → `.off` |
| any release | reset fails and flag reads 1 | `.stuck` |
| `.stuck` | Reset with password ✓, or flag reads 0 | `.off` |

- `.suspended`, `.latched`, `.error`: the flag is **verified 0**, normal assertions keep running, and the Mac sleeps normally on lid close.
- `.stuck`: the flag is 1 and we can't clear it. Never say "sleeps normally" here.
- `.engaged(lidClosed: true)` runs the reopen-report counters (closed seconds, battery at close, worst thermal state).

---

## 8. Verify by hand, and M2 release blockers

```sh
sudo -n /usr/bin/pmset -a disablesleep 0; echo $?   # rule works (only when the flag is 0)
ioreg -r -c IOPMrootDomain -d 1 | grep -E '"(SleepDisabled|AppleClamshellState)"'
ls -l /etc/sudoers.d/zz_insomnia /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist
launchctl print-disabled system | grep insomnia
pgrep -fl 'read -r -t 90'                            # watchdog alive while engaged
pmset -g assertions
```

| # | Test (engaged unless noted) | Pass |
|---|---|---|
| T1 | `kill -9 $(pgrep -x Insomnia)` | `SleepDisabled = No` within 1 s |
| T2 | `kill -TERM <watchdog pid>` | `No` within 1 s; UI `.error(.watchdogLost)` |
| T3 | `kill -STOP $(pgrep -x Insomnia)` (simulated hang) | `No` within 100 s |
| T4 | Reboot (and power-cut) while engaged | `No` at the login window |
| T5 | Disable Insomnia in Login Items | `.daemonDisabled`; engage refused |
| T6 | `sudo rm /etc/sudoers.d/zz_insomnia`, then Stop | `.stuck` (red); Reset with password clears it |
| T7 | Dev build with cap = 1 min; lid closed on battery; let it sleep; trigger a wake (Bluetooth, Power Nap) | Stays `.latched`, flag `No`; re-engages only on lid open |
| T8 | Dev build with backstop at 95%; set the flag with `sudo pmset -a disablesleep 1` on battery | Mac sleeps within 60 s |
| T9 | Clamshell with ext. display; unplug it with the lid shut | Internal panel dark (phone camera at the hinge) |
| T10 | Logout while engaged | `No` at the login window |

## 9. Uninstall by hand

```sh
osascript -e 'quit app "Insomnia"'        # FIRST, so drift and the watchdog can't race the removal
sudo pmset -a disablesleep 0
sudo launchctl bootout system/com.gdeml.insomnia.safety 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist /etc/sudoers.d/zz_insomnia
rm -f ~/Library/Application\ Support/Insomnia/lid-engaged
```

## 10. Open questions (manual QA before M2 ships)

| # | Question | Until answered |
|---|---|---|
| 1 | Does `SleepDisabled = 1` block thermal-emergency sleep? | Assume **yes** (hence the bag-condition thermal rule). |
| 2 | Is `/etc/sudoers.d` included on stock macOS 27? | Exit 11 with an explanation. |
| 3 | Does the internal panel stay lit with the lid closed? | `displaysleepnow` runs anyway (harmless). |
| 4 | Does macOS itself clear the flag on an AC plug/unplug while closed? | If yes, re-apply once **on that event only**; drift still treats other zeros as overrides. |
| 5 | Does releasing with the lid closed sleep the Mac? | We call `pmset sleepnow`; confirm. |
| 6 | Which of `statusForLegacyPlist(at:)` / `launchctl print-disabled` tracks the Login Items toggle? | Check both; either reporting disabled → `.daemonDisabled`. |
