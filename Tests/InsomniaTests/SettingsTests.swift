import Foundation
import Testing
@testable import Insomnia

// Settings: defaults, clamping, and the "no notification from init" rule (a post from init re-enters observers
// while `Settings.shared` is still being created, which crashed the first M1 launch with dispatch_once recursion).

/// Collects posted keys (observers run synchronously on the posting thread, here the main actor).
private final class KeyRecorder: @unchecked Sendable {
    var keys: [String] = []
}

@MainActor
@Suite("Settings")
struct SettingsTests {
    private static func freshDefaults() -> UserDefaults {
        ScratchDefaults.make("Settings")
    }

    @Test func initPostsNothingAndWritesNothing() {
        let defaults = Self.freshDefaults()
        defaults.set("abc", forKey: "helperRegisteredCDHash")
        let posted = KeyRecorder()
        let token = NotificationCenter.default.addObserver(forName: .insomniaSettingsDidChange, object: nil, queue: nil) { note in
            posted.keys.append(note.userInfo?["key"] as? String ?? "?")
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let settings = Settings(defaults: defaults)
        #expect(posted.keys.isEmpty)
        #expect(settings.helperRegisteredCDHash == "abc")
        #expect(defaults.object(forKey: "keepScreenOn") == nil)   // defaults are not persisted by init
    }

    @Test func settersPostTheirKey() {
        let settings = Settings(defaults: Self.freshDefaults())
        let posted = KeyRecorder()
        let token = NotificationCenter.default.addObserver(forName: .insomniaSettingsDidChange, object: settings, queue: nil) { note in
            posted.keys.append(note.userInfo?["key"] as? String ?? "?")
        }
        defer { NotificationCenter.default.removeObserver(token) }
        settings.keepScreenOn.toggle()
        settings.batteryFloorPercent = 99
        #expect(posted.keys == ["keepScreenOn", "batteryFloorPercent"])
        #expect(settings.batteryFloorPercent == 50)
    }

    @Test func capsSnapToTheirChoices() {
        let settings = Settings(defaults: Self.freshDefaults())
        settings.lidMaxOnBatteryMinutes = 50
        settings.lidMaxOnACMinutes = 1000
        #expect(settings.lidMaxOnBatteryMinutes == 60)
        #expect(settings.lidMaxOnACMinutes == 720)
    }
}
