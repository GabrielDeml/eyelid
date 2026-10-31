import Foundation
import Testing
@testable import Insomnia
import InsomniaShared

/// Regression tests for the 2026-10-31 review's simplification pass: duplicated code that also disagreed now has one
/// implementation. Spawn's stdout capture and shared WaitStatus (R2), one Why-awake report for the menu and
/// `insomnia why` (R3), one duration parser for the CLI and URLs (R5), shared IORegistry / IOPS readers (R11),
/// `Rule.options(closedLidMode:)` (R18), notification fallbacks (R55), one cap formatter (R79), the engine's headline
/// (R80), one guard phrase (R82), eye bags (R84) and one "h / min" formatter (R85).

// MARK: - R2: one spawn path

@Suite("Fix simplification: Spawn")
struct FixSimplificationSpawnTests {
    @Test func capturesStdoutAndStderrSeparately() {
        let r = Spawn.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 4"], timeout: 5,
                          captureStderr: true, captureStdout: true)
        #expect(r.status == 4)
        #expect(r.stdout == "out\n")
        #expect(r.stderr == "err")
    }

    @Test func stdoutIsDiscardedUnlessAsked() {
        let r = Spawn.run("/bin/sh", ["-c", "echo out"], timeout: 5)
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
    }

    /// More than a pipe buffer: the child never blocks on a full pipe, and the capture stops at 64 KB. Pipe data wakes
    /// the wait (R2): falling back to the 1 s poll would stall about a second per pipe buffer.
    @Test func largeOutputDoesNotDeadlock() {
        let start = Date()
        let r = Spawn.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' x"], timeout: 10, captureStdout: true)
        #expect(Date().timeIntervalSince(start) < 1.0)
        #expect(r.status == 0)
        #expect(r.stdout.utf8.count >= 64 * 1024 && r.stdout.utf8.count < 64 * 1024 + 4096)
    }

    /// A closed pipe stays readable; the wait must not spin on it while the child keeps running.
    @Test func anEarlyClosedPipeDoesNotSpin() {
        var start = timespec(), end = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start)
        let r = Spawn.run("/bin/sh", ["-c", "echo hi; exec 1>&-; sleep 1"], timeout: 5, captureStdout: true)
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &end)
        #expect(r.status == 0)
        #expect(r.stdout == "hi\n")
        let cpu = Double(end.tv_sec - start.tv_sec) + Double(end.tv_nsec - start.tv_nsec) / 1e9
        #expect(cpu < 0.3)
    }

    @Test func decodeIsBuiltOnWaitStatus() {
        #expect(WaitStatus(3 << 8) == .exited(3))
        #expect(Spawn.decode(3 << 8) == 3)
        #expect(WaitStatus(0x80 | 9) == .signaled(9))
        #expect(Spawn.decode(0x80 | 9) == 128 + 9)
    }
}

// MARK: - R3, R80, R82: `insomnia why` is the Why-awake report

@Suite("Fix simplification: one Why-awake report", .serialized)
@MainActor
struct FixSimplificationWhyTests {
    private func responder(_ h: Harness, sleepDisabled: Bool? = false) -> EngineControlResponder {
        EngineControlResponder(engine: h.engine, settings: h.settings, power: h.power,
                               sleepDisabled: { sleepDisabled }, clock: { h.clock.now })
    }

    private func report(_ h: Harness, sleepDisabled: Bool? = false) -> WhyAwakeReport {
        WhyAwakeReport.build(WhyAwakeInput.make(engine: h.engine, settings: h.settings, power: h.power,
                                                sleepDisabled: sleepDisabled, foreign: [], appPIDs: []))
    }

    private func cli(_ r: WhyAwakeReport) -> [WhyRow] {
        r.cliRows.map { WhyRow(section: $0.section, who: $0.who, what: $0.what) }
    }

