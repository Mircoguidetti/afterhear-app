import AVFoundation
import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// A word with when it was said.
struct Word: Codable, Hashable {
    let text: String
    let at: Date
    let duration: Double
    /// Said by you (your voice's fingerprint, § 19.25): the evening doesn't offer your own words.
    var mine: Bool? = nil
}

/// What the night found for one time out, waiting for you in the evening review (§ 11.10).
struct Evening: Codable, Identifiable {
    struct Line: Codable, Hashable, Identifiable {
        var id: Date { at }
        let at: Date
        let end: Date
        let text: String
        /// Your own line (told apart by your voice): context, never a candidate.
        var mine: Bool? = nil
    }
    struct Candidate: Codable, Hashable, Identifiable {
        var id = UUID()
        let piece: Piece
        let line: Line
        var clip: String?
    }
    struct Mark: Codable, Identifiable {
        var id: UUID { bookmark.id }
        let bookmark: Bookmark
        /// "Was it one of these?", ordered by your model.
        var candidates: [Candidate]
        /// The whole window, only on this phone, only if none of the candidates was it.
        var lines: [Line]
        var resolved = false
    }
    struct Pause: Codable, Identifiable, Hashable {
        var id: Date { question.at }
        let question: Line
        let seconds: Double
        var resolved = false
    }

    let id: UUID
    let title: String
    let start: Date
    let end: Date
    var marks: [Mark]
    /// Hard pieces heard without a tap (§ 11.8): "did you get this?"
    var unmarked: [Candidate]
    var pauses: [Pause]
    var unmarkedDone: Set<UUID> = []

    var open: Int {
        marks.filter { !$0.resolved }.count + unmarked.filter { !unmarkedDone.contains($0.id) }.count + pauses.filter { !$0.resolved }.count
    }
}

/// "Record light by day, understand at night" (§ 13.3–13.7).
/// On the charger (or when you ask), the iPhone transcribes the kept minutes itself, your model
/// picks the candidates, the AI gets only a few sentences without names, and the evening's audio
/// is deleted: only the hard pieces stay, with a few seconds of the real voice for the review.
@MainActor
final class Night: ObservableObject {
    static let shared = Night()
    static let taskID = "app.lexalie.ios.night"

