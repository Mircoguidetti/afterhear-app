import AppKit
import SwiftUI

/// `LEXALIE --selftest`, run by GitHub on a Mac after every build (docs/PIANO.md, block D):
/// the inner pieces checked one by one, then every window opened with example moments. A window
/// that takes the app down kills this run, so the version isn't published (05/10: Settings
/// crashed on the owner's Mac because nothing had opened it before him).
/// Results go to $SELFTEST_OUT (one JSON line per check, written as it goes) and to stdout.
@MainActor
enum SelfTest {
    private static var failed = 0
    private static let out: URL = {
        let path = ProcessInfo.processInfo.environment["SELFTEST_OUT"] ?? NSTemporaryDirectory() + "lexalie-selftest.jsonl"
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
        await ear()
        let samples = addExamples()
        await windows(samples)
        await SelfTestShots.run()
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
        check("message in the call's language", ParticipantNotice.message(for: .itIT).hasPrefix("Uso LEXALIE"))

        let rule = NeverCalls.Rule(kind: .app, value: "us.zoom.xos")
        NeverCalls.add(rule)
        check("never in these calls: an app", NeverCalls.match(call: nil, app: "us.zoom.xos") != nil)
        check("never in these calls: other apps still listened", NeverCalls.match(call: nil, app: "com.microsoft.teams2") == nil)
        NeverCalls.remove(rule)
        check("never in these calls: removed", NeverCalls.match(call: nil, app: "us.zoom.xos") == nil)

        // The card's shape (07/10): what goes on top, in the fixed order, and the plain card when unsure.
        let shapes = SelfTestShots.cards().map { CardShape.raw($0.1) }
        check("card shape: didn't hear, word, for you, who, tone, plain", shapes == [.heard, .word, .forYou, .who, .tone, .plain], "\(shapes)")
        // Below their bar in the test (07/10), "for you" and "who" show the plain card.
        let shown = SelfTestShots.cards().map { CardShape.of($0.1) }
        check("card shape: only the shapes that passed the test", shown == [.heard, .word, .plain, .plain, .tone, .plain], "\(shown)")
        var unsure = SelfTestShots.cards()[0].1
        unsure.soundsLike = nil
        unsure.signals = Signals(syllablesPerSecond: 3.5, overlap: false, snrDb: 20, reduced: [], minutesIntoCall: nil, hour: 10, accent: nil)
        check("card shape: hearing not confirmed by the Mac gives the plain card", CardShape.of(unsure) == .plain)

        // Your name becomes [tu] before leaving the Mac (P3).
        let before = Redactor.me
        Redactor.me = "Marco"
        let toYou = Redactor.redact("Marco, could you send the deck by Friday?")
        check("your name leaves as [tu]", toYou.contains("[tu]") && !toYou.contains("Marco"), toYou)
        Redactor.me = before

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
        let first = Conversation.offer(turns, tapAt: 12.5, usualDelay: nil, freshWithin: AppModel.reactionSeconds).first
        check("the tap offers the sentence just missed", first.map { turns[$0.index].text.contains("figures") } ?? false,
              first.map { turns[$0.index].text } ?? "nothing offered")
        // Someone starts answering half a second before the tap: still the question first (bench P1).
        let answering = Conversation.turns(others: heard + words("Sure, I", from: 10.4), mine: [], clipStart: start)
        let beforeAnswer = Conversation.offer(answering, tapAt: 11.0, usualDelay: nil, freshWithin: AppModel.reactionSeconds).first
        check("an answer just starting doesn't hide the question", beforeAnswer.map { answering[$0.index].text.contains("figures") } ?? false,
              beforeAnswer.map { answering[$0.index].text } ?? "nothing offered")
    }

    // MARK: The tap with the ear (07/10)

