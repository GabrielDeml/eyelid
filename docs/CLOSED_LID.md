# Insomnia: Closed-Lid Mode (technical design)

Goal: a MacBook keeps running with the **lid closed, on AC or battery, without an external display**. When anything goes wrong (crash, hang, Force Quit, reboot, heat, low battery), it **returns to normal sleep**, and when it can't, it says so loudly (`.stuck`).

Verified on macOS 27.0.1 (arm64) with read-only probes. `pmset disablesleep` is **undocumented** (absent from `man pmset` on 27.0.1), so readback is load-bearing: a mismatch goes to `.error`, never a retry loop. Release blockers are in §8, open questions in §10. Lid mode exists only when `PowerMonitor.hasLid`; on desktops none of this is offered.

> **Verified on this Mac** (macOS 27.0.1 26A434, Xcode 27, arm64; helper spike with ids `com.gdeml.InsomniaSpike*`; nothing registered, nothing written to `/Library`, no power setting changed)
> - **Signing.** `Apple Development: Gabriel Deml (H3P5Q4G9WC)` signs **without a prompt** (login keychain). Certificate subject `OU=38Z68N4XM3` = Team ID; issuer Apple Worldwide Developer Relations CA G3. Signed with `--options runtime`: `flags=0x10000(runtime)`, `TeamIdentifier=38Z68N4XM3`, no entitlements.
> - **Requirement** `identifier "…" and anchor apple generic and certificate leaf[subject.OU] = "38Z68N4XM3" and !(entitlement["com.apple.security.get-task-allow"] exists)`: the signed build passes; an ad-hoc copy and a team-signed copy **with** `get-task-allow` fail (`codesign -v -R`, exit 3). `SecRequirementCreateWithString` parses it.
> - **SwiftPM.** Two executables + one static library build cleanly in Swift 6 mode. Products land in `.build/out/Products/Release` (use `swift build -c release --show-bin-path`). SwiftPM linker-signs ad hoc with identifier = target name, so re-signing needs `--force` and `--identifier`. Release binaries carry `LC_RPATH`s (`@loader_path`, the Xcode toolchain, a `/var/run/com.apple.security.cryptexd/mnt/…` path) but no `@rpath` loads; `otool -L` lists only `/usr/lib` and `/System`.
> - **cdhash** is unchanged by a re-sign or relink of identical code; it changes only when the code does.
> - **`SMAppService.daemon(plistName:).status` for a never-registered daemon is `.notFound`** (raw 3; BTM log "record not found"), **not** `.notRegistered`. Same for a missing plist and for an ad-hoc copy. `register()` has **not** been called yet; the SDK header says "Apps that contain LaunchDaemons must be notarized" (§10 #6).
> - `NSXPCConnection.setCodeSigningRequirement` and `NSXPCListener.setConnectionCodeSigningRequirement` are macOS 13+ and compile.
> - **Flag.** No `kIOPMSleepDisabledKey` constant and no header for `IOPMSetSystemPowerSetting` (exported, `dlsym` finds it; never called). `/usr/bin/pmset` holds private entitlements (`com.apple.private.iokit.rootdomain-set-property`, `RootDomainUserClient`), so the helper spawns `pmset`. Readable **without root**: IORegistry `SleepDisabled` and `IOPMCopySystemPowerSettings()` (via `dlsym`).
> - **Own cdhash.** `csops(getpid(), 5 /*CS_OPS_CDHASH*/, buf, 20)` via `dlsym` returns the kernel's cdhash. After the file is replaced by rename, the on-disk cdhash differs and `SecCodeCheckValidity(self)` returns `-67034` (`errSecCSStaticCodeChanged`).
> - `/var/run` is emptied at boot (every entry ≥ `kern.boottime`); `kern.bootsessionuuid` is readable. `/Applications` is `root:admin 0775`; the user is in `admin`.
> - **Not usable without root:** `sfltool dumpbtm` blocks; `launchctl print system/<label>` exits 113 whether or not the job exists. The app and build.sh rely on `SMAppService.status` instead.
> - Signature reads on the main thread log a Security runtime issue, so they run once, off the main thread.

---

## 1. Mechanism

| Mechanism | Lid closed, no ext. display | Used for |
|---|---|---|
| `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` | ✗ (the header says lid close still sleeps) | Normal keep-awake (every hold) |
| `kIOPMAssertionTypePreventUserIdleDisplaySleep` | ✗ | "Keep screen on" |
| `kIOPMAssertionTypePreventSystemSleep` | ✗ (deprecated since 10.9, AC only) | Not used |
| Official clamshell (ext. display + input + power) | ✓ | Works without us |
| **`SleepDisabled = 1`** (`pmset -a disablesleep 1`, kernel/powerd) | **✓ on AC and battery** | **Lid mode** |

**Decision:** lid mode **adds** `SleepDisabled = 1` on top of the normal assertions. It never replaces them. Only root can set it, hence §2.

**Side effects we must own:**

1. **macOS low-battery sleep is disabled**, and probably thermal-emergency sleep too (§10 #1; assume yes). Hence the mandatory lid battery floor, the stricter bag-condition thermal guard (§6) and the root battery backstop (§2.5).
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

### 2.1 Backends and selection

Both backends sit behind `PrivilegedBackend` (`ARCHITECTURE.md`), chosen **once at launch, off the main thread** (`CodeSignature.currentTeamID()` reads certificates; the result is cached):

| Backend | When | Install UX | Safety net |
|---|---|---|---|
| **`HelperBackend`** (primary) | Our own signature has a Team ID | `make install` (root-owned `/Applications/Insomnia.app`, §2.3), then `SMAppService.daemon` → user allows it in System Settings | Root helper: XPC connection watch + heartbeat, boot reset, battery backstop (§2.5) |
| **`SudoersBackend`** (fallback) | Build made ad hoc **on purpose** (`INSOMNIA_SIGN_IDENTITY=-`; no Team ID) | One admin password prompt | Bash watchdog + root safety daemon (§2.7) |

**No silent fallback.** `scripts/build.sh` fails instead of signing ad hoc when no identity is usable (locked keychain over SSH, expired certificate), and refuses an ad-hoc build while the installed app reports a registered helper (`Insomnia --helper-status`). At runtime the sudoers backend still reads `SMAppService.daemon(plistName:).status`: `.enabled` or `.requiresApproval` → `HelperStatus.leftoverHelper` ("A helper from a signed build is still registered [Remove…]"), and the sudoers install is **never offered** while it is. Remove calls `unregister()`; if macOS refuses that from an unsigned copy, the row says to run `make uninstall` from a signed build or switch Insomnia off in Login Items.

Rejected for both: `osascript … with administrator privileges` per toggle (a password per toggle, no unattended reset; used only for **Reset with password…**), `AuthorizationExecuteWithPrivileges` (deprecated), a setuid helper (same-user code could abuse it), and granting `/usr/bin/pmset` without fixed arguments (`pmset -a hibernatefile <path>` = root writes an arbitrary path).

If the helper backend is active and sudoers artefacts from an earlier unsigned build exist, Lid & Safety offers **Remove old setup…** (§2.7 uninstall script). They're never used by the helper backend.

### 2.2 Signing and trust

- **The Team ID is never in source.** It is read from our **own** signature at runtime (`InsomniaShared.CodeSignature`), so anyone can build with their own team. On this Mac it is **`38Z68N4XM3`** (`H3P5Q4G9WC` in the certificate name is the person id, **not** the team).
  - **App:** `CodeSignature.currentTeamID()` once at launch, off the main thread, cached.
  - **Helper:** `CodeSignature.readSelf()` once at start-up, **before** `listener.resume()`. The cdhash comes from the kernel (`csops CS_OPS_CDHASH`, via `dlsym`) and is compared with the file at its path. Match → Team ID and cdhash are kept in `let`s for the life of the process, and `status()` reports that cdhash. Mismatch (the binary was replaced since launch) → run the boot / restart reset (it only clears), log and `exit(75)`; launchd starts the new binary (`KeepAlive.SuccessfulExit = false`), which runs the restart reset. Nothing is ever re-read per connection, so a swapped file can't change whom a running helper trusts.
- **Helper → app**, set **once on the listener before `resume()`**: `listener.setConnectionCodeSigningRequirement(HelperInfo.clientRequirement(teamID:))` (macOS 13+). A bad peer is rejected before the delegate runs.
  ```
  identifier "com.gdeml.Insomnia" and anchor apple generic and certificate leaf[subject.OU] = "38Z68N4XM3" and !(entitlement["com.apple.security.get-task-allow"] exists)
  ```
- **App → helper**, set once on the connection before `resume()`: `connection.setCodeSigningRequirement(HelperInfo.helperRequirement(teamID:))`, the same string with `identifier "com.gdeml.Insomnia.helper"`.
- Both setters raise an Objective-C exception (uncatchable in Swift) on a malformed string, so each side checks it with `HelperInfo.isValidRequirement` first. Invalid, a nil Team ID or a failed self-check → the helper accepts **no** connections; the app reports `.unreachable`.
- The `get-task-allow` clause rejects debuggable team builds (Xcode's default), which same-user code could drive through `task_for_pid`. Hardened runtime can't be expressed in a requirement; build.sh enforces it on our builds (`flags=0x10000(runtime)` on both binaries), with **no** `get-task-allow`, `disable-library-validation`, `allow-dyld-environment-variables`, `allow-unsigned-executable-memory`, `disable-executable-page-protection` or `allow-jit`, and no non-system `LC_RPATH` (`ARCHITECTURE.md` Build model).
- **Who is trusted: anything that can use the team's signing key.** With the identity in the unlocked login keychain (today, verified), that is **every process running as you**. Such code can sign a client that passes the requirement and drive the helper without the app's guards (the same residual risk as sudoers; the root backstop still applies), or sign a replacement helper (blocked by §2.3 unless it can also replace the root-owned bundle). Optional hardening: keep the identity in a dedicated keychain that is locked by default; build.sh unlocks it (a password prompt), signs with `--keychain`, and locks it again (`INSOMNIA_SIGN_KEYCHAIN`, `ARCHITECTURE.md`). Default: open question (§10 #12).

### 2.3 Bundle layout, install location and launchd plist

```
/Applications/Insomnia.app/Contents/                    root:wheel, no group/other write (make install)
  MacOS/Insomnia
  MacOS/InsomniaHelper                                  codesign identifier com.gdeml.Insomnia.helper
  Library/LaunchDaemons/com.gdeml.Insomnia.helper.plist
```

**Install location.** launchd runs `BundleProgram` as root straight out of the bundle, so a bundle the user can write is a same-user → root path (swap the helper, wait for the next spawn). Therefore:

- The helper is registered **only** from `/Applications/Insomnia.app` installed by `make install`: `sudo ditto` into a root-created staging directory (`mktemp -d`, unpredictable name), `chown -R root:wheel`, `chmod -R go-w`, verify **that staged copy** (`scripts/lid-verify.sh --staged`: seal, code requirements, pinned helper cdhash, `RunAtLoad`, ownership), then rename into place. `InstallLocation.check` (exact path; the bundle and every item in it owned by root and not group/other-writable; `lstat`, no symlink following) runs before `register()`. Failure → `HelperStatus.unsafeLocation` / `LidSetupError.unsafeLocation`: "Install Insomnia with `make install` to use lid mode". **Never from `build/`.** This also avoids two copies sharing one Label and a registration that dangles when `build/` is deleted (registration is tied to the app's path; the header also wants `/Applications` so the daemon can start before login).
- **The helper runs the same check at start.** Failure → **reset-only mode**: boot reset, restart reset and backstop still run (they only ever clear the flag), the listener is never resumed, nothing is ever set to 1. It stays up, so there's no respawn loop.
- **Never copy onto an existing binary** (the kernel caches signatures per vnode, so the next launch is SIGKILLed). build.sh and `make install` assemble fresh copies and rename them into place.
- **Residual:** `/Applications` is `root:admin 0775`, so an admin user's process can rename the whole bundle aside and drop its own. Its helper must still pass launchd's team check (it needs our signing key, §2.2) and the build's `SpawnConstraint`, if launchd uses the one recorded at registration (§10 #9).

**Plist.** Template `Resources/com.gdeml.Insomnia.helper.plist.in`. build.sh fills in the Team ID and the signed helper's cdhash, then signs the app, which seals the plist. Until the helper is implemented (M2), build.sh leaves the plist out.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.gdeml.Insomnia.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/InsomniaHelper</string>
  <key>MachServices</key><dict><key>com.gdeml.Insomnia.helper</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>com.gdeml.Insomnia</string></array>
  <key>SpawnConstraint</key><dict>
    <key>team-identifier</key><string>__TEAM_ID__</string>
    <key>signing-identifier</key><string>com.gdeml.Insomnia.helper</string>
    <key>cdhash</key><dict><key>$in</key><array><data>__HELPER_CDHASH_BASE64__</data></array></dict>
  </dict>
</dict></plist>
```

- `RunAtLoad`: runs at boot (before login) for the boot reset.
- `KeepAlive {SuccessfulExit: false}`: a crash or the self-replace `exit(75)` restarts it (restart reset, §2.5). A clean exit 0 (`SIGTERM`, the M1 stub) stays down. Resident, so the backstop also covers foreign setters. Idle cost is zero: event-driven, with timers only while engaged or on battery ≤ 15%.
- `SpawnConstraint` (macOS 14+): launchd refuses to spawn any binary but this exact build. Defence in depth; upgrades unregister + register anyway, so a cached constraint is refreshed (§10 #9).
- `AssociatedBundleIdentifiers` makes Login Items show it as "Insomnia".

### 2.4 XPC protocol (`Sources/InsomniaShared/HelperProtocol.swift`)

```swift
@objc(INSHelperProtocol)
public protocol HelperProtocol {
    func status(withReply reply: @escaping @Sendable (_ version: String, _ cdhash: String,
                                                      _ sleepDisabled: Bool, _ ownsFlag: Bool) -> Void)
    func engage(withReply reply: @escaping @Sendable (_ result: Int32, _ sleepDisabled: Bool) -> Void)
    func release(withReply reply: @escaping @Sendable (_ result: Int32, _ sleepDisabled: Bool) -> Void)
    func heartbeat(withReply reply: @escaping @Sendable (_ result: Int32) -> Void)
}
public enum HelperResult: Int32 { case ok = 0, foreignFlag, backstop, setFailed, notEngaged, overridden, otherUser }
```

That's the whole surface: **no paths, no arguments, no shell, no "reset a foreign flag"**. One `NSXPCConnection` is one session.

**Client (`HelperBackend`, on `LidReconciler`):** `NSXPCConnection(machServiceName: "com.gdeml.Insomnia.helper", options: .privileged)`, `remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)`, `setCodeSigningRequirement(helperRequirement)` once **before** `resume()`, `remoteObjectProxyWithErrorHandler`. Timeouts: 2 s for `status`, 5 s for `engage`/`release`; a timeout or proxy error is `-1`. One long-lived connection per engagement; `status` uses its own short-lived connection. **`interruptionHandler` or `invalidationHandler` while engaged → `onLost`** (the helper has reset, §2.5); the next engage uses a fresh connection.

**Constants (`HelperInfo`):** heartbeat every **10 s**; the helper drops a silent session after **45 s** (a one-shot deadline per session on uptime, so a real system sleep never counts); backstop **10%**, with a 60 s re-check on battery ≤ **15%**.

### 2.5 The helper (root, `InsomniaHelper` target)

All state lives on one serial queue: `sessions` (live engaged connections, each with its uid and deadline timer), `ownsFlag`, `dropReason` per dropped session, and the start-up `SelfInfo` (`let`).

**Responsibilities:**

| Duty | How |
|---|---|
| **Start-up self-check** | Before `listener.resume()`: `CodeSignature.readSelf()` (kernel cdhash ≠ file, or the file unreadable → run the boot / restart reset only, log, `exit(75)`, §2.2); `InstallLocation.check` on its own bundle (fail → reset-only mode, §2.3); `HelperInfo.isValidRequirement` (fail → reset-only). |
| **Set / clear `SleepDisabled`** | `posix_spawn("/usr/bin/pmset", ["pmset","-a","disablesleep","0"/"1"])`, empty environment, 5 s timeout. Apple-signed, holds the private entitlements, fixed argv, ~50 ms. **No private setter** (`IOPMSetSystemPowerSetting` has no header and `pmset` needs entitlements for the same job). Read back **both** IORegistry `SleepDisabled` and the saved setting from `IOPMCopySystemPowerSettings()` (`dlsym`, read-only; IORegistry alone if the symbol is missing), 3 × 200 ms. Disagreement or a non-zero exit → `.setFailed`. |
| **Ownership file** | `/var/run/com.gdeml.Insomnia.helper.engaged` (root, `0644`): written + `fsync`ed **before** setting 1, deleted **after** a verified 0. Lets a restarted helper know the flag is its own. |
| **Crash watch** | A session's connection invalidates (app crash, Force Quit, `kill -9`, logout) → drop it → reset if `sessions` is empty. Immediate. |
| **Hang watch** | Each session has a one-shot `DispatchSourceTimer` on the serial queue, deadline 45 s, re-armed on every heartbeat (`DispatchTime` is uptime-based, like `CLOCK_UPTIME_RAW`). On expiry: drop the session (`.notEngaged`), invalidate its connection, reset if it was the last. Worst case 45 s + ≤ 0.6 s readback, inside T3's 50 s. No timers without sessions. |
| **Users** | Each session records `connection.effectiveUserIdentifier`. While engaged, `engage` from a different uid → `.otherUser` (fast user switching: one user's session can't keep the flag at 1 after the other releases). Any uid may engage when idle. |
| **Boot reset** | At start, the boot marker `/var/run/com.gdeml.Insomnia.helper.booted` holds `kern.bootsessionuuid`. Missing or a different uuid = a boot: write it, and if `SleepDisabled` is not a verified 0 (1 or unreadable) **reset it whoever set it** (it persists across reboots in `/Library/Preferences/com.apple.PowerManagement.plist`; Amphetamine and MDM re-apply their own). The ownership file is written **before** that reset and deleted only after a verified 0, so a helper restarted in the same boot while the reset still fails (crash, upgrade, Login Items off/on) retries it as a restart reset. |
| **Restart reset** | At start (not a boot), if the ownership file exists, the previous helper instance died holding it and no session survives a restart: unless the flag reads a verified 0, reset; delete the file only after a verified 0. A foreign flag is untouched. |
| **Battery backstop** | `IOPSNotificationCreateRunLoopSource`, a check on every `engage`, and, **only while on battery at ≤ 15%**, a 60 s `DispatchSourceTimer` that re-reads the flag (catches a foreign setter while the percentage holds steady). On battery, ≤ 10%, flag 1 → drop all sessions (`dropReason = .backstop`), reset **whoever set it**, then `IOPMSleepSystem(IOPMFindPowerManagement(MACH_PORT_NULL))` (fallback `/usr/bin/pmset sleepnow`). Works whether the app is alive, hung or gone, and in reset-only mode. |
| **External override** | On each heartbeat it reads the flag; `0` while `ownsFlag` → someone cleared it: drop all sessions (`.overridden`), `ownsFlag = false`, delete the file. Never re-applied. |
| **Stop** | `SIGTERM` (unregister, Login Items switch off, shutdown, `kill`): reset if `ownsFlag`, delete the file, exit 0 (not respawned). `SIGPIPE` ignored. |
| **Status** | `status()`: `HelperInfo.version`, the **cached kernel cdhash**, flag, and `ownsFlag` *for the caller*: the helper set the flag and either no session holds it (its reset is pending a retry: the caller treats it as its own and ends in `.stuck` if the reset keeps failing) or a session of the caller's uid does. Another uid's sessions read as not ours (foreign) for this caller. Logs to `os.Logger(subsystem: "com.gdeml.Insomnia.helper")`. |

**State machine:**

| State | Event | Action → next state |
|---|---|---|
| *start* | kernel cdhash ≠ file | boot / restart reset only, log, `exit(75)` → launchd starts the new binary |
| *start* | boot marker missing or other boot uuid | write it; flag not 0 → write file, reset (file deleted on a verified 0, else retried) → **idle** |
| *start* | same boot, ownership file exists | flag not 0 → reset; delete file after a verified 0 → **idle** |
| *start* | location or requirement check fails | as above, then **reset-only** (listener never resumed; backstop active) |
| **idle** | `engage`, on battery ≤ 10% | reply `.backstop` → **idle** |
| **idle** | `engage`, flag already 1 (not ours) | reply `.foreignFlag` → **idle** |
| **idle** | `engage`, flag 0 | write file, set 1, read back → `.ok`, **engaged**{s} (or reset, delete file, `.setFailed` → **idle**) |
| **engaged** | `engage` from another connection, same uid | add session → **engaged** |
| **engaged** | `engage` from another uid | reply `.otherUser` → **engaged** |
| **engaged** | `release` / invalidation / deadline of the **last** session | set 0, read back, delete file → **idle** (failed reset: keep file, retry every 5 s, log) |
| **engaged** | backstop trips | drop all (`.backstop`), reset, sleep → **idle** |
| **engaged** | heartbeat reads flag 0 | drop all (`.overridden`) → **idle** |
| any | `SIGTERM` | reset if owned → exit 0 |
| any | helper crashes | launchd restarts it (`KeepAlive.SuccessfulExit = false`) → *start* (restart reset) |

`heartbeat` replies `.ok` for a live session (and re-arms its deadline), else the session's `dropReason` (`.notEngaged` if unknown). `release` from a session the helper already dropped replies `.notEngaged`; with a readback of 0 the client treats that as success (§4.3).

### 2.6 Setup, approval, upgrade, removal (`HelperBackend`)

**`status()` → `HelperStatus`** (on `LidReconciler`, never the main thread; `SMAppService.status` is a blocking call to smd and BTM, so read it **once** per check):

| `SMAppService.daemon(plistName:).status` | Also | `HelperStatus` |
|---|---|---|
| `.notRegistered` **or `.notFound`** | plist or `InsomniaHelper` missing from the bundle | `.notFound` ("Reinstall Insomnia") |
| `.notRegistered` or `.notFound` | both present; `InstallLocation.check` fails | `.unsafeLocation` |
| `.notRegistered` or `.notFound` | both present; location safe | `.notInstalled` (Set Up…) |
| `.requiresApproval` (first time, or switched off later) | | `.requiresApproval` |
| `.enabled` | location check fails | `.unsafeLocation` |
| `.enabled` | XPC `status()` answers (2 s), cdhash ≠ `CodeSignature.cdhash(ofFileAt: …/MacOS/InsomniaHelper)` | `.versionMismatch(running:bundled:)` |
| `.enabled` | answers, cdhash matches | `.installed` |
| `.enabled` | no answer; bundled cdhash ≠ `Settings.helperRegisteredCDHash` | `.versionMismatch(running: saved, bundled:)` (macOS may refuse to start a changed executable until it's re-registered) |
| `.enabled` | no answer, or the requirement fails; same cdhash | `.unreachable` |

A never-registered daemon reports `.notFound` on macOS 27 (verified), so `.notRegistered` "may never appear"; the file check is what separates "not set up" from "broken bundle".

Re-check at launch, after setup/removal, on `didBecomeActive`, when Lid & Safety opens, and **every 1 s while the approval step is on screen** (there is no status notification).

**Install (`Set Up…`):** refuse with `LidSetupError.unsafeLocation` unless `InstallLocation.check` passes. Then `register()`. For a daemon this normally ends in `.requiresApproval`; if it throws but the status is then `.requiresApproval`, that's the expected path, not an error. Any other throw → `LidSetupError.registrationFailed(code:detail:)`. On success save `Settings.helperRegisteredCDHash` = the bundled helper's cdhash. The UI then shows the approval step with **Open System Settings** (`SMAppService.openSystemSettingsLoginItems()`) → *General ▸ Login Items & Extensions ▸ Allow in the Background ▸ Insomnia* (macOS asks for Touch ID or an admin password there). macOS also posts "Background Items Added". Once `.enabled` and the XPC answers: `.installed` → setup done; if the lid was requested, engage. Enabled but no answer after 2 s → `.helperUnreachable`.

**Upgrade (`.versionMismatch`):** only while not engaged (launch runs recovery first): `unregister()`, then `register()`, save the new cdhash, then poll up to 5 s for `.installed`. If macOS asks again, the status becomes `.requiresApproval` and the UI shows the approval step. Detection uses the **cdhash**, so any code change is caught without a version bump (a re-sign of identical code keeps the cdhash and needs nothing).

**Repair (`.unreachable`):** the same as upgrade.

**Remove (`uninstall()`):** (1) Release (§4.3); (2) `unregister()`; launchd sends `SIGTERM`, and the helper resets an owned flag anyway; (3) succeed only if the status is now `.notRegistered` or `.notFound`, else `LidSetupError.unregisterIncomplete`; (4) clear `helperRegisteredCDHash`, delete the marker, `Settings.closedLidMode = false`. Leftover sudoers artefacts → offer **Remove old setup…**

**Headless (`Insomnia` argv, no GUI; `ARCHITECTURE.md` App shell):**
- `--helper-status`: prints the `SMAppService` status; exit 0 if registered (`.enabled` / `.requiresApproval`), 1 if not. Used by build.sh.
- `--unregister-helper`: asks a running GUI instance to quit (its Release runs) and waits up to 5 s, then `unregister()` and confirms `.notRegistered` / `.notFound`; exit 0 or 1. The first step of `make uninstall` and §9.
- `launchctl bootout system/com.gdeml.Insomnia.helper` alone is **temporary**: BTM bootstraps the job again at boot while a bundle is at the path. `sfltool resetbtm` resets every app's entries.

### 2.7 Fallback: sudoers backend (ad-hoc / unsigned builds)

Unchanged from the original design, now only for builds made ad hoc on purpose (`INSOMNIA_SIGN_IDENTITY=-`). A **narrow sudoers rule** installed once through an admin prompt; afterwards `sudo -n` runs silently. It also works for any same-user code (§3).

**Rule.** `/etc/sudoers.d/zz_insomnia`, `root:wheel`, `0440`. No dot or `~` in the name (sudo skips those); `zz_` sorts last because **the last matching entry wins**. `#<uid>` is numeric (can't collide with `ALL` or an alias); Swift first validates the name against `^[A-Za-z0-9._][A-Za-z0-9._-]*$`. Never add `*`.

```
# Installed by Insomnia.app. Allows exactly two commands. Remove: Insomnia > Settings > Lid & Safety > Remove, or: sudo rm /etc/sudoers.d/zz_insomnia
#<uid> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

**Safety daemon** (boot reset + 10% backstop, every 60 s, whoever set the flag). `/Library/LaunchDaemons/com.gdeml.insomnia.safety.plist`, `root:wheel`, `0644`; `Label` `com.gdeml.insomnia.safety`, `RunAtLoad`, `StartInterval 60`, `ProgramArguments` = `/bin/sh`, `-c`, this script (it contains `&&`, so the plist builder XML-escapes it; a test round-trips it):

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

**Install** (one prompt). The script runs **inline**: substitute the validated user and the plist, escape as an AppleScript literal (`\` → `\\`, `"` → `\"`, newline → `\n`), run `/usr/bin/osascript -e 'do shell script "<escaped>" with administrator privileges with prompt "Insomnia needs your password once to keep your Mac awake with the lid closed."'` (argv array, never a shell). osascript exits 1 for every failure; match stderr `/\((-?\d+)\)\s*$/`: `-128` → `.cancelled`, `10` → `.invalidUser`, `11` → `.includedirMissing`, other → `.scriptFailed(code:detail:)`.

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
pd=$(/usr/bin/mktemp -d /private/var/root/insomnia.XXXXXX)
p="$pd/$LABEL.plist"
trap '/bin/rm -rf "$t" "$pd"' EXIT
/bin/cat > "$p" <<'PLIST'
<SAFETY_DAEMON_PLIST_XML>
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

Why it's shaped this way: never edit `/etc/sudoers` (abort on a missing `#includedir`); temp files only in root-owned dirs, so same-user code can't swap them: the sudoers temp has a dotted name (sudo skips it), and the plist is staged in root-only `/private/var/root` (same volume, so `mv` stays atomic) rather than in `/Library/LaunchDaemons`, which launchd reads at boot; **daemon before rule**; `touch …booted` before `bootstrap` so its first run can't reset a foreign flag; `visudo` on the file and then the whole config, rolling back on failure; the final probe proves `sudo -n` works for that user and never resets the flag.

**Watchdog** (spawned **before** the flag is set to 1, only on `LidReconciler`):

```
pipe(fds); fcntl(fds[1], F_SETFD, FD_CLOEXEC); fcntl(fds[1], F_SETNOSIGPIPE, 1)
file actions: adddup2(fds[0] → 0); addopen(1 and 2, "/dev/null", O_WRONLY)
attr flags:   POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
argv: /bin/bash -c 'r(){ /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; sleep 6; exec /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; }; trap r TERM HUP INT; while IFS= read -r -t 45 l; do [ "$l" = disarm ] && exit 0; done; r'
parent: close(fds[0]); keep fds[1]; DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)
```

- `/bin/bash` explicitly (`read -t` and the trap need it). Heartbeat `"h\n"` every 10 s; EOF, 45 s of silence or TERM/HUP/INT → reset, then reset **again 6 s later**: a `sudo -n … 1` still in flight when the app died (crash or quit timeout mid-engage; the `sudo` child outlives the app) can land after the first reset but not after the second (6 s > the 5 s spawn timeout). Disarm = reset, read back 0, write `"disarm\n"`, close. `abandon()` = close **without** disarm, so the watchdog retries.
- **Engage order:** arm the new watchdog; **disarm** (never abandon) a previous one, and `SIGKILL` any abandoned watchdog still waiting on its delayed reset (only while it hasn't been reaped, so the pid is still its own); then `sudo -n … 1`. Afterwards, if this watchdog is no longer the armed one or a heartbeat write fails (the quit timeout abandoned it meanwhile), run `sudo -n … 0` and fail the engage (`-1`). Watchdog exits while engaged → `.error(.safetyNetLost)` (or `.stuck`). `posix_spawn` fails → refuse to engage (`.commandFailed(-1)`).
- **fd hygiene:** the pipe and every child process (watchdog, `sudo`, `pmset`, `osascript`) are created only on `LidReconciler`.

**Status:** rule file present; rule **works** (only while the flag is 0: `sudo -n /usr/bin/pmset -a disablesleep 0` exits 0, a real no-op; while 1, keep the last result); daemon file present; daemon enabled (`SMAppService.statusForLegacyPlist(at:) == .enabled`, cross-checked with `launchctl print-disabled system`, §10 #6). All four → `.installed`; both present but daemon off → `.daemonDisabled` (refuse to engage); one missing or rule broken → `.partial` (Repair re-runs install); neither → `.notInstalled`.

**Uninstall** (one prompt; also **Remove old setup…**). `<reset>` is `1` only if our marker exists, so a foreign flag is never touched:

```sh
L=com.gdeml.insomnia.safety
[ '<reset>' = 1 ] && /usr/bin/pmset -a disablesleep 0
/bin/launchctl bootout "system/$L" 2>/dev/null || true
/bin/rm -f "/Library/LaunchDaemons/$L.plist" /etc/sudoers.d/zz_insomnia /etc/sudoers.d/.insomnia.* /Library/LaunchDaemons/.insomnia.* /var/run/com.gdeml.insomnia.booted
[ ! -e /etc/sudoers.d/zz_insomnia ] && [ ! -e "/Library/LaunchDaemons/$L.plist" ] || exit 20
```

---

## 3. Threat model

**Helper backend (primary):**

| Threat | Mitigation | Residual risk |
|---|---|---|
| Other same-user code drives the helper directly | The listener accepts only peers satisfying the client requirement (§2.2): our bundle id, Apple-issued, our Team ID, not debuggable. Hardened runtime blocks injection into the app. | **Trusted = whatever can use the team's signing key; on a dev Mac with an unlocked key that is every same-user process.** Such code can sign its own client and engage without the app's guards (the sudoers-level risk; the root backstop still applies). Narrowed by a locked signing keychain (§2.2, §10 #12). |
| Same-user code replaces the helper (same-user → root) | Registered and run only from root-owned `/Applications/Insomnia.app` (§2.3); the helper refuses to serve from an unsafe location; build-time `SpawnConstraint` pins team + identifier + cdhash; launchd refuses another team's binary. | An admin user's process with the signing key can rename the root-owned bundle aside in the group-writable `/Applications` and drop its own; blocked only if launchd enforces the constraint recorded at registration (§10 #9, T15). |
| Swapped helper binary while it runs | Team ID and cdhash come from the kernel once at start (`csops`), never re-read from disk; a mismatch at start → exit and relaunch. | None known. |
| Same-user code drives the **app** instead (CLI socket) | Socket `0600` in a `0700` dir, `getpeereid`. CLI lid is per hold and **every in-app guard applies**; the URL scheme can never request lid. | Same-user code can turn lid mode on through the CLI, but only within the battery floor, heat, LPM and cap guards. |
| An older signed Insomnia build with a bug | Any non-debuggable build with our id and team passes the requirement. | Accepted for local use. Add `and info[CFBundleVersion] >= "N"` to the requirement if an old build ever needs to be locked out. |
| Another user on the Mac (fast user switching) | Sessions carry their uid; while one uid holds the flag, others get `.otherUser`. | None known. |
| Helper attack surface (root) | Four argument-free methods; no paths, strings or shell from the client; `pmset` with fixed argv and an empty env. Swift, no unsafe parsing. | A bug in the helper itself. Kept tiny for review. |
| Spoofed helper on the Mach name | Only root can register in the system domain; the app checks the helper's signature too. | None known |
| Helper killed or disabled while engaged | `SIGTERM` → reset. Crash or `SIGKILL` → `KeepAlive` restart → restart reset (§2.5). Login Items switch off → launchd stops it (`SIGTERM`); app sees `.requiresApproval`. | Between a `SIGKILL` and the restart (≈ launchd throttle, ≤ 10 s) the flag stays 1. |
| Foreign setter (Amphetamine, admin, MDM) | Never taken over at engage (`.foreignFlag`) or cleared, except by the boot reset and the 10% backstop. | None (by design, Decision 23). |
| A web page opens an `insomnia://` link | **URL holds never get lid** (`lid` param ignored and logged). `insomnia://sleep` asks before sleeping. | A page can keep the Mac awake with the lid open. Low impact. |
| App deleted without Remove | `make uninstall` / `--unregister-helper` first (§2.6, §9). | The BTM record stays and points at `/Applications/Insomnia.app`; the next bundle placed there with our team and identifier runs at boot without a new approval. A flag left at 1 at that moment gets no boot reset: `sudo pmset -a disablesleep 0` (§9). |
| Ad-hoc rebuild strands a registered helper | build.sh refuses; the sudoers backend shows `.leftoverHelper` and never installs over it (§2.1). | None known. |

**Sudoers fallback** keeps its original risks: **any same-user code can run the two `pmset` commands** and silently bypass lid-close and low-battery sleep with none of our in-app guards (the root backstop still enforces 10%). Stated in the unsigned-build setup sheet. Mitigations: two fixed commands, SIP-protected `pmset`, `zz_` ordering, inline install with root-owned temp files, `visudo` checks with rollback, `.daemonDisabled` refusal. Its uninstall resets the flag only when our user-writable marker exists, so same-user code could plant the marker and have uninstall clear a foreign flag (trivial impact; accepted).

Rejected: resetting the flag whenever no Insomnia process runs. It would fight foreign setters (Decision 23) for friction, not security; the helper resets only **its own** flag when its sessions end.

---

## 4. Layered failure safety

Invariant: **if no live, responsive Insomnia process wants lid mode, `SleepDisabled` is 0**; if it can't be made 0, the UI is `.stuck`.

| Layer | Covers | Helper backend | Sudoers backend |
|---|---|---|---|
| **1. Normal path** | Stop, timer, guards, Sleep Now, Quit, logout, restart, shutdown | XPC `release` | `sudo -n pmset … 0` |
| **2. Crash / hang** | Crash, Force Quit, `kill -9`, **app hang > 45 s** | Connection invalidation (instant) + 45 s heartbeat deadline, enforced by root | Watchdog: pipe EOF, 45 s `read` timeout, signal trap |
| **3. Boot + backstop** | Reboot, power loss, panic; flag 1 on battery ≤ 10% for any reason | Helper `RunAtLoad` boot reset; IOPS-driven backstop | Safety daemon (60 s) |
| **4. Launch recovery** | Any gap | Marker (§4.2) | Marker |

Layer 1 detail: Quit, logout and shutdown all arrive as a quit Apple Event: `applicationShouldTerminate` returns `.terminateLater` when the marker exists or lid ≠ `.off`, awaits `releaseForQuit(timeout: 2)`, then replies `true`.

### 4.1 Heartbeat (both backends)

- While engaged, a **main-actor** timer asks the reconciler to call `backend.heartbeat()` every **10 s**, so a hung main actor or reconciler stops it and the safety net resets within **45 s**. Schedule it with `RunLoop.main.add(t, forMode: .common)`, tolerance 1 s, so menu tracking, sheets and open panels don't starve it (a menu held open for 45 s must not read as a hang).
- It returns `LidError?`: `nil` = still engaged. Helper reply `.overridden` → `.overridden`; any other non-`.ok` reply, or `EPIPE` on the watchdog pipe → `.safetyNetLost`. Non-nil → run Release, then `.error(e)`. (A backstop drop also reads as `.safetyNetLost`, but the engine's battery-floor guard, at ≥ 10%, has normally tripped first and wins in the `lid` derivation.)
- **App Nap:** while engaged, hold `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Insomnia lid mode safety guards")`; end it on release.

### 4.2 Marker file

- `~/Library/Application Support/Insomnia/lid-engaged`: our PID and an ISO date. Written (with `fsync`) **before** engaging; deleted after a verified release. At launch, its presence means the last run ended uncleanly → recovery banner.
- **Foreign flag:** `SleepDisabled == true` and not ours (helper: `status().ownsFlag == false`; sudoers: no marker) means something else set it. The app **never touches it**; Diagnostics says "set by something else", and `foreign-flag` posts once per boot.

### 4.3 Sequences (all on `actor LidReconciler`, one at a time)

The engine publishes a *desired* boolean; the reconciler converges on the latest value and coalesces changes that arrive mid-call.

**Engage:** (1) `helper == .installed`, else `.needsSetup`. (2) Flag already 1 and not ours → `.error(.foreignFlag)`, stop (sudoers: checked here against the marker; helper: the helper refuses with `.foreignFlag`, or `.otherUser` → `.error(.otherUser)`, and changes nothing). (3) Write the marker. (4) `backend.engage(onLost:)`: the helper session (or armed watchdog + `sudo -n … 1`), 5 s timeout. (5) Read back, up to 3 × 200 ms. (6) `true` → `.engaged(lidClosed:)`, start the heartbeat. Otherwise Release, then `.error(.readbackMismatch)` / `.commandFailed(code)`.

**Release:** (1) `backend.release()`; a helper reply `.notEngaged` (it already dropped the session) counts as success if (2) reads 0. (2) Read back `false`. (3) Delete the marker. (4) Lid closed and no external display → `pmset sleepnow`. (5) `.off`. If (1) or (2) fails: `backend.abandon()` (helper: invalidate the connection; sudoers: close without disarm), wait 2 s, read again: `false` → `.error(.commandFailed(status))`; still `true` → **`.stuck`**. A release that follows a lost safety net (helper crash, watchdog exit, heartbeat failure) polls for up to 15 s instead (a crashed helper's launchd respawn and restart reset, T2), and any outcome other than `.stuck` reports the loss itself (`.error(.safetyNetLost)` / `.error(.overridden)`).

**`.stuck`:** red and persistent; `lid-stuck` notification; the panel offers **Reset with password…** (`osascript … do shell script "/usr/bin/pmset -a disablesleep 0" with administrator privileges`, either backend). Guards keep evaluating and notifying, and the root backstop still applies.

**Drift:** while engaged, re-read every 60 s, on `didWakeNotification` and on power-source changes. An unexpected `false` with the safety net alive is an **intentional external override**: release the session, delete the marker, `.error(.overridden)`. Never re-applied without a user action.

**Quit:** `releaseForQuit(timeout:)` cancels any pending desired state and runs Release. On timeout or failure it calls `abandon()` so the safety net finishes the job.

**Launch recovery:** marker present → if the flag reads 1 and is ours, reset via the backend; delete the marker; `recovered` banner + notification. (With the helper, layer 2 has normally reset it already.)

---

## 5. Engagement condition

```
closedNoExt   = isLidClosed && externalDisplayCount == 0
bag           = closedNoExt && !isOnAC
wantLid       = any live, non-suspended hold has options.lid
lidGuards     = tripped of [batteryFloor, thermal, lowPowerMode, acRequired, lidBatteryCap, lidACCap]
desired       = wantLid && hasLid && helper == .installed && lidGuards.isEmpty && !latched
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

**Lid-closed counters** (engine-scoped, for any hold type, accumulate only while engaged; reset **only when the lid opens**, never on a new hold or a power change):

- `lidBagSeconds`: while `bag` (closed, no ext. display, on battery). Feeds `lidBatteryCap`.
- `lidClosedACSeconds`: while `closedNoExt && isOnAC`. Feeds `lidACCap`.

Closing on battery for 40 min and then plugging in keeps the 40 min on the battery counter, and the AC counter starts from 0.

---

## 6. Safety guards

| Guard (`GuardReason`) | Trips when | Clears when | Affects | Configurable |
|---|---|---|---|---|
| `batteryFloor` | `hasBattery && !isOnAC && percent <= floor` | `isOnAC \|\| percent >= floor + 3` | Lid only | Floor 10–50%, default 20. **Mandatory.** |
| `awakeBatteryFloor` | Same, and `awakeBatteryFloorEnabled` | Same | **Everything**: ends manual holds (`DeactivationReason.batteryFloor`), suspends the rest | Opt-in, default off |
| `thermal` | `>= .serious`; **or** `>= .fair` for 5 min in the bag condition | Trip condition false for 60 s | Lid only | Always on |
| `lowPowerMode` | `isLowPowerModeEnabled` | It turns off | Lid only | Always on |
| `acRequired` | `lidRequiresAC && hasBattery && !isOnAC` | `isOnAC` | Lid only | Default off |
| `lidBatteryCap` | `lidBagSeconds >= lidMaxOnBatteryMinutes × 60` | The lid opens | Lid only | **Always on.** 15 min – 8 h (15m, 30m, 1h, 2h, 4h, 8h), **default 1 h**, no "unlimited" |
| `lidACCap` | `lidCapOnACEnabled && lidClosedACSeconds >= lidMaxOnACMinutes × 60` | The lid opens | Lid only | **Off by default** (no cap on AC). 1–24 h (1h, 2h, 4h, 8h, 12h, 24h), default 4 h when enabled |
| *(root backstop)* | Flag 1, on battery, ≤ 10% | n/a | Resets + sleeps, any setter | No |

Guard notifications fire once per engagement per guard, always on and silent (`UX.md` §10). Sensors: `IOPSCopyPowerSourcesInfo` + `IOPSNotificationCreateRunLoopSource`; `thermalStateDidChangeNotification`; `.NSProcessInfoPowerStateDidChange`; lid per §1.

---

## 7. State machine (`LidStatus`)

| From | Event | To |
|---|---|---|
| any | `wantLid` and `helper != .installed` | `.needsSetup` |
| `.off` / `.suspended` (not latched) | `desired` becomes true | `.engaging` |
| `.engaging` | readback ✓ | `.engaged(lidClosed:)` |
| `.engaging` | flag already 1, not ours | `.error(.foreignFlag)` |
| `.engaging` | failure, flag verified 0 | `.error(e)` |
| `.engaged` | clamshell change | `.engaged(lidClosed: !old)` |
| `.engaged` | lid guard trips | release → `.suspended(g)`; latched if the lid is closed |
| `.suspended(g)` | guard clears, latched | `.latched` |
| `.latched` | lid opens or user action | `.engaging` (if desired) |
| `.engaged` | safety net lost / drift sees 0 | `.error(.safetyNetLost)` / `.error(.overridden)` |
| `.error` | Retry or user action | `.engaging` |
| any | `wantLid` false | release → `.off` |
| any release | reset fails and flag reads 1 | `.stuck` |
| `.stuck` | Reset with password ✓, or flag reads 0 | `.off` (the 10 s stuck check then converges again, so a lid request that is still wanted re-engages) |

- `.suspended`, `.latched`, `.error` (except `.foreignFlag` / `.otherUser`): the flag is **verified 0**, normal assertions keep running, and the Mac sleeps normally on lid close. `.error(.foreignFlag)` / `.error(.otherUser)`: the flag is 1 but not ours; say so, don't promise sleep.
- `.stuck`: the flag is 1 and we can't clear it. Never say "sleeps normally" here.
- `.engaged(lidClosed: true)` runs the reopen-report counters (closed seconds, battery at close, worst thermal state).

---

## 8. Verify by hand, and M2 release blockers

```sh
codesign -dv /Applications/Insomnia.app 2>&1 | grep -E 'TeamIdentifier|flags'           # 38Z68N4XM3, runtime
codesign -d -r- /Applications/Insomnia.app/Contents/MacOS/InsomniaHelper                 # identifier com.gdeml.Insomnia.helper
codesign -d --entitlements - /Applications/Insomnia.app                                  # no get-task-allow
stat -f '%Su:%Sg %Sp' /Applications/Insomnia.app /Applications/Insomnia.app/Contents/MacOS/*  # root:wheel, no group/other w
/Applications/Insomnia.app/Contents/MacOS/Insomnia --helper-status                        # enabled
sudo launchctl print system/com.gdeml.Insomnia.helper | grep -E 'state|pid'
sfltool dumpbtm | grep -B2 -A8 com.gdeml.Insomnia                                         # Login Items approval
ioreg -r -c IOPMrootDomain -d 1 | grep -E '"(SleepDisabled|AppleClamshellState)"'
log stream --predicate 'subsystem BEGINSWITH "com.gdeml.Insomnia"'
pmset -g assertions
```

Helper backend (engaged unless noted):

| # | Test | Pass |
|---|---|---|
| T1 | `kill -9 $(pgrep -x Insomnia)` | `SleepDisabled = No` within 1 s |
| T2 | `sudo kill -TERM $(pgrep -x InsomniaHelper)`; then `sudo kill -9` it while engaged | `No` within 1 s; after `-9`, `No` within 15 s (restart reset); UI `.error(.safetyNetLost)` both times |
| T3 | `kill -STOP $(pgrep -x Insomnia)` (simulated hang); separately hold a menu open for 60 s | `No` within 50 s; the held menu causes no `.safetyNetLost` |
| T4 | Reboot (and power-cut) while engaged | `No` at the login window |
| T5 | Switch Insomnia off in Login Items while engaged | `No` within 2 s; UI `.needsSetup` ("Allow in System Settings") |
| T6 | A test client signed (a) ad hoc, (b) with our team but another identifier, (c) with our team and identifier **plus `get-task-allow`**, calls `engage` | Connection rejected before any method runs; flag unchanged; helper logs the rejection |
| T7 | Dev build with battery cap = 1 min; lid closed on battery; let it sleep; trigger a wake (Bluetooth, Power Nap) | Stays `.latched`, flag `No`; re-engages only on lid open |
| T8 | Dev build with backstop at 95% (battery below it); on AC, `sudo pmset -a disablesleep 1`; unplug | Mac sleeps within 5 s |
| T9 | Clamshell with ext. display; unplug it with the lid shut | Internal panel dark (phone camera at the hinge) |
| T10 | Logout while engaged | `No` at the login window |
| T11 | Set up with build A; `make install` build B (helper code changed) while A's helper runs; launch | Old helper reports A's cdhash (not B's file); silent re-register; then `status().cdhash` = B's; `.installed` or the approval step. Same with A's helper refusing to start: `.versionMismatch`, not "Repair" |
| T12 | Remove… while engaged; separately `make uninstall` | `No`; status `.notRegistered`/`.notFound`; `sudo launchctl print system/com.gdeml.Insomnia.helper` fails, also after a reboot; Login Items entry gone |
| T13 | Fresh user: Set Up… → approve in System Settings | Panel reaches `.engaged` within 2 s of approval, without relaunch |
| T14 | AC cap enabled at 1 h (dev: 1 min); lid closed on AC | `.suspended(.lidACCap)`, latched, flag `No`; AC cap off → never trips on AC |
| T15 | In a VM snapshot (constraints may be cached): (a) replace the installed helper with a different team-signed binary, reboot; (b) edit the bundled plist in place, reboot; (c) `chown -R $USER` the bundle, reboot | (a) launchd refuses it; (b) ignored or refused; (c) helper runs reset-only (boot reset still happens), UI `.unsafeLocation` |
| T16 | Running from `build/Insomnia.app` (signed) | Set Up… disabled, "Install with make install"; `register()` never called |
| T17 | Fast user switching: user A engaged; user B engages | B gets `.error(.otherUser)`; A releases → `No` |
| T18 | Only with a dedicated signing keychain (§2.2): from an unrelated process, `codesign -s "Apple Development: …" ./x` | A keychain prompt appears; no silent signature |
| T19 | Ad-hoc build: `INSOMNIA_SIGN_IDENTITY=` unset with no usable identity; and `=-` while a helper is registered | build.sh exits non-zero both times |

Sudoers fallback (`INSOMNIA_SIGN_IDENTITY=-` build): T1, T3, T4, T7, T10 as above, a registered signed helper → `.leftoverHelper` and no sudoers install offered, plus `kill -TERM <watchdog pid>` → `No` within 1 s and `.error(.safetyNetLost)`; Login Items daemon off → `.daemonDisabled`, engage refused; `sudo rm /etc/sudoers.d/zz_insomnia`, then Stop → `.stuck`, Reset with password clears it.

## 9. Uninstall by hand

```sh
/Applications/Insomnia.app/Contents/MacOS/Insomnia --unregister-helper   # FIRST: quits the app (releases the flag), unregisters, confirms
sudo pmset -a disablesleep 0
sudo rm -rf /Applications/Insomnia.app                                     # make uninstall does both steps
# bootout alone is temporary (BTM re-bootstraps at boot while a bundle is at the path).
# If the app is already gone: switch Insomnia off in Login Items (sfltool resetbtm resets ALL apps' entries)
# sudoers fallback leftovers, if any:
sudo launchctl bootout system/com.gdeml.insomnia.safety 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist /etc/sudoers.d/zz_insomnia
rm -f ~/Library/Application\ Support/Insomnia/lid-engaged
```

## 10. Open questions (manual QA before M2 ships)

| # | Question | Until answered |
|---|---|---|
| 1 | Does `SleepDisabled = 1` block thermal-emergency sleep? | Assume **yes** (hence the bag-condition thermal rule). |
| 2 | After `pmset -a disablesleep 1` from the helper, do IORegistry `SleepDisabled`, `IOPMCopySystemPowerSettings()` and the persisted pref all agree, within 600 ms? | Readback of both decides; disagreement → `.setFailed`. (The private setter was dropped: no header, and `pmset` needs entitlements for it.) |
| 3 | Does the internal panel stay lit with the lid closed? | `displaysleepnow` runs anyway (harmless). |
| 4 | Does macOS itself clear the flag on an AC plug/unplug while closed? | If yes, re-apply once **on that event only**; drift still treats other zeros as overrides. |
| 5 | Does releasing with the lid closed sleep the Mac? | We call `pmset sleepnow`; confirm. |
| 6 | Does `SMAppService.daemon` `register()` and launch a daemon in an **Apple Development**-signed (not notarized) app in root-owned `/Applications`? The header says "Apps that contain LaunchDaemons must be notarized." | **First M2 task, before any helper code:** one real `register()` of the spike (with the user's OK: it shows the approval prompt and writes a BTM record), then `unregister()`. Record the result here. Refused → Developer ID + notarization (paid membership), or sudoers becomes primary. |
| 7 | After `unregister()` + `register()` (upgrade), does macOS keep the approval? Does switching it off in Login Items report `.requiresApproval`? | UI handles both outcomes via `HelperStatus`. |
| 8 | Sudoers only: which of `statusForLegacyPlist(at:)` / `launchctl print-disabled` tracks the Login Items toggle? Is `/etc/sudoers.d` included on stock 27? | Check both; either disabled → `.daemonDisabled`. Exit 11 with an explanation. |
| 9 | Does launchd enforce `SpawnConstraint` from the plist recorded at `register()` or from the bundle at each spawn (forum 799933: cached)? Is `cdhash` the 20-byte value? | Defence in depth only; T15 decides. A malformed constraint must fail T4 loudly, not silently. |
| 10 | Does BTM auto-enable a **new** daemon from an already-approved team without asking? Does it refuse another team's binary at the registered path? | T15 (a); assume the worst for the threat model. |
| 11 | After a helper code change, does the old registration still launch, or must it be re-registered first? | Handled either way (`.versionMismatch` via the saved cdhash); T11 confirms. |
| 12 | **User decision:** keep the signing identity in the login keychain (silent signing; any same-user code is trusted, §3) or in a dedicated keychain locked by default (a password prompt per build)? | build.sh supports both; login keychain until decided. |