    @Published private(set) var running = false
    @Published private(set) var progress: String?
    @Published private(set) var evenings: [Evening] = []
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("evenings.json")
    static var clips: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("clips", isDirectory: true) }

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([Evening].self, from: data) { evenings = saved }
        try? FileManager.default.createDirectory(at: Self.clips, withIntermediateDirectories: true)
    }

    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            Task { @MainActor in
                task.expirationHandler = { Task { @MainActor in Night.shared.cancelled = true } }
                await Night.shared.run(auto: true)
                task.setTaskCompleted(success: true)
            }
        }
    }

    private var cancelled = false

    /// Automatic at night: only on the charger, with network (iOS decides the exact moment).
    func schedule() {
        guard K.bool(K.autoNight) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }

    var pending: [OutSession] { Sessions.shared.all.filter { $0.end != nil && !$0.processed && !$0.chunks.isEmpty } }
    var pendingMinutes: Int { pending.reduce(0) { $0 + $1.chunks.count } }

    /// "About 4% of your battery" (§ 13.6): roughly 1% every ten minutes of audio.
    var batteryCost: Int { max(1, Int((Double(pendingMinutes) / 10).rounded(.up))) }
    var battery: Int { Int(max(0, UIDevice.current.batteryLevel) * 100) }
    var charging: Bool { [.charging, .full].contains(UIDevice.current.batteryState) }

    /// "You have 1 evening to transcribe. Now?" when you plug in (§ 13.7), if not automatic.
    func pluggedIn() {
        guard charging, !pending.isEmpty, !running else { return }
        if K.bool(K.autoNight) { schedule(); return }
        let content = UNMutableNotificationContent()
        content.title = "You have \(pending.count) \(pending.count == 1 ? "evening" : "evenings") to transcribe"
        content.body = "On this iPhone, while it charges. Do it now?"
        content.categoryIdentifier = "TRANSCRIBE"
        content.userInfo = ["kind": "transcribe"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "transcribe", content: content, trigger: nil))
    }

    /// Never automatic below 30% (§ 13.6).
    func run(auto: Bool) async {
        guard !running, !pending.isEmpty else { return }
        if auto && !charging && battery < 30 { return }
        // Everything is transcribed on this iPhone by Parakeet (§ 19.25): not here yet, it downloads first.
        guard Private.isDownloaded else {
            await Private.shared.prepare()
            progress = "The private model is downloading (about 0.5 GB, on Wi-Fi). The evening waits for it."
            return
        }
        running = true
        cancelled = false
        defer { running = false }
        await Memory.shared.sync()
        var found = 0
        for session in pending {
            guard !cancelled else { break }
            if let evening = await process(session) {
                evenings.removeAll { $0.id == evening.id }
                evenings.insert(evening, at: 0)
                found += evening.open
                save()
            }
        }
        progress = nil
        await Private.shared.release()
        await Memory.shared.sync()
        guard found > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your evening is ready"
        content.body = "\(found) \(found == 1 ? "thing" : "things") to look at. Over coffee, five minutes."
        content.userInfo = ["kind": "evening"]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "evening", content: content, trigger: nil))
    }

    private func process(_ s: OutSession) async -> Evening? {
        let folder = Sessions.folder(s)
        var words: [Word] = []
        let chunks = s.chunks.sorted { $0.value < $1.value }
        for (i, (name, start)) in chunks.enumerated() {
            guard !cancelled else { return nil }
            progress = "Transcribing \(s.title): \(i + 1) of \(chunks.count) minutes"
            guard let sound = Private.read(folder.appendingPathComponent(name)) else { continue }
            guard let heard = await Private.shared.words(sound, start: start) else { return nil }
            // Your voice, told apart from the others: your lines stay as context, never as candidates.
            let yours = await Private.shared.mine(sound)
            words += heard.map { word in
                var w = word
                let t = word.at.timeIntervalSince(start) + word.duration / 2
                if yours.contains(where: { $0.contains(t) }) { w.mine = true }
                return w
            }
        }
        let lines = Self.lines(words)
        let theirs = lines.filter { $0.mine != true }
        progress = "Your model is looking for what you missed…"

        // Marks: the window before each one, candidates picked by your model (§ 11.9).
        var marks: [Evening.Mark] = []
        for b in s.bookmarks.sorted(by: { $0.at < $1.at }) {
            let window = theirs.filter { $0.end >= b.at.addingTimeInterval(-b.window * 60 - 20) && $0.at <= b.at.addingTimeInterval(8) }
            var candidates: [Evening.Candidate] = []
            if !window.isEmpty, let spotted = try? await Api.spot(window.map(\.text).joined(separator: "\n")) {
                // A tap can come long after the words (§ 19.3): rank what your model found with the signs
                // of a missed line — a question to you, a silence after it, being close to the tap — and keep 3.
                // The same scoring as the Mac (Ranking): close to the tap, a question then a silence,
                // "yeah yeah", a laugh, a change of subject, how well you know it, and what your model says.
                let origin = window[0].at
                let lines = window.map { Ranking.Line(start: $0.at.timeIntervalSince(origin), end: $0.end.timeIntervalSince(origin), text: $0.text, mine: false) }
                let best: (Int) -> Double? = { i in
                    spotted.pieces.filter { Memory.key(window[i].text).contains(Memory.key($0.text)) }.map(\.likelihood).max()
                }
                // A tap much later than usual (a marked minute ago, an "earlier" mark) widens "close".
                let delay = max(2.5, b.window * 60 / 3)
                let scored = Ranking.rank(lines, tapAt: b.at.timeIntervalSince(origin), usualDelay: delay,
                                          hardness: Memory.shared.hardness, likelihood: best)
                let score = Dictionary(uniqueKeysWithValues: scored.map { ($0.index, $0.score) })
                let ranked = spotted.pieces.compactMap { f -> (Evening.Candidate, Double)? in
                    guard let i = window.lastIndex(where: { Memory.key($0.text).contains(Memory.key(f.text)) }) ?? (window.isEmpty ? nil : window.count - 1) else { return nil }
                    let piece = Piece(text: f.text, gloss: f.gloss, meaning: f.meaning, cause: f.cause, level: f.level)
                    return (Evening.Candidate(piece: piece, line: window[i]), (score[i] ?? 0) + 0.2 * f.likelihood)
                }
                candidates = Array(ranked.sorted { $0.1 > $1.1 }.map(\.0).prefix(3))
            }
            marks.append(Evening.Mark(bookmark: b, candidates: candidates, lines: window))
        }

        // The whole evening, if you kept it: hard pieces without a tap (§ 11.8), at most 20 looks.
        var unmarked: [Evening.Candidate] = []
        if s.keepAll {
            var i = 0, looks = 0
            while i < theirs.count && looks < 20 && !cancelled {
                let slice = Array(theirs[i..<min(i + 25, theirs.count)])
                i += 25
                looks += 1
                guard let spotted = try? await Api.spot(slice.map(\.text).joined(separator: "\n")) else { continue }
                for f in spotted.pieces where f.likelihood >= 0.6 {
                    guard let line = slice.first(where: { Memory.key($0.text).contains(Memory.key(f.text)) }) else { continue }
                    // Already a candidate for a mark: not twice.
                    guard !marks.contains(where: { $0.candidates.contains { $0.piece.text == f.text } }) else { continue }
                    unmarked.append(Evening.Candidate(piece: Piece(text: f.text, gloss: f.gloss, meaning: f.meaning, cause: f.cause, level: f.level), line: line))
                }
            }
        }

        // Hesitations (§ 11.5): a question, then a long silence.
        var pauses: [Evening.Pause] = []
        for (i, line) in lines.enumerated() where i + 1 < lines.count && Self.isQuestion(line.text) {
            let gap = lines[i + 1].at.timeIntervalSince(line.end)
            if gap >= 4, !marks.contains(where: { abs($0.bookmark.at.timeIntervalSince(line.at)) < 180 }) {
                pauses.append(Evening.Pause(question: line, seconds: gap))
            }
        }
        pauses = Array(pauses.sorted { $0.seconds > $1.seconds }.prefix(3))

        // What you learned before and heard again without marking: a clean encounter (§ 12.3).
        let near = Set(marks.flatMap { $0.lines.map(\.text) })
        let marked = Set(marks.flatMap { $0.candidates.map { Memory.key($0.piece.text) } } + unmarked.map { Memory.key($0.piece.text) })
        Memory.shared.encounters(in: lines.map(\.text).filter { !near.contains($0) }, except: marked)

        // A few seconds of the real voice for each candidate, then the evening's audio goes (§ 13.4).
        for m in marks.indices {
            for c in marks[m].candidates.indices { marks[m].candidates[c].clip = cut(marks[m].candidates[c].line, from: s) }
        }
        for c in unmarked.indices { unmarked[c].clip = cut(unmarked[c].line, from: s) }
        try? FileManager.default.removeItem(at: folder)
        Sessions.shared.markProcessed(s.id)
        return Evening(id: s.id, title: s.title, start: s.start, end: s.end ?? s.start, marks: marks, unmarked: Array(unmarked.prefix(10)), pauses: pauses)
    }

    /// Words → sentences, split at punctuation or a pause.
    static func lines(_ words: [Word]) -> [Evening.Line] {
        var out: [Evening.Line] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let yours = current.filter { $0.mine == true }.count * 2 > current.count
            out.append(Evening.Line(at: first.at, end: last.at.addingTimeInterval(last.duration),
                                    text: current.map(\.text).joined(separator: " "), mine: yours ? true : nil))
            current = []
        }
        for w in words.sorted(by: { $0.at < $1.at }) {
            if let last = current.last, w.at.timeIntervalSince(last.at.addingTimeInterval(last.duration)) > 1.2 || (last.mine == true) != (w.mine == true) { flush() }
            current.append(w)
            if w.text.hasSuffix(".") || w.text.hasSuffix("?") || w.text.hasSuffix("!") { flush() }
        }
        flush()
        return out
    }

    static func isQuestion(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.hasSuffix("?") || t.range(of: #"^(what|when|where|why|how|who|which|do|does|did|are|is|was|can|could|would|will|have|has)\b"#, options: .regularExpression) != nil
    }

    /// The line and a second either side, from the kept audio, as a small clip.
    private func cut(_ line: Evening.Line, from s: OutSession) -> String? {
        guard let chunk = s.chunks.filter({ $0.value <= line.at }).max(by: { $0.value < $1.value }),
              let file = try? AVAudioFile(forReading: Sessions.folder(s).appendingPathComponent(chunk.key)) else { return nil }
        let start = chunk.value
        let rate = file.processingFormat.sampleRate
        let from = max(0, line.at.timeIntervalSince(start) - 1)
        let length = min(line.end.timeIntervalSince(line.at) + 2, 20)
        let count = AVAudioFrameCount(length * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
        file.framePosition = AVAudioFramePosition(from * rate)
        guard (try? file.read(into: buffer, frameCount: count)) != nil else { return nil }
        let clip = UUID().uuidString + ".m4a"
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        guard let out = try? AVAudioFile(forWriting: Self.clips.appendingPathComponent(clip), settings: settings,
                                         commonFormat: file.processingFormat.commonFormat, interleaved: false),
              (try? out.write(from: buffer)) != nil else { return nil }
        return clip
    }

    func update(_ e: Evening) {
        guard let i = evenings.firstIndex(where: { $0.id == e.id }) else { return }
        evenings[i] = e
        // Reviewed: the whole-window text and the clips of what wasn't it are deleted (§ 11.10).
        if e.open == 0 {
            for m in e.marks { for c in m.candidates { if let clip = c.clip { try? FileManager.default.removeItem(at: Self.clips.appendingPathComponent(clip)) } } }
            for c in e.unmarked { if let clip = c.clip { try? FileManager.default.removeItem(at: Self.clips.appendingPathComponent(clip)) } }
            evenings[i].marks = e.marks.map { var m = $0; m.lines = []; return m }
        }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(evenings.prefix(30))) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }
}
