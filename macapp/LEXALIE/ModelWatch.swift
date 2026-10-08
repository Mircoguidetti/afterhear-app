import SwiftUI
import UserNotifications

/// "Use your model" (docs/BRAIN.md § 18.2–18.3, § 14.5–14.9, § 17.4–17.6).
///
/// Your model follows the call, watches the film, listens to the song with you, and picks
/// by itself what you most likely didn't catch, without a tap (the tap stays). Only the text
/// of what's playing goes to the AI, a minute at a time, without names.
/// It never interrupts (decided 01/10): nothing shows up while you watch or listen. It counts,
/// and in the evening it tells you: "6 hard lines heard, 4 understood, 2 maybe not".
/// - Films and songs: a quiz at the end, with the real voice.
/// - Calls: only if you chose Suggestions for this call; otherwise everything waits for tonight.
/// - Songs: hearing an expression again is the second encounter, weighed apart because singers stretch words.
@MainActor
final class ModelWatch: ObservableObject {
    static let shared = ModelWatch()

    enum Kind: String { case video, song, call }

    private struct Spotted: Decodable {
        struct Piece: Decodable {
            let text: String
            let line: String
            let gloss: String
            let meaning: String
            let cause: String
            let level: String
            let likelihood: Double
        }
        let pieces: [Piece]
    }

    private let panel = FloatingPanel(position: .topCenter)
    private var lastSpot = Date.distantPast
    private var spotting = false
    private var session: (kind: Kind, title: String?, start: Date, lastActive: Date)?
    private var spottedKeys = Set<String>()
    private var song: NowPlaying.Song?

    /// Today's count, for the evening (key "2026-10-01": [heard, maybe not]).
    struct Day { var heard = 0; var maybeNot = 0; var understood: Int { max(heard - maybeNot, 0) } }

    static func day(_ date: Date = Date()) -> Day {
        let all = UserDefaults.standard.dictionary(forKey: "modelDays") as? [String: [Int]] ?? [:]
        let v = all[Store.dayKey(date)] ?? []
        return Day(heard: v.first ?? 0, maybeNot: v.count > 1 ? v[1] : 0)
    }

    /// "6 hard lines heard, 4 understood, 2 maybe not", or nil on a day your model didn't listen.
    static func eveningLine(_ date: Date = Date()) -> String? {
        let d = day(date)
        guard d.heard > 0 else { return nil }
        return d.heard == 1 ? String(localized: "Your model today: 1 hard line heard, \(d.understood) understood, \(d.maybeNot) maybe not.") : String(localized: "Your model today: \(d.heard) hard lines heard, \(d.understood) understood, \(d.maybeNot) maybe not.")
    }

