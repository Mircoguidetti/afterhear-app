import AppKit
import AVFoundation
import CoreAudio
import MediaPlayer

/// The tap with the ear (the map of 07/10: the ear is the interface, the screen is the reminder).
/// In a video or a podcast the tap doesn't end with "read an explanation" but with "hear the sentence
/// again and get it": a short sound at once, the sentence again a little slower with the real voice
/// while its text goes to our server, then (with headphones) one line said in your language, the
/// sentence again at normal speed, and the video goes on. The card stays on the screen, silent, for
/// whoever looks. In a call there is never a voice in your ears: there it's written (fixed rule).
@MainActor
final class EarFlow {
    static let shared = EarFlow()

    /// What the AirPods do while it speaks: once = more (it stops, the card stays, the video waits),
    /// twice = skip (the video goes on now), three times = keep it for tonight and go on. A long press
    /// belongs to the Mac (noise control, Siri): it never reaches an app.
    enum Gesture { case more, skip, later }

    enum Chime { case here, more }

    /// The sentence again, a little slower: slow enough to separate the words, still the same voice.
    static let slowRate: Float = 0.8
    /// After the slow replay, how long the line may still take before the video goes on without it.
    static let patience: Double = 3.5

    /// Where sound goes: the Mac's speakers and voice, or a recorder in the self-test.
    var output: EarOutput = SystemEarOutput()

    private(set) var running = false
    /// "More": everything stops, the video stays paused with the card.
    private(set) var held = false
    private var stopped = false
    private var replay: Task<Void, Never>?
    /// The explanation came too late: the video went on, the card comes on the screen alone.
    private(set) var gaveUp = false
    private var explained = false
    private var watchdog: Task<Void, Never>?
    private var started = Date()
    /// What a gesture did last, for the self-test.
    private(set) var lastGesture: Gesture?
    /// Called when the flow lets the video go (skip, later, the end, or the line taking too long).
    var resume: @MainActor () -> Void = { AppModel.shared.resumeVideo() }
    /// Taps resolved by hearing the sentence again (pause = tap, no server), and how many were tried.
    static var resolvedByReplay: Int {
        get { UserDefaults.standard.integer(forKey: "earResolvedByReplay") }
        set { UserDefaults.standard.set(newValue, forKey: "earResolvedByReplay") }
    }
    static var replayOnlyTried: Int {
        get { UserDefaults.standard.integer(forKey: "earReplayOnlyTried") }
        set { UserDefaults.standard.set(newValue, forKey: "earReplayOnlyTried") }
    }

    // MARK: When

    /// The ear in this situation: a video or a podcast (never a call, never a song: there the replay
    /// stays a button), and the setting on.
    static func wanted(_ context: AppContext) -> Bool {
        context == .video && UserDefaults.standard.bool(forKey: Key.earAnswers)
    }

    /// The voice speaks only into headphones: with the speakers on, the line stays written.
    static var speaks: Bool { Headphones.on() }

    // MARK: What it says

    /// What the ear does for one card.
    struct Plan: Equatable {
        /// The words the line is about, with the real voice, on the clip's clock.
        var cut: ClosedRange<Double>?
        /// The line said in your language; nil when hearing the sentence again is enough, or the
        /// answer needs the eyes.
        var line: String?
        /// A second small sound: there's more on the screen (a list, a spelling, numbers).
        var moreOnScreen: Bool
    }

    /// The rule per kind of gap (07/10): not heard = no voice, only the sentence slower then normal;
    /// a word or an idiom = the word with the real voice, then its sense; who or what = one line; the
    /// tone = "it was ironic: …"; numbers, lists, spelling = on the screen, with a sound.
    static func plan(for m: Moment) -> Plan {
        let cause = m.pieces.first?.cause ?? ""
        let hearing = CardShape.hearing.contains(cause)
        let say = clean(m.say)
        if hearing && say == nil { return Plan(cut: nil, line: nil, moreOnScreen: false) }
        if cause == "numbers" && say == nil { return Plan(cut: nil, line: nil, moreOnScreen: true) }
        var line = say
        // An older server without "say": the start of "In practice", if it's one short sentence.
        if line == nil, let practice = clean(m.inPractice) {
            let first = practice.split(whereSeparator: { ".!?;".contains($0) }).first.map(String.init) ?? practice
            if first.split(separator: " ").count <= 14 { line = first.trimmingCharacters(in: .whitespaces) }
        }
        let cut = line == nil ? nil : cutRange(m)
        return Plan(cut: cut, line: line, moreOnScreen: line == nil && !m.pieces.isEmpty)
    }

