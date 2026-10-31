import Foundation
import InsomniaShared
import Testing
@testable import Insomnia

// Sudoers fallback strings and parsing (docs/CLOSED_LID.md §2.7), plus the Spawn utility. Nothing here installs,
// prompts or runs pmset: scripts are only syntax-checked with `sh -n` / `bash -n` and `plutil -lint`.

@Suite("Sudoers backend")
struct SudoersBackendTests {
    @Test func userNameValidation() {
        #expect(SudoersBackend.isValidUserName("gdeml"))
        #expect(SudoersBackend.isValidUserName("first.last"))
        #expect(SudoersBackend.isValidUserName("_svc-user"))
        #expect(!SudoersBackend.isValidUserName(""))
        #expect(!SudoersBackend.isValidUserName("-rf"))
        #expect(!SudoersBackend.isValidUserName("a b"))
        #expect(!SudoersBackend.isValidUserName("x'y"))
        #expect(!SudoersBackend.isValidUserName("ALL,root"))
        #expect(!SudoersBackend.isValidUserName("é"))
    }

    @Test func statusMapping() {
        #expect(SudoersBackend.mapStatus(rulePresent: false, ruleWorks: false, daemonPresent: false, daemonEnabled: false) == .notInstalled)
        #expect(SudoersBackend.mapStatus(rulePresent: true, ruleWorks: true, daemonPresent: true, daemonEnabled: true) == .installed)
        #expect(SudoersBackend.mapStatus(rulePresent: true, ruleWorks: true, daemonPresent: true, daemonEnabled: false) == .daemonDisabled)
        #expect(SudoersBackend.mapStatus(rulePresent: true, ruleWorks: false, daemonPresent: true, daemonEnabled: true)
                == .partial(sudoers: false, safetyDaemon: true))
        #expect(SudoersBackend.mapStatus(rulePresent: true, ruleWorks: true, daemonPresent: false, daemonEnabled: false)
                == .partial(sudoers: true, safetyDaemon: false))
        #expect(SudoersBackend.mapStatus(rulePresent: false, ruleWorks: false, daemonPresent: true, daemonEnabled: true)
                == .partial(sudoers: false, safetyDaemon: true))
    }

    @Test func printDisabledParsing() {
        let out = """
            disabled services = {
            \t"com.apple.ftpd" => disabled
            \t"com.gdeml.insomnia.safety" => enabled
            }
            """
        #expect(!SudoersBackend.isDisabled(label: "com.gdeml.insomnia.safety", printDisabledOutput: out))
        #expect(SudoersBackend.isDisabled(label: "com.gdeml.insomnia.safety",
                                          printDisabledOutput: "\"com.gdeml.insomnia.safety\" => disabled"))
        #expect(SudoersBackend.isDisabled(label: "com.gdeml.insomnia.safety",
                                          printDisabledOutput: "\"com.gdeml.insomnia.safety\" => true"))
        #expect(!SudoersBackend.isDisabled(label: "com.gdeml.insomnia.safety", printDisabledOutput: ""))
    }

    @Test func appleScriptEscaping() {
        #expect(AdminScript.appleScriptEscaped(#"a\b"c"#) == #"a\\b\"c"#)
        #expect(AdminScript.appleScriptEscaped("one\ntwo") == #"one\ntwo"#)
    }

    @Test func osascriptTrailingCode() {
        #expect(AdminScript.trailingCode("0:120: execution error: User canceled. (-128)") == -128)
        #expect(AdminScript.trailingCode("execution error: The command exited with a non-zero status. (11)\n") == 11)
        #expect(AdminScript.trailingCode("no code here") == nil)
        #expect(AdminScript.trailingCode("(abc)") == nil)
    }

    @Test func safetyScriptEmbedsUnescapedAndParses() throws {
        #expect(!SudoersBackend.safetyScript.contains("<"))
        // It does contain `&&`: safetyDaemonPlist XML-escapes it, and safetyDaemonPlistLints proves the round trip.
        #expect(SudoersBackend.safetyDaemonPlist.contains("&amp;&amp;"))
        #expect(SudoersBackend.safetyScript.contains(#"s/^ *"CurrentCapacity" = \([0-9]*\)$/\1/p"#))
        #expect(SudoersBackend.safetyScript.contains("-le $((m * 10))"))
        #expect(try shellSyntaxOK("/bin/sh", SudoersBackend.safetyScript))
    }

    @Test func safetyDaemonPlistLints() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("insomnia-safety-\(UUID().uuidString).plist")
        try SudoersBackend.safetyDaemonPlist.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Spawn.run("/usr/bin/plutil", ["-lint", "-s", url.path], timeout: 10).status == 0)
        let plist = try #require(NSDictionary(contentsOf: url))
        #expect(plist["Label"] as? String == "com.gdeml.insomnia.safety")
        #expect(plist["StartInterval"] as? Int == 60)
        #expect((plist["ProgramArguments"] as? [String])?.last == SudoersBackend.safetyScript)
    }

    @Test func installScriptHasTheExactRuleAndParses() throws {
        let script = SudoersBackend.installScript(user: "gdeml")
        #expect(script.contains("U='gdeml'"))
        #expect(script.contains(##""#$UID_N ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1""##))
        #expect(script.contains("\nPLIST\n"))                        // heredoc terminator at column 0
        #expect(!script.contains("*\" ALL"))
        #expect(try shellSyntaxOK("/bin/sh", script))
    }

    @Test func uninstallScriptResetsOnlyWithMarker() throws {
        #expect(SudoersBackend.uninstallScript(reset: true).contains("[ '1' = 1 ]"))
        #expect(SudoersBackend.uninstallScript(reset: false).contains("[ '0' = 1 ]"))
        #expect(try shellSyntaxOK("/bin/sh", SudoersBackend.uninstallScript(reset: false)))
    }

    @Test func watchdogScriptParses() throws {
        #expect(Watchdog.script.contains("read -r -t 45"))
        #expect(try shellSyntaxOK("/bin/bash", Watchdog.script))
    }

    /// `sh -n -c`: parse only, never executes.
    private func shellSyntaxOK(_ shell: String, _ script: String) throws -> Bool {
        Spawn.run(shell, ["-n", "-c", script], timeout: 10).status == 0
    }
}

@Suite("Spawn")
struct SpawnTests {
    @Test func exitStatus() {
        #expect(Spawn.run("/usr/bin/true", [], timeout: 5).status == 0)
        #expect(Spawn.run("/usr/bin/false", [], timeout: 5).status == 1)
    }

    @Test func capturesStderr() {
        let r = Spawn.run("/bin/sh", ["-c", "echo oops >&2; exit 3"], timeout: 5, captureStderr: true)
        #expect(r.status == 3)
        #expect(r.stderr == "oops")
    }

    @Test func emptyEnvironmentByDefault() {
        let r = Spawn.run("/bin/sh", ["-c", "[ -z \"$HOME\" ] && [ -z \"$PATH_X\" ]"], timeout: 5)
        #expect(r.status == 0)
    }

    @Test func timeoutKills() {
        let start = Date()
        let r = Spawn.run("/bin/sleep", ["5"], timeout: 0.3)
        #expect(r.status == -1)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func missingExecutable() {
        #expect(Spawn.run("/nonexistent/binary", [], timeout: 1).status != 0)
    }

    @Test func decodesSignals() {
        #expect(Spawn.decode(0x0300) == 3)
        #expect(Spawn.decode(9) == 137)
    }
}
