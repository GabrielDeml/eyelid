import Foundation
import Testing
@testable import Insomnia

// Why awake? report (UX.md §1.5), AssertionInspector parsing, EventLog ring.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func rows(_ r: WhyAwakeReport, _ kind: WhyAwakeReport.Section.Kind) -> [String] {
    r.section(kind)?.rows.map(\.title) ?? []
}

@MainActor
@Suite("Why awake report")
struct WhyAwakeReportTests {
    @Test func nothingShowsOnlySystem() {
        var input = WhyAwakeInput()
        input.sleepDisabled = false
        let r = WhyAwakeReport.build(input)
        #expect(r.isNothing)
        #expect(r.sections.map(\.kind) == [.system])
        #expect(rows(r, .system) == ["SleepDisabled: No", "Thermal: nominal · AC"])
        #expect(r.text(generatedAt: t0).contains(WhyAwakeReport.nothingText))
    }

    @Test func ourHolds() {
        let ruleID = UUID()
        var input = WhyAwakeInput()
        input.hasLid = true
        input.rules = [Rule(id: ruleID, condition: .app(bundleID: "com.apple.dt.Xcode", name: "Xcode"))]
        input.holds = [
            Hold(owner: .manual(.panel), options: AwakeOptions(screen: true, lid: true), start: t0,
                 end: t0.addingTimeInterval(3600)),
            Hold(owner: .babysit(.process(name: "ffmpeg")), options: .systemOnly, start: t0),
            Hold(owner: .client(connection: UUID(), label: "make"), options: .systemOnly, start: t0, followsSettings: false),
            Hold(owner: .rule(ruleID), options: .systemOnly, start: t0),
        ]
        input.matchedPIDs = [.process(name: "ffmpeg"): 4411]
        let r = WhyAwakeReport.build(input)
        #expect(!r.isNothing)
        #expect(rows(r, .insomnia) == [
            "You · 1h timer · screen on · lid",
            "Watching · ffmpeg (4411)",
            "Command · make (CLI)",
            "Rule · Xcode is running",
        ])
        #expect(r.section(.insomnia)?.rows.first?.since == t0)
    }

    @Test func durationText() {
        let indefinite = Hold(owner: .manual(.hotkey), options: .systemOnly, start: t0)
        #expect(WhyAwakeReport.durationText(indefinite) == "until you stop it")
        let odd = Hold(owner: .manual(.panel), options: .systemOnly, start: t0, end: t0.addingTimeInterval(47 * 60))
        let until = "until " + t0.addingTimeInterval(47 * 60).formatted(date: .omitted, time: .shortened)
        #expect(WhyAwakeReport.durationText(odd) == until)
    }

    @Test func sourcesAndDesktopLid() {
        var input = WhyAwakeInput()
        input.hasLid = false   // desktop: never says "lid"
        input.holds = [Hold(owner: .manual(.urlScheme), options: AwakeOptions(screen: false, lid: true), start: t0,
                            end: t0.addingTimeInterval(1800), followsSettings: false)]
        #expect(rows(WhyAwakeReport.build(input), .insomnia) == ["Link · 30m timer"])
        input.holds = [Hold(owner: .manual(.cli), options: .systemOnly, start: t0, followsSettings: false)]
        #expect(rows(WhyAwakeReport.build(input), .insomnia) == ["Command line · until you stop it"])
    }

    @Test func pausedRulesAreListed() {
        let id = UUID()
        var input = WhyAwakeInput()
        input.rules = [Rule(id: id, condition: .process(name: "make"))]
        input.pausedRuleIDs = [id]
        #expect(rows(WhyAwakeReport.build(input), .insomnia) == ["Rule · make is running · paused until it stops"])
    }

    @Test func lidGuardsOnlyWhenLidIsRequested() {
        var input = WhyAwakeInput()
        input.guards = [.thermal, .lowPowerMode]
        input.lid = .off
        #expect(WhyAwakeReport.build(input).section(.guards) == nil)

        input.lid = .suspended(.thermal)
        #expect(rows(WhyAwakeReport.build(input), .guards) == ["Paused lid mode · running hot", "Paused lid mode · Low Power Mode"])

        input.guards = [.lidBatteryCap]
        input.lidBatteryCapMinutes = 60
        input.lid = .latched
        #expect(rows(WhyAwakeReport.build(input), .guards) == ["Paused lid mode · 1 h limit on battery", "Paused lid mode · until the lid opens"])
    }

    @Test func awakeFloorAlwaysShows() {
        var input = WhyAwakeInput()
        input.guards = [.awakeBatteryFloor]
        input.batteryFloor = 25
        #expect(rows(WhyAwakeReport.build(input), .guards) == ["Paused keeping awake · battery at 25%"])
    }

    @Test func otherAppsNamedAndDeduplicated() {
        var input = WhyAwakeInput()
        input.appPIDs = [100]
        input.foreign = [
            ForeignAssertion(id: "100:1", pid: 100, process: "zoom.us", type: "PreventUserIdleDisplaySleep", name: "Meeting", since: t0),
            ForeignAssertion(id: "100:2", pid: 100, process: "zoom.us", type: "NoDisplaySleepAssertion", name: "Video",
                             since: t0.addingTimeInterval(-60)),
            ForeignAssertion(id: "61150:3", pid: 61150, process: "caffeinate", type: "PreventUserIdleSystemSleep",
                             name: "caffeinate command-line tool", since: nil),
            ForeignAssertion(id: "573:4", pid: 573, process: "coreaudiod", type: "PreventUserIdleSystemSleep", name: "audio",
                             since: nil, onBehalfOfPID: 100, onBehalfOfName: "zoom.us"),
        ]
        let r = WhyAwakeReport.build(input)
        #expect(rows(r, .otherApps) == [
            "zoom.us · Preventing display sleep",
            "caffeinate (61150) · Preventing idle sleep",
            "coreaudiod for zoom.us · Preventing idle sleep",
        ])
        #expect(r.section(.otherApps)?.rows.first?.since == t0.addingTimeInterval(-60))   // earliest wins
        #expect(r.section(.otherApps)?.rows.first?.detail == "Meeting")
    }

    @Test func systemRows() {
        var input = WhyAwakeInput()
        input.hasLid = true
        input.lidClosed = false
        input.hasBattery = true
        input.batteryPercent = 95
        input.isOnAC = true
        input.sleepDisabled = true
        input.sleepDisabledByInsomnia = true
        input.lid = .engaged(lidClosed: false)
        #expect(rows(WhyAwakeReport.build(input), .system) == [
            "SleepDisabled: Yes (set by Insomnia)", "Lid: open · Thermal: nominal · AC · 95%", "Lid mode: engaged",
        ])
        input.sleepDisabledByInsomnia = false
        input.isOnAC = false
        input.thermal = .serious
        input.lowPowerMode = true
        input.lid = .off
        #expect(rows(WhyAwakeReport.build(input), .system) == [
            "SleepDisabled: Yes (set by something else)", "Lid: open · Thermal: serious · Battery · 95% · Low Power Mode",
        ])
        input.sleepDisabled = nil
        #expect(rows(WhyAwakeReport.build(input), .system).first == "SleepDisabled: Unknown")
    }

    @Test func textAndCLIRows() {
        var input = WhyAwakeInput()
        input.headline = "Wide awake"
        input.holds = [Hold(owner: .manual(.panel), options: .systemOnly, start: t0)]
        input.sleepDisabled = false
        input.footer = ["Insomnia 1.0.0 (1)"]
        let r = WhyAwakeReport.build(input)
        let text = r.text(generatedAt: t0)
        #expect(text.hasPrefix(WhyAwakeReport.title))
        #expect(text.contains("Wide awake"))
        #expect(text.contains("Insomnia\n  You · until you stop it"))
        #expect(text.hasSuffix("Insomnia 1.0.0 (1)"))
        #expect(r.cliRows.first?.section == "Insomnia")
        #expect(r.cliRows.first?.who == "You")
        #expect(r.cliRows.first?.what == "until you stop it")
    }

    @Test func liveReportBuilds() {
        // Smoke: reads IOKit and the shared singletons without crashing; System is always present.
        let r = WhyAwakeReport.build(.live())
        #expect(r.section(.system) != nil)
    }
}

