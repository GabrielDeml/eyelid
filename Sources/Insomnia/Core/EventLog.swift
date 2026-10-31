import Foundation
import Observation
import os

/// In-memory ring of the last 200 events (engine, lid, guard, URL, CLI, watch), shown in Settings ▸ Diagnostics and
/// mirrored to the unified log (`os.Logger`, subsystem `com.gdeml.Insomnia`, category = the event kind).
/// ARCHITECTURE.md "Core/EventLog.swift". Nothing is written to disk.
@MainActor
@Observable
final class EventLog: EventLogging {
    static let shared = EventLog()

    struct Entry: Identifiable, Equatable, Sendable {
        /// Monotonic sequence number (stable SwiftUI identity even after the ring drops old entries).
        let id: Int
        let date: Date
        /// Short category: "engine", "lid", "guard", "notify", "watch", "url", "cli", …
        let kind: String
        let message: String
    }

    /// Oldest first.
    private(set) var entries: [Entry] = []

    @ObservationIgnored let capacity: Int
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let mirrorsToSystemLog: Bool
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var loggers: [String: Logger] = [:]

    init(capacity: Int = 200, mirrorsToSystemLog: Bool = true, clock: @escaping @MainActor () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.mirrorsToSystemLog = mirrorsToSystemLog
        self.clock = clock
    }

    func log(_ kind: String, _ message: String) {
        let kind = kind.isEmpty ? "app" : kind
        entries.append(Entry(id: nextID, date: clock(), kind: kind, message: message))
        nextID += 1
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        if mirrorsToSystemLog { logger(for: kind).info("\(message, privacy: .public)") }
    }

    func clear() {
        entries.removeAll()
    }

    /// Plain text for Copy (Diagnostics) and bug reports: one line per entry, oldest first, with full date.
    func text() -> String {
        entries.map { Self.line($0, dateStyle: .full) }.joined(separator: "\n")
    }

    enum DateStyle { case time, full }

    /// "15:01:12  lid  engaged (readback ✓)". `.full` prefixes the date ("2026-10-31 15:01:12").
    static func line(_ e: Entry, dateStyle: DateStyle = .time) -> String {
        let stamp = dateStyle == .time ? timeFormatter.string(from: e.date) : fullFormatter.string(from: e.date)
        return "\(stamp)  \(e.kind)  \(e.message)"
    }

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    // MARK: Private

    private func logger(for kind: String) -> Logger {
        if let l = loggers[kind] { return l }
        let l = Logger(subsystem: "com.gdeml.Insomnia", category: kind)
        loggers[kind] = l
        return l
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
