import Foundation
import Testing
@testable import Insomnia

// insomnia:// parsing (ARCHITECTURE.md "App/URLCommandHandler.swift"). Pure: no engine involved.

@Suite("URLCommand")
struct URLCommandTests {
    private func parse(_ s: String) -> URLCommand? {
        URL(string: s).flatMap(URLCommand.parse)
    }

    @Test func simpleHosts() {
        #expect(parse("insomnia://toggle")?.action == .toggle)
        #expect(parse("insomnia://off")?.action == .off)
        #expect(parse("insomnia://sleep")?.action == .sleep)
        #expect(parse("insomnia://panel")?.action == .panel)
        #expect(parse("INSOMNIA://Toggle")?.action == .toggle)
        #expect(parse("insomnia:toggle")?.action == .toggle)
    }

    @Test func onDurations() {
        #expect(parse("insomnia://on")?.action == .on(.defaultDuration, screen: nil))
        #expect(parse("insomnia://on?for=45m")?.action == .on(.minutes(45), screen: nil))
        #expect(parse("insomnia://on?for=2h")?.action == .on(.minutes(120), screen: nil))
        #expect(parse("insomnia://on?for=90")?.action == .on(.minutes(90), screen: nil))
        #expect(parse("insomnia://on?for=1h30m")?.action == .on(.minutes(90), screen: nil))
        #expect(parse("insomnia://on?for=1h30")?.action == .on(.minutes(90), screen: nil))
        #expect(parse("insomnia://on?for=forever")?.action == .on(.forever, screen: nil))
        #expect(parse("insomnia://on?for=0") == nil)
        #expect(parse("insomnia://on?for=abc") == nil)
        #expect(parse("insomnia://on?for=99999h")?.action == .on(.minutes(7 * 24 * 60), screen: nil))
    }

    @Test func onUntilAndScreen() {
        #expect(parse("insomnia://on?until=17:30&screen=1")?.action == .on(.until(hour: 17, minute: 30), screen: true))
        #expect(parse("insomnia://on?until=0730")?.action == .on(.until(hour: 7, minute: 30), screen: nil))
        #expect(parse("insomnia://on?until=24:00") == nil)
        #expect(parse("insomnia://on?until=7:5") == nil)
        #expect(parse("insomnia://on?screen=0")?.action == .on(.defaultDuration, screen: false))
        let both = parse("insomnia://on?until=08:00&for=2h")
        #expect(both?.action == .on(.until(hour: 8, minute: 0), screen: nil))
        #expect(both?.ignored == ["for"])
    }

    @Test func lidIsNeverAcceptedFromAURL() {
        let c = parse("insomnia://on?for=1h&lid=1")
        #expect(c?.action == .on(.minutes(60), screen: nil))
        #expect(c?.ignored.contains("lid") == true)
    }

    @Test func extendAndSettings() {
        #expect(parse("insomnia://extend")?.action == .extend(minutes: 15))
        #expect(parse("insomnia://extend?by=30m")?.action == .extend(minutes: 30))
        #expect(parse("insomnia://extend?by=forever") == nil)
        #expect(parse("insomnia://settings")?.action == .settings(.general))
        #expect(parse("insomnia://settings?tab=lid")?.action == .settings(.lidSafety))
        #expect(parse("insomnia://settings?tab=diagnostics")?.action == .settings(.diagnostics))
        #expect(parse("insomnia://settings?tab=nope")?.ignored == ["tab"])
    }

    @Test func unknownsAreIgnoredOrRejected() {
        #expect(parse("insomnia://launch-missiles") == nil)
        #expect(parse("https://toggle") == nil)
        #expect(parse("insomnia://toggle?x=1&y=2")?.ignored == ["x", "y"])
    }
}
