import Foundation
import Testing
@testable import Insomnia

// AwakeDuration, TimeFormat and the engine's tick planning (ARCHITECTURE.md AwakeEngine "Timers").

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite("AwakeDuration")
struct AwakeDurationTests {
    @Test func presetsInPanelOrder() {
        #expect(AwakeDuration.presets == [.minutes(30), .minutes(60), .minutes(120), .minutes(240), .minutes(480), .indefinite])
        #expect(AwakeDuration.presets.map(\.shortLabel) == ["30m", "1h", "2h", "4h", "8h", "∞"])
    }

    @Test func endDates() {
        #expect(AwakeDuration.indefinite.endDate(from: t0) == nil)
        #expect(AwakeDuration.minutes(30).endDate(from: t0) == t0.addingTimeInterval(1800))
        #expect(AwakeDuration.until(t0.addingTimeInterval(42)).endDate(from: t0) == t0.addingTimeInterval(42))
    }

    @Test(arguments: [0, -5])
    func nonPositiveMinutesClampToOne(minutes: Int) {
        #expect(AwakeDuration.minutes(minutes).endDate(from: t0) == t0.addingTimeInterval(60))
    }

    @Test func shortLabels() {
        #expect(AwakeDuration.minutes(45).shortLabel == "45m")
        #expect(AwakeDuration.minutes(60).shortLabel == "1h")
        #expect(AwakeDuration.minutes(90).shortLabel == "1h 30m")
        #expect(AwakeDuration.minutes(1440).shortLabel == "24h")
        #expect(AwakeDuration.until(t0).shortLabel.hasPrefix("→ "))
    }

    @Test func storedMinutesRoundTrip() {
        #expect(AwakeDuration(storedMinutes: 0) == .indefinite)
        #expect(AwakeDuration(storedMinutes: -3) == .indefinite)
        #expect(AwakeDuration(storedMinutes: 90) == .minutes(90))
        #expect(AwakeDuration.minutes(90).storedMinutes == 90)
        #expect(AwakeDuration.indefinite.storedMinutes == 0)
        #expect(AwakeDuration.until(t0).storedMinutes == 0)
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)) ?? t0
    }

    @Test func nextOccurrenceLaterToday() {
        let d = AwakeDuration.nextOccurrence(hour: 17, minute: 30, after: date(2026, 10, 31, 9, 0), calendar: utc)
        #expect(d == .until(date(2026, 10, 31, 17, 30)))
    }

    @Test func nextOccurrencePastTimeMeansTomorrow() {
        let d = AwakeDuration.nextOccurrence(hour: 7, minute: 0, after: date(2026, 10, 31, 23, 15), calendar: utc)
        #expect(d == .until(date(2026, 11, 1, 7, 0)))
    }

    @Test func nextOccurrenceIsStrictlyAfterNow() {
        let d = AwakeDuration.nextOccurrence(hour: 7, minute: 0, after: date(2026, 12, 31, 7, 0), calendar: utc)
        #expect(d == .until(date(2027, 1, 1, 7, 0)))
    }
}

@Suite("TimeFormat")
struct TimeFormatTests {
    @Test func countdown() {
        #expect(TimeFormat.countdown(0) == "0:00")
        #expect(TimeFormat.countdown(-12) == "0:00")
        #expect(TimeFormat.countdown(42) == "0:42")
        #expect(TimeFormat.countdown(59.2) == "1:00")      // rounds up: never shows 0:00 with time left
        #expect(TimeFormat.countdown(12 * 60 + 3) == "12:03")
        #expect(TimeFormat.countdown(3723) == "1:02:03")
    }

    @Test func compact() {
        #expect(TimeFormat.compact(0) == "<1m")
        #expect(TimeFormat.compact(59) == "<1m")
        #expect(TimeFormat.compact(60) == "1m")
        #expect(TimeFormat.compact(61) == "2m")
        #expect(TimeFormat.compact(42 * 60) == "42m")
        #expect(TimeFormat.compact(3600) == "1h")
        #expect(TimeFormat.compact(3600 + 5 * 60) == "1h 5m")
        #expect(TimeFormat.compact(2 * 3600) == "2h")
    }

    @Test func humanLongMentionsTheNumbers() {
        #expect(TimeFormat.humanLong(7 * 60).contains("7"))
        #expect(TimeFormat.humanLong(-1).contains("0"))
    }
}

@Suite("TickPlanner")
struct TickPlannerTests {
    @Test func asleepWithPanelClosedRunsNoTimerAtAll() {
        let plan = TickPlanner.plan(.init(now: t0))
        #expect(plan == TickPlan(everySecond: false, nextDeadline: nil))
    }

    @Test func panelVisibleTicksEverySecond() {
        #expect(TickPlanner.plan(.init(now: t0, panelVisible: true)).everySecond)
    }

    @Test func longTimedHoldWakesAtTheFirstInterestingMoment() {
        // 2 h left, menu bar "last 10 min", no Dock: nothing to redraw until 10 minutes before the end.
        let end = t0.addingTimeInterval(7200)
        let plan = TickPlanner.plan(.init(now: t0, timedEnd: end, timedStart: t0, menuBarTimer: .lastTenMinutes))
        #expect(!plan.everySecond)
        #expect(plan.nextDeadline == end.addingTimeInterval(-600))
    }

