import AVFoundation
import Foundation
import NaturalLanguage

/// Block INSIEME (owner, 08/10 evening): "we listened to it together: ask me what you didn't get".
/// Every call, video, podcast and conversation in person becomes a session: what the others said, line
/// by line, as this Mac heard it, and at the end the card with the 3–4 moments you most likely missed.
/// It goes to your account (Supabase, your rows only), so the iPhone, the Watch and the web see the same
/// sessions and "Ask LEXALIE" can answer about any of them. Your own sentences are not kept (owner,
/// 06/10). The voice stays on this Mac while the session lasts; at the end only the few seconds of each
/// moment on the card are kept, and sent to your account to replay anywhere. Videos and podcasts stay
/// until you delete them; calls too, unless you chose to delete them after some days (Settings).
@MainActor
final class Sessions: ObservableObject {
    static let shared = Sessions()

    struct Line: Codable, Hashable {
        var i: Int
        /// Seconds from the session's start.
        var start: Double
        var end: Double
        var text: String
    }

    struct Term: Codable, Hashable {
        var term: String
        var meaning: String
        var isPublic: Bool

        enum CodingKeys: String, CodingKey { case term, meaning, isPublic = "public" }
    }

    /// A moment on the end card: the sentence as said, what it meant, and its voice.
    struct CardMoment: Codable, Identifiable, Hashable {
        var id = UUID()
        var line: Int
        var sentence: String
        var why: String
        var meaning: String
        var numbers: String
        var negation: String
        var terms: [Term]
        var unsure: Bool
        /// "tap", "picked", "asked".
        var source: String
        /// The few seconds of voice, in the session's folder.
        var clip: String? = nil
        var glossary: String? = nil
        var discarded = false
        var knew = false
    }

    struct Asked: Codable, Hashable {
        var line: Int
        var sentence: String
        var meaning: String
        /// A question nobody answered (not one put to you).
        var open: Bool
    }