    /// The CLI used to say "Nothing" while ⌥-click listed a rule the eyes paused.
    @Test func pausedRulesShowInTheCLI() {
        let h = Harness()
        let rule = Rule(condition: .app(bundleID: "com.apple.dt.Xcode", name: "Xcode"))
        h.settings.rules = [rule]
        h.watch.satisfiedRules = [rule]
        h.engine.reevaluate()
        h.engine.toggle(source: .panel)                    // the eyes pause it
        #expect(h.engine.pausedRuleIDs == [rule.id])

        let rows = responder(h).respond(to: .why, connection: UUID(), peerPID: nil).why ?? []
        #expect(rows.contains(WhyRow(section: "Insomnia", who: "Rule", what: "Xcode is running · paused")))
        #expect(CLIFormat.why(rows).contains("Nothing") == false)
        #expect(rows == cli(report(h)))
    }

    @Test func holdsGuardsAndSystemMatchTheMenu() {
        let h = Harness()
        h.settings.closedLidMode = true
        h.engine.activate(.minutes(60), source: .cli)
        h.power.thermalState = .serious
        h.power.externalDisplayCount = 2
        h.engine.reevaluate()
        let r = responder(h, sleepDisabled: true)
        let rows = r.respond(to: .why, connection: UUID(), peerPID: nil).why ?? []
        #expect(rows == cli(report(h, sleepDisabled: true)))
        #expect(rows.contains { $0.who == "Command line" })
        #expect(rows.contains(WhyRow(section: "Guards", who: "Paused lid mode", what: "running hot")))
        #expect(rows.contains { $0.who == "Power" && $0.what.hasSuffix("2 external displays") })
        // Status lists holds with the report's words too.
        let status = r.status()
        #expect(status.holds == report(h).section(.insomnia)?.rows.map(\.title))
        #expect(status.headline == h.engine.headline)
        #expect(status.lidDetail == "paused · running hot")
    }

    @Test func headlineIsTheFallbackHeadline() {
        let h = Harness()
        h.engine.activate(.indefinite, source: .panel)
        #expect(h.engine.headline == "Wide awake")
        #expect(h.engine.headline == FallbackCopy.headline(status: h.engine.status, lid: h.engine.lid,
                                                           batteryFloor: h.settings.batteryFloorPercent))
    }

    /// One guard phrase: Why awake, the CLI's lid detail, H′ and VoiceOver say the same words.
    @Test(arguments: GuardReason.allCases)
    func guardPhraseIsShared(_ g: GuardReason) {
        let phrase = PlainCopy.guardPhrase(g, batteryFloor: 25, batteryCap: 90, acCap: 240)
        var input = WhyAwakeInput()
        input.lid = .suspended(g)
        input.guards = [g]
        input.batteryFloor = 25
        input.lidBatteryCapMinutes = 90
        input.lidACCapMinutes = 240
        let guardRows = WhyAwakeReport.build(input).section(.guards)?.rows.map(\.what) ?? []
        #expect(guardRows.contains(phrase))

        var s = PanelState()
        s.status = .indefinite
        s.lid = .suspended(g)
        s.batteryFloor = 25
        s.lidBatteryCapMinutes = 90
        s.lidACCapMinutes = 240
        if g != .acRequired { #expect(PlainCopy.lidSublabel(s)?.text == "Paused · " + phrase) }
        let spoken = PlainCopy.guardPhrase(g, batteryFloor: 25, batteryCap: 90, acCap: 240, spoken: true)
        #expect(PlainCopy.accessibilityValue(s).hasSuffix("lid mode paused: " + spoken))
    }
}

// MARK: - R5: one duration parser

@Suite("Fix simplification: durations")
struct FixSimplificationDurationTests {
    private func url(_ text: String) -> Int? {
        if case .minutes(let m)? = URLCommand.parseDuration(text) { return m }
        return nil
    }

    /// `1d` used to work only in the CLI, `1h30` only in URLs, and the forever words differed.
    @Test(arguments: ["45m", "2h", "90", "1h30m", "1h 30m", "1h30", "1d", "2 hours", " 15M "])
    func cliAndURLAgree(_ text: String) {
        let cli = ControlDuration.minutes(text)
        #expect(cli != nil, "\(text)")
        #expect(url(text) == cli, "\(text)")
    }