    @Test func dockPillNeedsMinuteBoundaries() {
        let end = t0.addingTimeInterval(7200 + 25)
        let plan = TickPlanner.plan(.init(now: t0, timedEnd: end, timedStart: t0, menuBarTimer: .off, showInDock: true))
        #expect(plan.nextDeadline == t0.addingTimeInterval(25))
    }

    @Test func menuBarOffAndNoDockOnlyNeedsHeadsUpAndEnd() {
        let end = t0.addingTimeInterval(3600)
        let plan = TickPlanner.plan(.init(now: t0, timedEnd: end, timedStart: t0, menuBarTimer: .off))
        #expect(plan.nextDeadline == end.addingTimeInterval(-300))
        let fired = TickPlanner.plan(.init(now: t0, timedEnd: end, timedStart: t0, endingSoonFired: true, menuBarTimer: .off))
        #expect(fired.nextDeadline == end.addingTimeInterval(-60))
    }

    @Test func shortHoldsGetNoHeadsUp() {
        let end = t0.addingTimeInterval(240)
        let plan = TickPlanner.plan(.init(now: t0, timedEnd: end, timedStart: t0, menuBarTimer: .off))
        #expect(plan.nextDeadline == end.addingTimeInterval(-60))
        #expect(!TickPlanner.endingSoonApplies(start: t0, end: end))
        #expect(TickPlanner.endingSoonApplies(start: t0, end: t0.addingTimeInterval(301)))
        #expect(TickPlanner.endingSoonApplies(start: nil, end: end))
    }

    @Test func finalMinuteTicksEverySecond() {
        let end = t0.addingTimeInterval(60)
        let plan = TickPlanner.plan(.init(now: t0, timedEnd: end, timedStart: t0.addingTimeInterval(-3600),
                                          endingSoonFired: true, menuBarTimer: .off))
        #expect(plan.everySecond)
        #expect(plan.nextDeadline == end)
    }

    @Test func pastDeadlinesAreIgnored() {
        let plan = TickPlanner.plan(.init(now: t0, extraDeadlines: [t0.addingTimeInterval(-1), t0, t0.addingTimeInterval(9)]))
        #expect(plan.nextDeadline == t0.addingTimeInterval(9))
    }

    @Test func minuteBoundaries() {
        let end = t0.addingTimeInterval(125)
        #expect(TickPlanner.nextMinuteBoundary(end: end, now: t0) == t0.addingTimeInterval(5))          // "3m" → "2m"
        #expect(TickPlanner.nextMinuteBoundary(end: t0.addingTimeInterval(120), now: t0) == t0.addingTimeInterval(60))
        #expect(TickPlanner.nextMinuteBoundary(end: t0.addingTimeInterval(30), now: t0) == t0.addingTimeInterval(30))
        #expect(TickPlanner.nextMinuteBoundary(end: t0, now: t0) == nil)
        // The compact text really does change at each boundary.
        let b = TickPlanner.nextMinuteBoundary(end: end, now: t0) ?? t0
        #expect(TimeFormat.compact(end.timeIntervalSince(b.addingTimeInterval(-0.5))) == "3m")
        #expect(TimeFormat.compact(end.timeIntervalSince(b)) == "2m")
    }

    @Test func minuteTextVisibility() {
        #expect(TickPlanner.showsMinuteText(remaining: 3600, menuBarTimer: .off, showInDock: true))
        #expect(TickPlanner.showsMinuteText(remaining: 3600, menuBarTimer: .always, showInDock: false))
        #expect(!TickPlanner.showsMinuteText(remaining: 601, menuBarTimer: .lastTenMinutes, showInDock: false))
        #expect(TickPlanner.showsMinuteText(remaining: 600, menuBarTimer: .lastTenMinutes, showInDock: false))
        #expect(!TickPlanner.showsMinuteText(remaining: 10, menuBarTimer: .off, showInDock: false))
    }

    @Test func escalations() {
        let since = t0.addingTimeInterval(-3600)
        #expect(TickPlanner.nextEscalation(since: since, fired: [])?.hours == 2)
        #expect(TickPlanner.nextEscalation(since: since, fired: [])?.date == since.addingTimeInterval(7200))
        #expect(TickPlanner.nextEscalation(since: since, fired: [2])?.hours == 8)
        #expect(TickPlanner.nextEscalation(since: since, fired: [2, 8, 24, 72]) == nil)

        let plan = TickPlanner.plan(.init(now: t0, awakeSince: since))
        #expect(plan.nextDeadline == since.addingTimeInterval(7200))

        let longAgo = t0.addingTimeInterval(-25 * 3600)
        #expect(TickPlanner.crossedEscalations(since: longAgo, now: t0, fired: []) == [2, 8, 24])
        #expect(TickPlanner.crossedEscalations(since: longAgo, now: t0, fired: [2, 8]) == [24])
    }
}
