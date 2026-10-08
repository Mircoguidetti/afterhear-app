import AVFoundation
import Speech
import SwiftUI

/// Block INSIEME on the iPhone (owner, 08/10 evening): the same sessions, cards and questions as the
/// Mac, from your account, and "Ask LEXALIE" over all of them, written or said. The Mac listens; the
/// iPhone is where you come back to ask. Your rows only (row level security on the server).
@MainActor
final class Together: ObservableObject {
    static let shared = Together()

    struct SessionRow: Decodable, Identifiable, Hashable {
        let id: String
        let kind: String
        let title: String
        let people: [String]
        let started_at: String

        var date: Date { Together.date(started_at) ?? .distantPast }
    }

    struct Term: Decodable, Hashable {
        let term: String
        let meaning: String
        let isPublic: Bool
        enum CodingKeys: String, CodingKey { case term, meaning, isPublic = "public" }
    }

    struct Card: Decodable, Hashable {
        var sentence: String? = nil
        var why: String? = nil
        var meaning: String? = nil
        var numbers: String? = nil
        var negation: String? = nil
        var terms: [Term]? = nil
        var glossary: String? = nil
    }

    struct MomentRow: Decodable, Identifiable, Hashable {
        let id: String
        let session_id: String
        let source: String
        let quote: String
        let card: Card
        let clip: String?
        let discarded: Bool
    }

    struct Quote: Decodable, Identifiable, Hashable {
        let session_id: String
        let title: String
        let kind: String
        let started_at: String
        let idx: Int
        let sentence: String
        var id: String { "\(session_id):\(idx)" }
    }

    struct Answer: Decodable {
        let found: Bool
        let answer: String
        let quotes: [Quote]
        let reason: String
        let looked_in: [String]?
        let error: String?
    }

    @Published private(set) var sessions: [SessionRow] = []
    @Published private(set) var moments: [String: [MomentRow]] = [:]
    @Published private(set) var loading = false
    @Published var problem: String?
    private var player: AVAudioPlayer?

    // MARK: Reading

    func refresh() async {
        guard let token = await Account.shared.accessToken() else { problem = "Sign in with the account you use on the Mac."; return }
        loading = true
        defer { loading = false }
        do {
            let data = try await Api.rest("GET", "sessions?select=id,kind,title,people,started_at&order=started_at.desc&limit=100", token: token)
            sessions = try JSONDecoder().decode([SessionRow].self, from: data)
            let rows = try await Api.rest("GET", "session_moments?select=id,session_id,source,quote,card,clip,discarded&discarded=eq.false&order=start_s&limit=1000", token: token)
            let all = try JSONDecoder().decode([MomentRow].self, from: rows)
            moments = Dictionary(grouping: all, by: \.session_id)
            problem = nil
            WatchLink.shared.sendCard(latest())
        } catch {
            problem = "Couldn't reach your account. Pull to try again."
        }
    }

    /// The latest card, one line per moment: for the Watch.
    func latest() -> (title: String, lines: [String]) {
        guard let s = sessions.first(where: { !(moments[$0.id] ?? []).isEmpty }) else { return ("", []) }
        let lines = (moments[s.id] ?? []).prefix(6).map { m in
            [m.card.meaning, m.quote].compactMap { $0 }.first { !$0.isEmpty } ?? m.quote
        }
        return (s.title.isEmpty ? Together.kindLabel(s.kind) : s.title, Array(lines))
    }

    // MARK: Asking

