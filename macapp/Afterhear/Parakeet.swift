import CoreML
import FluidAudio
import Foundation

/// The recogniser on this Mac (docs/BRAIN.md § 19.25): NVIDIA's Parakeet on the Neural Engine,
/// through FluidAudio. Nothing leaves the Mac. English uses v2 (the most accurate on English in
/// our test, 02/10); the other languages Parakeet Ultra (v3's 25 languages, retrained: more
/// accurate than v3 on all of them). The model (~0.5 GB) downloads by itself when the app starts,
/// and leaves memory after a few minutes without voices.
actor Parakeet {
    static let shared = Parakeet()

    enum Status: Equatable {
        case missing
        case downloading(Int)
        case ready
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .missing: "Not downloaded yet"
            case .downloading(let percent): "Downloading \(percent)% (about 0.5 GB, once)…"
            case .ready: "Ready · stays on your device"
            case .failed(let why): "Download failed: \(why)"
            }
        }
    }

    /// Read from the main thread for Settings and the panel; written from the download.
    static var status: Status {
        get { statusLock.lock(); defer { statusLock.unlock() }; return _status }
        set { statusLock.lock(); _status = newValue; statusLock.unlock() }
    }
    nonisolated(unsafe) private static var _status: Status = .missing
    private static let statusLock = NSLock()

    private var manager: AsrManager?
    private var loaded: AsrModelVersion?
    private var loading: Task<AsrManager?, Never>?
    private var downloading: Task<Void, Never>?
    private var lastUse = Date()

    /// The voice detector (Silero, ~2 MB): it decides when there's someone to transcribe.
    private var vad: VadManager?
    private var vadLoading: Task<VadManager?, Never>?

    /// Intel Macs have no Neural Engine, and CoreML on their processor crashes inside Apple's
    /// code with these models (owner's MacBook Pro 2020, 02/10): there the same Parakeet runs as
    /// ONNX on the processor (ParakeetCPU), and loudness stands in for the voice detector.
    static var onProcessor: Bool {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }

    static func version(for language: HeardLanguage) -> AsrModelVersion {
        language.rawValue.hasPrefix("en") ? .v2 : .ultra
    }

    static func name(for language: HeardLanguage) -> String {
        if onProcessor { return language.rawValue.hasPrefix("en") ? "parakeet-v2-cpu" : "parakeet-v3-cpu" }
        return language.rawValue.hasPrefix("en") ? "parakeet-v2" : "parakeet-ultra"
    }

    static func isDownloaded(_ language: HeardLanguage) -> Bool {
        if onProcessor { return ParakeetCPU.isDownloaded(language) }
        let version = version(for: language)
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Downloads the model for this language if it isn't here yet (a Mac is on Wi-Fi or a cable
    /// almost always: no waiting for a "free" network, it starts right away).
    func prepare(_ language: HeardLanguage, anyNetwork: Bool = false) {
        if Self.isDownloaded(language) {
            Self.status = .ready
            return
        }
        guard downloading == nil else { return }
        let version = Self.version(for: language)
        Self.status = .downloading(0)
        if Self.onProcessor {
            downloading = Task {
                defer { self.downloading = nil }
                do {
                    try await ParakeetCPU.download(language) { fraction in
                        Parakeet.status = .downloading(min(99, Int(fraction * 100)))
                    }
                    Self.status = .ready
                } catch {
                    Self.status = .failed(error.localizedDescription)
                }
            }
            return
        }
        downloading = Task {
            defer { self.downloading = nil }
            do {
                _ = try await AsrModels.download(version: version, progressHandler: { progress in
                    Parakeet.status = .downloading(min(99, Int(progress.fractionCompleted * 100)))
                })
                Self.status = .ready
            } catch {
                Self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// Timed words for 16 kHz mono sound, times in seconds from its start. Nil while the model
    /// isn't on this Mac yet.
    func words(_ samples: [Float], language: HeardLanguage) async -> [WordTiming]? {
        if Self.onProcessor {
            guard samples.count >= 8_000 else { return [] }
            guard Self.isDownloaded(language) else { prepare(language); return nil }
            lastUse = Date()
            // Seconds of work on the processor: off this actor, so other calls aren't held up.
            let found = await Task.detached(priority: .userInitiated) { ParakeetCPU.shared.words(samples, language: language) }.value
            return found?.map { WordTiming(word: $0.word, startTime: $0.start, endTime: $0.end) }
        }
        guard samples.count >= 8_000, let manager = await load(language) else { return nil }
        lastUse = Date()
        var state = TdtDecoderState.make()
        let hint = Self.version(for: language) == .v2 ? nil : Language(rawValue: String(language.rawValue.prefix(2)))
        guard let result = try? await manager.transcribe(samples, decoderState: &state, language: hint) else { return [] }
        lastUse = Date()
        return buildWordTimings(from: result.tokenTimings ?? [])
    }

    /// Is there a voice in this 256 ms of 16 kHz sound? Nil when the detector isn't loaded (yet).
    func voice(_ chunk: [Float], state: VadStreamState) async -> (voice: Bool, state: VadStreamState)? {
        if Self.onProcessor { return nil }
        guard let vad = await loadVad(),
              let result = try? await vad.processStreamingChunk(chunk, state: state) else { return nil }
        return (result.probability >= 0.5, result.state)
    }

    /// A few minutes without anyone speaking: the model leaves memory (it comes back in a second or two).
    func unloadIfIdle(after seconds: TimeInterval = 300) async {
        if Self.onProcessor { ParakeetCPU.shared.unloadIfIdle(after: seconds); return }
        guard let manager, loading == nil, Date().timeIntervalSince(lastUse) > seconds else { return }
        await manager.cleanup()
        self.manager = nil
        loaded = nil
    }

    private func load(_ language: HeardLanguage) async -> AsrManager? {
        let version = Self.version(for: language)
        if let manager, loaded == version { return manager }
        if let loading { return await loading.value }
        guard Self.isDownloaded(language) else {
            prepare(language)
            return nil
        }
        let task = Task<AsrManager?, Never> {
            do {
                let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: version), version: version)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                return manager
            } catch {
                return nil
            }
        }
        loading = task
        let manager = await task.value
        loading = nil
        if let old = self.manager, old !== manager { await old.cleanup() }
        self.manager = manager
        loaded = manager == nil ? nil : version
        if manager != nil { Self.status = .ready }
        return manager
    }

    private var vadFailed: Date?

    private func loadVad() async -> VadManager? {
        if let vad { return vad }
        if let vadLoading { return await vadLoading.value }
        // It couldn't load (no network yet): loudness decides meanwhile, try again in a minute.
        if let vadFailed, Date().timeIntervalSince(vadFailed) < 60 { return nil }
        let task = Task<VadManager?, Never> { try? await VadManager() }
        vadLoading = task
        vad = await task.value
        vadLoading = nil
        if vad == nil { vadFailed = Date() }
        return vad
    }

    /// 16 kHz mono from whatever rate the sound came at (the recognisers want exactly 16 kHz).
    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate > 0, abs(rate - 16_000) > 1, !samples.isEmpty else { return samples }
        let ratio = rate / 16_000
        let count = Int(Double(samples.count) / ratio)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let x = Double(i) * ratio
            let j = Int(x)
            let f = Float(x - Double(j))
            let a = samples[min(j, samples.count - 1)]
            let b = samples[min(j + 1, samples.count - 1)]
            out[i] = a + (b - a) * f
        }
        return out
    }

    /// The words of a clip, on the wall clock: what the tap and the marks rank (Conversation).
    func timedWords(_ samples: [Float], rate: Double, language: HeardLanguage, clipStart: Date) async -> [TimedWord]? {
        let speech = Self.resample(samples, from: rate)
        guard let words = await words(speech, language: language) else { return nil }
        return words.map {
            TimedWord(start: clipStart.addingTimeInterval($0.startTime), end: clipStart.addingTimeInterval($0.endTime), text: $0.word)
        }
    }
}
