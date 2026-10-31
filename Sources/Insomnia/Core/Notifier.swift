import AppKit
import Foundation
import os
import UserNotifications

/// Local notifications (docs/UX.md §10; ARCHITECTURE.md "Core/Notifier.swift").
///
/// - Never with sound. Banner style. Posting an id replaces the previous notification with that id.
/// - Gating (`sessionNotifications` for ending-soon / ended / target-exited) is the engine's job; this posts what it's
///   given.
/// - Authorization is requested only at the welcome card's "Got it", lid setup success, and when session notifications
///   are switched on. Posts made before macOS has an answer are queued (latest per id), so the first safety
///   notification is never lost; a denial drops the queue.
/// - Inert when the process isn't a real `.app` bundle (`swift test`, the raw binary): UNUserNotificationCenter raises
///   an exception without a bundle proxy.
@MainActor
enum Notifier: NotificationPosting {
    /// Action handlers that live in other modules (M2 ClosedLidController). Assigned by AppDelegate.
    static var retryLidHandler: (() -> Void)?
    static var resetLidHandler: (() -> Void)?

    enum Category: String, CaseIterable {
        case sessionEnding = "SESSION_ENDING"
        case lidHeat = "LID_HEAT"
        case lidError = "LID_ERROR"
        case lidStuck = "LID_STUCK"
        case foreignFlag = "FOREIGN_FLAG"
    }

    enum Action: String, CaseIterable {
        case extend15 = "EXTEND_15"
        case stop = "STOP"
        case retry = "RETRY"
        case reset = "RESET"
        case why = "WHY"
    }

    /// Category per id (only ids with action buttons have one).
    static func category(for id: NotificationID) -> Category? {
        switch id {
        case .endingSoon: return .sessionEnding
        case .lidHeat: return .lidHeat
        case .lidError: return .lidError
        case .lidStuck: return .lidStuck
        case .foreignFlag: return .foreignFlag
        default: return nil
        }
    }

    private enum Authorization { case unknown, notDetermined, allowed, denied }

    private static var authorization = Authorization.unknown
    private static var queue: [NotificationID: (title: String, body: String)] = [:]
    private static var queueOrder: [NotificationID] = []
    private static var isSetUp = false
    private static let log = Logger(subsystem: "com.gdeml.Insomnia", category: "notify")

    /// True only inside a real app bundle with an identifier.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private static var center: UNUserNotificationCenter? { isAvailable ? UNUserNotificationCenter.current() : nil }

    // MARK: Setup

    /// Sets the center's delegate (inert outside a real `.app`). Call in `applicationWillFinishLaunching`; the caller
    /// keeps `delegate` alive (the center holds it weakly).
    static func attach(_ delegate: NotificationDelegate) {
        center?.delegate = delegate
    }

    /// Registers the categories and reads the current authorization (no prompt). Call once at launch, after the
    /// delegate is set.
    static func setUp() {
        guard !isSetUp, let center else { return }
        isSetUp = true
        center.setNotificationCategories(makeCategories())
        refreshAuthorization()
    }

