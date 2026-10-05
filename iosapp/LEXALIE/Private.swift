import AVFoundation
import FluidAudio
import Foundation
import Network
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Everything heard in real life stays on this iPhone (docs/BRAIN.md § 19.25): Parakeet turns
/// it into text (v2 for English, Ultra for the other languages), a small model tells the voices
/// apart, and your voice's fingerprint says which lines are yours, so the evening only offers
/// what the others said. The models (~0.5 GB, plus ~30 MB for the voices) download by themselves
/// on Wi-Fi. Nothing runs while you listen: only for "now" and at night, then memory is freed.
actor Private {
    static let shared = Private()

    enum Status: Equatable {
        case missing, waitingForWifi, downloading, ready
        case failed(String)

        var label: String {
            switch self {
            case .missing: "Not downloaded yet"
            case .waitingForWifi: "Waiting for Wi-Fi to download (about 0.5 GB)"
            case .downloading: "Downloading (about 0.5 GB)…"
            case .ready: "Ready · stays on your device"
            case .failed(let why): "Download failed: \(why)"
            }
        }
    }

    nonisolated(unsafe) private(set) static var status: Status = .missing

    private var manager: AsrManager?
    private var loaded: AsrModelVersion?
    private var downloading: Task<Void, Never>?
    private var diarizer: OfflineDiarizerManager?

    static var english: Bool { K.string(K.heard).hasPrefix("en") }
    static var version: AsrModelVersion { english ? .v2 : .ultra }
    static var name: String { english ? "parakeet-v2" : "parakeet-ultra" }

    static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Downloads the model if it isn't here. `anyNetwork`: "Download now" was pressed.
    func prepare(anyNetwork: Bool = false) {
        if Self.isDownloaded { Self.status = .ready; return }
        guard downloading == nil else { return }
        let version = Self.version
        downloading = Task {
            defer { self.downloading = nil }
            if !anyNetwork, !(await Self.unmetered()) {
                Self.status = .waitingForWifi
                return
            }
            Self.status = .downloading
            do {
                _ = try await AsrModels.download(version: version)
                Self.status = .ready
            } catch {
                Self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// Timed words of 16 kHz mono sound starting at `start`. Nil while the model isn't here.
    func words(_ samples: [Float], start: Date) async -> [Word]? {
        guard samples.count >= 8_000, let manager = await load() else { return nil }
        var state = TdtDecoderState.make()
        let hint = Self.english ? nil : Language(rawValue: String(K.string(K.heard).prefix(2)))
        guard let result = try? await manager.transcribe(samples, decoderState: &state, language: hint) else { return [] }
        return buildWordTimings(from: result.tokenTimings ?? []).map {
            Word(text: $0.word, at: start.addingTimeInterval($0.startTime), duration: $0.endTime - $0.startTime)
        }
    }

    /// A recorded file (a minute of the day, a voice memo), as timed words.
    func words(file url: URL, start: Date) async -> [Word]? {
        guard let samples = Self.read(url) else { return [] }
        return await words(samples, start: start)
    }

    /// When you said something in this sound (seconds from its start), told apart by your voice's
    /// fingerprint. Empty without a fingerprint, or when the voices model isn't available.
    func mine(_ samples: [Float]) async -> [ClosedRange<Double>] {
        guard let me = Self.fingerprint, samples.count >= 16_000 * 3, let diarizer = await loadDiarizer(),
              let result = try? await diarizer.process(audio: samples) else { return [] }
        let speakers = Self.voices(result)
        let mine = Set(speakers.filter { Self.similarity($0.value, me) >= Self.sameVoice }.keys)
        return result.segments.filter { mine.contains($0.speakerId) }
            .map { Double($0.startTimeSeconds)...Double($0.endTimeSeconds) }
    }

    /// Your voice, once (Settings): about 20 seconds of you talking, kept as numbers on this iPhone.
    func learnVoice(_ samples: [Float]) async -> Bool {
        guard let diarizer = await loadDiarizer(), let result = try? await diarizer.process(audio: samples) else { return false }
        // The voice that speaks the most in the recording is yours.
        var spoken: [String: Double] = [:]
        for s in result.segments { spoken[s.speakerId, default: 0] += Double(s.endTimeSeconds - s.startTimeSeconds) }
        guard let id = spoken.max(by: { $0.value < $1.value })?.key, let embedding = Self.voices(result)[id] else { return false }
        Self.fingerprint = embedding
        return true
    }

    /// The night is over: the models leave memory.
    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
        loaded = nil
        diarizer = nil
    }

    // MARK: -

    /// Cosine similarity at which two recordings are the same person (WeSpeaker embeddings).
    private static let sameVoice: Float = 0.6

    static var fingerprint: [Float]? {
        get { UserDefaults.standard.array(forKey: "voiceFingerprint") as? [Float] }
        set { UserDefaults.standard.set(newValue, forKey: "voiceFingerprint") }
    }

    /// One voice per speaker: the pipeline's own, or the average of that speaker's segments.
    private static func voices(_ result: DiarizationResult) -> [String: [Float]] {
        if let database = result.speakerDatabase, !database.isEmpty { return database }
        var sums: [String: [Float]] = [:]
        for s in result.segments where !s.embedding.isEmpty {
            if let sum = sums[s.speakerId], sum.count == s.embedding.count {
                sums[s.speakerId] = zip(sum, s.embedding).map { $0 + $1 }
            } else {
                sums[s.speakerId] = s.embedding
            }
        }
        return sums
    }

    private static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    private func load() async -> AsrManager? {
        let version = Self.version
        if let manager, loaded == version { return manager }
        guard Self.isDownloaded else { prepare(); return nil }
        do {
            let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: version), version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            if let old = self.manager { await old.cleanup() }
            self.manager = manager
            loaded = version
            Self.status = .ready
            return manager
        } catch {
            return nil
        }
    }

    private func loadDiarizer() async -> OfflineDiarizerManager? {
        if let diarizer { return diarizer }
        let manager = OfflineDiarizerManager()
        guard (try? await manager.prepareModels()) != nil else { return nil }
        diarizer = manager
        return manager
    }

    private static func unmetered() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && !path.isExpensive && !path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "app.lexalie.ios.network"))
        }
    }

    /// Any audio file as 16 kHz mono.
    static func read(_ url: URL) -> [Float]? {
        try? AudioConverter().resampleAudioFile(url)
    }
}