    private static func clean(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Where the words of "cut" (or the first piece) are in the sentence, from the recogniser's word
    /// times. Nil when they can't be found word for word: better no cut than the wrong one. The margins
    /// come from bench/wordtimes.py on AMI meetings (07/10): 0.10 s before and 0.18 s after give the whole
    /// word in about 8 cases of 10 on both recognisers (0.06/0.12 gave 2 in 3).
    static func cutRange(_ m: Moment) -> ClosedRange<Double>? {
        guard let times = m.wordTimes, !times.isEmpty,
              let target = clean(m.cut) ?? clean(m.pieces.first?.heardAs) ?? clean(m.pieces.first?.text) else { return nil }
        let wanted = Memory.key(target).split(separator: " ").map(String.init)
        let have = times.map { Memory.key($0.text) }
        guard !wanted.isEmpty, wanted.count <= have.count else { return nil }
        for i in 0...(have.count - wanted.count) where Array(have[i..<(i + wanted.count)]) == wanted {
            let a = times[i].start, b = times[i + wanted.count - 1].end
            guard b > a else { return nil }
            return max(0, a - 0.10)...(b + 0.18)
        }
        return nil
    }

    // MARK: The flow

    /// The tap: the sound "I'm here" at once, and the AirPods' presses come to us while it runs.
    func begin() {
        stopped = false
        held = false
        gaveUp = false
        explained = false
        lastGesture = nil
        onMore = nil
        onSkip = nil
        started = Date()
        running = true
        output.chime(.here)
        Remote.shared.take()
    }

    /// The sentence again, a little slower, while the text goes to our server. No clip: it was already
    /// played after your pause, only the patience is armed.
    func replaySlowly(_ url: URL?, turn: Turn) {
        replay?.cancel()
        if let url {
            replay = Task { @MainActor [output] in
                await output.play(url, from: max(0, turn.start - 0.3), to: turn.end + 0.4, rate: Self.slowRate)
            }
        } else {
            replay = nil
        }
        // The line may come late (a slow network): after the replay and a little patience, the video
        // goes on and the card arrives on the screen by itself.
        watchdog?.cancel()
        let slow = replay
        watchdog = Task { @MainActor [weak self] in
            await slow?.value
            try? await Task.sleep(nanoseconds: UInt64(Self.patience * 1_000_000_000))
            guard let self, !Task.isCancelled, self.running, !self.explained, !self.stopped, !self.held else { return }
            self.gaveUp = true
            self.output.chime(.more)
            self.end(resume: true)
        }
    }

    /// The explanation is here: the line, the sentence at normal speed, and the video goes on. Returns
    /// how long you were out of the video (the time to come back in, 07/10), nil if it didn't run.
    @discardableResult
    func finish(_ moment: Moment, clip: URL?, turn: Turn?) async -> Int? {
        explained = true
        watchdog?.cancel()
        guard running, !gaveUp else { return nil }
        await replay?.value
        guard !stopped else { return reentry() }
        let plan = Self.plan(for: moment)
        if Self.speaks {
            if let cut = plan.cut, let clip {
                await output.play(clip, from: cut.lowerBound, to: cut.upperBound, rate: 1)
            }
            if let line = plan.line, !stopped {
                await output.say(line, language: AppSettings.current.native.rawValue)
            } else if plan.moreOnScreen {
                output.chime(.more)
            }
        } else if plan.moreOnScreen || plan.line != nil {
            // Speakers: the line is on the screen; a sound says it's there.
            output.chime(.more)
        }
        guard !stopped else { return reentry() }
        if let clip, let turn {
            await output.play(clip, from: max(0, turn.start - 0.3), to: turn.end + 0.4, rate: 1)
        }
        guard !stopped else { return reentry() }
        end(resume: true)
        return reentry()
    }

    /// Offline or the server failed: a second sound, the sentence ends, then the caller lets the video
    /// go on with the card still there.
    func failed() async {
        explained = true
        watchdog?.cancel()
        guard running else { return }
        output.chime(.more)
        await replay?.value
        running = false
        Remote.shared.release()
    }

    /// An AirPods press while it runs.
    func gesture(_ g: Gesture) {
        guard running else { return }
        lastGesture = g
        switch g {
        case .more:
            held = true
            halt()
            end(resume: false)
        case .skip:
            halt()
            end(resume: true)
        case .later:
            halt()
            end(resume: true)
            AppModel.shared.keepForTonight()
        }
    }

    /// Continue, a new tap, or the card closed: stop talking at once.
    func stop() {
        guard running else { return }
        halt()
        end(resume: false)
    }

    private func halt() {
        stopped = true
        replay?.cancel()
        watchdog?.cancel()
        output.stop()
    }

    private func end(resume: Bool) {
        guard running else { return }
        running = false
        Remote.shared.release()
        if resume { self.resume() }
    }

    private func reentry() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

    // MARK: Pause = tap, without the server

    /// You paused a video right after people spoke (the AirPods, the space bar): the sentence again,
    /// slower, from the sound kept on this Mac. Nothing leaves the Mac. If that was enough, you play
    /// the video again and that's all; a press while it's still paused asks for the explanation.
    func pausedByYou(clip: URL, turn: Turn, pausedAt: Date, explain: @escaping () -> Void, playAgain: @escaping () -> Void) {
        begin()
        Self.replayOnlyTried += 1
        onMore = explain
        onSkip = playAgain
        replay = Task { @MainActor [output] in
            await output.play(clip, from: max(0, turn.start - 0.3), to: turn.end + 0.4, rate: Self.slowRate)
        }
        Task { @MainActor in
            await replay?.value
            // The flow ends; the presses stay ours a moment longer, for "explain it".
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.running, self.onMore != nil { self.running = false; Remote.shared.release() }
            self.onMore = nil
            self.onSkip = nil
        }
    }

    /// The video plays again after a replay-only pause: hearing it again was enough.
    func playedAgainAfterReplay() {
        guard onMore != nil else { return }
        Self.resolvedByReplay += 1
        onMore = nil
        onSkip = nil
        if running { running = false; Remote.shared.release() }
    }

    fileprivate var onMore: (() -> Void)?
    fileprivate var onSkip: (() -> Void)?

    func press(_ g: Gesture) {
        // After a replay-only pause: once = explain it, twice = play again.
        if let more = onMore {
            onMore = nil
            let skip = onSkip
            onSkip = nil
            halt()
            running = false
            Remote.shared.release()
            if g == .more { more() } else { skip?() }
            return
        }
        gesture(g)
    }

    // MARK: Tonight, with the ear

    /// One moment of the evening: the voice, two seconds to try by yourself, the line, the voice again.
    func evening(_ moment: Moment, clip: URL, turn: Turn) async {
        stopped = false
        await output.play(clip, from: max(0, turn.start - 0.3), to: turn.end + 0.4, rate: 1)
        guard !stopped else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !stopped else { return }
        let line = Self.plan(for: moment).line ?? Self.clean(moment.inPractice) ?? moment.pieces.first.map { "\($0.text): \($0.gloss ?? $0.meaning)" }
        if let line { await output.say(line, language: AppSettings.current.native.rawValue) }
        guard !stopped else { return }
        await output.play(clip, from: max(0, turn.start - 0.3), to: turn.end + 0.4, rate: 1)
    }

    func stopEvening() {
        stopped = true
        output.stop()
    }

    /// Says one line in your ear (a question's answer), when headphones are on.
    func sayIfHeadphones(_ text: String) {
        guard Self.speaks, let line = Self.clean(text) else { return }
        Task { @MainActor in await output.say(line, language: AppSettings.current.native.rawValue) }
    }
}

// MARK: - Sound out

/// Where the ear's sound goes. The self-test swaps in a recorder.
@MainActor
protocol EarOutput: AnyObject {
    func chime(_ kind: EarFlow.Chime)
    func play(_ url: URL, from: Double, to: Double, rate: Float) async
    func say(_ text: String, language: String) async
    func stop()
}

/// The Mac's own: the clip from the kept sound, the system's voice in your language (on this Mac,
/// free, no service), and two of the Mac's short sounds.
@MainActor
final class SystemEarOutput: NSObject, EarOutput, AVSpeechSynthesizerDelegate {
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var spoken: CheckedContinuation<Void, Never>?
    private var playing: CheckedContinuation<Void, Never>?
    private var timer: Task<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func chime(_ kind: EarFlow.Chime) {
        NSSound(named: kind == .here ? "Tink" : "Pop")?.play()
    }