    /// Asks once (macOS remembers the answer). `.alert` and `.badge` only: never sound.
    static func requestAuthorization() {
        guard let center else { return }
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                Logger(subsystem: "com.gdeml.Insomnia", category: "notify")
                    .error("authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                authorization = granted ? .allowed : .denied
                drainQueue()
            }
        }
    }

    private static func refreshAuthorization() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                switch status {
                case .authorized, .provisional, .ephemeral: authorization = .allowed
                case .denied: authorization = .denied
                case .notDetermined: authorization = .notDetermined
                @unknown default: authorization = .notDetermined
                }
                drainQueue()
            }
        }
    }

    // MARK: NotificationPosting

    static func post(_ id: NotificationID, title: String, body: String) {
        guard isAvailable else { return }
        switch authorization {
        case .allowed:
            deliver(id, title: title, body: body)
        case .denied:
            log.info("notification \(id.rawValue, privacy: .public) dropped: not allowed")
        case .unknown, .notDetermined:
            enqueue(id, title: title, body: body)
            if !isSetUp { setUp() }
        }
    }

    static func clear(_ id: NotificationID) {
        if queue.removeValue(forKey: id) != nil { queueOrder.removeAll { $0 == id } }
        guard let center else { return }
        center.removeDeliveredNotifications(withIdentifiers: [id.rawValue])
        center.removePendingNotificationRequests(withIdentifiers: [id.rawValue])
    }

    // MARK: Queue

    private static func enqueue(_ id: NotificationID, title: String, body: String) {
        queue[id] = (title, body)
        queueOrder.removeAll { $0 == id }
        queueOrder.append(id)
    }

    private static func drainQueue() {
        switch authorization {
        case .allowed:
            let pending = queueOrder.compactMap { id in queue[id].map { (id, $0) } }
            queue = [:]
            queueOrder = []
            for (id, copy) in pending { deliver(id, title: copy.title, body: copy.body) }
        case .denied:
            queue = [:]
            queueOrder = []
        case .unknown, .notDetermined:
            break
        }
    }

    private static func deliver(_ id: NotificationID, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil                                   // never with sound (UX §10)
        content.threadIdentifier = "insomnia"
        if let category = category(for: id) { content.categoryIdentifier = category.rawValue }
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: id.rawValue, content: content, trigger: nil)
        center.add(request) { error in
            guard let error else { return }
            Logger(subsystem: "com.gdeml.Insomnia", category: "notify")
                .error("post \(id.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeCategories() -> Set<UNNotificationCategory> {
        func action(_ a: Action, _ title: String, foreground: Bool = false) -> UNNotificationAction {
            UNNotificationAction(identifier: a.rawValue, title: title, options: foreground ? [.foreground] : [])
        }
        let stop = action(.stop, "Allow Sleep")
        return [
            UNNotificationCategory(identifier: Category.sessionEnding.rawValue,
                                   actions: [action(.extend15, "+15 min"), stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.lidHeat.rawValue, actions: [stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.lidError.rawValue, actions: [action(.retry, "Retry")],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.lidStuck.rawValue,
                                   actions: [action(.reset, "Reset…", foreground: true)], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.foreignFlag.rawValue,
                                   actions: [action(.why, "Why Awake?", foreground: true)], intentIdentifiers: []),
        ]
    }

    // MARK: Responses (from NotificationDelegate, on the main actor)

    /// `actionIdentifier` is a `Notifier.Action` raw value, or the system default/dismiss identifiers.
    static func handleResponse(actionIdentifier: String, requestIdentifier: String) {
        let engine = AwakeEngine.shared
        switch Action(rawValue: actionIdentifier) {
        case .extend15:
            engine.extend(minutes: 15, source: .notification)
        case .stop:
            engine.deactivate(.user(.notification))
        case .retry:
            if let retryLidHandler { retryLidHandler() } else { AppRouter.shared.openSettings(.lidSafety) }
        case .reset:
            if let resetLidHandler { resetLidHandler() } else { AppRouter.shared.openSettings(.lidSafety) }
        case .why:
            AppRouter.shared.showWhyAwake()
        case nil:
            guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
            // A click on the notification itself: show the thing it's about.
            switch NotificationID(rawValue: requestIdentifier) {
            case .lidError, .lidStuck, .lidCap, .lidHeat, .lidLPM, .batteryFloor:
                AppRouter.shared.showPanel()
            case .foreignFlag:
                AppRouter.shared.showWhyAwake()
            default:
                AppRouter.shared.showPanel()
            }
        }
    }
}

/// `UNUserNotificationCenter.delegate`. Strongly retained by AppDelegate and assigned in
/// `applicationWillFinishLaunching` (so a launch from a notification click isn't missed). Uses the completion-handler
/// variants, calls the handler synchronously, then hops to the main actor with only Sendable strings
/// (UNNotification / UNNotificationResponse aren't Sendable).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])   // frontmost: banner only, never sound (UX §10)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let request = response.notification.request.identifier
        completionHandler()
        Task { @MainActor in
            Notifier.handleResponse(actionIdentifier: action, requestIdentifier: request)
        }
    }
}
