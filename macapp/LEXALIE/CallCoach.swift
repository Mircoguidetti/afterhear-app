import AppKit
import SwiftUI
import UserNotifications

/// The server's catch-up and report endpoints (api/catchup.ts, api/report.ts).
enum CoachClient {
    struct CatchUp: Decodable {
        let topic: String
        let last_question: String
        let points: [String]
        let question_to_you: String
    }

    struct Report: Codable {
        struct Missed: Codable { let question: String; let simple: String; let why: String }
        struct OffTopic: Codable { let question: String; let your_answer: String; let they_asked: String }
        struct Request: Codable { let request: String; let when: String }
        struct Hesitation: Codable { let question: String; let language: Bool; let note: String }
        let summary: String
        let missed_questions: [Missed]
        let off_topic: [OffTopic]
        let requests: [Request]
        let hesitations: [Hesitation]
    }

    static func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        let settings = AppSettings.current
        guard let base = URL(string: settings.server.trimmingCharacters(in: .whitespaces)) else { throw LexalieError.server("url") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        // Writing a report or an episode takes the model a while (owner, 03/10: the episode timed out at 15 s).
        request.timeoutInterval = ["api/report", "api/podcast", "api/story", "api/endcard", "api/ask"].contains(path) ? 90 : 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        try await ServerAccess.authorize(&request, settings: settings)
        var full = body
        full["heard"] = settings.heard.rawValue
        full["native"] = settings.native.rawValue
        full["level"] = settings.level
        full["level_reliability"] = LevelEstimate.reliability
        full["provider"] = settings.provider.rawValue
        request.httpBody = try JSONSerialization.data(withJSONObject: full)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw LexalieError.server(code ?? "HTTP \(status)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Help during calls, and the report after them (docs/BRAIN.md § 3, § 4, § 5.2–5.4).
///
/// - "What are they talking about?" (⌃⌥S): two lines near the camera, readable in two seconds.
/// - "They asked me": your name and a question, and the question appears, simply (opt-in).
/// - During a call it keeps only short snippets around signals, on this Mac: a question you
///   hesitated on or answered with "yeah, yeah", your own sentences, a request with your name.
///   Never the call. At the end they become the report: what you missed, what they asked you
///   to do, the phrase you needed, how a native would say what you said.
@MainActor
final class CallCoach: ObservableObject {
    static let shared = CallCoach()

    struct Pair: Codable, Hashable {
        let question: String
        let answer: String
        let pause: Double
        let fillers: Int
    }

    struct Session {
        let id: String
        let title: String
        let people: [String]
        let start: Date
        var lastInCall: Date
        var pairs: [Pair] = []
        var requests: [String] = []
        /// What the others said, for "What they told you to do" at the end (block COSA 7).
        var lines: [String] = []
        var seen: Set<String> = []
        var theirTurns = 0
        var hesitations = 0
        /// The line just before the last laugh LEXALIE heard (SoundAnalysis, on the Mac).
        var laughed: String? = nil
        var lastLaughCheck = Date.distantPast
    }

    private let panel = FloatingPanel(position: .topCenter)
    private var session: Session?
    private var lastHesitation = Date.distantPast
    private var ticking = false

    private static let fillers: Set<String> = ["um", "umm", "uh", "uhm", "erm", "er", "ehm", "hmm", "mm", "well", "like"]
    private static let questionStart = #"^(what|when|where|why|how|who|which|whose|do|does|did|are|is|was|were|can|could|would|will|shall|should|have|has|had|any|so what|and what|right)\b"#
    private static let requestCue = #"\b(can you|could you|would you|will you|please|send|share|follow up|get back|by (monday|tuesday|wednesday|thursday|friday|tomorrow|tonight|eod|end of)|let me know)\b"#
    /// You, looking for a word mid-sentence (§ 4.3).
    private static let genericAnswer = #"^(yeah|yes|yep|sure|right|ok|okay|mm+|uh huh|exactly|absolutely|totally|of course)( (yeah|yes|sure|right|ok|okay|exactly))*[.!]?$"#

    /// Your first name, to notice when someone asks you something. Stays on this Mac.
    var myName: String {
        let typed = UserDefaults.standard.string(forKey: Key.myName)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !typed.isEmpty { return typed }
        return Memory.shared.displayName?.split(separator: " ").first.map(String.init) ?? ""
    }

    private var inCall: Bool {
        ContextDetector.current() == .call || CalendarWatch.shared.current != nil
    }

    // MARK: What are they talking about?

    func catchUp() async {
        let turns = AppModel.shared.recentTurns(seconds: 180)
        guard !turns.isEmpty else {
            panel.show(CatchUpView(lines: [String(localized: "Nothing heard in the last few minutes.")], points: []), autoHide: 3, width: 420)
            return
        }
        panel.show(CatchUpView(lines: [String(localized: "Catching up…")], points: []), autoHide: nil, width: 420)
        do {
            let answer: CoachClient.CatchUp = try await CoachClient.post("api/catchup", ["turns": Self.payload(turns), "mode": "catchup"])
            var lines = [answer.topic]
            if !answer.last_question.isEmpty { lines.append(String(localized: "Last question: \(answer.last_question)")) }
            panel.show(CatchUpView(lines: lines, points: answer.points), autoHide: 10, width: 420)
        } catch {
            panel.show(CatchUpView(lines: [error.localizedDescription], points: []), autoHide: 4, width: 420)
        }
    }

    private static func payload(_ turns: [Turn]) -> [[String: String]] {
        AppModel.syncRedactor()
        return turns.suffix(80).map { ["who": $0.isMine ? "you" : "them", "text": String(Redactor.redact($0.text).prefix(2000))] }
    }

    // MARK: Every few seconds

    func tick() async {
        guard !ticking, AppModel.shared.state == .listening else { return }
        ticking = true
        defer { ticking = false }
        let now = Date()
        if inCall {
            if session == nil {
                let call = CalendarWatch.shared.current
                session = Session(id: call?.id ?? "ctx-\(Int(now.timeIntervalSince1970))", title: call?.title ?? String(localized: "Call"),
                                  people: call?.people ?? [], start: now, lastInCall: now)
                ToldVoice.shared.reset()
                await Sessions.shared.begin(kind: "call", title: call?.title ?? "", people: call?.people ?? [],
                                            deal: Deals.shared.deal(forCall: call?.title ?? "")?.id)
            }
            session?.lastInCall = now
            let turns = AppModel.shared.recentTurns(seconds: 60)
            observe(turns, clipStart: now.addingTimeInterval(-60))
            Sessions.shared.observe(turns, clipStart: now.addingTimeInterval(-60))
            listenForLaughter(now: now)
            // Nothing shows up by itself during a call (owner, 06/10 night): a question put to you is on
            // the card when you tap, and at the end of the call among what is still open for you.
        } else if let s = session, now.timeIntervalSince(s.lastInCall) > 90 {
            session = nil
            await finish(s, ended: s.lastInCall)
        }
    }

    /// Picks the snippets worth keeping from the last minute of turns.
    private func observe(_ turns: [Turn], clipStart: Date) {
        guard var s = session else { return }
        let name = myName.lowercased()
        for (i, turn) in turns.enumerated() {
            let text = turn.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let key = (turn.isMine ? "me:" : "them:") + text.lowercased()
            // A turn still growing is seen again with more words: only count it once it has settled.
            guard turn.end < 57, !s.seen.contains(key) else { continue }
            s.seen.insert(key)
            // Your own sentences are not kept nor judged: LEXALIE is about what you hear (owner, 06/10).
            if turn.isMine { continue }
            s.theirTurns += 1
            if s.lines.count < 400 { s.lines.append(String(text.prefix(1200))) }
            let lower = text.lowercased()
            // A sentence that may ask you something keeps its real voice for the end card's Replay.
            if Told.looksLikeRequest(text) || (!name.isEmpty && lower.contains(name)) { ToldVoice.shared.keep(turn, clipStart: clipStart) }
            if !name.isEmpty, lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .regularExpression) != nil,
               lower.range(of: Self.requestCue, options: .regularExpression) != nil, s.requests.count < 20 {
                s.requests.append(String(text.prefix(600)))
            }
            guard Self.isQuestion(text) else { continue }
            // The first thing you said after their question.
            guard let answer = turns[(i + 1)...].first(where: \.isMine) else { continue }
            let pause = max(0, answer.start - turn.end)
            let firstWords = answer.text.lowercased().split(separator: " ").prefix(6).map { $0.trimmingCharacters(in: .punctuationCharacters) }
            let fillers = firstWords.filter { Self.fillers.contains($0) }.count
            let generic = answer.text.lowercased().trimmingCharacters(in: .whitespaces).range(of: Self.genericAnswer, options: .regularExpression) != nil
            let hesitated = pause >= 4 || fillers >= 2
            guard hesitated || generic, s.pairs.count < 40 else { continue }
            s.pairs.append(Pair(question: String(text.prefix(600)), answer: String(answer.text.prefix(600)), pause: pause, fillers: fillers))
            if hesitated {
                s.hesitations += 1
                // A moment of its own, silently: it goes to tonight's review, where you say
                // whether it was the language or you were just thinking (§ 1.4, § 1.7).
                if Date().timeIntervalSince(lastHesitation) > 60 {
                    lastHesitation = Date()
                    Task { await AppModel.shared.captureMoment(trigger: "hesitation") }
                }
            }
        }
        session = s
    }

    static func isQuestion(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        return t.hasSuffix("?") || t.range(of: questionStart, options: .regularExpression) != nil
    }

    // MARK: Laughter

    /// Every 10 seconds in a call: did they laugh? Then the line just before is "why they laughed" at the
    /// end, but only if it was heard well (a real sentence, not a few broken words).
    private func listenForLaughter(now: Date) {
        guard let s = session, now.timeIntervalSince(s.lastLaughCheck) >= 10 else { return }
        session?.lastLaughCheck = now
        let (voice, rate) = AppModel.shared.recentVoice(seconds: 10)
        guard !voice.isEmpty, ToneMeter.laughter(in: voice, rate: rate) else { return }
        let turns = AppModel.shared.recentTurns(seconds: 25)
        guard let line = turns.last(where: { !$0.isMine && !Ranking.isLaugh($0.text) && $0.text.split(separator: " ").count >= 4 }) else { return }
        session?.laughed = line.text
    }

    // MARK: After the call

    private func finish(_ s: Session, ended: Date) async {
        // No report after the call any more (07/10): the end card is the only one, made on this Mac
        // from the words themselves: a request with your name, a question to you.
        let name = myName.lowercased()
        let open = s.requests + s.pairs.filter { !name.isEmpty && $0.question.lowercased().contains(name) }.map(\.question)
        await EndCards.afterCall(open: open, told: s.lines, since: s.start, laughed: s.laughed, with: s.people, reportID: nil)
    }

    func openReport(_ id: String) {
        guard let saved = Reports.shared.find(id) else { return }
        AppWindows.show(id: "report", title: String(localized: "Your call report"), width: 520, height: 680) {
            ReportView(saved: saved).environmentObject(AppModel.shared.store)
        }
    }
}

/// A call report kept on this Mac (the last 30), and mirrored to your account.
struct SavedReport: Codable, Identifiable {
    let id: String
    let title: String
    let people: [String]
    let start: Date
    let end: Date
    let score: Int
    let turns: Int
    let report: CoachClient.Report?
    /// Your taps in this call, and what got better since the last call with the same people (§ 19.16).
    var taps: Int? = nil
    var improved: [String]? = nil
}

@MainActor
final class Reports {
    static let shared = Reports()
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LEXALIE/reports.json")
    private(set) var all: [SavedReport] = []

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([SavedReport].self, from: data) { all = saved }
    }

    func add(_ report: SavedReport) {
        all.removeAll { $0.id == report.id }
        all.insert(report, at: 0)
        all = Array(all.prefix(30))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(all) { try? data.write(to: url, options: .atomic) }
    }

    func find(_ id: String) -> SavedReport? { all.first { $0.id == id } }

    func clear() {
        all = []
        try? FileManager.default.removeItem(at: url)
    }
}

/// Two lines near the camera: readable in two seconds. Click for the points.
struct CatchUpView: View {
    let lines: [String]
    let points: [String]
    @State private var open = false