    @Test(arguments: ["forever", "Forever", "indefinite", "indefinitely", "inf", "infinite", "infinity", "∞"])
    func foreverWordsAgree(_ word: String) {
        #expect(ControlDuration.parse(word) == .indefinite)
        #expect(URLCommand.parseDuration(word) == .forever)
    }

    @Test(arguments: ["", "0", "0h0m", "abc", "90s", "-5", "1.5h", "h", "30 45", "1hxyz"])
    func bothRejectTheSame(_ text: String) {
        #expect(ControlDuration.minutes(text) == nil, "\(text)")
        #expect(URLCommand.parseDuration(text) == nil, "\(text)")
    }

    @Test func onlyTheCapDiffers() {
        #expect(ControlDuration.minutes("8d") == 8 * 1440)                 // CLI: up to a year
        #expect(ControlDuration.minutes("400d") == nil)                    // past a year: refused
        #expect(url("8d") == URLCommand.maxMinutes)                         // URL: saturates at 7 days
        #expect(ControlDuration.minutes("8d", cap: 7 * 1440, saturating: true) == 7 * 1440)
    }

    @Test func clockTimesAgree() {
        for text in ["17:30", "7:05", "0730"] {
            let cli = ControlDuration.clock(text)
            #expect(cli != nil, "\(text)")
            let parsed = URLCommand.parse(URL(string: "insomnia://on?until=\(text)")!)
            #expect(parsed?.action == .on(.until(hour: cli!.hour, minute: cli!.minute), screen: nil))
        }
        #expect(ControlDuration.clock("0730")! == (7, 30))
        #expect(ControlDuration.clock("2400") == nil)
    }
}

// MARK: - R11: shared readers

@Suite("Fix simplification: power readers")
struct FixSimplificationPowerTests {
    /// The shared parser (app and helper) treats a battery IOPS reports as not present as a desktop. The app's copy
    /// already did; the helper's own reader didn't, which is what `helperHasNoPowerReaderOfItsOwn` guards against.
    @Test func absentBatteryIsADesktop() {
        let r = PowerSourceReading.parse(providingType: "Battery Power", descriptions: [[
            "Type": "InternalBattery", "Is Present": false, "Current Capacity": 5, "Max Capacity": 100,
        ]])
        #expect(r == .desktop)
    }

    /// R11: the drift was a second IOPS reader in the helper. Only InsomniaShared/PowerSources.swift reads IOPS.
    @Test func helperHasNoPowerReaderOfItsOwn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 10)
        for file in files where file.lastPathComponent != "PowerSources.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("IOPSCopyPowerSources"), "\(file.lastPathComponent) reads IOPS itself")
        }
        let helper = try String(contentsOf: root.appendingPathComponent("InsomniaHelper/HelperDaemon.swift"), encoding: .utf8)
        #expect(helper.contains("PowerSourceReading.current()"))
    }

    @Test func rootDomainGoesThroughTheSharedReader() {
        #expect(RootDomain.sleepDisabled() == RootDomainRegistry.bool(HelperInfo.sleepDisabledKey))
    }
}

// MARK: - R18, R84: small model helpers

@Suite("Fix simplification: model helpers")
struct FixSimplificationModelTests {
    @Test func ruleOptionsFollowTheLidSwitch() {
        let rule = Rule(condition: .onAC, keepScreenOn: true, allowLid: false)
        #expect(rule.options(closedLidMode: false) == AwakeOptions(screen: true, lid: false))
        #expect(rule.options(closedLidMode: true) == AwakeOptions(screen: true, lid: true))
        let lidRule = Rule(condition: .onAC, allowLid: true)
        #expect(lidRule.options(closedLidMode: false).lid)
    }

    @Test func noBagsWhileAsleep() {
        var s = PanelState()
        s.awakeFor = 100 * 3600
        #expect(s.bags == 0)
        s.status = .indefinite
        #expect(s.bags == 2)
        s.awakeFor = 30 * 3600
        #expect(s.bags == EyeBags.level(awakeFor: 30 * 3600))
    }
}

