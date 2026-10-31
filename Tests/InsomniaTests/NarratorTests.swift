import Foundation
import Testing
@testable import Insomnia

// Narrator + copy pools: the voice rules of PRODUCT.md §4, enforced in code review AND here.

@MainActor
@Suite("Narrator")
struct NarratorTests {
    private static func settings() -> Settings {
        Settings(defaults: ScratchDefaults.make("Narrator"))
    }

    private static var gmt: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }

    private static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        gmt.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)) ?? Date()
    }

    private static func narrator(seed: UInt64 = 42) -> Narrator {
        Narrator(settings: settings(), calendar: gmt, seed: seed)
    }

    /// A plain weekday afternoon: no date window.
    private static let ordinary = date(2026, 3, 11, 14)

    // MARK: Pool sizes (rule 6)

    @Test(arguments: [Personality.cheeky, .unhinged])
    func poolSizes(_ p: Personality) {
        let total = CopyKind.allCases.reduce(0) { $0 + Copy.pool($1, p).count }
        #expect(total >= 40)
        for (moment, kinds) in CopyKind.mainMoments {
            let n = kinds.reduce(0) { $0 + Copy.pool($1, p).count }
            #expect(n >= 10, "\(p) \(moment) has \(n) lines")
        }
        for kind in CopyKind.allCases {
            #expect(Copy.pool(kind, p).count >= 3, "\(p) \(kind) is a rare moment with < 3 lines")
        }
    }

    // MARK: Professional (rules 7, voice table)

    @Test func professionalIsPlain() {
        for kind in CopyKind.allCases {
            let pool = Copy.pool(kind, .professional)
            if !CopyKind.professionalKinds.contains(kind) {
                #expect(pool.isEmpty, "\(kind) is never shown in Professional: no line")
            } else {
                #expect((1...2).contains(pool.count), "\(kind): Professional has one or two lines")
            }
            for line in pool {
                #expect(!line.contains("!"), "no exclamation marks: \(line)")
                #expect(!Self.hasEmoji(line), "no emoji: \(line)")
            }
        }
    }

    /// Professional has no quip row, so `line()` is nil for every moment (and never spends the quip budget).
    @Test func professionalReturnsNilForEveryMoment() {
        let n = Self.narrator()
        let moments: [Moment] = [.idle, .awake(hours: 2), .awake(hours: 72), .poke(5), .poke(50),
                                 .milestone(hours: 100), .lidReopened, .activated(.minutes(60)), .activated(.indefinite),
                                 .lidEngaged, .deactivated(.user(.panel)), .deactivated(.batteryFloor(percent: 20)),
                                 .watching(.process(name: "ffmpeg")), .guardTripped(.thermal), .recoveredAfterCrash,
                                 .setupDone, .setupCancelled]
        for m in moments {
            #expect(n.line(m, .professional, now: Self.ordinary) == nil, "\(m)")
        }
        #expect(n.sample(.professional) == "Lid mode is on.")
    }

    // MARK: Lint (rules 1, 2, 12)

    @Test(arguments: Personality.allCases)
    func linesAreShortPunctuatedAndKind(_ p: Personality) {
        let bannedWords: Set<String> = ["stupid", "idiot", "dumb", "damn", "hell", "crap", "shit", "fart", "poop", "pee",
                                        "sweat", "sweaty", "lazy", "loser"]
        let bannedPhrases = ["you should", "go to bed", "get some sleep", "you need sleep"]
        for kind in CopyKind.allCases {
            for template in Copy.pool(kind, p) {
                let line = Narrator.fill(template, ["name": "ffmpeg", "floor": "20", "cap": "1 h"])   // no {duration} (R51)
                #expect(!line.contains("{") && !line.contains("}"), "unfilled placeholder: \(line)")
                #expect(line.count <= 95, "too long for two quip lines: \(line)")
                #expect(line.last.map { ".!?)\"…".contains($0) } ?? false, "ends without punctuation: \(line)")
                let lower = line.lowercased()
                let words = Set(lower.split { !$0.isLetter }.map(String.init))
                for word in bannedWords.intersection(words) { Issue.record("banned '\(word)': \(line)") }
                for phrase in bannedPhrases { #expect(!lower.contains(phrase), "guilt trip '\(phrase)': \(line)") }
            }
        }
    }

    @Test func unhingedHasAtMostTwoAllCapsLinesPerPool() {
        for kind in CopyKind.allCases {
            let caps = Copy.pool(kind, .unhinged).filter(Self.isAllCaps).count
            #expect(caps <= 2, "\(kind) has \(caps) ALL-CAPS lines")
        }
        for kind in CopyKind.allCases {
            #expect(Copy.pool(kind, .cheeky).filter(Self.isAllCaps).isEmpty, "Cheeky never shouts: \(kind)")
        }
    }

    // MARK: Rotation (rule 5)

    @Test func shuffleBagEmptiesBeforeRepeatingAndNeverRepeatsBackToBack() {
        var rng = SplitMix64(seed: 7)
        for count in [2, 3, 5, 12] {
            var bag = ShuffleBag(count: count)
            var draws: [Int] = []
            for _ in 0..<(count * 6) { if let i = bag.draw(using: &rng) { draws.append(i) } }
            for round in stride(from: 0, to: draws.count, by: count) {
                #expect(Set(draws[round..<round + count]).count == count, "round \(round / count) repeats a line")
            }
            for (a, b) in zip(draws, draws.dropFirst()) { #expect(a != b, "back-to-back repeat with \(count) lines") }
        }
    }

    @Test func narratorRotatesThroughThePool() {
        let n = Self.narrator(seed: 3)
        let pool = Copy.pool(.deactivatedUser, .cheeky)
        var seen: [String] = []
        for _ in 0..<pool.count { if let l = n.line(.deactivated(.user(.panel)), .cheeky, now: Self.ordinary) { seen.append(l) } }
        #expect(Set(seen).count == pool.count)
    }

    // MARK: Moment mapping and placeholders

    @Test func placeholdersAreFilled() {
        let n = Self.narrator()
        for _ in 0..<12 {
            let line = n.line(.watching(.process(name: "ffmpeg")), .cheeky, now: Self.ordinary) ?? ""
            #expect(line.contains("ffmpeg"), "\(line)")
            let exited = n.line(.deactivated(.targetExited(.pid(4411, name: "make"))), .unhinged, now: Self.ordinary) ?? ""
            #expect(!exited.contains("{"))
        }
        let floor = n.line(.deactivated(.batteryFloor(percent: 15)), .cheeky, now: Self.ordinary) ?? ""
        #expect(!floor.contains("{"), "\(floor)")
    }

    @Test func pokeLinesOnlyAtTheSteps() {
        let n = Self.narrator()
        for count in [5, 10, 20, 50] { #expect(n.line(.poke(count), .cheeky, now: Self.ordinary) != nil) }
        for count in [4, 6, 11, 49, 51] { #expect(n.line(.poke(count), .cheeky, now: Self.ordinary) == nil) }
        #expect(n.line(.poke(50), .cheeky, now: Self.ordinary)?.hasPrefix("Complaint filed.") == true)
    }

    @Test func silentMoments() {
        let n = Self.narrator()
        #expect(n.line(.deactivated(.replaced), .cheeky, now: Self.ordinary) == nil)
        #expect(n.line(.awake(hours: 1), .cheeky, now: Self.ordinary) == nil)
        #expect(n.line(.milestone(hours: 50), .cheeky, now: Self.ordinary) == nil)
    }

    @Test func escalationBuckets() {
        #expect(Narrator.kind(for: .awake(hours: 2)) == .awake2)
        #expect(Narrator.kind(for: .awake(hours: 8)) == .awake8)
        #expect(Narrator.kind(for: .awake(hours: 24)) == .awake24)
        #expect(Narrator.kind(for: .awake(hours: 72)) == .awake72)
        #expect(Narrator.kind(for: .milestone(hours: 1000)) == .milestone1000)
    }

    // MARK: Date lines (rule 10, UX §11)

    @Test func dateWindows() {
        let n = Self.narrator()
        #expect(n.dateKind(at: Self.date(2026, 10, 31, 15)) == .dateHalloween)
        #expect(n.dateKind(at: Self.date(2026, 10, 31, 3, 30)) == .dateHalloween)   // the more special one wins
        #expect(n.dateKind(at: Self.date(2027, 1, 1, 0, 5)) == .dateNewYear)
        #expect(n.dateKind(at: Self.date(2027, 1, 1, 0, 10)) == nil)
        #expect(n.dateKind(at: Self.date(2026, 3, 11, 4, 59)) == .date3am)
        #expect(n.dateKind(at: Self.date(2026, 3, 11, 5, 0)) == nil)
        #expect(n.dateKind(at: Self.ordinary) == nil)
    }

    @Test func halloweenLinesShowAboutAThirdOfTheTimeOncePerWindow() {
        let halloween = Set(Copy.pool(.dateHalloween, .cheeky))
        let day = Self.date(2026, 10, 31, 15)
        // 1 in 3 per eligible moment: over many fresh narrators, about a third show the line on the first try.
        var hits = 0
        let trials = 600
        for seed in 0..<UInt64(trials) {
            if let line = Self.narrator(seed: seed).dateLine(.cheeky, now: day) {
                #expect(halloween.contains(line))
                hits += 1
            }
        }
        #expect(hits > trials / 5 && hits < trials / 2, "\(hits) of \(trials)")
        // At most once per window; `line()` never returns a date line.
        let n = Self.narrator(seed: 11)
        let shown = (0..<60).compactMap { _ in n.dateLine(.cheeky, now: day) }
        #expect(shown.count == 1)
        for _ in 0..<60 { #expect(!halloween.contains(n.line(.activated(.minutes(60)), .cheeky, now: day) ?? "")) }
        // Never on an ordinary day, never in Professional.
        for _ in 0..<60 { #expect(n.dateLine(.cheeky, now: Self.ordinary) == nil) }
        let pro = Set(CopyKind.dateKinds.flatMap { Copy.pool($0, .professional) })
        #expect(pro.isEmpty)
        for _ in 0..<30 { #expect(Self.narrator(seed: 3).dateLine(.professional, now: day) == nil) }
    }

    // MARK: Notifications (rule 3, UX §10)

    @Test func notificationTitlesArePlainInEveryTier() {
        let n = Self.narrator()
        let context = ["floor": "20", "name": "ffmpeg", "cap": "1 h", "minutes": "5"]
        for id in NotificationID.allCases {
            let titles = Set(Personality.allCases.map { n.notification(id, $0, context: context).title })
            #expect(titles.count == 1, "\(id) title changes with personality: \(titles)")
            for p in Personality.allCases {
                let body = n.notification(id, p, context: context).body
                #expect(!body.contains("{"), "\(id) \(p): \(body)")
            }
        }
        #expect(n.notification(.endingSoon, .cheeky, context: ["minutes": "5"]).title == "Insomnia: 5 minutes left")
        #expect(n.notification(.targetExited, .cheeky, context: ["name": "ffmpeg"]).title == "ffmpeg finished")
        #expect(n.notification(.batteryFloor, .unhinged, context: ["floor": "15"]).title == "Lid mode off at 15% battery")
    }

    @Test func safetyBodiesStayPlain() {
        let n = Self.narrator()
        for id in [NotificationID.batteryStop, .lidLPM, .lidCap, .lidError, .lidStuck, .foreignFlag] {
            let bodies = Set(Personality.allCases.map { n.notification(id, $0, context: ["floor": "20", "cap": "1 h"]).body })
            #expect(bodies.count == 1, "\(id) body must be plain in every tier")
            #expect(bodies.first?.isEmpty == false, "\(id) body is blank")
        }
    }

    @Test func plainCopyIsOneSource() {
        var s = PanelState()
        s.status = .indefinite
        #expect(PlainCopy.headline(s) == "Wide awake")
        #expect(FallbackCopy.headline(status: .asleep, lid: .stuck) == "Lid mode is stuck on")
        #expect(PlainCopy.durationName(.minutes(47), .unhinged) == "One more episode")
        #expect(PlainCopy.durationName(.minutes(60), .professional) == nil)
        s.lid = .engaged(lidClosed: false)
        #expect(PlainCopy.accessibilityValue(s) == "Awake until you stop it, lid mode on")
        s.lid = .engaged(lidClosed: true)
        s.closedLidMode = true
        #expect(PlainCopy.lidSublabel(s)?.joined == "Engaged · lid closed")
    }

    // MARK: Helpers

    private static func isAllCaps(_ line: String) -> Bool {
        let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4 else { return false }
        return letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
    }

    private static func hasEmoji(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }
}
