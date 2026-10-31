import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Insomnia

// Pure helpers of the M4 surfaces: hotkey strings, the Dock pill/badge, the night-vision day gate, Settings tabs.

@MainActor
@Suite("Personality & polish")
struct PersonalityPolishTests {
    // MARK: HotKeyManager

    @Test func hotKeyStrings() {
        let mods = UInt32(cmdKey | optionKey | controlKey)
        #expect(HotKeyManager.displayString(keyCode: UInt32(kVK_F5), modifiers: mods) == "⌃⌥⌘F5")
        #expect(HotKeyManager.displayString(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey)) == "⌃⇧Space")
        #expect(HotKeyManager.spokenString(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey)) == "Command Return")
        #expect(HotKeyManager.modifierSymbols(UInt32(shiftKey | cmdKey)) == "⇧⌘")
        #expect(HotKeyManager.keyName(9999).hasPrefix("Key"))   // never traps on an out-of-range code
    }

    @Test func hotKeyRules() {
        #expect(HotKeyManager.isAllowed(modifiers: UInt32(cmdKey)))
        #expect(HotKeyManager.isAllowed(modifiers: UInt32(controlKey | optionKey)))
        #expect(!HotKeyManager.isAllowed(modifiers: UInt32(optionKey)))
        #expect(!HotKeyManager.isAllowed(modifiers: UInt32(optionKey | shiftKey)))
        #expect(HotKeyManager.carbonModifiers(from: [.command, .shift]) == UInt32(cmdKey | shiftKey))
        #expect(HotKeyManager.message(for: OSStatus(eventHotKeyExistsErr)) == "That shortcut is taken by another app.")
        #expect(HotKeyManager.message(for: -50) == "Couldn't register (code -50).")
    }

    // MARK: DockController

    @Test func dockPill() {
        let now = Date()
        #expect(DockController.pill(status: .timed(end: now.addingTimeInterval(2520)), remaining: 2520) == "42m")
        #expect(DockController.pill(status: .timed(end: now.addingTimeInterval(3900)), remaining: 3900) == "1h 5m")
        #expect(DockController.pill(status: .timed(end: now.addingTimeInterval(42)), remaining: 42) == "0:42")
        #expect(DockController.pill(status: .indefinite, remaining: nil) == "∞")
        #expect(DockController.pill(status: .watching(.process(name: "ffmpeg")), remaining: nil) == "ffmp…")
        #expect(DockController.pill(status: .watching(.pid(4411, name: "ffmpeg")), remaining: nil) == "ffmp…")
        #expect(DockController.pill(status: .client(label: "make"), remaining: nil) == "make")
        #expect(DockController.pill(status: .automatic([.onAC]), remaining: nil) == nil)
        #expect(DockController.pill(status: .asleep, remaining: nil) == nil)
        #expect(DockController.pill(status: .suspended(.awakeBatteryFloor), remaining: nil) == nil)
    }

    @Test func dockBadgeOnlyForAlarms() {
        #expect(DockController.badge(.stuck) == "!")
        #expect(DockController.badge(.error(.readbackMismatch)) == "!")
        #expect(DockController.badge(.error(.foreignFlag)) == nil)
        #expect(DockController.badge(.error(.otherUser)) == nil)
        #expect(DockController.badge(.engaged(lidClosed: true)) == nil)
        #expect(DockController.badge(.suspended(.thermal)) == nil)
    }

    @Test func dockHeaderDropsPanelLinks() {
        var watching = PanelState()
        watching.status = .watching(.pid(4411, name: "ffmpeg"))
        #expect(DockController.dockHeader(watching) == "Awake for ffmpeg · While ffmpeg (4411) runs")
        #expect(DockController.dockHeader(PanelState()) == "Sleep allowed")
    }

    // MARK: EpicMoments

    @Test func nightVisionOncePerDay() {
        let d = ScratchDefaults.make("Epic")
        let epic = EpicMoments(settings: Settings(defaults: d), defaults: d)
        let morning = Date(timeIntervalSince1970: 1_790_000_000)
        epic.stateChanged(lid: .off, now: morning)
        epic.stateChanged(lid: .engaged(lidClosed: false), now: morning)
        #expect(epic.nightVisionCount == 1)
        epic.stateChanged(lid: .engaged(lidClosed: true), now: morning)   // still engaged: no new moment
        epic.stateChanged(lid: .off, now: morning)
        epic.stateChanged(lid: .engaged(lidClosed: false), now: morning.addingTimeInterval(3600))
        #expect(epic.nightVisionCount == 1)                                 // same day
        epic.stateChanged(lid: .off, now: morning)
        epic.stateChanged(lid: .engaged(lidClosed: false), now: morning.addingTimeInterval(86_400 * 1.5))
        #expect(epic.nightVisionCount == 2)                                 // next day
    }

    @Test func eyeBagLevels() {
        #expect(EyeBags.level(awakeFor: 23 * 3600) == 0)
        #expect(EyeBags.level(awakeFor: 24 * 3600) == 1)
        #expect(EyeBags.level(awakeFor: 72 * 3600) == 2)
    }

    @Test func missionReportSummary() {
        let r = ReopenReport(closedFor: 72 * 60, batteryStart: 82, batteryEnd: 61, worstThermal: .fair)
        #expect(MissionReportCard.spokenSummary(r) == "While you were away: 1 hour 12 minutes closed, battery 82 to 61 percent, got warm")
    }

    // MARK: Settings tabs

    @Test func settingsTabsPerMac() {
        #expect(SettingsLayout.visibleTabs(hasLid: true, hasBattery: true) == SettingsTab.allCases)
        #expect(SettingsLayout.visibleTabs(hasLid: false, hasBattery: true).contains(.lidSafety))
        #expect(!SettingsLayout.visibleTabs(hasLid: false, hasBattery: false).contains(.lidSafety))
        #expect(SettingsLayout.title(.lidSafety, hasLid: false) == "Safety")
        #expect(SettingsLayout.title(.lidSafety, hasLid: true) == "Lid & Safety")
        #expect(SettingsLayout.resolve(.lidSafety, visible: [.general, .automations, .diagnostics]) == .general)
    }
}
