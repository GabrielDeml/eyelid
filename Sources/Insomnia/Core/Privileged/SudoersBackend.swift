import Foundation
import InsomniaShared
import os
import ServiceManagement

/// Fallback for builds made ad hoc on purpose (`INSOMNIA_SIGN_IDENTITY=-`, no Team ID): a two-command sudoers rule,
/// a bash watchdog and a root safety daemon, installed with one admin prompt. docs/CLOSED_LID.md §2.7.
struct SudoersBackend: PrivilegedBackend {
    let kind = PrivilegeBackendKind.sudoers
    let userName: String
    private let marker: LidMarker
    private let shared: Shared

    static let sudoersFile = "/etc/sudoers.d/zz_insomnia"
    static let daemonLabel = "com.gdeml.insomnia.safety"
    static let daemonPlist = "/Library/LaunchDaemons/com.gdeml.insomnia.safety.plist"
    static let bootMarker = "/var/run/com.gdeml.insomnia.booted"
    static let installPrompt = "Insomnia needs your password once to keep your Mac awake with the lid closed."
    static let uninstallPrompt = "Insomnia needs your password to remove its lid-mode setup."

    /// Mutable bits shared by copies of this struct: the armed watchdog and the last "rule works" probe result.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var watchdog: Watchdog?
        /// Abandoned watchdogs (release failure, Reset with password…) that may still run their delayed reset.
        var abandoned: [Watchdog] = []
        var ruleWorks: Bool?
    }

    init(userName: String = NSUserName(), marker: LidMarker = .standard) {
        self.userName = userName
        self.marker = marker
        self.shared = Shared()
    }

    /// `^[A-Za-z0-9._][A-Za-z0-9._-]*$` (sudoers- and shell-safe; the script also requires a numeric uid).
    static func isValidUserName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= 255 else { return false }
        func allowed(_ c: Unicode.Scalar, dash: Bool) -> Bool {
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "." || c == "_"
                || (dash && c == "-")
        }
        return allowed(first, dash: false) && name.unicodeScalars.dropFirst().allSatisfy { allowed($0, dash: true) }
    }

    // MARK: Status (§2.7)

    func status() async -> HelperStatus {
        // A signed build's helper still registered: never install sudoers over it (Decision 38).
        let helper = SMAppService.daemon(plistName: HelperInfo.plistName).status
        if helper == .enabled || helper == .requiresApproval { return .leftoverHelper }

        let fm = FileManager.default
        let rulePresent = fm.fileExists(atPath: Self.sudoersFile)
        let daemonPresent = fm.fileExists(atPath: Self.daemonPlist)
        var ruleWorks = false
        if rulePresent {
            if RootDomain.sleepDisabled() == false {
                // A real no-op: the flag is already 0. Only probed while 0, so it can never clear a foreign flag.
                ruleWorks = Self.sudo(["/usr/bin/pmset", "-a", "disablesleep", "0"]).status == 0
                shared.lock.withLock { shared.ruleWorks = ruleWorks }
            } else {
                ruleWorks = shared.lock.withLock { shared.ruleWorks } ?? true
            }
        }
        let daemonEnabled = daemonPresent && Self.daemonEnabled()
        return Self.mapStatus(rulePresent: rulePresent, ruleWorks: ruleWorks, daemonPresent: daemonPresent,
                              daemonEnabled: daemonEnabled)
    }

    /// Pure (unit-tested).
    static func mapStatus(rulePresent: Bool, ruleWorks: Bool, daemonPresent: Bool, daemonEnabled: Bool) -> HelperStatus {
        if !rulePresent && !daemonPresent { return .notInstalled }
        if rulePresent && daemonPresent {
            if !ruleWorks { return .partial(sudoers: false, safetyDaemon: true) }
            return daemonEnabled ? .installed : .daemonDisabled
        }
        return .partial(sudoers: rulePresent && ruleWorks, safetyDaemon: daemonPresent)
    }

    /// `SMAppService.statusForLegacyPlist(at:)` cross-checked with `launchctl print-disabled system` (§10 #8): either
    /// saying disabled wins.
    private static func daemonEnabled() -> Bool {
        let sm = SMAppService.statusForLegacyPlist(at: URL(fileURLWithPath: daemonPlist))
        if sm == .requiresApproval || sm == .notRegistered { return false }
        let out = Spawn.runCapturingStdout("/bin/launchctl", ["print-disabled", "system"], timeout: 5)
        return !isDisabled(label: daemonLabel, printDisabledOutput: out)
    }

    /// Lines look like `"com.example" => disabled` (macOS 14+) or `=> true` (older).
    static func isDisabled(label: String, printDisabledOutput: String) -> Bool {
        for line in printDisabledOutput.split(separator: "\n") where line.contains("\"\(label)\"") {
            let value = line.split(separator: ">").last?.trimmingCharacters(in: .whitespaces) ?? ""
            return value == "disabled" || value == "true"
        }
        return false
    }

    /// Signed builds: leftovers from an earlier unsigned build (Lid & Safety "Remove old setup…").
    static var legacyArtefactsPresent: Bool {
        FileManager.default.fileExists(atPath: sudoersFile) || FileManager.default.fileExists(atPath: daemonPlist)
    }

    // MARK: Install / uninstall

    func install() async throws(LidSetupError) -> HelperStatus {
        guard Self.isValidUserName(userName) else { throw .invalidUser }
        if await status() == .leftoverHelper { throw .registrationFailed(code: -1, detail: "A helper from a signed build is still registered. Remove it first.") }
        let r = AdminScript.run(Self.installScript(user: userName), prompt: Self.installPrompt)
        switch r.code {
        case 0: break
        case -128: throw .cancelled
        case 10: throw .invalidUser
        case 11: throw .includedirMissing
        default: throw .scriptFailed(code: r.code, detail: r.detail)
        }
        shared.lock.withLock { shared.ruleWorks = nil }
        return await status()
    }

    func uninstall(resetFlag: Bool) async throws(LidSetupError) {
        let helper = SMAppService.daemon(plistName: HelperInfo.plistName)
        if helper.status == .enabled || helper.status == .requiresApproval {
            // .leftoverHelper: remove the signed build's registration instead.
            do { try await helper.unregister() } catch {}
            guard helper.status == .notRegistered || helper.status == .notFound else { throw .unregisterIncomplete }
            return
        }
        try Self.runUninstall(reset: resetFlag)
    }

    /// Also used by signed builds to remove old sudoers artefacts. `reset` only when our marker exists.
    static func runUninstall(reset: Bool) throws(LidSetupError) {
        let r = AdminScript.run(uninstallScript(reset: reset), prompt: uninstallPrompt)
        switch r.code {
        case 0: return
        case -128: throw .cancelled
        default: throw .scriptFailed(code: r.code, detail: r.detail)
        }
    }

    // MARK: Session

    func engage(onLost: @escaping @Sendable () -> Void) async -> Int32 {
        // Watchdog first: if we die between here and the readback, it resets.
        let dog: Watchdog
        do {
            dog = try Watchdog.arm(onExit: onLost)
        } catch {
            return -1
        }
        let (old, abandoned) = shared.lock.withLock { () -> (Watchdog?, [Watchdog]) in
            let o = shared.watchdog
            let a = shared.abandoned
            shared.watchdog = dog
            shared.abandoned = []
            return (o, a)
        }
        // The new watchdog already covers the flag. Disarm the old one, and stop any abandoned one still waiting to
        // reset: either would clear the flag right after (or 6 s after) the set below.
        old?.disarm()
        for a in abandoned { a.stopSuperseded() }
        let status = Self.sudo(["/usr/bin/pmset", "-a", "disablesleep", "1"]).status
        // The quit timeout (or anything else) may have abandoned this watchdog while `sudo` ran, and its reset may
        // have landed before our set. Never leave a 1 behind without a live watchdog.
        let stillArmed = shared.lock.withLock { shared.watchdog === dog } && dog.isArmed
        guard stillArmed else {
            _ = Self.sudo(["/usr/bin/pmset", "-a", "disablesleep", "0"])
            return -1
        }
        return status
    }

    func release() async -> Int32 {
        let status = Self.sudo(["/usr/bin/pmset", "-a", "disablesleep", "0"]).status
        guard status == 0 else { return status }   // the watchdog stays armed
        // Disarm only after the flag reads back 0 (3 × 200 ms).
        for attempt in 0...3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            if RootDomain.sleepDisabled() == false {
                let dog = shared.lock.withLock { () -> Watchdog? in
                    let d = shared.watchdog
                    shared.watchdog = nil
                    return d
                }
                dog?.disarm()
                return 0
            }
        }
        return HelperResult.setFailed.rawValue
    }

    func abandon() async {
        let dog = shared.lock.withLock { () -> Watchdog? in
            let d = shared.watchdog
            shared.watchdog = nil
            if let d { shared.abandoned.append(d) }
            return d
        }
        dog?.abandon()
    }

    func heartbeat() async -> LidError? {
        guard let dog = shared.lock.withLock({ shared.watchdog }) else { return .safetyNetLost }
        return dog.heartbeat() ? nil : .safetyNetLost
    }

    func ownsFlag() async -> Bool { marker.exists }

    func resetWithPassword() async throws(LidSetupError) {
        try AdminScript.resetFlag()
    }

    /// `sudo -n <args>`: never prompts.
    private static func sudo(_ args: [String]) -> Spawn.Result {
        Spawn.run("/usr/bin/sudo", ["-n"] + args, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 5)
    }

    // MARK: Scripts (CLOSED_LID.md §2.7, verbatim apart from substitutions)

    /// Safety daemon: boot reset + 10% backstop every 60 s, whoever set the flag. No `<` or `&`.
    static let safetyScript = """
        B=\(bootMarker)
        /usr/sbin/ioreg -r -c IOPMrootDomain -d 1 | /usr/bin/grep -q '"SleepDisabled" = Yes' || { /usr/bin/touch $B; exit 0; }
        if [ ! -e $B ]; then /usr/bin/touch $B; /usr/bin/pmset -a disablesleep 0; exit 0; fi
        b=$(/usr/sbin/ioreg -r -c AppleSmartBattery -d 1)
        case $b in *'"ExternalConnected" = No'*) ;; *) exit 0 ;; esac
        c=$(echo "$b" | /usr/bin/sed -n 's/^ *"CurrentCapacity" = \\([0-9]*\\)$/\\1/p')
        m=$(echo "$b" | /usr/bin/sed -n 's/^ *"MaxCapacity" = \\([0-9]*\\)$/\\1/p')
        if [ -n "$c" ] && [ -n "$m" ] && [ $((c * 100)) -le $((m * \(HelperInfo.backstopPercent))) ]; then /usr/bin/pmset -a disablesleep 0; /usr/bin/pmset sleepnow; fi
        """

    static var safetyDaemonPlist: String {
        func xml(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>\(daemonLabel)</string>
              <key>RunAtLoad</key><true/>
              <key>StartInterval</key><integer>60</integer>
              <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>\(xml(safetyScript))</string></array>
            </dict></plist>
            """
    }

    static let ruleComment = "# Installed by Insomnia.app. Allows exactly two commands. Remove: Insomnia > Settings > Lid & Safety > Remove, or: sudo rm /etc/sudoers.d/zz_insomnia"

    /// `user` must already satisfy isValidUserName (it is embedded in single quotes).
    static func installScript(user: String) -> String {
        """
        set -eu
        umask 077
        U='\(user)'
        SD=/etc/sudoers.d
        LD=/Library/LaunchDaemons
        LABEL=\(daemonLabel)
        UID_N=$(/usr/bin/id -u "$U") || exit 10
        case $UID_N in ''|*[!0-9]*) exit 10;; esac
        [ -d "$SD" ] && [ ! -L "$SD" ] || exit 16
        /usr/bin/grep -Eq '^[#@]includedir[[:space:]]+(/private)?/etc/sudoers\\.d[[:space:]]*$' /etc/sudoers || exit 11
        /bin/rm -f "$SD"/.insomnia.* "$LD"/.insomnia.*
        t=$(/usr/bin/mktemp "$SD/.insomnia.XXXXXX")
        pd=$(/usr/bin/mktemp -d /private/var/root/insomnia.XXXXXX)
        p="$pd/$LABEL.plist"
        trap '/bin/rm -rf "$t" "$pd"' EXIT
        /bin/cat > "$p" <<'PLIST'
        \(safetyDaemonPlist)
        PLIST
        /usr/sbin/chown root:wheel "$p"; /bin/chmod 0644 "$p"
        /usr/bin/plutil -lint -s "$p" || exit 13
        /usr/bin/touch \(bootMarker)
        /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
        /bin/mv -f "$p" "$LD/$LABEL.plist"
        /bin/launchctl bootstrap system "$LD/$LABEL.plist" || exit 17
        /usr/bin/printf '%s\\n' '\(ruleComment)' "#$UID_N ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" > "$t"
        /usr/sbin/chown root:wheel "$t"; /bin/chmod 0440 "$t"
        /usr/sbin/visudo -cqf "$t" || exit 12
        /bin/mv -f "$t" "$SD/zz_insomnia"
        /usr/sbin/visudo -cq || { /bin/rm -f "$SD/zz_insomnia"; exit 14; }
        trap - EXIT
        if /usr/sbin/ioreg -r -c IOPMrootDomain -d 1 | /usr/bin/grep -q '"SleepDisabled" = No'; then
          /usr/bin/sudo -u "#$UID_N" /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 || exit 15
        fi
        exit 0
        """
    }

    /// `reset` is true only when our marker exists, so a foreign flag is never touched.
    static func uninstallScript(reset: Bool) -> String {
        """
        L=\(daemonLabel)
        [ '\(reset ? 1 : 0)' = 1 ] && /usr/bin/pmset -a disablesleep 0
        /bin/launchctl bootout "system/$L" 2>/dev/null || true
        /bin/rm -f "/Library/LaunchDaemons/$L.plist" \(sudoersFile) /etc/sudoers.d/.insomnia.* /Library/LaunchDaemons/.insomnia.* \(bootMarker)
        [ ! -e \(sudoersFile) ] && [ ! -e "/Library/LaunchDaemons/$L.plist" ] || exit 20
        """
    }
}

extension Spawn {
    /// stdout of a short read-only command (launchctl print-disabled). Empty on failure.
    static func runCapturingStdout(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let deadline = DispatchTime.now() + timeout
        let reader = DispatchQueue.global(qos: .utility)
        let box = OSAllocatedUnfairLock(initialState: Data())
        let group = DispatchGroup()
        group.enter()
        reader.async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            box.withLock { $0 = data }
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return ""
        }
        process.waitUntilExit()
        return String(decoding: box.withLock { $0 }, as: UTF8.self)
    }
}
