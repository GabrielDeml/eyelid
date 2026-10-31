import Foundation
import Testing
@testable import Insomnia

/// The hooks the integration added on top of the module contracts.
@MainActor
final class RecordingNarrator: Narrating {
    var asked: [Moment] = []
    func line(_ m: Moment, _ p: Personality, now: Date) -> String? {
        asked.append(m)
        switch m {
        case .setupDone: return "done line"
        case .setupCancelled: return "cancelled line"
        default: return nil
        }
    }
    func notification(_ id: NotificationID, _ p: Personality, context: [String: String]) -> (title: String, body: String) {
        ("", "")
    }
}

@Suite("Integration hooks", .serialized)
@MainActor
struct IntegrationHookTests {
    @Test func narrateRoutesSetupMomentsThroughTheNarrator() {
        let h = Harness()
        let narrator = RecordingNarrator()
        h.engine.narrator = narrator
        h.engine.narrate(.setupCancelled)
        #expect(narrator.asked.contains(.setupCancelled))
        #expect(h.engine.quip == "cancelled line")
        h.engine.narrate(.setupDone)
        #expect(h.engine.quip == "done line")
        #expect(h.engine.status == .asleep)   // a quip never changes state
    }

    @MainActor @Test func inlineLinksCarryTheirActionAndSpokenLabel() {
        var s = PanelState()
        s.hasLid = true
        s.lid = .error(.readbackMismatch)
        #expect(PlainCopy.lidSublabel(s)?.link?.action == .lidRetry)
        s.lid = .stuck
        #expect(PlainCopy.lidSublabel(s)?.link?.action == .lidReset)
        s.lid = .off
        s.closedLidMode = true
        let setup = PlainCopy.lidSublabel(s)
        #expect(setup?.link?.action == .lidSetup)
        #expect(setup?.joined == "Setup needed ›")

        var w = PanelState()
        w.status = .watching(.process(name: "ffmpeg"))
        let sub = PlainCopy.subline(w)
        #expect(sub.link?.action == .stopBabysit)
        #expect(sub.link?.accessibilityLabel == "Stop watching ffmpeg")
        #expect(sub.joined == "While ffmpeg runs · Stop")
    }
}