// MARK: - R55, R79, R85: one formatter per thing

private enum TitleNotifier: NotificationPosting {
    @MainActor static var posted: [(id: NotificationID, title: String, body: String)] = []
    static func post(_ id: NotificationID, title: String, body: String) { posted.append((id, title, body)) }
    static func clear(_ id: NotificationID) {}
}

@Suite("Fix simplification: formatters", .serialized)
@MainActor
struct FixSimplificationFormatTests {
    @Test func hoursMinutes() {
        #expect(TimeFormat.hoursMinutes(0) == "0 min")
        #expect(TimeFormat.hoursMinutes(42) == "42 min")
        #expect(TimeFormat.hoursMinutes(60) == "1 h")
        #expect(TimeFormat.hoursMinutes(125) == "2 h 5 min")
    }

    /// A 0-minute cap used to read "0 h" while every other formatter said minutes.
    @Test func capsAndTimeLeftAgree() {
        #expect(PlainCopy.capText(0) == "0 min")
        for minutes in [15, 60, 90, 240, 1440] {
            #expect(PlainCopy.capText(minutes) == CLIFormat.remaining(minutes * 60))
        }
        var s = PanelState()
        s.now = Date(timeIntervalSinceReferenceDate: 0)
        s.status = .timed(end: s.now.addingTimeInterval(90 * 60))
        s.remaining = 90 * 60
        #expect(PlainCopy.subline(s).text.hasPrefix(PlainCopy.capText(90) + " left"))
    }

    @Test func longCapNames() {
        #expect(PlainCopy.capLong(15) == "15 minutes")
        #expect(PlainCopy.capLong(60) == "1 hour")
        #expect(PlainCopy.capLong(240) == "4 hours")
        #expect(PlainCopy.capLong(90) == "1 hour 30 minutes")
    }

    /// The lid-cap notification used to say "4h" while the banner said "4 h".
    @Test func lidCapNotificationMatchesTheBanner() {
        let h = Harness()
        TitleNotifier.posted = []
        h.engine.notifier = TitleNotifier.self
        h.settings.closedLidMode = true
        h.settings.lidMaxOnBatteryMinutes = 240
        h.engine.activate(.indefinite, source: .panel)
        h.power.isLidClosed = true
        h.lid.converge(lidClosed: true)
        h.clock.advance(240 * 60)
        h.engine.reevaluate()
        #expect(h.engine.lid == .suspended(.lidBatteryCap))
        var s = PanelState()
        s.lidBatteryCapMinutes = 240
        let banner = PlainCopy.banner(.guardTripped(.lidBatteryCap), s).text
        let title = TitleNotifier.posted.first { $0.id == .lidCap }?.title
        #expect(title == banner)
        #expect(title == "Lid mode paused after 4 h closed on battery")
    }

    /// Without a Narrator the ending-soon title used to say 5 minutes whatever was left, and LPM / cap bodies were blank.
    @Test func fallbackNotificationsMatchTheNarrator() {
        let narrator = Narrator(settings: Settings(defaults: ScratchDefaults.make("FixSimplification")))
        for id in [NotificationID.endingSoon, .lidLPM, .lidCap] {
            let context = ["minutes": "3", "cap": "1 h"]
            let fallback = FallbackCopy.notification(id, context: context)
            #expect(narrator.notification(id, .professional, context: context).title == fallback.title)
        }
        #expect(FallbackCopy.notification(.endingSoon, context: ["minutes": "3"]).title == "Insomnia: 3 minutes left")
        #expect(FallbackCopy.notification(.endingSoon, context: ["minutes": "1"]).title == "Insomnia: 1 minute left")
        #expect(FallbackCopy.notification(.endingSoon, context: [:]).title == "Insomnia: 5 minutes left")
        #expect(!FallbackCopy.notification(.lidLPM, context: [:]).body.isEmpty)
        #expect(!FallbackCopy.notification(.lidCap, context: [:]).body.isEmpty)
    }
}
