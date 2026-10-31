import Foundation

// MARK: - When does the engine need to wake up? (ARCHITECTURE.md AwakeEngine "Timers"). Pure; unit-tested.
//
// No timer runs while asleep with the panel closed. A 1 Hz tick runs only while the panel is visible or a timed
// hold has ≤ 60 s left; otherwise a single one-shot fires at the next interesting wall-clock moment.

struct TickPlan: Equatable, Sendable {
    /// Run the 1 Hz display tick.
    var everySecond: Bool
    /// The next one-shot re-evaluation, or nil for none.
    var nextDeadline: Date?
}

enum TickPlanner {
    /// Heads-up notification lead time ("ending-soon").
    static let endingSoonLead: TimeInterval = 5 * 60
    /// The 1 Hz tick starts this long before a timed hold ends.
    static let finalCountdown: TimeInterval = 60
    /// `MenuBarTimerStyle.lastTenMinutes` shows text from this long before the end.
    static let lastTenMinutes: TimeInterval = 10 * 60
    /// Escalation moments, in hours of continuous awake (`Moment.awake(hours:)`).
    static let escalationHours = [2, 8, 24, 72]

    struct Input: Equatable, Sendable {
        var now: Date
        var panelVisible = false
        /// The manual hold's end, when it is timed.
        var timedEnd: Date?
        /// The manual hold's start (to know whether an ending-soon heads-up makes sense at all).
        var timedStart: Date?
        /// The heads-up for `timedEnd` was already posted.
        var endingSoonFired = false
        var menuBarTimer: MenuBarTimerStyle = .lastTenMinutes
        var showInDock = false
        /// Start of the current continuous-awake stretch, if awake.
        var awakeSince: Date?
        var escalationsFired: Set<Int> = []
        /// Anything else the engine must re-evaluate at (Policy.recheckAt, lid cap deadlines).
        var extraDeadlines: [Date] = []
    }

    static func plan(_ input: Input) -> TickPlan {
        let now = input.now
        var candidates = input.extraDeadlines

        var everySecond = input.panelVisible
        if let end = input.timedEnd {
            let remaining = end.timeIntervalSince(now)
            if remaining <= finalCountdown { everySecond = true }

            candidates.append(end)
            candidates.append(end.addingTimeInterval(-finalCountdown))
            if !input.endingSoonFired, endingSoonApplies(start: input.timedStart, end: end) {
                candidates.append(end.addingTimeInterval(-endingSoonLead))
            }
            if input.menuBarTimer == .lastTenMinutes {
                candidates.append(end.addingTimeInterval(-lastTenMinutes))
            }
            if showsMinuteText(remaining: remaining, menuBarTimer: input.menuBarTimer, showInDock: input.showInDock),
               let boundary = nextMinuteBoundary(end: end, now: now) {
                candidates.append(boundary)
            }
        }
        if let since = input.awakeSince, let next = nextEscalation(since: since, fired: input.escalationsFired) {
            candidates.append(next.date)
        }

        let next = candidates.filter { $0 > now }.min()
        return TickPlan(everySecond: everySecond, nextDeadline: next)
    }

    /// A heads-up only makes sense for holds longer than the lead time itself.
    static func endingSoonApplies(start: Date?, end: Date) -> Bool {
        guard let start else { return true }
        return end.timeIntervalSince(start) > endingSoonLead
    }

    /// Whether the menu bar or Dock currently shows minute-resolution countdown text for a timed hold.
    static func showsMinuteText(remaining: TimeInterval, menuBarTimer: MenuBarTimerStyle, showInDock: Bool) -> Bool {
        if showInDock { return true }   // the Dock pill always shows a timed hold's remaining time
        switch menuBarTimer {
        case .off: return false
        case .always: return true
        case .lastTenMinutes: return remaining <= lastTenMinutes
        }
    }

    /// `TimeFormat.compact` rounds remaining time up to whole minutes, so its text changes exactly when the remaining
    /// time crosses a multiple of 60 s: at `end − k·60`. Returns the next such moment strictly after `now`.
    static func nextMinuteBoundary(end: Date, now: Date) -> Date? {
        let remaining = end.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        // Largest multiple of 60 strictly below `remaining`.
        let k = (remaining / 60).rounded(.up) - 1
        return end.addingTimeInterval(-k * 60)
    }

    /// The next escalation threshold (hours) not yet fired, with its date.
    static func nextEscalation(since: Date, fired: Set<Int>) -> (hours: Int, date: Date)? {
        for hours in escalationHours where !fired.contains(hours) {
            return (hours, since.addingTimeInterval(TimeInterval(hours) * 3600))
        }
        return nil
    }

    /// Thresholds crossed by `now` that haven't fired yet, ascending.
    static func crossedEscalations(since: Date, now: Date, fired: Set<Int>) -> [Int] {
        let elapsed = now.timeIntervalSince(since)
        return escalationHours.filter { !fired.contains($0) && elapsed >= TimeInterval($0) * 3600 }
    }
}
