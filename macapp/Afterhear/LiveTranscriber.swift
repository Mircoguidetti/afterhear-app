import FluidAudio
import Foundation

struct TimedWord {
    let start: Date
    let end: Date
    let text: String
}

/// Transcribes the Mac's sound continuously, on the Mac, in memory only, so the text of the
/// last minutes is there for the live help (CallCoach), the second encounter (Memory) and
/// "sorry?". Parakeet on the Neural Engine (docs/BRAIN.md § 19.25); a small voice detector
/// decides when: silence, typing, a quiet room cost nothing, and the big model only works
/// while someone speaks. Apple's recogniser is gone (50% of words wrong on our clips, 02/10).
final class LiveTranscriber: @unchecked Sendable {
    /// How long words are kept: long enough for a tap that comes minutes later.
    static let memorySeconds: TimeInterval = 190

    /// Names and words the recogniser should expect: the people in your calls, the words of
    /// your meetings, the expressions you're learning (docs/BRAIN.md § 2.4). Parakeet doesn't
    /// take them yet; the server's recogniser does, when it's used for a comparison.
    static var vocabulary: [String] = []

    private static let rate: Double = 16_000
    private static let chunk = 4_096
    /// About 0.8 s of quiet after a voice closes the sentence; nobody speaks 14 s without a breath,
    /// but a song or a monologue might: cut there (the model's window is 15 s).
    private static let quietChunks = 3
    private static let longest = Int(rate * 14)

    private let lock = NSLock()
    private var language: HeardLanguage?
    private var running = false
    /// Battery low (Power): stop recognising while it lasts; the sound is still kept.
    private var saving = false
    private var inbox: [Float] = []
    private var inboxStart = Date()
    private var working = false
    private var words: [TimedWord] = []
    private var heard = Date.distantPast

    // Only touched by the one drain running at a time.
    private var vadState = VadStreamState.initial()
    private var utterance: [Float] = []
    private var utteranceStart = Date()
    private var quiet = 0
    private var before: [Float] = []
    private var beforeStart = Date()

    /// False until the model is on this Mac (the tap then asks the server, as before).
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        guard running, !saving, let language else { return false }
        return Parakeet.isDownloaded(language)
    }

    /// Which recogniser is listening, for the moment's record.
    var engineName: String {
        lock.lock(); defer { lock.unlock() }
        return language.map(Parakeet.name(for:)) ?? "parakeet"
    }

    func configure(language: HeardLanguage) {
        lock.lock()
        if self.language != language { words = [] }
        self.language = language
        running = true
        lock.unlock()
        Task { await Parakeet.shared.prepare(language) }
    }

    /// The vocabulary changed: nothing to tell Parakeet yet (§ 19.25).
    func refreshVocabulary() {}

    func setSaving(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        saving = on
        if on { inbox = [] }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        running = false
        inbox = []
        words = []
    }

    /// Called on the audio queue with every chunk of sound.
    func append(_ samples: UnsafePointer<Float>, count: Int, rate: Double) {
        guard count > 0 else { return }
        let speech = Parakeet.resample(Array(UnsafeBufferPointer(start: samples, count: count)), from: rate)
        lock.lock()
        guard running, !saving else { lock.unlock(); return }
        if inbox.isEmpty { inboxStart = Date().addingTimeInterval(-Double(speech.count) / Self.rate) }
        inbox += speech
        // The Mac too busy to keep up: drop the oldest, never grow without end.
        let most = Int(Self.rate * 30)
        if inbox.count > most {
            let extra = inbox.count - most
            inbox.removeFirst(extra)
            inboxStart = inboxStart.addingTimeInterval(Double(extra) / Self.rate)
        }
        let start = !working && inbox.count >= Self.chunk
        if start { working = true }
        lock.unlock()
        if start { Task.detached(priority: .utility) { await self.drain() } }
    }

    private func drain() async {
        while let item = next() {
            await listen(item.piece, start: item.start, language: item.language)
        }
    }

    /// The next 256 ms to listen to, or nil (and the drain stops) when there's nothing yet.
    private func next() -> (piece: [Float], start: Date, language: HeardLanguage)? {
        lock.lock(); defer { lock.unlock() }
        guard running, !saving, inbox.count >= Self.chunk, let language else {
            working = false
            return nil
        }
        let piece = Array(inbox.prefix(Self.chunk))
        inbox.removeFirst(Self.chunk)
        let start = inboxStart
        inboxStart = inboxStart.addingTimeInterval(Double(Self.chunk) / Self.rate)
        return (piece, start, language)
    }

    /// Everything before this moment is already in `words` (or was silence): a tap only needs
    /// the seconds after it transcribed (§ 19.25, Intel Macs: the tap in ~half the time).
    var heardUntil: Date {
        lock.lock(); defer { lock.unlock() }
        return heard
    }

    private func setHeard(_ date: Date) {
        lock.lock(); heard = date; lock.unlock()
    }

    private func keep(_ timed: [TimedWord]) {
        lock.lock(); defer { lock.unlock() }
        words += timed
        let cutoff = Date().addingTimeInterval(-Self.memorySeconds - 30)
        words.removeAll { $0.end < cutoff }
    }

    private func listen(_ piece: [Float], start: Date, language: HeardLanguage) async {
        let voice: Bool
        if let heard = await Parakeet.shared.voice(piece, state: vadState) {
            voice = heard.voice
            vadState = heard.state
        } else {
            // The detector isn't here yet: loud enough counts as a voice.
            voice = Clip.loudness(piece) > 0.01
        }
        if voice {
            if utterance.isEmpty {
                // Keep the quarter second before: the first syllable is often softer.
                utterance = before
                utteranceStart = before.isEmpty ? start : beforeStart
            }
            utterance += piece
            quiet = 0
        } else if !utterance.isEmpty {
            utterance += piece
            quiet += 1
        }
        before = piece
        beforeStart = start
        guard !utterance.isEmpty else {
            setHeard(start.addingTimeInterval(Double(piece.count) / Self.rate))
            return
        }
        guard quiet >= Self.quietChunks || utterance.count >= Self.longest else {
            setHeard(utteranceStart)
            return
        }
        let sound = utterance
        let from = utteranceStart
        utterance = []
        quiet = 0
        setHeard(from)
        guard let found = await Parakeet.shared.words(sound, language: language) else { return }
        let timed = found.map {
            TimedWord(start: from.addingTimeInterval($0.startTime), end: from.addingTimeInterval($0.endTime), text: $0.word)
        }
        keep(timed)
        setHeard(from.addingTimeInterval(Double(sound.count) / Self.rate))
    }

    /// Roughly the words spoken in the last `seconds`.
    func text(last seconds: Double) -> String {
        timedWords(since: Date().addingTimeInterval(-seconds)).map(\.text).joined(separator: " ")
    }

    /// Every word since `since`, with its time.
    func timedWords(since: Date) -> [TimedWord] {
        lock.lock(); defer { lock.unlock() }
        return words.filter { $0.end >= since }
    }
}