    func play(_ url: URL, from: Double, to: Double, rate: Float) async {
        finishPlaying()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.enableRate = true
        p.rate = rate
        p.currentTime = min(max(0, from), max(0, p.duration - 0.05))
        p.prepareToPlay()
        player = p
        guard p.play() else { return }
        let seconds = max(0.1, (min(to, p.duration) - p.currentTime) / Double(rate))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            playing = c
            timer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.finishPlaying()
            }
        }
    }

    private func finishPlaying() {
        timer?.cancel()
        player?.stop()
        playing?.resume()
        playing = nil
    }

    func say(_ text: String, language: String) async {
        finishSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Voice.best(for: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            spoken = c
            synth.speak(utterance)
        }
    }

    private func finishSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        spoken?.resume()
        spoken = nil
    }

    func stop() {
        finishPlaying()
        finishSpeaking()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.spoken?.resume(); self.spoken = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.spoken?.resume(); self.spoken = nil }
    }
}

/// The system's voice for your language: the best quality installed (enhanced or premium, downloaded
/// once in System Settings), never a novelty voice.
enum Voice {
    static func best(for language: String) -> AVSpeechSynthesisVoice? {
        let code = String(language.prefix(2)).lowercased()
        let mine = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(code) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        return mine.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: code)
    }

    /// Whether only the basic voice is installed: Settings suggests the better one.
    static func onlyBasic(for language: String) -> Bool {
        (best(for: language)?.quality ?? .default) == .default
    }
}

