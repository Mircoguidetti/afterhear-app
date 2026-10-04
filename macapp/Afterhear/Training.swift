import AVFoundation
import AppKit
import SwiftUI

/// Where to go to train the ear you find hardest (docs/BRAIN.md § 5.12, § 5.13, § 5.16):
/// real people talking, watched with Afterhear on, so your model follows along.
enum Watch {
    static let accentQueries: [String: String] = [
        "Scottish": "scottish accent interview conversation",
        "Irish": "irish accent interview conversation",
        "British": "british people talking everyday conversation",
        "American": "american podcast conversation",
        "Australian": "australian accent interview",
        "Indian": "indian english conversation interview",
    ]
    static let causeQueries: [String: String] = [
        "connected_speech": "fast natural english conversation",
        "speed_accent": "fast talking interview",
        "idiom": "british slang explained conversation",
        "numbers": "prices numbers dates listening practice",
        "subtext": "british politeness what they really mean",
    ]

    static func url(accent: String?, cause: String?) -> URL {
        let q = accent.flatMap { accentQueries[$0] } ?? cause.flatMap { causeQueries[$0] } ?? "natural english conversation"
        var parts = URLComponents(string: "https://www.youtube.com/results")!
        parts.queryItems = [URLQueryItem(name: "search_query", value: q)]
        return parts.url!
    }
}

/// The card before a call, written by the AI from the meeting and your model (§ 5.11).
struct PrepCard: View {
    let call: Call
    @EnvironmentObject private var store: Store
    @State private var card: Card?
    @State private var failed = false

    struct Card: Decodable {
        struct Term: Decodable, Hashable { let term: String; let meaning: String }
        struct Phrase: Decodable, Hashable { let phrase: String; let when: String }
        let focus: String
        let terms: [Term]
        let phrases: [Phrase]
        let listen_for: String
    }

    init(call: Call) {
        self.call = call
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let card {
                Text(card.focus).font(.callout.weight(.medium))
                if !card.listen_for.isEmpty { Label(card.listen_for, systemImage: "ear").font(.callout) }
                if !card.terms.isEmpty {
                    Text("Words you'll probably hear").font(.caption).foregroundStyle(.secondary)
                    ForEach(card.terms, id: \.self) { t in Text("**\(t.term)** · \(t.meaning)").font(.callout) }
                }
                if !card.phrases.isEmpty {
                    Text("Phrases you might need").font(.caption).foregroundStyle(.secondary)
                    ForEach(card.phrases, id: \.self) { p in Text("**\(p.phrase)** · \(p.when)").font(.callout) }
                }
            } else if !failed {
                HStack { ProgressView().controlSize(.small); Text("Preparing your card…").font(.caption).foregroundStyle(.secondary) }
            }
            let accent = call.people.compactMap { store.accent(of: $0) }.first
            Button(accent.map { String(localized: "Warm up your ear · 2 min · \(Person.label($0))") } ?? String(localized: "Warm up your ear · 2 min")) {
                NSWorkspace.shared.open(Watch.url(accent: accent, cause: nil))
            }
            .controlSize(.small)
        }
        .task { await load() }
    }

    private func load() async {
        let missed = CalendarWatch.shared.prep(for: call).flatMap(\.pieces).map(\.text)
        let speaking = Memory.shared.items.values.filter { $0.cause == "speaking" && $0.state != "promoted" }.prefix(8).map(\.text)
        do {
            card = try await CoachClient.post("api/prep", [
                "title": String(call.title.prefix(200)),
                "people": call.people.map { ["name": $0, "accent": store.accent(of: $0) ?? ""] },
                "missed": Array(missed.prefix(20)),
                "speaking": Array(speaking),
            ])
        } catch {
            failed = true
        }
    }
}

/// Your week, in three minutes (§ 5.14): a short conversation with the expressions you
/// missed this week, in the accent you find hardest, spoken by two voices.
@MainActor
final class Podcast: ObservableObject {
    static let shared = Podcast()
    @Published private(set) var status: String?
    /// The episode couldn't be made: said once, the spinner stops, "Try again" (owner, 03/10).
    @Published private(set) var failed = false
    @Published private(set) var script: Script?
    private var player: AVAudioPlayer?

