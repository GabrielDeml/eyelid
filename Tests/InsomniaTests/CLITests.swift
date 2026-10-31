import Darwin
import Foundation
import Testing
@testable import Insomnia

// CLI parsing and formatting (pure), wait-status decoding, the `run` spawner, and the CLI symlink installer.

@Suite("CLI parser")
struct CLIParserTests {
    private func parse(_ line: String) -> Result<CLICommand, CLIUsageError> {
        CLIParser.parse(line.split(separator: " ").map(String.init))
    }

    private func ok(_ line: String) -> CLICommand? {
        if case .success(let c) = parse(line) { return c }
        return nil
    }

    private func fails(_ line: String) -> Bool {
        if case .failure = parse(line) { return true }
        return false
    }

    @Test func on() {
        #expect(ok("on") == .request(.on(duration: nil, until: nil, screen: nil, lid: nil), json: false))
        #expect(ok("on 2h --screen") == .request(.on(duration: "2h", until: nil, screen: true, lid: nil), json: false))
        #expect(ok("on forever --no-screen --lid --json") == .request(.on(duration: "forever", until: nil, screen: false, lid: true), json: true))
        #expect(ok("on --until 17:30") == .request(.on(duration: nil, until: "17:30", screen: nil, lid: nil), json: false))
        #expect(ok("on --until=7:05 --no-lid") == .request(.on(duration: nil, until: "7:05", screen: nil, lid: false), json: false))
        #expect(ok("on --for 90") == .request(.on(duration: "90", until: nil, screen: nil, lid: nil), json: false))
        #expect(fails("on 2h --until 17:30"))
        #expect(fails("on 2h 3h"))
        #expect(fails("on soon"))
        #expect(fails("on --until 25:00"))
        #expect(fails("on --until"))
        #expect(fails("on --bogus"))
    }

    @Test func simpleCommands() {
        #expect(ok("off") == .request(.off, json: false))
        #expect(ok("toggle --json") == .request(.toggle, json: true))
        #expect(ok("status --json") == .request(.status, json: true))
        #expect(ok("why") == .request(.why, json: false))
        #expect(ok("extend") == .request(.extend(by: "15m"), json: false))
        #expect(ok("extend 1h") == .request(.extend(by: "1h"), json: false))
        #expect(fails("extend forever"))
        #expect(fails("status now"))
        #expect(fails("off --force"))
        #expect(ok("help") == .help)
        #expect(ok("--help") == .help)
        #expect(ok("--why") == .existential)
        #expect(CLIParser.parse([]) == .success(.help))
        #expect(fails("nap"))
    }

    @Test func run() {
        #expect(ok("run -- make -j8") == .run(command: ["make", "-j8"], screen: false, lid: false))
        #expect(ok("run --screen --lid -- ffmpeg -i a.mov b.mp4") == .run(command: ["ffmpeg", "-i", "a.mov", "b.mp4"], screen: true, lid: true))
        // Without `--`, the first non-option starts the command; its own flags stay its own.
        #expect(ok("run make --keep-going") == .run(command: ["make", "--keep-going"], screen: false, lid: false))
        #expect(ok("run -- --weird-name") == .run(command: ["--weird-name"], screen: false, lid: false))
        #expect(fails("run"))
        #expect(fails("run --"))
        #expect(fails("run --screen"))
        #expect(fails("run --bogus make"))
    }

    @Test func watch() {
        #expect(ok("watch --pid 4411") == .watch(pid: 4411, screen: false, lid: false))
        #expect(ok("watch --pid=12 --screen") == .watch(pid: 12, screen: true, lid: false))
        #expect(ok("watch 99 --lid") == .watch(pid: 99, screen: false, lid: true))
        #expect(fails("watch"))
        #expect(fails("watch --pid"))
        #expect(fails("watch --pid 0"))
        #expect(fails("watch --pid abc"))
        #expect(fails("watch 1 2"))
    }

