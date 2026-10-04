import AVFoundation
import WatchConnectivity
import WatchKit

/// The Watch as the table microphone (docs/BRAIN.md § 11.2, § 19.18): it records by itself,
/// screen off, wrist down (UIBackgroundModes audio), when the iPhone stays in the pocket or the
/// bag, or isn't there. Compressed audio (AAC, 16 kHz) and your marks stay on the Watch; when
/// you stop, they go to the iPhone, which transcribes them at night like its own.
/// A phone call or Siri can interrupt it: it starts again by itself when they end.
final class WatchRecorder: NSObject, ObservableObject {
    static let shared = WatchRecorder()

    @Published private(set) var recording = false
    @Published private(set) var marks: [Date] = []
    private var recorder: AVAudioRecorder?
    private var start = Date()
    private var file: URL?
    /// Three hours at most: then it stops, to keep the Watch's battery and space.
    static let maxSeconds: TimeInterval = 3 * 3600
    private var limit: Timer?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended, self?.recording == true { self?.recorder?.record() }
        }
    }

    func toggle() {
        recording ? stop() : begin()
    }

    func begin() {
        guard !recording else { return }
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { if granted { self.startNow() } }
        }
    }

    private func startNow() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 24_000]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else { return }
        self.recorder = recorder
        file = url
        start = Date()
        marks = []
        recording = true
        WKInterfaceDevice.current().play(.start)
        limit = Timer.scheduledTimer(withTimeInterval: Self.maxSeconds, repeats: false) { [weak self] _ in self?.stop() }
    }

    /// One tap while the Watch records: the mark stays with the audio.
    func mark(minutesAgo: Double = 0) {
        guard recording else { return }
        marks.append(Date().addingTimeInterval(-minutesAgo * 60))
        WKInterfaceDevice.current().play(.click)
    }

    func stop() {
        guard recording, let recorder, let file else { return }
        recorder.stop()
        limit?.invalidate()
        recording = false
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        WKInterfaceDevice.current().play(.stop)
        // Nothing marked: the audio goes now, nothing is sent.
        guard !marks.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        // Sent in the background, even if the iPhone is far: it arrives when they're close again.
        WCSession.default.transferFile(file, metadata: [
            "watchRecording": true,
            "start": start.timeIntervalSince1970,
            "marks": marks.map(\.timeIntervalSince1970),
        ])
        marks = []
    }
}