    struct Script: Codable {
        struct Line: Codable, Hashable { let speaker: String; let text: String }
        struct Word: Codable, Hashable { let text: String; let meaning: String }
        let title: String
        let lines: [Line]
        let glossary: [Word]
    }

    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Afterhear/podcasts", isDirectory: true)
    }
    private var weekKey: String {
        let c = Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return "\(c.yearForWeekOfYear ?? 0)-W\(c.weekOfYear ?? 0)"
    }

    func open() {
        AppWindows.show(id: "podcast", title: String(localized: "Your week, in three minutes"), width: 480, height: 560) { PodcastView() }
        Task { await prepare() }
    }

    func prepare() async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("\(weekKey).wav"), text = folder.appendingPathComponent("\(weekKey).json")
        if let data = try? Data(contentsOf: text), let saved = try? JSONDecoder().decode(Script.self, from: data), FileManager.default.fileExists(atPath: audio.path) {
            script = saved
            status = nil
            return
        }
        let store = AppModel.shared.store
        let week = store.moments.filter { $0.date > Date().addingTimeInterval(-7 * 86_400) && $0.label != .badAudio && $0.label != .notAMiss }
        let pieces = Array(Dictionary(week.flatMap(\.pieces).map { (Memory.key($0.text), $0) }, uniquingKeysWith: { a, _ in a }).values.prefix(10))
        failed = false
        guard !pieces.isEmpty else { status = String(localized: "Tap a few moments this week, and your episode will be made from them."); failed = true; return }
        // The accent that costs you the most taps.
        let accent = store.byPerson().compactMap { $0.accent }.first ?? "British"
        do {
            status = String(localized: "Writing your episode…")
            let s: Script = try await CoachClient.post("api/podcast", ["mode": "script", "expressions": pieces.map { ["text": $0.text, "meaning": $0.meaning] }, "accent": accent])
            script = s
            status = String(localized: "Recording the voices…")
            let wav = try await Self.audio(lines: s.lines, accent: accent)
            try wav.write(to: audio)
            try JSONEncoder().encode(s).write(to: text)
            status = nil
        } catch {
            status = String(localized: "Couldn't make the episode right now: \(error.localizedDescription)")
            failed = true
        }
    }

    private static func audio(lines: [Script.Line], accent: String) async throws -> Data {
        let settings = AppSettings.current
        guard let base = URL(string: settings.server) else { throw AfterhearError.server("url") }
        var request = URLRequest(url: base.appendingPathComponent("api/podcast"))
        request.httpMethod = "POST"
        // Two voices for three minutes: the server can take up to five minutes.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        try await ServerAccess.authorize(&request, settings: settings)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": "audio", "accent": accent,
                                                                       "lines": lines.map { ["speaker": $0.speaker, "text": $0.text] }])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AfterhearError.server("podcast") }
        return data
    }

    func play() {
        let audio = folder.appendingPathComponent("\(weekKey).wav")
        if player?.isPlaying == true { player?.pause(); objectWillChange.send(); return }
        if player == nil || player?.url != audio { player = try? AVAudioPlayer(contentsOf: audio) }
        player?.play()
        objectWillChange.send()
    }

    var isPlaying: Bool { player?.isPlaying ?? false }
}

struct PodcastView: View {
    @ObservedObject private var podcast = Podcast.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let script = podcast.script {
                Text(script.title).font(.title2.weight(.semibold))
                if podcast.status == nil {
                    Button(podcast.isPlaying ? String(localized: "Pause") : String(localized: "▶ Play")) { podcast.play() }
                        .buttonStyle(.borderedProminent).tint(Brand.accent).foregroundStyle(Brand.onyx)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(script.lines.enumerated()), id: \.offset) { _, l in
                            Text("**\(l.speaker == "A" ? "Anna" : "Tom"):** \(l.text)").font(.callout)
                        }
                        Divider()
                        ForEach(script.glossary, id: \.self) { w in Text("**\(w.text)** · \(w.meaning)").font(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let status = podcast.status {
                HStack(alignment: .firstTextBaseline) {
                    if !podcast.failed { ProgressView().controlSize(.small) }
                    Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if podcast.failed, podcast.script == nil || status.hasPrefix("Couldn't") {
                    Button("Try again") { Task { await podcast.prepare() } }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 480)
    }
}
