import Foundation

/// Parakeet on the processor, for Macs without a Neural Engine (Intel). The same model as on
/// Apple silicon, in the ONNX format our benchmark used (33.5% on real meetings, 02/10), run by
/// sherpa-onnx. CoreML on an Intel processor crashed inside Apple's code (owner's MacBook Pro
/// 2020, 02/10), so these Macs never touch it. Nothing leaves the Mac here either.
final class ParakeetCPU: @unchecked Sendable {
    static let shared = ParakeetCPU()

    private let lock = NSLock()
    private var recognizer: OpaquePointer?
    private var loadedName: String?
    private var lastUse = Date()

    /// v2 for English, v3 for the other languages (Ultra has no ONNX build).
    static func modelName(for language: HeardLanguage) -> String {
        language.rawValue.hasPrefix("en") ? "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8" : "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("app.afterhear.mac/models", isDirectory: true)
    }

    private static func files(_ name: String) -> (encoder: URL, decoder: URL, joiner: URL, tokens: URL) {
        let dir = folder.appendingPathComponent(name, isDirectory: true)
        return (dir.appendingPathComponent("encoder.int8.onnx"), dir.appendingPathComponent("decoder.int8.onnx"),
                dir.appendingPathComponent("joiner.int8.onnx"), dir.appendingPathComponent("tokens.txt"))
    }

    static func isDownloaded(_ language: HeardLanguage) -> Bool {
        let f = files(modelName(for: language))
        return [f.encoder, f.decoder, f.joiner, f.tokens].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Downloads and unpacks the model (~0.6 GB, once). Progress from 0 to 1.
    static func download(_ language: HeardLanguage, progress: @escaping @Sendable (Double) -> Void) async throws {
        let name = modelName(for: language)
        guard let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(name).tar.bz2") else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent(name + ".tar.bz2")
        let delegate = DownloadProgress(progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temp, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AfterhearError.server("model download") }
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: temp, to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        // Unpacked with the Mac's own tar, next to the others.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xjf", archive.path, "-C", folder.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, isDownloaded(language) else { throw AfterhearError.server("model unpack") }
    }

    /// Timed words of 16 kHz mono sound, seconds from its start. Nil while the model isn't here.
    func words(_ samples: [Float], language: HeardLanguage) -> [(word: String, start: Double, end: Double)]? {
        lock.lock(); defer { lock.unlock() }
        guard let recognizer = load(language) else { return nil }
        lastUse = Date()
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return [] }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16_000, $0.baseAddress, Int32($0.count)) }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return [] }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        let r = result.pointee
        let count = Int(r.count)
        guard count > 0, let tokens = r.tokens_arr, let times = r.timestamps else { return [] }
        let total = Double(samples.count) / 16_000
        // Pieces of words: a new word starts where a piece starts with a space (or "▁").
        var out: [(word: String, start: Double, end: Double)] = []
        for i in 0..<count {
            guard let raw = tokens[i] else { continue }
            let piece = String(cString: raw)
            let start = Double(times[i])
            let end = r.durations.map { start + Double($0[i]) } ?? (i + 1 < count ? Double(times[i + 1]) : total)
            let newWord = piece.hasPrefix(" ") || piece.hasPrefix("▁") || out.isEmpty
            let text = piece.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
            if newWord {
                guard !text.isEmpty else { continue }
                out.append((text, start, end))
            } else if let last = out.last {
                out[out.count - 1] = (last.word + text, last.start, max(last.end, end))
            }
        }
        return out
    }

    /// A few minutes without voices: the model leaves memory.
    func unloadIfIdle(after seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard let recognizer, Date().timeIntervalSince(lastUse) > seconds else { return }
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
        self.recognizer = nil
        loadedName = nil
    }

    private func load(_ language: HeardLanguage) -> OpaquePointer? {
        let name = Self.modelName(for: language)
        if let recognizer, loadedName == name { return recognizer }
        guard Self.isDownloaded(language) else { return nil }
        if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
        recognizer = nil
        let f = Self.files(name)
        // The C strings must live until the recognizer is made.
        let encoder = strdup(f.encoder.path), decoder = strdup(f.decoder.path), joiner = strdup(f.joiner.path)
        let tokens = strdup(f.tokens.path), provider = strdup("cpu"), type = strdup("nemo_transducer"), method = strdup("greedy_search")
        defer { for string in [encoder, decoder, joiner, tokens, provider, type, method] { free(UnsafeMutableRawPointer(string)) } }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = UnsafePointer(encoder)
        config.model_config.transducer.decoder = UnsafePointer(decoder)
        config.model_config.transducer.joiner = UnsafePointer(joiner)
        config.model_config.tokens = UnsafePointer(tokens)
        // Half the cores: the Mac stays usable (and cooler) while it transcribes.
        config.model_config.num_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        config.model_config.provider = UnsafePointer(provider)
        config.model_config.model_type = UnsafePointer(type)
        config.decoding_method = UnsafePointer(method)
        config.max_active_paths = 4
        recognizer = SherpaOnnxCreateOfflineRecognizer(&config)
        loadedName = recognizer == nil ? nil : name
        return recognizer
    }
}

/// Download progress for the model, as a fraction.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
