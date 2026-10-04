import AVFoundation
import Foundation
import Speech

/// The light recorder (docs/BRAIN.md § 11.6, § 13.1–13.2): during the day it only records.
/// - Compressed audio (AAC, 16 kHz, about 0.2 MB a minute) in one-minute pieces, encrypted
///   on this iPhone; the pieces older than 30 minutes are deleted unless you marked near them.
/// - A tiny voice detector: when someone is speaking (for long silences and hesitations).
/// - The last minute also in memory, for "help me live" (only if you turned it on).
/// No transcription, no cloud.
final class Recorder {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var fileStart = Date()
    private(set) var folder: URL?
    private let queue = DispatchQueue(label: "app.afterhear.recorder")
    /// The last 60 seconds, for live help. Only read on `queue`.
    private var recent: [Float] = []

    /// A finished one-minute piece (its file name and when it started).
    var onChunk: ((String, Date) -> Void)?
    /// Every buffer, 16 kHz mono: for the phrase detector.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// When someone was last heard speaking.
    private(set) var lastVoice = Date()
    /// When the current conversation began: the first voice after two quiet minutes (§ 19.3).
    private(set) var conversationStart = Date()

    var isRunning: Bool { engine.isRunning || feeding }
    /// Sound that comes from somewhere else than the microphone (the other apps, iOS 27: AppAudio).
    private var feeding = false
    private var feedConverter: (AVAudioFormat, AVAudioConverter)?

    /// Records what `feed` gives it instead of the microphone, in the same one-minute pieces.
    func startFeed(into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        self.folder = folder
        feeding = true
        lastVoice = Date()
        conversationStart = Date()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async {
            guard self.feeding else { return }
            if self.feedConverter?.0 != buffer.format {
                self.feedConverter = AVAudioConverter(from: buffer.format, to: Self.format).map { (buffer.format, $0) }
            }
            self.converter = self.feedConverter?.1
            self.handle(buffer, inRate: buffer.format.sampleRate)
        }
    }

    func stopFeed() {
        guard feeding else { return }
        queue.sync {
            feeding = false
            closeFile()
        }
    }

    func start(into folder: URL) throws {
        guard !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = K.bool(K.airpods) ? [.allowBluetooth] : [.mixWithOthers, .allowBluetooth]
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        self.folder = folder
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw AfterhearError.server("no microphone") }
        converter = AVAudioConverter(from: inFormat, to: Self.format)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.queue.async { self?.handle(buffer, inRate: inFormat.sampleRate) }
        }
        try engine.start()
        lastVoice = Date()
        conversationStart = Date()
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync { closeFile() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// After a phone call or Siri: start again where we were.
    func resume() {
        guard !engine.isRunning, folder != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    /// The last `seconds` of audio, for live help.
    func last(_ seconds: Double) -> [Float] {
        queue.sync { Array(recent.suffix(Int(seconds * Self.format.sampleRate))) }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, inRate: Double) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.format.sampleRate / inRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        // Voice or not: loudness is enough (no words, no transcription).
        var sum: Float = 0
        for s in samples { sum += s * s }
        if (sum / Float(samples.count)).squareRoot() > 0.012 {
            let now = Date()
            if now.timeIntervalSince(lastVoice) > 120 { conversationStart = now }
            lastVoice = now
        }
        // The last minute in memory, always: two taps explain it at once (§ 19.5).
        recent.append(contentsOf: samples)
        if recent.count > 70 * 16_000 { recent.removeFirst(recent.count - 60 * 16_000) }
        onBuffer?(out)
        write(out)
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        if file == nil || Date().timeIntervalSince(fileStart) >= 60 { rotate() }
        try? file?.write(from: buffer)
    }

    private func rotate() {
        closeFile()
        guard let folder else { return }
        fileStart = Date()
        let url = folder.appendingPathComponent("\(Int(fileStart.timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000,
        ]
        file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    private func closeFile() {
        guard let file else { return }
        let name = file.url.lastPathComponent
        let start = fileStart
        self.file = nil
        DispatchQueue.main.async { self.onChunk?(name, start) }
    }
}

/// The phrases that work as a tap (§ 11.4): "sorry?", "say again?", "you what?"…
/// Recognised on the iPhone only, only while you listen, and only if you turn it on
/// (it costs battery: that's what the device test measures).
final class PhraseSpotter {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var startedAt = Date()
    private var lastFired = Date.distantPast
    /// How much of the current transcript was already checked (a phrase counts once).
    private var checked = 0
    private let action: () -> Void

    static let pattern = #"\b(sorry(\?|\s*$| what)|pardon|what do you mean|can you repeat|could you repeat|say (that|it) again|say again|come again|what was that|(didn't|did not) catch (that|it)|you what)"#

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func start() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: K.string(K.heard)))
        guard recognizer?.supportsOnDeviceRecognition == true else { return }
        restart()
    }

    func stop() {
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        recognizer = nil
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard recognizer != nil else { return }
        // Recognition requests are limited to about a minute: start a fresh one often.
        if Date().timeIntervalSince(startedAt) > 50 { restart() }
        request?.append(buffer)
    }

    private func restart() {
        task?.cancel()
        request?.endAudio()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["sorry?", "pardon?", "say again?", "come again?", "you what?", "what do you mean?"]
        self.request = request
        startedAt = Date()
        checked = 0
        task = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let text = result?.bestTranscription.formattedString.lowercased() else { return }
            let fresh = String(text.dropFirst(max(0, min(self.checked, text.count) - 12)))
            guard Date().timeIntervalSince(self.lastFired) > 8, fresh.range(of: Self.pattern, options: .regularExpression) != nil else { return }
            self.lastFired = Date()
            self.checked = text.count
            DispatchQueue.main.async { self.action() }
        }
    }
}