    private func count(heard: Int, maybeNot: Int) {
        var all = UserDefaults.standard.dictionary(forKey: "modelDays") as? [String: [Int]] ?? [:]
        let key = Store.dayKey(Date())
        let old = all[key] ?? [0, 0]
        all[key] = [(old.first ?? 0) + heard, (old.count > 1 ? old[1] : 0) + maybeNot]
        // A month is enough for the evening and the weekly story.
        if all.count > 40 { for k in all.keys.sorted().prefix(all.count - 40) { all[k] = nil } }
        UserDefaults.standard.set(all, forKey: "modelDays")
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Key.useModel) }

    /// "Watch with me" from the menu: your model on, silent until the end (§ 19.8).
    func setWatching(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Key.useModel)
        if on { lastSpot = .distantPast }
        objectWillChange.send()
    }

    /// Where you are, for signals and moments ("song" when music is playing and you're not in a call).
    @Published private(set) var kind: Kind?
    private(set) var songLabel: String?

    /// Every 15 seconds, while LEXALIE listens.
    func tick() async {
        let model = AppModel.shared
        guard model.state == .listening else { return }
        let now = Date()
        let context = ContextDetector.current()
        let playing = context == .call ? nil : NowPlaying.current()
        songChanged(to: playing)
        let current: Kind? = context == .call ? .call : context == .video ? .video : playing != nil ? .song : nil
        kind = current
        songLabel = playing?.label
        Memory.shared.context = current?.rawValue

        if let current {
            let title = current == .song ? playing?.label : current == .video ? ContextDetector.show() : CalendarWatch.shared.current?.title
            if session == nil || session?.kind != current {
                if let old = session { await finish(old) }
                session = (current, title, now, now)
                spottedKeys = []
                if current == .video { await Sessions.shared.begin(kind: "video", title: title ?? "", people: []) }
            }
            session?.lastActive = now
            if session?.title == nil { session?.title = title }
            // Going back in a video is a tap (block R): noticed from the words, explained at the end.
            if current == .video {
                let turns = model.recentTurns(seconds: 60)
                RewindWatch.shared.observe(turns, since: now.addingTimeInterval(-60), show: session?.title)
                Sessions.shared.observe(turns, clipStart: now.addingTimeInterval(-60))
                if let title = session?.title { Sessions.shared.retitle(title) }
            }
            // The names and terms you hear, as nodes on this Mac (block MEM): never in songs.
            if current != .song {
                Nodes.shared.scan(model.recentTurns(seconds: 60), since: now.addingTimeInterval(-60), context: current.rawValue,
                                  source: session?.title ?? (current == .call ? String(localized: "a call") : String(localized: "a video")))
            }
            guard enabled else { return }
            if now.timeIntervalSince(lastSpot) >= 60, !spotting { await spot(current) }
        } else if let old = session, now.timeIntervalSince(old.lastActive) > 180 {
            session = nil
            await finish(old)
        }
    }

    // MARK: Spotting

    private func spot(_ kind: Kind) async {
        spotting = true
        defer { spotting = false }
        lastSpot = Date()
        let model = AppModel.shared
        let text = model.theirWords(seconds: 60)
        guard text.split(separator: " ").count >= 12 else { return }
        let store = model.store
        let weak = Memory.shared.weakCauses
        let source = kind == .song ? "song: \(songLabel ?? "")" : kind == .video ? (ContextDetector.show() ?? "a video") : "a work call"
        guard let found: Spotted = try? await CoachClient.post("api/spot", [
            "text": Redactor.redact(text), "source": source,
            "known": Array((Array(store.known) + Memory.shared.knownWell + Memory.shared.dictionary).prefix(500)),
            "watch": Array(Memory.shared.watch.prefix(200)), "weak": weak,
        ]) else { return }
        let new = found.pieces.filter { spottedKeys.insert(Memory.key($0.text)).inserted }
        let fresh = new.filter { $0.likelihood >= 0.55 }
        count(heard: new.count, maybeNot: fresh.count)
        for p in fresh {
            let piece = Piece(text: p.text, heardAs: nil, gloss: p.gloss, meaning: p.meaning, note: "", cause: p.cause, level: p.level)
            model.addModelMoment(piece, line: p.line, kind: kind, show: session?.title)
        }
        // Your model never interrupts, in calls neither: only the tap shows something (owner, 06/10).
    }

    // MARK: Songs

    private func songChanged(to playing: NowPlaying.Song?) {
        guard playing != song else { return }
        song = playing
    }

    // MARK: The quiz

    /// The end of a video or an episode: one card, only if something is worth it (owner, 06/10 night).
    /// "Watch with me" and its quiz notification become this card. Music: only the tap, never a card.
    private func finish(_ s: (kind: Kind, title: String?, start: Date, lastActive: Date)) async {
        guard s.kind == .video else { return }
        await EndCards.afterWatching(title: s.title, since: s.start)
    }

    func quiz(since: Date) -> [Moment] {
        AppModel.shared.store.moments.filter { $0.trigger == "model" && $0.review == nil && $0.date >= since }.sorted { $0.date < $1.date }
    }

    func openQuiz(since: Date) {
        let ids = quiz(since: since).map(\.id)
        guard !ids.isEmpty else { return }
        AppWindows.show(id: "quiz", title: String(localized: "Did you get these?"), width: 480, height: 520) {
            QuizView(ids: ids).environmentObject(AppModel.shared.store)
        }
    }

    /// Every line waiting for an answer, from any session.
    func openAllQuiz() { openQuiz(since: .distantPast) }
}

/// "Did you get it?" with the real voice. Yes = a small win; no = tonight's lesson (§ 14.5).
struct QuizView: View {
    let ids: [UUID]
    @EnvironmentObject private var store: Store
    @State private var index = 0
    @State private var shown = false
    @State private var right = 0

    init(ids: [UUID]) {
        self.ids = ids
    }

    var body: some View {
        let moments = ids.compactMap { id in store.moments.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 16) {
            if Memory.shared.items.count < 40 {
                Text("I still know you a little: the more we watch together, the better I guess.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if index < moments.count {
                let m = moments[index]
                Text("\(index + 1) / \(moments.count)\(m.show.map { " · \($0)" } ?? "")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Button("▶ Listen") { playLine(m, slow: false) }.disabled(store.clipURL(m) == nil)
                    Button("Slow") { playLine(m, slow: true) }.disabled(store.clipURL(m) == nil)
                }
                if shown || store.clipURL(m) == nil {
                    Text("“\(m.transcript)”").font(.title3)
                    if let p = m.pieces.first { Text("Did you get **\(p.text)**?") }
                } else {
                    Button("Show the line") { shown = true }
                }
                Spacer(minLength: 0)
                HStack {
                    Button("No") { answer(m, got: false) }
                    Spacer()
                    Button("Yes, I got it") { answer(m, got: true) }
                        .buttonStyle(.borderedProminent).tint(Brand.accent).foregroundStyle(Brand.onyx)
                }
            } else {
                Text("\(right) of \(moments.count) were already yours.").font(.title2.weight(.semibold))
                Text(right == moments.count ? String(localized: "Your model will guess harder ones next time.") : String(localized: "The others are in tonight's review, with the real voice."))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360, alignment: .topLeading)
        .onAppear { if let first = moments.first { playLine(first, slow: false) } }
    }

    private func playLine(_ m: Moment, slow: Bool) {
        if let turns = m.turns, let i = m.chosen, turns.indices.contains(i) {
            AppModel.shared.play(m, turn: turns[i], slow: slow)
        } else {
            AppModel.shared.play(m, slow: slow)
        }
    }

    private func answer(_ m: Moment, got: Bool) {
        Memory.shared.record(got ? "quiz_yes" : "quiz_no", pieces: m.pieces, moment: m)
        var updated = m
        updated.review = got ? .known : .again
        updated.step = got ? Store.intervals.count : 0
        updated.due = Date()
        store.update(updated)
        if got { right += 1 }
        shown = false
        index += 1
        let next = ids.compactMap { id in store.moments.first { $0.id == id } }
        if index < next.count { playLine(next[index], slow: false) }
    }
}