    struct Session: Codable, Identifiable {
        var id = UUID()
        /// "call", "video", "podcast", "film", "in_person", "voice_note".
        var kind: String
        var title: String
        var people: [String]
        var language: String
        var start: Date
        var end: Date? = nil
        var lines: [Line] = []
        var card: [CardMoment] = []
        var asked: [Asked] = []
        var deleteAfter: Date? = nil
        /// Something changed since it last reached the account.
        var dirty = true
        var cardMade = false
        /// When the first second of the session's sound was heard (its sound file starts there).
        var audioStart: Date? = nil
    }

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var current: Session?

    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LEXALIE/sessions", isDirectory: true)
    private var audio: AVAudioFile?
    private var lastAudio: Date?
    private var lastSave = Date()

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        sessions = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Session.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start > $1.start }
        purgeExpired()
    }

    // MARK: Recording

    /// A call, a video or a podcast starts. A session already running ends first.
    func begin(kind: String, title: String, people: [String]) async {
        if current != nil { _ = await end() }
        var s = Session(kind: kind, title: String(title.prefix(200)), people: Array(people.prefix(40)),
                        language: AppSettings.current.heard.rawValue, start: Date())
        if kind == "call", let days = Profile.shared.callsDeleteDays { s.deleteAfter = s.start.addingTimeInterval(Double(days) * 86_400) }
        current = s
        openAudio(for: s)
    }

    /// Every few seconds while it lasts: the settled lines of the last minute, and the sound since last time.
    func observe(_ turns: [Turn], clipStart: Date) {
        guard var s = current else { return }
        for turn in turns where !turn.isMine && turn.end < 57 {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.split(separator: " ").count >= 2 else { continue }
            let start = clipStart.addingTimeInterval(turn.start).timeIntervalSince(s.start)
            let end = clipStart.addingTimeInterval(turn.end).timeIntervalSince(s.start)
            guard end > 0 else { continue }
            // The same words seen again in the next window (or the same sentence grown) is one line.
            if let k = s.lines.lastIndex(where: { Self.overlap($0, start, end) > 0.5 || $0.text == text }) {
                if text.count > s.lines[k].text.count { s.lines[k].text = String(text.prefix(2000)); s.lines[k].end = end }
                continue
            }
            guard s.lines.count < 2500 else { break }
            s.lines.append(Line(i: s.lines.count, start: max(0, start), end: end, text: String(text.prefix(2000))))
            s.dirty = true
        }
        s.lines.sort { $0.start < $1.start }
        current = s
        appendAudio()
        if Date().timeIntervalSince(lastSave) > 60 { save(s); lastSave = Date() }
    }

    /// The video's title, once it's known (it often comes a few seconds late).
    func retitle(_ title: String) {
        guard var s = current, s.title.isEmpty, !title.isEmpty else { return }
        s.title = String(title.prefix(200))
        current = s
    }

    /// It ended: the session is kept (and sent), and returned for its end card. Only a session of
    /// these kinds: a video that ends after a call began doesn't end the call.
    func end(kinds: Set<String>? = nil) async -> Session? {
        guard var s = current, kinds.map({ $0.contains(s.kind) }) ?? true else { return nil }
        appendAudio()
        audio = nil  // closes the file
        current = nil
        s.end = Date()
        guard !s.lines.isEmpty else { dropAudio(s.id); return nil }
        keep(s)
        return s
    }

    /// A conversation in person or a voice note, heard by its own microphone: the lines as they are.
    func record(kind: String, title: String, lines: [String], start: Date) -> Session? {
        let clean = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return nil }
        var s = Session(kind: kind, title: title, people: [], language: AppSettings.current.heard.rawValue, start: start, end: Date())
        s.lines = clean.prefix(2500).enumerated().map { Line(i: $0.offset, start: 0, end: 0, text: String($0.element.prefix(2000))) }
        keep(s)
        return s
    }

    private func keep(_ s: Session) {
        sessions.removeAll { $0.id == s.id }
        sessions.insert(s, at: 0)
        save(s)
        SessionSync.shared.schedule()
    }

    func update(_ s: Session) {
        var s = s
        s.dirty = true
        if let k = sessions.firstIndex(where: { $0.id == s.id }) { sessions[k] = s } else { sessions.insert(s, at: 0) }
        save(s)
        SessionSync.shared.schedule()
    }

    func markSynced(_ id: UUID) {
        guard let k = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[k].dirty = false
        save(sessions[k])
    }

    static func overlap(_ line: Line, _ start: Double, _ end: Double) -> Double {
        let shared = min(line.end, end) - max(line.start, start)
        let shorter = min(line.end - line.start, end - start)
        return shorter > 0 ? max(0, shared) / shorter : 0
    }

    // MARK: The sound of the session (on this Mac only, until the card is made)

    private func audioURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).m4a") }
    func clipFolder(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func openAudio(for s: Session) {
        audio = nil
        lastAudio = Date()
    }

    private func appendAudio() {
        guard var s = current, s.kind != "in_person", let last = lastAudio else { return }
        let now = Date()
        let seconds = min(now.timeIntervalSince(last), SystemAudio.hiSeconds - 1)
        lastAudio = now
        guard seconds > 0.2 else { return }
        let (samples, rate) = AppModel.shared.recentVoice(seconds: seconds)
        guard rate > 0, !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        if audio == nil {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
            audio = try? AVAudioFile(forWriting: audioURL(s.id), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            s.audioStart = now.addingTimeInterval(-Double(samples.count) / rate)
            current = s
        }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        do { try audio?.write(from: buffer) } catch { ErrorLog.record("sessions.audio", error) }
    }

    /// The few seconds of each moment on the card, then the rest of the sound goes.
    func cutClips(_ s: inout Session) async {
        defer { dropAudio(s.id) }
        let url = audioURL(s.id)
        guard FileManager.default.fileExists(atPath: url.path), let started = s.audioStart else { return }
        try? FileManager.default.createDirectory(at: clipFolder(s.id), withIntermediateDirectories: true)
        let asset = AVURLAsset(url: url)
        for k in s.card.indices {
            guard let line = s.lines.first(where: { $0.i == s.card[k].line }), line.end > line.start else { continue }
            let from = s.start.addingTimeInterval(line.start).timeIntervalSince(started) - 0.4
            let to = s.start.addingTimeInterval(line.end).timeIntervalSince(started) + 0.6
            guard to > 0.5 else { continue }
            let out = clipFolder(s.id).appendingPathComponent("\(s.card[k].id.uuidString).m4a")
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { continue }
            export.outputURL = out
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(start: CMTime(seconds: max(0, from), preferredTimescale: 600),
                                           end: CMTime(seconds: min(to, max(0, from) + 30), preferredTimescale: 600))
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
            if export.status == .completed { s.card[k].clip = out.lastPathComponent }
        }
    }

    private func dropAudio(_ id: UUID) {
        try? FileManager.default.removeItem(at: audioURL(id))
    }

    func clipURL(_ s: Session, _ m: CardMoment) -> URL? {
        guard let clip = m.clip else { return nil }
        let url = clipFolder(s.id).appendingPathComponent(clip)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Forgetting

    /// "Forget this session": here, on the account and on every device.
    func forget(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: clipFolder(id))
        dropAudio(id)
        SessionSync.shared.forget(id)
    }

    /// Settings → "Forget everything I heard".
    func forgetAll() {
        let ids = sessions.map(\.id)
        for id in ids {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).json"))
            try? FileManager.default.removeItem(at: clipFolder(id))
        }
        sessions = []
        current = nil
        audio = nil
        SessionSync.shared.forgetAll(ids)
    }

    /// Calls past the days you chose go, here and (through the account) everywhere.
    func purgeExpired() {
        let now = Date()
        for s in sessions where (s.deleteAfter.map { $0 <= now } ?? false) { forget(s.id) }
    }

    private func save(_ s: Session) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(s) else { return }
        try? data.write(to: folder.appendingPathComponent("\(s.id.uuidString).json"), options: .atomic)
    }

    // MARK: For "Ask LEXALIE"

    /// Without the account: this Mac's latest sessions, as the server's ask takes them.
    func inline(limit: Int) -> [[String: Any]] {
        let all = (current.map { [$0] } ?? []) + sessions
        return all.prefix(limit).map { s in
            ["id": s.id.uuidString.lowercased(), "kind": s.kind, "title": s.title, "people": s.people,
             "started_at": SessionSync.iso(s.start),
             "lines": s.lines.suffix(400).map { ["i": $0.i, "who": "them", "text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }] as [String: Any]
        }
    }

    /// The voice of a line, when it's a moment of that session's card.
    func voice(session id: String, line: Int) -> URL? {
        guard let s = sessions.first(where: { $0.id.uuidString.lowercased() == id.lowercased() }),
              let m = s.card.first(where: { $0.line == line }) else { return nil }
        return clipURL(s, m)
    }

    // MARK: Names back

    /// The server's words with this line's names and numbers put back, in order: [tu] is you.
    static func restore(_ text: String, from original: String) -> String {
        var out = Told.restore(text, from: original)
        if out.contains("[tu]"), !Redactor.me.isEmpty { out = out.replacingOccurrences(of: "[tu]", with: Redactor.me) }
        guard out.contains("[nome]") else { return out }
        var names: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = original
        tagger.enumerateTags(in: original.startIndex..<original.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if tag == .personalName { names.append(String(original[range])) }
            return true
        }
        while let range = out.range(of: "[nome]"), !names.isEmpty { out.replaceSubrange(range, with: names.removeFirst()) }
        return out
    }
}

extension ISO8601DateFormatter {
    /// Now, in your time zone ("2026-10-08T21:40:00+02:00"): the server reads "yesterday" and "on Tuesday" from it.
    static func localNow() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
