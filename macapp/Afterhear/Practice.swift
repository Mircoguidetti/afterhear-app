import SwiftUI

/// Evening practice around one moment (docs/BRAIN.md § 5.6, § 5.8, § 4.5):
/// the enriched lesson, dictation with the real voice, and saying it yourself.
enum LessonClient {
    struct Lesson: Codable, Hashable {
        struct Example: Codable, Hashable { let sentence: String; let translation: String }
        let text: String
        let examples: [Example]
        let variants: [String]
        let usage: String
        let careful: String
    }
    private struct Reply: Decodable { let lessons: [Lesson] }

    /// Made once per expression and kept on this Mac.
    @MainActor private static var cache: [String: Lesson] = {
        guard let data = UserDefaults.standard.data(forKey: "lessons"), let saved = try? JSONDecoder().decode([String: Lesson].self, from: data) else { return [:] }
        return saved
    }()

    @MainActor static func lessons(for pieces: [Piece]) async throws -> [Lesson] {
        let missing = pieces.filter { cache[Memory.key($0.text)] == nil }
        if !missing.isEmpty {
            let reply: Reply = try await CoachClient.post("api/lesson", ["expressions": missing.prefix(10).map { ["text": $0.text, "meaning": $0.meaning] }])
            for lesson in reply.lessons { cache[Memory.key(lesson.text)] = lesson }
            if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: "lessons") }
        }
        return pieces.compactMap { cache[Memory.key($0.text)] }
    }
}

struct PracticeView: View {
    let moment: Moment
    @State private var lessons: [LessonClient.Lesson] = []
    @State private var loading = false
    @State private var error: String?
    @State private var typed = ""
    @State private var checked = false
    @State private var said: String?
    @State private var listening = false

    init(moment: Moment) {
        self.moment = moment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Dictation: write what you hear, then compare, word by word.
            VStack(alignment: .leading, spacing: 6) {
                Text("Write what you hear").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    TextField("Type it, then Check", text: $typed).textFieldStyle(.roundedBorder)
                        .onSubmit { checked = true }
                    Button("Check") { checked = true }.disabled(typed.isEmpty)
                }
                if checked { Text(Self.compare(typed, with: moment.transcript)).font(.callout) }
            }
            // Shadowing: say it after them; your Mac's own recogniser listens.
            VStack(alignment: .leading, spacing: 6) {
                Text("Say it yourself").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    Button(listening ? "Listening…" : "Say it") { Task { await shadow() } }.disabled(listening)
                    if let said {
                        let score = Self.overlap(said, moment.transcript)
                        Text("\(Int(score * 100))% of the words · “\(said)”").font(.callout).foregroundStyle(score > 0.7 ? Brand.accent : .secondary).lineLimit(2)
                    }
                }
            }
            // The enriched lesson.
            if lessons.isEmpty {
                Button(loading ? "Loading…" : "More examples") { Task { await load() } }.disabled(loading || moment.pieces.isEmpty)
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(lessons, id: \.self) { lesson in
                VStack(alignment: .leading, spacing: 4) {
                    Text(lesson.text).font(.headline)
                    ForEach(lesson.examples, id: \.self) { e in
                        Text("“\(e.sentence)”").font(.callout)
                        Text(e.translation).font(.caption).foregroundStyle(.secondary)
                    }
                    if !lesson.variants.isEmpty { Text("Also: " + lesson.variants.joined(separator: " · ")).font(.caption) }
                    if !lesson.usage.isEmpty { Text(lesson.usage).font(.caption).foregroundStyle(.secondary) }
                    if !lesson.careful.isEmpty { Label(lesson.careful, systemImage: "exclamationmark.triangle").font(.caption) }
                }
            }
        }
        .controlSize(.small)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { lessons = try await LessonClient.lessons(for: moment.pieces) } catch { self.error = error.localizedDescription }
    }

    /// Plays the line, then listens to you for a few seconds with the microphone already on.
    private func shadow() async {
        guard AppModel.shared.voiceIsOn else { said = "Turn on “Also listen to my voice” in Settings."; return }
        listening = true
        AppModel.shared.play(moment, slow: false)
        try? await Task.sleep(nanoseconds: UInt64((Double(moment.transcript.split(separator: " ").count) * 0.45 + 5) * 1_000_000_000))
        said = AppModel.shared.myRecentWords(seconds: 7)
        listening = false
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    static func overlap(_ a: String, _ b: String) -> Double {
        let target = words(b), got = Set(words(a))
        guard !target.isEmpty else { return 0 }
        return Double(target.filter(got.contains).count) / Double(target.count)
    }

    /// Your dictation against what was said: missed words shown in [brackets].
    static func compare(_ typed: String, with truth: String) -> AttributedString {
        let got = Set(words(typed))
        var out = AttributedString()
        for w in truth.split(separator: " ") {
            var piece = AttributedString(String(w) + " ")
            if !got.contains(words(String(w)).first ?? "") {
                piece.foregroundColor = .orange
                piece.font = .callout.weight(.semibold)
            }
            out += piece
        }
        return out
    }
}
