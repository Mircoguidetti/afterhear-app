import AppKit
import SwiftUI

/// `Afterhear --selftest`, run by GitHub on a Mac after every build (docs/PIANO.md, block D):
/// the inner pieces checked one by one, then every window opened with example moments. A window
/// that takes the app down kills this run, so the version isn't published (05/10: Settings
/// crashed on the owner's Mac because nothing had opened it before him).
/// Results go to $SELFTEST_OUT (one JSON line per check, written as it goes) and to stdout.
@MainActor
enum SelfTest {
    private static var failed = 0
    private static let out: URL = {
        let path = ProcessInfo.processInfo.environment["SELFTEST_OUT"] ?? NSTemporaryDirectory() + "afterhear-selftest.jsonl"
        FileManager.default.createFile(atPath: path, contents: nil)
        return URL(fileURLWithPath: path)
    }()

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failed += 1 }
        let line = (try? JSONSerialization.data(withJSONObject: ["check": name, "ok": ok, "detail": detail])) ?? Data()
        if let handle = try? FileHandle(forWritingTo: out) {
            handle.seekToEndOfFile()
            handle.write(line + "\n".data(using: .utf8)!)
            try? handle.close()
        }
        print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " · " + detail))
        fflush(stdout)
    }

    static func run() async {
        AppSettings.registerDefaults()
        pieces()
        let samples = addExamples()
        await windows(samples)
        for id in samples { AppModel.shared.store.delete(id) }
        check("done", true, failed == 0 ? "all passed" : "\(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: The inner pieces

    private static func pieces() {
        let redacted = Redactor.redact("Call Sarah at 07700 900123 about the 4,500 pound invoice")
        check("names and numbers never leave", !redacted.contains("07700") && !redacted.contains("900123"), redacted)

        let messages = Set([HeardLanguage.enGB, .itIT, .esES, .frFR, .deDE, .ruRU, .ptBR].map { ParticipantNotice.message(for: $0) })
        check("message for the others in 7 languages", messages.count == 7)
        check("message in the call's language", ParticipantNotice.message(for: .itIT).hasPrefix("Uso Afterhear"))

        let rule = NeverCalls.Rule(kind: .app, value: "us.zoom.xos")
        NeverCalls.add(rule)
        check("never in these calls: an app", NeverCalls.match(call: nil, app: "us.zoom.xos") != nil)
        check("never in these calls: other apps still listened", NeverCalls.match(call: nil, app: "com.microsoft.teams2") == nil)
        NeverCalls.remove(rule)
        check("never in these calls: removed", NeverCalls.match(call: nil, app: "us.zoom.xos") == nil)

        let syllables = EarSignals.syllables("we should probably reschedule the meeting")
        check("speed: syllables counted", (10...14).contains(syllables), "\(syllables)")
        check("speed: reduced forms", EarSignals.reducedForms("I'm gonna ask, d'you know", language: .enGB) == ["d'you", "gonna"])

        // The sentence offered: the tap comes 2 s after "the figures by Friday".
        let start = Date(timeIntervalSince1970: 0)
        func words(_ text: String, from: Double) -> [TimedWord] {
            text.split(separator: " ").enumerated().map { i, w in
                TimedWord(start: start.addingTimeInterval(from + Double(i) * 0.35), end: start.addingTimeInterval(from + Double(i) * 0.35 + 0.3), text: String(w))
            }
        }
        let heard = words("Good morning everyone, thanks for joining.", from: 0)
            + words("So the client wants the figures by Friday at the latest.", from: 6)
        let turns = Conversation.turns(others: heard, mine: [], clipStart: start)
        let first = Conversation.rank(turns, tapAt: 12.5, usualDelay: nil, freshWithin: AppModel.reactionSeconds).first
        check("the tap offers the sentence just missed", first.map { turns[$0.index].text.contains("figures") } ?? false,
              first.map { turns[$0.index].text } ?? "nothing offered")
    }

    // MARK: Example moments, so the windows show rows and not empty pages

    private static func addExamples() -> [UUID] {
        let store = AppModel.shared.store
        let piece = Piece(text: "touch base", heardAs: nil, gloss: "sentirsi", meaning: "to talk briefly to catch up",
                          note: "Very common in offices.", cause: "idiom", level: "B2")
        var ids: [UUID] = []
        for (i, with) in [nil, "Sarah"].enumerated() {
            var m = Moment(date: Date().addingTimeInterval(Double(-i) * 3600), transcript: "Let's touch base after the call.",
                           sent: "Let's touch base after the call.", translation: "Sentiamoci dopo la call.", pieces: [piece],
                           clipFile: nil, provider: "selftest", latencyMs: 1200)
            m.trigger = "selftest"
            m.context = "call"
            m.with = with
            m.turns = [Turn(who: "loro", start: 1, end: 3, text: "Let's touch base after the call.")]
            m.chosen = 0
            m.callGuests = ["Sarah", "Tom", "Priya"]
            m.signals = Signals(syllablesPerSecond: 5.2, overlap: false, snrDb: 18, reduced: [], minutesIntoCall: 3, hour: 10, accent: nil)
            store.add(m)
            ids.append(m.id)
        }
        check("example moments added", ids.allSatisfy { id in store.moments.contains { $0.id == id } })
        return ids
    }

    // MARK: Every window, once

    private static func windows(_ samples: [UUID]) async {
        let store = AppModel.shared.store
        let list: [(String, AnyView)] = [
            ("settings", AnyView(Scenes.settings())),
            ("diary", AnyView(Scenes.diary())),
            ("review", AnyView(Scenes.review())),
            ("menu", AnyView(Scenes.menu())),
            ("lesson after a call", AnyView(ReviewView(only: samples, title: "Self-test").environmentObject(store))),
            ("progress", AnyView(ProgressStoryView())),
            ("is everything ready", AnyView(HealthView())),
            ("permissions", AnyView(PermissionsView())),
            ("welcome", AnyView(OnboardingView(done: {}))),
            ("your week", AnyView(PodcastView())),
        ]
        for (name, view) in list {
            AppWindows.show(id: "selftest-\(name)", title: name, width: 520, height: 640) { view }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            check("window opens: \(name)", true)
        }
    }
}