@Suite("AssertionInspector")
struct AssertionInspectorTests {
    private func a(_ pid: Int32, _ type: String, name: String = "n", level: Int = 255, trueType: String? = nil,
                   process: String? = "proc", id: Int = 1, behalf: Int32? = nil) -> [String: Any] {
        var d: [String: Any] = ["AssertPID": NSNumber(value: pid), "AssertType": type, "AssertName": name,
                                "AssertLevel": NSNumber(value: level), "AssertionId": NSNumber(value: id),
                                "AssertStartWhen": t0]
        if let trueType { d["AssertionTrueType"] = trueType }
        if let process { d["Process Name"] = process }
        if let behalf { d["AssertionOnBehalfOfPID"] = NSNumber(value: behalf) }
        return d
    }

    @Test func filtersOwnOffAndIrrelevant() {
        let parsed = AssertionInspector.parse([
            a(10, "PreventUserIdleSystemSleep", process: "caffeinate", id: 1),
            a(99, "PreventUserIdleSystemSleep", id: 2),                            // ours
            a(11, "PreventUserIdleDisplaySleep", level: 0, id: 3),                 // off
            a(12, "ExternalMedia", id: 4),                                         // doesn't block sleep
            a(355, "PreventUserIdleSystemSleep", name: "Powerd - Prevent sleep while display is on", process: "powerd", id: 5),
        ], ownPID: 99, processName: { _ in nil })
        #expect(parsed.map(\.process) == ["caffeinate"])
        #expect(parsed.first?.since == t0)
        #expect(parsed.first?.id == "10:1")
    }

