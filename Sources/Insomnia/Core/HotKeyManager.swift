import AppKit
import Carbon.HIToolbox
import Observation
import os

/// One global hotkey that toggles (eyes-button semantics). Carbon `RegisterEventHotKey` + an application event handler
/// for `kEventHotKeyPressed`: no Accessibility permission needed (ARCHITECTURE.md "Core/HotKeyManager.swift").
///
/// Rules (UX §4.1): the combo must include ⌘ or ⌃ (macOS 15+ rejects ⌥ / ⌥⇧-only). "That shortcut is taken by another
/// app." only for `eventHotKeyExistsErr`; any other failure says "Couldn't register (code N)".
@MainActor
@Observable
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// nil when registered fine (or nothing to register). Shown under the recorder in Settings ▸ General.
    private(set) var failureMessage: String?
    /// The OSStatus of the last registration attempt (`noErr` when fine).
    private(set) var lastStatus: OSStatus = noErr
    /// What's registered right now, if anything.
    private(set) var registered: (keyCode: UInt32, modifiers: UInt32)?

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var handler: (@MainActor () -> Void)?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private let log = Logger(subsystem: "com.gdeml.Insomnia", category: "hotkey")

    /// "INSM": our hotkey signature.
    private static let signature: OSType = 0x494E_534D
    private static let hotKeyID: UInt32 = 1

    // MARK: Contract

    /// Registers (replacing any previous hotkey). false if the combo is invalid or macOS refused it (`failureMessage`
    /// says why).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) -> Bool {
        unregisterHotKey()
        self.handler = handler
        guard Self.isAllowed(modifiers: modifiers) else {
            lastStatus = OSStatus(paramErr)
            failureMessage = "Include ⌘ or ⌃."
            return false
        }
        guard installHandlerIfNeeded() else { return false }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        lastStatus = status
        guard status == noErr, let ref else {
            failureMessage = Self.message(for: status)
            log.notice("hotkey \(Self.displayString(keyCode: keyCode, modifiers: modifiers), privacy: .public) failed: \(status)")
            return false
        }
        hotKeyRef = ref
        registered = (keyCode, modifiers)
        failureMessage = nil
        return true
    }

    func unregister() {
        unregisterHotKey()
        handler = nil
        failureMessage = nil
        lastStatus = noErr
    }

    // MARK: Settings binding (one line in AppDelegate)

    /// Registers per `Settings.hotKey*` now and whenever they change. `action` runs on each press.
    func bind(to settings: Settings, action: @escaping @MainActor () -> Void) {
        apply(settings, action: action)
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = NotificationCenter.default.addObserver(forName: .insomniaSettingsDidChange, object: settings,
                                                                  queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            guard key == "hotKeyEnabled" || key == "hotKeyCode" || key == "hotKeyModifiers" else { return }
            MainActor.assumeIsolated { self?.apply(settings, action: action) }
        }
    }

    /// While the recorder listens, the current combo must not toggle (Carbon would swallow the key first).
    func setSuspended(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        if on {
            unregisterHotKey()
        } else if let handler, let pending = pendingRegistration {
            register(keyCode: pending.0, modifiers: pending.1, handler: handler)
        }
    }

    @ObservationIgnored private var pendingRegistration: (UInt32, UInt32)?

    private func apply(_ settings: Settings, action: @escaping @MainActor () -> Void) {
        guard settings.hotKeyEnabled else {
            pendingRegistration = nil
            unregister()
            return
        }
        pendingRegistration = (settings.hotKeyCode, settings.hotKeyModifiers)
        handler = action
        guard !suspended else { return }
        register(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers, handler: action)
    }

    // MARK: Carbon plumbing

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            // Application event target: delivered on the main thread by the main run loop.
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == HotKeyManager.signature else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { HotKeyManager.shared.fire() }
            return noErr
        }, 1, &spec, nil, &ref)
        guard status == noErr, let ref else {
            lastStatus = status
            failureMessage = Self.message(for: status)
            return false
        }
        handlerRef = ref
        return true
    }

    private func fire() {
        handler?()
    }

    private func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
    }

    static func message(for status: OSStatus) -> String {
        status == OSStatus(eventHotKeyExistsErr)
            ? "That shortcut is taken by another app." : "Couldn't register (code \(status))."
    }

    // MARK: Pure helpers

    /// ⌘ or ⌃ required (UX §4.1).
    static func isAllowed(modifiers: UInt32) -> Bool {
        modifiers & UInt32(cmdKey) != 0 || modifiers & UInt32(controlKey) != 0
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// "⌃⌥⌘I" in Apple's canonical order (⌃ ⌥ ⇧ ⌘), key name from the current layout.
    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        modifierSymbols(modifiers) + keyName(keyCode)
    }

    /// "⌃⌥⇧⌘" subset, canonical order.
    static func modifierSymbols(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    /// Spoken form for VoiceOver: "Control Option Command I".
    static func spokenString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        parts.append(specialKeyNames[Int(keyCode)]?.spoken ?? keyName(keyCode))
        return parts.joined(separator: " ")
    }

    static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special.symbol }
        return translate(keyCode) ?? "Key \(keyCode)"
    }

    /// Keys whose character from UCKeyTranslate is invisible or misleading.
    private static let specialKeyNames: [Int: (symbol: String, spoken: String)] = [
        kVK_Return: ("↩", "Return"), kVK_Tab: ("⇥", "Tab"), kVK_Space: ("Space", "Space"),
        kVK_Delete: ("⌫", "Delete"), kVK_ForwardDelete: ("⌦", "Forward Delete"), kVK_Escape: ("⎋", "Escape"),
        kVK_LeftArrow: ("←", "Left Arrow"), kVK_RightArrow: ("→", "Right Arrow"),
        kVK_UpArrow: ("↑", "Up Arrow"), kVK_DownArrow: ("↓", "Down Arrow"),
        kVK_Home: ("↖", "Home"), kVK_End: ("↘", "End"), kVK_PageUp: ("⇞", "Page Up"), kVK_PageDown: ("⇟", "Page Down"),
        kVK_Help: ("Help", "Help"), kVK_ANSI_KeypadEnter: ("⌤", "Enter"), kVK_ANSI_KeypadClear: ("⌧", "Clear"),
        kVK_F1: ("F1", "F1"), kVK_F2: ("F2", "F2"), kVK_F3: ("F3", "F3"), kVK_F4: ("F4", "F4"),
        kVK_F5: ("F5", "F5"), kVK_F6: ("F6", "F6"), kVK_F7: ("F7", "F7"), kVK_F8: ("F8", "F8"),
        kVK_F9: ("F9", "F9"), kVK_F10: ("F10", "F10"), kVK_F11: ("F11", "F11"), kVK_F12: ("F12", "F12"),
        kVK_F13: ("F13", "F13"), kVK_F14: ("F14", "F14"), kVK_F15: ("F15", "F15"), kVK_F16: ("F16", "F16"),
        kVK_F17: ("F17", "F17"), kVK_F18: ("F18", "F18"), kVK_F19: ("F19", "F19"), kVK_F20: ("F20", "F20"),
    ]

    /// The character the key types on the current keyboard layout, uppercased ("I", "Ö", "1").
    private static func translate(_ keyCode: UInt32) -> String? {
        guard keyCode < 128 else { return nil }   // virtual key codes are 7-bit
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout -> String? in
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s.uppercased()
        }
    }
}