    /// What the ear did, in order, instead of sound: the sequence is checked, not the speakers.
    @MainActor
    final class Recorder: EarOutput {
        var events: [String] = []
        func chime(_ kind: EarFlow.Chime) { events.append(kind == .here ? "chime:here" : "chime:more") }
        func play(_ url: URL, from: Double, to: Double, rate: Float) async {
            events.append(String(format: "play:%.1f", rate))
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, (to - from) / Double(rate)) * 300_000_000))
        }
        func say(_ text: String, language: String) async {
            events.append("say:" + text)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        func stop() { events.append("stop") }
    }

    private static func ear() async {
        let cards = SelfTestShots.cards()
        // What it says, per kind of gap.
        var heard = cards[0].1
        heard.say = nil
        check("ear: not heard says nothing, replays only", EarFlow.plan(for: heard) == EarFlow.Plan(cut: nil, line: nil, moreOnScreen: false))
        var idiom = cards[1].1
        idiom.say = "cambiare le regole quando stai per perdere"
        idiom.cut = "moving the goalposts"
        idiom.wordTimes = [("He's", 0.0, 0.3), ("basically", 0.3, 0.8), ("moving", 0.8, 1.1), ("the", 1.1, 1.2), ("goalposts.", 1.2, 1.8)]
            .map { WordTime(text: $0.0, start: $0.1, end: $0.2) }
        let plan = EarFlow.plan(for: idiom)
        check("ear: a word is cut from the real voice, then its sense", plan.line == idiom.say && plan.cut.map { abs($0.lowerBound - 0.74) < 0.01 && abs($0.upperBound - 1.92) < 0.01 } == true,
              "\(String(describing: plan))")
        var numbers = cards[5].1
        numbers.pieces = [Piece(text: "4,500", heardAs: nil, gloss: nil, meaning: "4500", note: "", cause: "numbers", level: "B1")]
        numbers.say = nil
        numbers.inPractice = nil
        check("ear: numbers stay on the screen, with a sound", EarFlow.plan(for: numbers) == EarFlow.Plan(cut: nil, line: nil, moreOnScreen: true))
        var older = cards[4].1
        older.say = nil
        check("ear: without 'say', the start of In practice", EarFlow.plan(for: older).line?.hasPrefix("non è un complimento") == true,
              EarFlow.plan(for: older).line ?? "none")

        // The sequence, with a recorder instead of the speakers.
        let flow = EarFlow.shared
        let recorder = Recorder()
        let saved = flow.output
        flow.output = recorder
        final class Count { var n = 0 }
        let resumes = Count()
        flow.resume = { resumes.n += 1 }
        var resumed: Int { resumes.n }
        let clip = URL(fileURLWithPath: "/dev/null")
        let turn = Turn(who: "loro", start: 0, end: 1.8, text: idiom.transcript)

        Headphones.override = true
        flow.begin()
        flow.replaySlowly(clip, turn: turn)
        let ms = await flow.finish(idiom, clip: clip, turn: turn)
        check("ear: sound, slower, the word, the line, normal, the video goes on",
              recorder.events == ["chime:here", "play:0.8", "play:1.0", "say:" + (idiom.say ?? ""), "play:1.0"] && resumed == 1,
              recorder.events.joined(separator: " → ") + " · resumed \(resumed)")
        check("ear: the time to come back in is measured", (ms ?? 0) > 0 && (ms ?? 99999) < 10000, "\(ms ?? -1) ms")

        recorder.events = []; resumes.n = 0
        flow.begin()
        flow.replaySlowly(clip, turn: turn)
        _ = await flow.finish(heard, clip: clip, turn: turn)
        check("ear: not heard, the sentence slower then normal, no voice", recorder.events == ["chime:here", "play:0.8", "play:1.0"] && resumed == 1,
              recorder.events.joined(separator: " → "))

        Headphones.override = false
        recorder.events = []; resumes.n = 0
        flow.begin()
        flow.replaySlowly(clip, turn: turn)
        _ = await flow.finish(idiom, clip: clip, turn: turn)
        check("ear: speakers, no voice, a sound says the line is on the screen",
              recorder.events == ["chime:here", "play:0.8", "chime:more", "play:1.0"] && resumed == 1, recorder.events.joined(separator: " → "))

        Headphones.override = true
        recorder.events = []; resumes.n = 0
        flow.begin()
        flow.replaySlowly(clip, turn: turn)
        let skipping = Task { @MainActor in await flow.finish(idiom, clip: clip, turn: turn) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        flow.press(.skip)
        _ = await skipping.value
        check("ear: two presses skip, the video goes on at once", resumed == 1 && !recorder.events.contains { $0.hasPrefix("say:") },
              recorder.events.joined(separator: " → "))

        recorder.events = []; resumes.n = 0
        flow.begin()
        flow.replaySlowly(clip, turn: turn)
        let holding = Task { @MainActor in await flow.finish(idiom, clip: clip, turn: turn) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        flow.press(.more)
        _ = await holding.value
        check("ear: one press is 'more', the video waits with the card", resumed == 0 && flow.held, recorder.events.joined(separator: " → "))

        // The line comes too late: a second sound and the video goes on without it.
        recorder.events = []; resumes.n = 0
        flow.begin()
        flow.replaySlowly(clip, turn: turn)
        try? await Task.sleep(nanoseconds: UInt64((1.8 / 0.8 * 0.3 + EarFlow.patience + 0.6) * 1_000_000_000))
        check("ear: a slow server never keeps the video waiting", flow.gaveUp && resumed == 1 && recorder.events.last == "chime:more",
              recorder.events.joined(separator: " → "))
        let late = await flow.finish(idiom, clip: clip, turn: turn)
        check("ear: the late line doesn't speak over the video", late == nil)

        flow.output = saved
        flow.resume = { AppModel.shared.resumeVideo() }
        Headphones.override = nil

        // The voice of the system in the seven languages (on this Mac, no service).
        let voices = ["it", "en", "es", "fr", "de", "ru", "pt"].map { ($0, Voice.best(for: $0)?.name ?? "none") }
        check("ear: a system voice in English", Voice.best(for: "en") != nil)
        check("ear: system voices here (information)", true, voices.map { "\($0.0): \($0.1)" }.joined(separator: ", "))

        // Ask: the ready questions where you are.
        check("ask: in a call, meant / for me / who", Ask.ready(for: .call, song: false) == [.meant, .forMe, .who])
        check("ask: with a song, who's singing first", Ask.ready(for: .video, song: true).first == .singer)
        check("call line: one line for the card", CallLineView.line(cards[2].1) != nil)
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