    init(lines: [String], points: [String]) {
        self.lines = lines
        self.points = points
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line).font(.system(size: i == 0 ? 15 : 13, weight: i == 0 ? .semibold : .regular))
                    .foregroundStyle(i == 0 ? Brand.paper : Brand.paper.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if open {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    Text("· \(p)").font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !points.isEmpty {
                Text("More ▾").font(.system(size: 11)).foregroundStyle(Brand.accent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.onyx))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.accent.opacity(0.35)))
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
    }
}

/// The report of one call: how much you followed, what they asked you, what you missed,
/// how to say it better. Then the lesson.
struct ReportView: View {
    let saved: SavedReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(saved.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Text(saved.people.isEmpty ? saved.title : ListFormatter.localizedString(byJoining: saved.people)).font(.title2.weight(.semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(saved.score)%").font(.system(size: 34, weight: .semibold)).foregroundStyle(Brand.accent)
                        Text("of the call followed").foregroundStyle(.secondary)
                    }
                    if let summary = saved.report?.summary, !summary.isEmpty { Text(summary) }
                }
                if let improved = saved.improved, !improved.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What you improved since last time").font(.headline)
                        ForEach(improved, id: \.self) { line in
                            Label(line, systemImage: "arrow.up.right").foregroundStyle(Brand.accent)
                        }
                    }
                }
                if let r = saved.report {
                    section(String(localized: "They asked you to"), r.requests.map { ($0.request, $0.when) })
                    section(String(localized: "Questions that slipped past you"), r.missed_questions.map { ($0.question, "\($0.simple) · \($0.why)") })
                    section(String(localized: "You answered something else"), r.off_topic.map { ("“\($0.your_answer)”", String(localized: "They asked: \($0.they_asked)")) })
                } else {
                    Text("The detailed report couldn't be made this time (no connection or no tester code).").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Start the lesson") {
                        if let call = CalendarWatch.shared.calls.first(where: { $0.id == saved.id }) {
                            CalendarWatch.shared.openLesson(call)
                        } else {
                            let ids = AppModel.shared.store.moments.filter { $0.date >= saved.start && $0.date <= saved.end.addingTimeInterval(60) }.map(\.id)
                            AppWindows.show(id: "lesson", title: String(localized: "Your call"), width: 520, height: 640) {
                                ReviewView(only: ids, title: String(localized: "Your call")).environmentObject(AppModel.shared.store)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Brand.accent).foregroundStyle(Brand.onyx)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    @ViewBuilder private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(.system(size: 15, weight: .semibold))
                        if !row.1.isEmpty { Text(row.1).font(.callout).foregroundStyle(.secondary) }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Brand.paper).frame(width: 3) }
                }
            }
        }
    }
}

/// The player's own controls, pressed for you: back a few seconds, with the original voice.
enum VideoControl {
    /// Left arrow: YouTube goes back 5 s per press, Netflix 10 s.
    static func rewind(presses: Int = 2) {
        guard MediaKey.allowed else { MediaKey.askForPermission(); return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<presses {
            CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }
}