    @Test func prefersTrueTypeAndResolvesNames() {
        let parsed = AssertionInspector.parse([
            a(20, "NoIdleSleepAssertion", trueType: "PreventUserIdleSystemSleep", process: nil, id: 7),
            a(573, "PreventUserIdleSystemSleep", process: "coreaudiod", id: 8, behalf: 808),
        ], ownPID: 1, processName: { $0 == 20 ? "Electron" : ($0 == 808 ? "Music" : nil) })
        #expect(parsed.map(\.process) == ["coreaudiod", "Electron"])
        #expect(parsed.last?.type == "PreventUserIdleSystemSleep")
        #expect(parsed.first?.onBehalfOfName == "Music")
        #expect(parsed.first?.displayName(isApp: { $0 == 808 }) == "coreaudiod for Music")
        #expect(parsed.first?.displayName() == "coreaudiod for Music (808)")
    }

    @Test func describesTypes() {
        #expect(AssertionInspector.describe(type: "PreventUserIdleSystemSleep") == "Preventing idle sleep")
        #expect(AssertionInspector.describe(type: "NoDisplaySleepAssertion") == "Preventing display sleep")
        #expect(AssertionInspector.describe(type: "PreventSystemSleep") == "Preventing system sleep")
        #expect(AssertionInspector.describe(type: "SomethingNew") == "SomethingNew")
    }

    @Test func liveCallExcludesOurOwnAssertions() {
        #expect(!AssertionInspector.foreignAssertions().contains { $0.pid == getpid() })
    }
}

@MainActor
@Suite("EventLog")
struct EventLogTests {
    @Test func ringKeepsTheNewest() {
        let log = EventLog(capacity: 3, mirrorsToSystemLog: false, clock: { t0 })
        for i in 1...5 { log.log("engine", "event \(i)") }
        #expect(log.entries.map(\.message) == ["event 3", "event 4", "event 5"])
        #expect(log.entries.map(\.id) == [2, 3, 4])   // ids stay unique across drops
        log.clear()
        #expect(log.entries.isEmpty)
        log.log("lid", "engaged")
        #expect(log.entries.first?.id == 5)
    }

    @Test func textFormat() {
        let log = EventLog(capacity: 10, mirrorsToSystemLog: false, clock: { t0 })
        log.log("lid", "engaged (readback ✓)")
        log.log("", "no kind")
        let time = EventLog.time(t0)
        #expect(EventLog.line(log.entries[0]) == "\(time)  lid  engaged (readback ✓)")
        #expect(log.entries[1].kind == "app")
        let lines = log.text().split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("\(time)  lid  engaged (readback ✓)"))
        #expect(lines[0].count > EventLog.line(log.entries[0]).count)   // full date prefix
    }
}