/// Headphones on: AirPods or any Bluetooth audio, or the headphone jack. The voice only speaks there.
enum Headphones {
    /// The self-test sets it.
    static var override: Bool?

    static func on() -> Bool {
        if let override { return override }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
           transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        // The Mac's own output with something in the jack: the data source says "headphones".
        var source: UInt32 = 0
        address.mSelector = kAudioDevicePropertyDataSource
        address.mScope = kAudioDevicePropertyScopeOutput
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr, source == 0x6864_706E { // 'hdpn'
            return true
        }
        return false
    }
}

/// The AirPods' presses while the ear runs: the Mac sends them to the app playing sound, and while it
/// speaks that's LEXALIE. Once = more, twice = skip, three times = for tonight.
@MainActor
final class Remote {
    static let shared = Remote()
    private var targets: [(MPRemoteCommand, Any)] = []

    func take() {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ g: EarFlow.Gesture) {
            let t = command.addTarget { _ in
                Task { @MainActor in EarFlow.shared.press(g) }
                return .success
            }
            targets.append((command, t))
        }
        on(center.togglePlayPauseCommand, .more)
        on(center.playCommand, .more)
        on(center.pauseCommand, .more)
        on(center.nextTrackCommand, .skip)
        on(center.previousTrackCommand, .later)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "LEXALIE"]
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    func release() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        // The squeeze for "help me now" (Settings) keeps its own.
        if !RemoteTap.shared.isOn {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }
}
