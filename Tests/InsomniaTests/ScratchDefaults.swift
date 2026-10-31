import Foundation

/// Throwaway `UserDefaults` for tests: an in-memory store, so `swift test` never writes a preferences file (a real
/// suite leaves a plist in ~/Library/Preferences that cfprefsd re-creates even after the domain is removed). Never
/// falls back to `.standard`.
enum ScratchDefaults {
    static func make(_ label: String) -> UserDefaults {
        MemoryDefaults(suiteName: "InsomniaTests.\(label).\(UUID().uuidString)")
    }
}

/// Overrides every accessor the app uses; nothing reaches cfprefsd. The suite name is unique, so even an accessor
/// missed here would only read an empty, never-written domain.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Any] = [:]

    init(suiteName: String) {
        super.init(suiteName: suiteName)!   // fails only for a reserved name; ours is a fresh UUID
    }

    override func object(forKey key: String) -> Any? { lock.withLock { store[key] } }

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { store[key] = value }
    }
    override func set(_ value: Bool, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ url: URL?, forKey key: String) { set(url.map { $0 as NSURL }, forKey: key) }
    override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }

    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func url(forKey key: String) -> URL? { object(forKey: key) as? URL }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    override func dictionaryRepresentation() -> [String: Any] { lock.withLock { store } }
    override func removePersistentDomain(forName domainName: String) { lock.withLock { store.removeAll() } }
}