/// No connection: a quick explanation from the language model inside the iPhone (Apple
/// Intelligence, iOS 26), marked as such; the full one when the network is back.
enum OfflineExplainer {
    static func explain(_ sentence: String) async -> Api.Explanation? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return await AppleModel.explain(sentence) }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct OfflinePiece {
    @Guide(description: "The word or expression from the sentence that a learner would miss, exactly as written in the sentence")
    var text: String
    @Guide(description: "One to four words: its meaning in the learner's language")
    var gloss: String
    @Guide(description: "One short sentence in the learner's language: what it means here")
    var meaning: String
}

@available(iOS 26.0, *)
@Generable
struct OfflineAnswer {
    @Guide(description: "The whole sentence translated naturally into the learner's language")
    var translation: String
    @Guide(description: "The one to three hardest words or expressions, most important first", .maximumCount(3))
    var pieces: [OfflinePiece]
}

@available(iOS 26.0, *)
private enum AppleModel {
    static func explain(_ sentence: String) async -> Api.Explanation? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let heard = Locale.current.localizedString(forIdentifier: K.string(K.heard)) ?? K.string(K.heard)
        let native = Locale.current.localizedString(forLanguageCode: K.string(K.native)) ?? K.string(K.native)
        let session = LanguageModelSession(instructions: """
            You help someone who is learning \(heard) and speaks \(native). They just missed a sentence \
            they heard. Explain it in \(native), briefly and simply: the translation, and the words or \
            expressions that made it hard (idioms, slang, phrasal verbs, words a learner wouldn't know).
            """)
        guard let answer = try? await session.respond(to: "The sentence: \"\(sentence)\"", generating: OfflineAnswer.self).content else { return nil }
        let pieces = answer.pieces.filter { !$0.text.isEmpty }.map { Piece(text: $0.text, gloss: $0.gloss, meaning: $0.meaning, cause: "unknown_word") }
        return Api.Explanation(translation: answer.translation, intent: nil, pieces: pieces)
    }
}
#endif