    /// "Ask LEXALIE" over all your sessions: the server finds where, then answers with the true sentence.
    func ask(_ question: String) async -> Answer? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let token = await Account.shared.accessToken() else { return nil }
        let now = ISO8601DateFormatter()
        now.timeZone = .current
        guard let answer: Answer = try? await Api.postSigned("api/ask", ["question": String(q.prefix(1000)), "now": now.string(from: Date())], token: token) else { return nil }
        // The question and its answer go to the account too (they teach the profile).
        let row: [String: Any] = ["id": UUID().uuidString.lowercased(), "device": "iphone", "question": String(q.prefix(1000)),
                                  "answer": ["answer": answer.answer], "reason": answer.reason, "session_ids": answer.looked_in ?? []]
        _ = try? await Api.rest("POST", "questions", token: token, body: try JSONSerialization.data(withJSONObject: [row]), prefer: "return=minimal")
        return answer
    }

    // MARK: Voice and changes

    /// The few seconds of voice of a moment, from your account's storage.
    func play(_ m: MomentRow) async {
        guard let clip = m.clip, let token = await Account.shared.accessToken(),
              let url = URL(string: Account.supabaseURL + "/storage/v1/object/authenticated/snippets/" + clip) else { return }
        var request = URLRequest(url: url)
        request.setValue(Account.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let fetched = try? await URLSession.shared.data(for: request),
              (fetched.1 as? HTTPURLResponse)?.statusCode == 200 else { problem = "Couldn't play it now."; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player = try? AVAudioPlayer(data: fetched.0)
        player?.play()
    }

    /// "Not important": gone from the card on every device; the profile learns (on the Mac).
    func discard(_ m: MomentRow) async {
        guard let token = await Account.shared.accessToken() else { return }
        moments[m.session_id]?.removeAll { $0.id == m.id }
        _ = try? await Api.rest("PATCH", "session_moments?id=eq.\(m.id)", token: token, body: try JSONSerialization.data(withJSONObject: ["discarded": true]), prefer: "return=minimal")
    }

    /// "Forget this session": here, on the Mac and everywhere.
    func forget(_ s: SessionRow) async {
        guard let token = await Account.shared.accessToken() else { return }
        sessions.removeAll { $0.id == s.id }
        if let uid = Account.shared.session?.userID {
            let paths = (moments[s.id] ?? []).compactMap(\.clip).filter { $0.hasPrefix(uid + "/") }
            if !paths.isEmpty, let url = URL(string: Account.supabaseURL + "/storage/v1/object/snippets") {
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                request.setValue(Account.publishableKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["prefixes": paths])
                _ = try? await URLSession.shared.data(for: request)
            }
        }
        moments[s.id] = nil
        _ = try? await Api.rest("DELETE", "sessions?id=eq.\(s.id)", token: token)
    }

    // MARK: Words

    nonisolated static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    nonisolated static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "call": "A call"
        case "film": "A film"
        case "podcast": "A podcast"
        case "in_person": "A conversation"
        case "voice_note": "A voice message"
        default: "A video"
        }
    }

    static func label(_ m: MomentRow) -> String {
        if m.source == "asked" { return "They asked you" }
        if m.source == "open" { return "Nobody answered" }
        if m.source == "tap" { return "You tapped here" }
        switch m.card.why ?? "" {
        case "word": return "A word you may not know"
        case "acronym": return "An acronym"
        case "name": return "Who or what it is"
        case "meant": return "What they meant"
        case "numbers": return "The numbers"
        case "negation": return "Careful: a negation"
        case "joke": return "Why they laughed"
        case "speed": return "Said fast"
        default: return "Maybe you missed this"
        }
    }

    static func detail(_ m: MomentRow) -> String {
        var out = [m.card.meaning ?? "", m.card.numbers ?? "", m.card.negation ?? ""]
        for t in m.card.terms ?? [] {
            out.append(t.isPublic ? (t.meaning.isEmpty ? "" : "\(t.term): \(t.meaning)") : "\(t.term): nobody explained it in this session")
        }
        if let g = m.card.glossary, !g.isEmpty { out.append("Explained before: \(g)") }
        return out.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension Api {
    /// The server as the signed-in person (their account decides what "Ask LEXALIE" can read).
    static func postSigned<T: Decodable>(_ path: String, _ body: [String: Any], token: String, timeout: TimeInterval = 60) async throws -> T {
        guard let base = URL(string: K.string(K.server)) else { throw LexalieError.server("url") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let code = K.string(K.code).trimmingCharacters(in: .whitespaces)
        if !code.isEmpty { request.setValue(code, forHTTPHeaderField: "x-lexalie-code") }
        var full = body
        full["native"] = K.string(K.native)
        request.httpBody = try JSONSerialization.data(withJSONObject: full)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LexalieError.server("HTTP \(status)") }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Views

/// The first tab: ask about anything you heard with LEXALIE, by voice or in writing.
struct AskTab: View {
    @EnvironmentObject private var account: Account
    @StateObject private var voice = SpokenAsk()
    @State private var text = ""
    @State private var answer: Together.Answer?
    @State private var asking = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !account.signedIn {
                        Text("Sign in (Settings) with the account you use on the Mac: your sessions are there.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        TextField("Anything you heard, even days ago", text: $text)
                            .focused($focused)
                            .submitLabel(.send)
                            .onSubmit(send)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
                        Button {
                            if voice.listening { voice.stop() } else { voice.start { heard in text = heard; send() } }
                        } label: {
                            Image(systemName: voice.listening ? "stop.circle.fill" : "mic.fill").font(.title2)
                        }
                        .foregroundStyle(Brand.accent)
                        .disabled(!voice.available)
                    }
                    if voice.listening, !voice.heard.isEmpty { Text(voice.heard).font(.footnote).foregroundStyle(.secondary) }
                    if asking { ProgressView() }
                    if failed { Text("Couldn't ask now. Try again in a moment.").font(.footnote).foregroundStyle(.secondary) }
                    if let answer {
                        Text(answer.error == "no_sessions" ? "We haven't listened to anything together yet." : answer.answer)
                            .font(.body)
                        ForEach(answer.quotes) { q in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("“\(q.sentence)”").font(.system(.callout, design: .serif))
                                Text(place(q)).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Ask LEXALIE")
        }
    }

    private func place(_ q: Together.Quote) -> String {
        let when = Together.date(q.started_at).map { $0.formatted(.dateTime.weekday(.wide).hour().minute()) } ?? ""
        return [when, q.title.isEmpty ? Together.kindLabel(q.kind) : q.title].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func send() {
        let q = text
        guard !asking, !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        asking = true
        failed = false
        focused = false
        Task {
            let a = await Together.shared.ask(q)
            answer = a
            failed = a == nil
            asking = false
        }
    }
}

/// Your sessions, newest first: tap one for its card (never the whole transcript: not notes).
struct SessionsTab: View {
    @EnvironmentObject private var together: Together

    var body: some View {
        NavigationStack {
            List {
                if let p = together.problem { Text(p).font(.footnote).foregroundStyle(.secondary) }
                ForEach(together.sessions) { s in
                    NavigationLink(value: s) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.title.isEmpty ? Together.kindLabel(s.kind) : s.title).font(.headline).lineLimit(1)
                            Text(s.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) { Task { await together.forget(s) } }
                    }
                }
            }
            .navigationTitle("Together")
            .navigationDestination(for: Together.SessionRow.self) { SessionCardView(session: $0) }
            .refreshable { await together.refresh() }
            .task { await together.refresh() }
        }
    }
}

struct SessionCardView: View {
    @EnvironmentObject private var together: Together
    let session: Together.SessionRow

    var body: some View {
        List {
            let rows = together.moments[session.id] ?? []
            if rows.isEmpty { Text("No card for this session.").foregroundStyle(.secondary) }
            ForEach(rows) { m in
                VStack(alignment: .leading, spacing: 6) {
                    Text(Together.label(m)).font(.footnote.weight(.semibold)).foregroundStyle(Brand.accent)
                    Text("“\(m.card.sentence ?? m.quote)”").font(.system(.body, design: .serif))
                    let detail = Together.detail(m)
                    if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary) }
                    HStack(spacing: 18) {
                        if m.clip != nil { Button("Replay") { Task { await together.play(m) } } }
                        if m.source != "asked" && m.source != "open" { Button("Not important") { Task { await together.discard(m) } } }
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(session.title.isEmpty ? Together.kindLabel(session.kind) : session.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A question said out loud, recognised on this iPhone only: the voice doesn't leave it.
@MainActor
final class SpokenAsk: ObservableObject {
    @Published var listening = false
    @Published var heard = ""
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer? { SFSpeechRecognizer(locale: Locale(identifier: K.string(K.native))) }
    private var done: ((String) -> Void)?

    var available: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func start(_ onDone: @escaping (String) -> Void) {
        done = onDone
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in if status == .authorized { self.begin() } }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return }
        heard = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        engine.prepare()
        guard (try? engine.start()) != nil else { return }
        listening = true
        task = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result { self.heard = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { self.finish() }
            }
        }
    }

    func stop() { request?.endAudio() }

    private func finish() {
        guard listening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        listening = false
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { done?(text) }
    }
}
