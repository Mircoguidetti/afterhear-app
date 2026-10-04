import Combine
import AVFoundation
import MediaPlayer
import Speech
import UIKit

/// Which microphone the test uses. The three options are the three ways iOS can
/// route audio with AirPods, and each one changes whether the AirPods press
/// reaches the app — which is exactly what the test has to find out.
enum MicMode: String, CaseIterable, Identifiable {
    case airpods = "Microfono AirPods"
    case airpodsHQ = "AirPods alta qualità (iOS 26)"
    case phone = "Microfono iPhone"
    var id: String { rawValue }
}

/// The language spoken around you: what the recognizer listens for.
enum HeardLanguage: String, CaseIterable, Identifiable, Codable {
    case enGB = "en-GB", enUS = "en-US", itIT = "it-IT", frFR = "fr-FR", esES = "es-ES", deDE = "de-DE", ruRU = "ru-RU"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .enGB: "Inglese (UK)"
        case .enUS: "Inglese (US)"
        case .itIT: "Italiano"
        case .frFR: "Francese"
        case .esES: "Spagnolo"
        case .deDE: "Tedesco"
        case .ruRU: "Russo"
        }
    }
}

/// The evening diary: why this moment was missed. This is the question the whole
/// product hangs on — how often is it really an unknown word?
enum MomentLabel: String, CaseIterable, Identifiable, Codable {
    case unknownWord = "Parola che non conoscevo"
    case knownNotRecognized = "Parola nota, non riconosciuta"
    case idiom = "Modo di dire / slang"
    case speedAccent = "Troppo veloce / accento"
    case cultural = "Riferimento culturale"
    case badAudio = "Audio incomprensibile"
    case transcriptWrong = "Trascrizione sbagliata"
    case notAMiss = "Falso allarme"
    var id: String { rawValue }
}

struct TestEvent: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let source: String
    let latencyMs: Int?
    let text: String
    /// File name only: the app's folder path changes on every reinstall.
    let audioFile: String?
    var label: MomentLabel?

    var audioURL: URL? {
        audioFile.map { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent($0) }
    }
}

/// Keeps only the last few seconds of audio in memory. Nothing is written to
/// disk unless a trigger asks for a snapshot.
nonisolated final class RingBuffer: @unchecked Sendable {
    private var buffers: [AVAudioPCMBuffer] = []
    private var frames: AVAudioFramePosition = 0
    private let lock = NSLock()
    let maxSeconds: Double

    init(maxSeconds: Double) { self.maxSeconds = maxSeconds }

    func reset() {
        lock.lock(); buffers.removeAll(); frames = 0; lock.unlock()
    }

    func append(_ source: AVAudioPCMBuffer) {
        guard let copy = RingBuffer.copy(source) else { return }
        lock.lock()
        buffers.append(copy)
        frames += AVAudioFramePosition(copy.frameLength)
        let limit = AVAudioFramePosition(maxSeconds * copy.format.sampleRate)
        while frames > limit, let first = buffers.first, buffers.count > 1 {
            frames -= AVAudioFramePosition(first.frameLength)
            buffers.removeFirst()
        }
        lock.unlock()
    }

    /// The last `seconds` of audio as one buffer.
    func snapshot(seconds: Double) -> AVAudioPCMBuffer? {
        lock.lock()
        let parts = buffers
        lock.unlock()
        guard let format = parts.last?.format else { return nil }
        let wanted = AVAudioFrameCount(seconds * format.sampleRate)
        var picked: [AVAudioPCMBuffer] = []
        var total: AVAudioFrameCount = 0
        for b in parts.reversed() {
            picked.insert(b, at: 0)
            total += b.frameLength
            if total >= wanted { break }
        }
        guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let dst = out.floatChannelData else { return nil }
        let channels = Int(format.channelCount)
        var offset = 0
        for b in picked {
            guard let src = b.floatChannelData else { continue }
            let n = Int(b.frameLength)
            for c in 0..<channels {
                memcpy(dst[c].advanced(by: offset), src[c], n * MemoryLayout<Float>.size)
            }
            offset += n
        }
        out.frameLength = AVAudioFrameCount(offset)
        return out
    }

    static func copy(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength),
              let s = src.floatChannelData, let d = dst.floatChannelData else { return nil }
        dst.frameLength = src.frameLength
        let n = Int(src.frameLength)
        for c in 0..<Int(src.format.channelCount) {
            memcpy(d[c], s[c], n * MemoryLayout<Float>.size)
        }
        return dst
    }
}

