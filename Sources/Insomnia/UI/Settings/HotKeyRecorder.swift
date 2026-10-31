import AppKit
import SwiftUI

/// Click to record the global hotkey (ARCHITECTURE.md "HotKeyRecorder"). The next key whose modifiers include ⌘ or ⌃
/// becomes the shortcut; ⌥ / ⌥⇧-only combos are refused with "Include ⌘ or ⌃." (macOS 15+ won't register them).
/// Esc cancels, ⌫ clears. While recording, the current hotkey is suspended so pressing it doesn't toggle.
struct HotKeyRecorder: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @Binding var isEnabled: Bool

    @State private var session = RecorderSession()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            session.isRecording ? session.stop() : startRecording()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: session.isRecording ? .regular : .medium))
                .foregroundStyle(session.isRecording || !isEnabled ? .secondary : .primary)
                .frame(minWidth: 110)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(session.isRecording ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: session.isRecording ? 1.5 : 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.isRecording ? "Type a shortcut. Esc cancels, Delete clears." : "Click to record a shortcut")
        .accessibilityLabel("Global hotkey")
        .accessibilityValue(session.isRecording ? "Recording" : spokenValue)
        .accessibilityHint("Press to record a new shortcut. Escape cancels, Delete clears.")
        .onDisappear { session.stop() }
    }

    private var label: String {
        if session.isRecording {
            if session.rejected { return "Include ⌘ or ⌃" }
            let live = HotKeyManager.modifierSymbols(session.liveModifiers)
            return live.isEmpty ? "Type shortcut…" : live + "…"
        }
        return isEnabled ? HotKeyManager.displayString(keyCode: keyCode, modifiers: modifiers) : "Record Shortcut"
    }

    private var spokenValue: String {
        isEnabled ? HotKeyManager.spokenString(keyCode: keyCode, modifiers: modifiers) : "None"
    }

    private func startRecording() {
        session.start { result in
            switch result {
            case .set(let code, let mods):
                keyCode = code
                modifiers = mods
                isEnabled = true
            case .cleared:
                isEnabled = false
            case .cancelled:
                break
            }
        }
    }
}

/// Owns the NSEvent monitor for one recording session.
@MainActor
@Observable
final class RecorderSession {
    enum Result { case set(UInt32, UInt32), cleared, cancelled }

    private(set) var isRecording = false
    private(set) var liveModifiers: UInt32 = 0
    private(set) var rejected = false

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var completion: ((Result) -> Void)?
    /// The window the recorder lives in. Keys for other windows pass through, and the session ends when this window
    /// closes or loses key: SwiftUI doesn't call `onDisappear` when the Settings window only hides (R8).
    @ObservationIgnored private var windowID: ObjectIdentifier?
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []

    func start(_ completion: @escaping (Result) -> Void) {
        start(in: NSApp.keyWindow, completion)
    }

    func start(in window: NSWindow?, _ completion: @escaping (Result) -> Void) {
        stop()
        self.completion = completion
        isRecording = true
        rejected = false
        liveModifiers = 0
        HotKeyManager.shared.setSuspended(true)
        if let window {
            windowID = ObjectIdentifier(window)
            for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stop() }
                })
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Local monitors run on the main thread. Only Sendable values cross into the isolated closure.
            let type = event.type, code = UInt32(event.keyCode), flags = event.modifierFlags
            let eventWindow = event.window.map(ObjectIdentifier.init)
            let swallow = MainActor.assumeIsolated {
                self?.handle(type: type, keyCode: code, flags: flags, window: eventWindow) ?? false
            }
            return swallow ? nil : event
        }
    }

    func stop() {
        finish(.cancelled)
    }

    private func finish(_ result: Result) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        windowID = nil
        let done = completion
        completion = nil
        if isRecording { HotKeyManager.shared.setSuspended(false) }
        isRecording = false
        liveModifiers = 0
        rejected = false
        done?(result)
    }

    /// Returns true to swallow the event. Events for another window (the panel's Esc, ⌘Q) are none of its business.
    func handle(type: NSEvent.EventType, keyCode code: UInt32, flags: NSEvent.ModifierFlags,
                window: ObjectIdentifier?) -> Bool {
        guard isRecording else { return false }
        if let windowID, window != windowID { return false }
        let mods = HotKeyManager.carbonModifiers(from: flags.intersection(.deviceIndependentFlagsMask))
        if type == .flagsChanged {
            liveModifiers = mods
            if mods != 0 { rejected = false }
            return false   // modifier changes pass through untouched
        }
        let bare = flags.intersection([.command, .control, .option, .shift]).isEmpty
        if bare && code == 53 { finish(.cancelled); return true }               // Esc
        if bare && (code == 51 || code == 117) { finish(.cleared); return true } // ⌫ / ⌦
        guard HotKeyManager.isAllowed(modifiers: mods) else {
            rejected = true
            NSSound.beep()
            return true
        }
        finish(.set(code, mods))
        return true
    }
}