    @Test func everyDispatchedWordIsACommand() {
        for word in ["on", "off", "toggle", "extend", "status", "why", "run", "watch", "help", "--why"] {
            #expect(CLIParser.commands.contains(word))
        }
    }
}

@Suite("CLI output")
struct CLIFormatTests {
    private func payload(_ state: String, remaining: Int? = nil, endsAt: Date? = nil, screen: Bool = false,
                         holds: [String] = [], headline: String? = nil, lidDetail: String? = nil) -> StatusPayload {
        StatusPayload(state: state, remainingSeconds: remaining, endsAt: endsAt, screen: screen, lid: "off",
                      guards: [], holds: holds, headline: headline, lidDetail: lidDetail)
    }

    @Test func remaining() {
        #expect(CLIFormat.remaining(1) == "1 min")
        #expect(CLIFormat.remaining(2520) == "42 min")
        #expect(CLIFormat.remaining(3600) == "1 h")
        #expect(CLIFormat.remaining(3601) == "1 h 1 min")
        #expect(CLIFormat.remaining(7500) == "2 h 5 min")
    }

    @Test func status() {
        let end = Date().addingTimeInterval(2520)
        let timed = CLIFormat.status(payload("timed", remaining: 2520, endsAt: end, screen: true, holds: ["You · 42m timer"],
                                             headline: "Wide awake", lidDetail: "on · lid closed"))
        let lines = timed.split(separator: "\n").map(String.init)
        #expect(lines[0] == "Wide awake")
        #expect(lines[1].hasPrefix("  42 min left · until "))
        #expect(lines[1].hasSuffix(" · screen on"))
        #expect(lines[2] == "  Lid mode: on · lid closed")
        #expect(lines.count == 3)

        #expect(CLIFormat.status(payload("indefinite", headline: "Wide awake")) == "Wide awake\n  until you say so")
        #expect(CLIFormat.status(payload("asleep", headline: "Sleep allowed")) == "Sleep allowed")
        #expect(CLIFormat.status(payload("client", holds: ["Command · make", "Rule · on power adapter"], headline: "Awake for make"))
                == "Awake for make\n  2 reasons · insomnia why")
        #expect(CLIFormat.status(payload("watching")) == "Awake")
    }

    @Test func why() {
        let nothing = CLIFormat.why([WhyRow(section: "System", who: "SleepDisabled", what: "No")])
        #expect(nothing == "Why is my Mac awake?\n\nNothing. Your Mac is free to sleep.\n\nSystem\n  SleepDisabled: No")
        let some = CLIFormat.why([
            WhyRow(section: "Insomnia", who: "You", what: "1h timer"),
            WhyRow(section: "Other apps", who: "zoom.us", what: "Preventing display sleep"),
            WhyRow(section: "Insomnia", who: "Command", what: "make"),
            WhyRow(section: "System", who: "Power", what: "Thermal: nominal"),
        ])
        #expect(some == """
            Why is my Mac awake?

            Insomnia
              You · 1h timer
              Command · make
            Other apps
              zoom.us · Preventing display sleep
            System
              Power: Thermal: nominal
            """)
    }

    @Test @MainActor func existentialAnswersFollowTheVoiceRules() {
        for p in Personality.allCases {
            let lines = CLI.existentialLines[p] ?? []
            #expect(!lines.isEmpty)
            if p == .professional { #expect(lines.allSatisfy { !$0.contains("!") }) }
        }
    }
}

@Suite("CLI run")
@MainActor
struct CLIRunTests {
    private func runAndWait(_ argv: [String]) -> WaitStatus? {
        guard case .success(let pid) = CLIRunner.spawn(argv) else { return nil }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return WaitStatus(status)
    }

    @Test func waitStatusDecodes() {
        #expect(WaitStatus(0) == .exited(0))
        #expect(WaitStatus(3 << 8) == .exited(3))
        #expect(WaitStatus(2) == .signaled(2))
        #expect(WaitStatus(0x80 | 9) == .signaled(9))   // core-dump bit
    }

    @Test func spawnPropagatesExitStatus() {
        #expect(runAndWait(["/usr/bin/true"]) == .exited(0))
        #expect(runAndWait(["false"]) == .exited(1))   // found on PATH
        #expect(runAndWait(["/bin/sh", "-c", "exit 42"]) == .exited(42))
    }

    @Test func spawnReportsMissingCommands() {
        guard case .failure(let e) = CLIRunner.spawn(["insomnia-no-such-command-\(UUID().uuidString)"]) else {
            Issue.record("expected ENOENT")
            return
        }
        #expect(e.code == ENOENT)
    }

    /// The parent ignores SIGPIPE (main.swift) and, during `run`, the forwarded signals; the child must not inherit that.
    @Test func childGetsDefaultSignalDispositions() {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        #expect(runAndWait(["/bin/sh", "-c", "kill -PIPE $$"]) == .signaled(SIGPIPE))
        #expect(runAndWait(["/bin/sh", "-c", "kill -TERM $$"]) == .signaled(SIGTERM))
    }

    @Test func processNameOfSelf() {
        #expect(CLIRunner.processName(getpid())?.isEmpty == false)
    }
}

@Suite("CLI installer", .serialized)
struct CLIInstallerTests {
    private func sandbox() throws -> (CLIInstaller, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        let exe = root.appendingPathComponent("Insomnia.app/Contents/MacOS/Insomnia")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: exe.path, contents: Data("#!/bin/sh\n".utf8))
        let installer = CLIInstaller(link: root.appendingPathComponent("home/.local/bin/insomnia"),
                                     target: exe.resolvingSymlinksInPath())
        return (installer, root, exe)
    }

    @Test func installReinstallRemove() throws {
        let (installer, root, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(installer.state() == .notInstalled)
        try installer.install()   // creates ~/.local/bin
        #expect(installer.state() == .installed)
        try installer.install()   // reinstall over our own link
        #expect(installer.state() == .installed)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installer.directory.path)
        #expect(leftovers == ["insomnia"])
        try installer.remove()
        #expect(installer.state() == .notInstalled)
        try installer.remove()    // nothing to do
    }

    @Test func anotherCopyIsReplaceable() throws {
        let (installer, root, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: installer.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: installer.link.path,
                                                   withDestinationPath: "/Volumes/Gone/Insomnia.app/Contents/MacOS/Insomnia")
        #expect(installer.state() == .pointsElsewhere("/Volumes/Gone/Insomnia.app/Contents/MacOS/Insomnia"))
        try installer.install()
        #expect(installer.state() == .installed)
    }

    @Test func someoneElsesFileIsLeftAlone() throws {
        let (installer, root, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: installer.directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: installer.link.path, contents: Data("mine".utf8))
        #expect(installer.state() == .occupied)
        #expect(throws: CLIInstaller.Failure.occupied) { try installer.install() }
        #expect(throws: CLIInstaller.Failure.occupied) { try installer.remove() }
        #expect(FileManager.default.contents(atPath: installer.link.path) == Data("mine".utf8))

        try FileManager.default.removeItem(at: installer.link)
        try FileManager.default.createSymbolicLink(atPath: installer.link.path, withDestinationPath: "/usr/bin/true")
        #expect(installer.state() == .occupied)
    }

    @Test func pathEvaluation() throws {
        let (installer, root, exe) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = installer.directory
        #expect(ShellPATH.evaluate(["/usr/bin", dir.path], directory: dir, target: exe) == .onPath)
        #expect(ShellPATH.evaluate(["/usr/bin", "/bin"], directory: dir, target: exe) == .missing)
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let impostor = other.appendingPathComponent("insomnia")
        FileManager.default.createFile(atPath: impostor.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        #expect(ShellPATH.evaluate([other.path, dir.path], directory: dir, target: exe) == .shadowed(by: impostor.path))
    }
}