/// Makes sure a continuation is resumed exactly once, whichever thread the
/// speech callbacks arrive on.
nonisolated final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var micMode: MicMode = .airpods
    @Published private(set) var listening = false
    @Published var language: HeardLanguage = .enGB { didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") } }
    /// Saved to disk on every change: the diary has to survive days and restarts.
    @Published private(set) var events: [TestEvent] = [] { didSet { persist() } }
    @Published private(set) var status = "Fermo"
    @Published private(set) var startedAt: Date?
    @Published private(set) var batteryStart: Float?
    @Published private(set) var batteryNow: Float?
    @Published private(set) var interruptions = 0
    @Published private(set) var routeName = "—"

    /// How much audio a trigger explains, and how much stays in memory.
    let explainSeconds: Double = 8
    private let ring = RingBuffer(maxSeconds: 15)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let speaker = AVSpeechSynthesizer()
    private var recognizer: SFSpeechRecognizer? { SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)) }
    private var batteryTimer: Timer?
    private var commandsReady = false
    private var reviewPlayer: AVAudioPlayer?

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "language"), let l = HeardLanguage(rawValue: raw) { language = l }
        if let data = try? Data(contentsOf: Engine.diaryURL),
           let saved = try? JSONDecoder().decode([TestEvent].self, from: data) { events = saved }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(raw) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshRoute() }
        }
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        let speech = await Engine.requestSpeechAuthorization()
        return mic && speech
    }

    // MARK: - Listening

    func start() async {
        guard !listening else { return }
        guard await requestPermissions() else { status = "Permessi negati: microfono o riconoscimento vocale"; return }
        do {
            try configureSession()
            try startEngine()
            setupRemoteCommands()
            ring.reset()
            listening = true
            startedAt = Date()
            batteryStart = currentBattery()
            batteryNow = batteryStart
            interruptions = 0
            status = "In ascolto · \(micMode.rawValue)"
            refreshRoute()
            batteryTimer?.invalidate()
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.batteryNow = self?.currentBattery() }
            }
            log(source: "Sistema", text: "Ascolto avviato (\(micMode.rawValue))")
        } catch {
            status = "Errore: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard listening else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        batteryTimer?.invalidate()
        batteryNow = currentBattery()
        listening = false
        status = "Fermo"
        log(source: "Sistema", text: "Ascolto fermato")
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        switch micMode {
        case .airpods:
            options.insert(.allowBluetooth)
        case .airpodsHQ:
            options.insert(.allowBluetooth)
            // iOS 26 high-quality AirPods recording. If Xcode marks this line as an
            // error, delete these three lines: the other two modes still work.
            if #available(iOS 26.0, *) {
                options.insert(.bluetoothHighQualityRecording)
            }
        case .phone:
            options.insert(.allowBluetoothA2DP)
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Engine.makeTap(ring: ring))
        // A silent loop keeps the app the "Now Playing" app, which is what lets it
        // receive the AirPods press (play/pause) at all.
        if player.engine == nil { engine.attach(player) }
        let outFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
        engine.prepare()
        try engine.start()
        if let silence = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(outFormat.sampleRate)) {
            silence.frameLength = silence.frameCapacity
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Encore · in ascolto",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }

    private func setupRemoteCommands() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        guard !commandsReady else { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        let handlers: [(MPRemoteCommand, String)] = [
            (center.togglePlayPauseCommand, "AirPods · play/pausa"),
            (center.playCommand, "AirPods · play"),
            (center.pauseCommand, "AirPods · pausa"),
            (center.nextTrackCommand, "AirPods · doppia pressione"),
            (center.previousTrackCommand, "AirPods · tripla pressione"),
        ]
        for (command, name) in handlers {
            command.isEnabled = true
            command.addTarget { _ in
                Task { @MainActor in await Engine.shared.trigger(source: name) }
                return .success
            }
        }
    }

    // MARK: - The test: gesture → last seconds → Italian transcript

    func trigger(source: String) async {
        guard listening else {
            log(source: source, text: "Gesto ricevuto, ma l'ascolto non è attivo")
            return
        }
        let t0 = Date()
        guard let snapshot = ring.snapshot(seconds: explainSeconds) else {
            log(source: source, text: "Gesto ricevuto, ma non c'era ancora audio in memoria")
            return
        }
        let file = save(snapshot)
        let text = await transcribe(snapshot)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        events.insert(TestEvent(date: t0, source: source, latencyMs: ms, text: text, audioFile: file), at: 0)
        speak(text.isEmpty ? "Non ho sentito niente" : text)
    }

    private func transcribe(_ buffer: AVAudioPCMBuffer) async -> String {
        await Engine.recognize(buffer, with: recognizer)
    }

    // The audio tap, the speech callbacks and the permission callback all run off
    // the main thread. Building them in nonisolated functions keeps Swift from
    // assuming they're on the main actor (with Xcode 26's default settings that
    // assumption would crash the app the first time audio arrives).
    nonisolated static func makeTap(ring: RingBuffer) -> AVAudioNodeTapBlock {
        { buffer, _ in ring.append(buffer) }
    }

    nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    nonisolated static func recognize(_ buffer: AVAudioPCMBuffer, with recognizer: SFSpeechRecognizer?) async -> String {
        guard let recognizer, recognizer.isAvailable else { return "(riconoscimento vocale non disponibile per questa lingua)" }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.append(buffer)
        request.endAudio()
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let once = Once()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { cont.resume(returning: result.bestTranscription.formattedString) }
                } else if let error {
                    if once.claim() { cont.resume(returning: "(errore: \(error.localizedDescription))") }
                }
            }
        }
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: String(text.prefix(140)))
        utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        utterance.rate = 0.45
        speaker.speak(utterance)
    }

    private func save(_ buffer: AVAudioPCMBuffer) -> String? {
        let name = "momento-\(Int(Date().timeIntervalSince1970)).caf"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        do {
            let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try file.write(from: buffer)
            return name
        } catch {
            return nil
        }
    }

    // MARK: - The diary

    private static var diaryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diario.json")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: Engine.diaryURL, options: .atomic) }
    }

    func setLabel(_ label: MomentLabel?, for id: UUID) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].label = label
    }

    func deleteAll() {
        for e in events { if let url = e.audioURL { try? FileManager.default.removeItem(at: url) } }
        events = []
    }

    func play(_ event: TestEvent) {
        guard !listening, let url = event.audioURL else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        reviewPlayer = try? AVAudioPlayer(contentsOf: url)
        reviewPlayer?.play()
    }

    // MARK: - Bookkeeping

    private func log(source: String, text: String) {
        events.insert(TestEvent(date: Date(), source: source, latencyMs: nil, text: text, audioFile: nil), at: 0)
    }

    private func handleInterruption(_ raw: UInt?) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            interruptions += 1
            log(source: "Sistema", text: "Interruzione dell'audio (chiamata, Siri, altra app?)")
        } else if listening {
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
            player.play()
            log(source: "Sistema", text: "Ascolto ripreso dopo l'interruzione")
        }
    }

    private func refreshRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        let input = route.inputs.first?.portName ?? "nessuno"
        let output = route.outputs.first?.portName ?? "nessuno"
        routeName = "Microfono: \(input) · Uscita: \(output)"
    }

    private func currentBattery() -> Float? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : level
    }

    // MARK: - Results

    var minutesListening: Double {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt) / 60
    }

    var batteryPerHour: Double? {
        guard let a = batteryStart, let b = batteryNow, minutesListening >= 5 else { return nil }
        return Double(a - b) * 100 / (minutesListening / 60)
    }

    var measured: [TestEvent] { events.filter { $0.latencyMs != nil } }
    var labelled: [TestEvent] { measured.filter { $0.label != nil } }

    func count(prefix: String) -> Int { measured.filter { $0.source.hasPrefix(prefix) }.count }

    var averageLatency: Int? {
        let values = measured.compactMap(\.latencyMs)
        return values.isEmpty ? nil : values.reduce(0, +) / values.count
    }

    func report() -> String {
        var lines = [
            "ENCORE · risultati del test",
            "Modalità microfono: \(micMode.rawValue)",
            routeName,
            String(format: "Minuti di ascolto: %.0f", minutesListening),
            "Interruzioni: \(interruptions)",
            "Batteria: " + (batteryPerHour.map { String(format: "%.1f%% all'ora", $0) } ?? "servono almeno 5 minuti"),
            "Gesti AirPods ricevuti: \(count(prefix: "AirPods"))",
            "Gesti tasto Azione ricevuti: \(count(prefix: "Tasto Azione"))",
            "Latenza media (gesto → testo): " + (averageLatency.map { "\($0) ms" } ?? "—"),
            "Lingua ascoltata: \(language.label)",
            "",
            "DIARIO · perché ti è sfuggito (\(labelled.count) momenti etichettati su \(measured.count))",
        ]
        for l in MomentLabel.allCases {
            let n = labelled.filter { $0.label == l }.count
            if n > 0 { lines.append("  \(l.rawValue): \(n) (\(n * 100 / max(1, labelled.count))%)") }
        }
        lines.append("")
        let fmt = DateFormatter(); fmt.dateFormat = "dd/MM HH:mm:ss"
        for e in events.reversed() {
            lines.append("\(fmt.string(from: e.date)) · \(e.source)" + (e.latencyMs.map { " · \($0) ms" } ?? "") + (e.label.map { " · [\($0.rawValue)]" } ?? "") + " · \(e.text)")
        }
        return lines.joined(separator: "\n")
    }
}
