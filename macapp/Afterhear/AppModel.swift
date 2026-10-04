import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI

enum ListenState: Equatable {
    case starting
    case listening
    case paused
    case needsPermission(String)
}

/// Ties everything together: shortcut → last seconds → transcript on the Mac →
/// names and numbers removed → server → panel → diary.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var state: ListenState = .starting
    @Published private(set) var hotKeyReady = false
    /// True when the double ⌥ gesture is on but macOS hasn't granted Accessibility yet.
    @Published private(set) var needsAccessibility = false
    /// Who you're talking with right now; every moment gets this label.
    @Published var talkingWith: String? = UserDefaults.standard.string(forKey: "talkingWith") {
        didSet { UserDefaults.standard.set(talkingWith, forKey: "talkingWith") }
    }
    let store = Store()

    private let audio = SystemAudio()
    fileprivate let live = LiveTranscriber()
    private let panel = FloatingPanel()
    private var hotKey: HotKey?
    private var doubleTap: DoubleTapOption?
    fileprivate var sorry: SorryDetector?
    private var listeningTimer: Timer?
    private var memoryTimer: Timer?
    private var micTimer: Timer?
    private var coachTimer: Timer?
    private var vocabularyTimer: Timer?
    private var catchUpKey: HotKey?
    private var nowKey: HotKey?
    private var powerTimer: Timer?
    private var pauseTimer: Timer?
    /// Below 20% and not charging: no live transcription, marks are kept as sound (Power).
    @Published private(set) var lowBattery = false
    @Published private(set) var waiting = PendingMark.all.count
    private var player: AVAudioPlayer?
    fileprivate var busy = false

    var menuIcon: String {
        switch state {
        case .listening: "waveform"
        case .paused: "pause.circle"
        case .starting, .needsPermission: "exclamationmark.circle"
        }
    }

    func boot() {
        AppSettings.registerDefaults()
        Reachability.shared.start()
        // One look everywhere: the panel's dark, warm style in every window (owner, 02/10).
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Voices never leave the devices (§ 19.26): the old "sync the real voice" is off for good.
        UserDefaults.standard.set(false, forKey: Key.syncAudio)
        hotKey = HotKey { Task { @MainActor in await AppModel.shared.captureMoment() } }
        hotKeyReady = hotKey != nil
        catchUpKey = HotKey(key: kVK_ANSI_S, id: 2) { Task { @MainActor in await CallCoach.shared.catchUp() } }
        nowKey = HotKey(key: kVK_ANSI_D, id: 3) { Task { @MainActor in await AppModel.shared.captureMoment(now: true) } }
        coachTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in await CallCoach.shared.tick() }
        }
        RemoteTap.shared.apply()
        doubleTap = DoubleTapOption(
            mark: { Task { @MainActor in await AppModel.shared.captureMoment() } },
            now: { Task { @MainActor in await AppModel.shared.captureMoment(now: true) } }
        )
        doubleTap?.onSeen = { Task { @MainActor in AppModel.shared.objectWillChange.send() } }
        sorry = SorryDetector { Task { @MainActor in await AppModel.shared.captureMoment(trigger: "sorry") } }
        // The second encounter: what the others said lately, checked against what you learned before.
        // A call starts or ends: the microphone follows (applyMicrophone).
        micTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.applyMicrophone() }
        }
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                let model = AppModel.shared
                if model.state == .listening, !model.busy {
                    model.showRecap()
                    Memory.shared.scan(model.live.text(last: 30))
                    if let mine = model.sorry?.live.text(last: 30) { Memory.shared.scanMine(mine) }
                }
                await ModelWatch.shared.tick()
                // Nobody spoke for a few minutes: the recogniser leaves memory until the next voice.
                await Parakeet.shared.unloadIfIdle()
            }
        }
        // What the recogniser should expect: people, calls, the expressions you're learning.
        vocabularyTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refreshVocabulary() }
        }
        // Pause = tap (owner, 03/10): a song or a video you pause mid-line.
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.watchPauses() }
        }
        checkPower()
        powerTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                let model = AppModel.shared
                model.checkPower()
                // Marks kept offline (a plane, no Wi-Fi): explained as soon as the server answers again.
                if !model.lowBattery, model.waiting > 0, !model.busy { await model.transcribeWaiting(quiet: true) }
                // Explained offline (a plane): the full explanation from Gemini once the server answers.
                if !model.busy { await model.upgradeOffline() }
            }
        }
        // Count listening time, to measure taps per hour.
        listeningTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                if AppModel.shared.state == .listening { AppModel.shared.store.addListening(seconds: 30) }
            }
        }
        let ring = audio.ring
        ContextDetector.soundPlaying = { Clip.loudness(ring.last(3).samples) > 0.01 }
        let live = self.live
        audio.onSamples = { samples, count, rate in live.append(samples, count: count, rate: rate) }
        audio.onStop = { error in
            Task { @MainActor in AppModel.shared.state = .needsPermission(error.localizedDescription) }
        }
        Task { await start() }
    }

    func start() async {
        state = .starting
        do {
            live.configure(language: AppSettings.current.heard)
            try await audio.start()
            state = .listening
            applyTriggers()
        } catch {
            state = .needsPermission(String(localized: "Afterhear needs the \"Screen & System Audio Recording\" permission. Once it's on, reopen Afterhear."))
        }
    }

    func togglePause() async {
        if state == .listening {
            await audio.stop()
            live.stop()
            state = .paused
            applyTriggers()
        } else {
            await start()
        }
    }

    /// Starts or stops the double ⌥ and "sorry?" triggers to match settings and state.
    func applyTriggers() {
        let settings = AppSettings.current
        let on = state == .listening
        if on && settings.doubleTap {
            doubleTap?.start()
            needsAccessibility = doubleTap?.via == nil
            if needsAccessibility { DoubleTapOption.askForPermission() }
        } else {
            doubleTap?.stop()
            needsAccessibility = false
        }
        applyMicrophone()
    }

    /// Your microphone, only in a call: there it hears your answers and your "sorry?". Watching
    /// or listening to something it stays off: with AirPods in you don't hear the room, so neither
    /// do we, and an open AirPods microphone also lowers the sound of the film (owner, 02/10).
    func applyMicrophone() {
        let settings = AppSettings.current
        let wanted = state == .listening && settings.sorry && ContextDetector.current() == .call
        if wanted {
            guard sorry?.isRunning == false else { return }
            Task {
                guard await SorryDetector.askForMicrophone() else { return }
                try? self.sorry?.start(language: settings.heard)
            }
        } else if sorry?.isRunning == true {
            sorry?.stop()
        }
    }

    /// Shown in the menu so it's clear whether the double ⌥ is live.
    var doubleTapStatus: String {
        switch doubleTap?.via {
        case "input": "\(DoubleTapOption.label): on · last key: \(doubleTap?.lastSeen ?? "none yet")"
        case "accessibility": "\(DoubleTapOption.label): on (Accessibility) · last key: \(doubleTap?.lastSeen ?? "none yet")"
        default: AppSettings.current.doubleTap ? "\(DoubleTapOption.label): permission missing" : "\(DoubleTapOption.label): off"
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Outside calls, a tap is about the last two minutes at most (§ 19.1).
    static let tapWindow: Double = 120
    /// The missed piece must have ended this recently, or we listen again (§ 19.2).
    static let freshSeconds: Double = 12
    /// A person's reaction time: you realise you didn't get it a little after the sentence ends.
    /// The sentence may have ended up to this long before the tap (owner, 02/10: 12 s was too strict).
    static let reactionSeconds: Double = 30
    /// "Now": the server's recogniser hears only the last 45 s, so it answers in a couple of seconds.
    /// With the whole two minutes it took ~4.5 s and lost the race against a 4 s wait (02/10).
    static let quickCloudSeconds: Double = 45

    /// The sentence the last "now" showed, so a second tap right after moves on to another one.
    private var lastShown: (text: String, date: Date)?

    /// The gesture: explain what I just missed.
    /// A mark (⌥⌥, ⌃⌥A, "sorry?") never stops anything: a small "Marked" and the rest waits
    /// for tonight. "Now" (right ⌥⌥, ⌃⌥D) pauses the video and explains, or shows one line in a call.
    /// `pausedAt`: you paused the video yourself and asked for the explanation (§ pause = tap): the
    /// moment is when you paused, nothing gets paused again, and Continue plays it.
    func captureMoment(trigger: String = "tap", now: Bool = false, pausedAt: Date? = nil) async {
        if pausedAt != nil { Self.offered = false } // the offer was taken: nothing to hide later
        if videoPaused, pausedAt == nil {
            resumeVideo()
            return
        }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let started = Date()
        let settings = AppSettings.current
        let context = ContextDetector.current()
        // Signals Afterhear noticed by itself (a long pause after a question) never show anything.
        let automatic = trigger == "hesitation"
        var mode: HelpMode = automatic || !now ? .silent : AppSettings.nowMode(for: context)
        // The private model isn't on this Mac yet (the first minutes after installing): "now" can't
        // answer, so it's a mark, said plainly, and nothing gets paused or stuck (owner, 02/10).
        var notReady: String? = nil
        if mode != .silent, !Parakeet.isDownloaded(settings.heard) {
            Task { await Parakeet.shared.prepare(settings.heard) }
            if case .downloading(let percent) = Parakeet.status {
                notReady = String(localized: "Marked. The private model is downloading (\(percent)%): explained as soon as it's ready.")
            } else {
                notReady = String(localized: "Marked. The private model isn't downloaded yet: Settings → Private transcription.")
            }
            mode = .silent
        }
        // The sentence you tapped on may still be ending: keep listening a moment after the tap, so
        // the clip (and Replay) has it whole. A mark lets the video run 2 s more; "now" pauses after 1 s.
        var after: Double = automatic ? 0 : (mode == .silent ? 2 : 1)
        var paused = false
        // A song playing (Spotify, Music, or recognised by Shazam): the moment is from a song (§ 17).
        let song = context == .call ? nil : NowPlaying.current()
        let source = song.map { "song: \($0.title) by \($0.artist)" } ?? (context == .video ? ContextDetector.show().map { "video: \($0)" } ?? "" : "")
        // A song with timed lyrics: the line comes from the lyrics at the song's position, not from the
        // singer's voice (owner, 03/10). No timed lyrics: the usual way, from the sound.
        if song != nil, !automatic, state == .listening,
           await songMoment(trigger: trigger, mode: mode, started: started, settings: settings) {
            return
        }
        let known = Array(store.known) + Memory.shared.knownWell + Memory.shared.dictionary
        var overlap = false
        do {
            guard state == .listening else { throw AfterhearError.paused }
            // Battery low: a mark keeps only the sound; "now" still transcribes, you asked for it.
            let hold = lowBattery && !now && !automatic
            // People (a call, a voice in the room): the sound never leaves the Mac (§ 19.25).
            let people = context == .call || sorry?.isRunning == true
            let narrow = mode == .glance
            func progress(_ step: PanelView.Progress) {
                panel.show(PanelView(phase: .progress(step)), autoHide: nil, width: narrow ? 300 : 380)
            }
            var step = PanelView.Progress(onDevice: true) // voices never leave the devices (§ 19.26)
            switch mode {
            case .silent:
                if let notReady { panel.show(PanelView(phase: .saved(notReady)), autoHide: 6, width: 400) }
                else if hold { break } else if !automatic { panel.show(PanelView(phase: .saved(trigger == "sorry" ? String(localized: "Marked: you said \"sorry?\"") : String(localized: "Marked"))), autoHide: 1.5, width: 220) }
            case .glance, .full, .pause: progress(step)
            }
            if let pausedAt {
                // Already paused by you: the sentence is the one before your pause.
                after = Date().timeIntervalSince(pausedAt)
            } else if mode != .silent {
                // "Now" lets the sentence finish (owner, 03/10): you often tap while they're still
                // talking, and half a sentence explained makes no sense. It waits for about 0.7 s of
                // quiet, at most 4 s in a video (then it pauses, at the end of the line) and 6 s
                // elsewhere, and shows the words as they come so nothing looks stuck.
                let longest: Double = context == .video ? 4 : 6
                let begun = Date()
                var quietSince: Date? = nil
                while true {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let elapsed = Date().timeIntervalSince(begun)
                    let (recent, _) = audio.ring.last(0.2)
                    if Clip.loudness(recent) < 0.01 { quietSince = quietSince ?? Date() } else { quietSince = nil }
                    if elapsed >= 0.4, let quiet = quietSince, Date().timeIntervalSince(quiet) >= 0.7 { break }
                    if elapsed >= longest { break }
                    let soFar = live.text(last: 8)
                    if !soFar.isEmpty, soFar != step.heardSoFar {
                        step.heardSoFar = soFar
                        progress(step)
                    }
                }
                after = Date().timeIntervalSince(begun)
            } else if after > 0 {
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            }
            // In a video, then stop it: nobody is waiting for you, so take the time to understand.
            // With the AirPods squeeze on, the play/pause key comes to Afterhear: the video isn't paused.
            paused = pausedAt != nil || (mode == .pause && !RemoteTap.shared.isOn && state == .listening && MediaKey.playPause())
            if mode == .pause {
                step.paused = paused
                step.pauseFailed = !paused && !RemoteTap.shared.isOn && pausedAt == nil
                progress(step)
            }
            // In a call the tap can come a minute or two after the missed words; in a video or
            // anywhere else it comes within two minutes (§ 19.1).
            var window = context == .call ? LiveTranscriber.memorySeconds : Self.tapWindow
            var (samples, rate) = audio.ring.last(window + after)
            // Quiet for two minutes, but somebody spoke before: go back to them, never "nothing"
            // when there was something to miss (owner, 03/10).
            if Clip.loudness(samples) <= 0.002, window < LiveTranscriber.memorySeconds {
                window = LiveTranscriber.memorySeconds
                (samples, rate) = audio.ring.last(window + after)
            }
            guard Clip.loudness(samples) > 0.002 else { throw AfterhearError.silence }
            let clipLength = rate > 0 ? Double(samples.count) / rate : 0
            let clipStart = Date().addingTimeInterval(-clipLength)
            // When you tapped, on the clip's clock (the clip runs a moment past it).
            let tapAt = max(0, clipLength - after)

            // The real voice, kept in full quality (§ 19.4); the 16 kHz copy only goes to the recogniser.
            let clip = store.newClipURL("m4a")
            let (voice, voiceRate) = audio.hiRing.last(clipLength)
            if voiceRate > 0, !voice.isEmpty {
                try Clip.writeVoice(voice, rate: voiceRate, to: clip)
            } else {
                try Clip.writeVoice(samples, rate: rate, to: clip)
            }
            // Kept for later: the sound stays on this Mac and is explained when it can be (battery
            // back, model downloaded, or connection back: nothing invented in the meantime).
            func keepForLater(_ message: String?, quietly: Bool = false) {
                let call = CalendarWatch.shared.current
                var marks = PendingMark.all
                marks.append(PendingMark(date: started, clipFile: clip.lastPathComponent, tapAt: tapAt, trigger: trigger,
                                         context: song != nil ? "song" : context == .other ? nil : context.rawValue,
                                         show: song.map { String($0.label.prefix(200)) } ?? (context == .video ? ContextDetector.show() : nil),
                                         call: call?.id, callTitle: call.map { String($0.title.prefix(200)) },
                                         with: talkingWith ?? call?.people.first))
                PendingMark.save(marks)
                waiting = marks.count
                Memory.shared.tapped()
                if quietly { return }
                if let message {
                    if paused { MediaKey.playPause(); paused = false }
                    panel.show(PanelView(phase: .saved(message)), autoHide: 6, width: 400)
                } else {
                    panel.show(PanelView(phase: .waiting(marks.count)), autoHide: 6, width: 400)
                }
            }
            if hold {
                keepForLater(nil)
                return
            }
            // A mark: nobody is waiting, so it goes to the queue and is worked out calmly, on the whole
            // two minutes, without holding up the next tap (owner, 02/10).
            if mode == .silent {
                keepForLater(nil, quietly: true)
                Task { await self.transcribeWaiting(quiet: true) }
                return
            }

            // "Now": Parakeet reads the clip on this Mac (~1 s for two minutes on the Neural Engine).
            // Test switch on, in a video: ElevenLabs hears the last 45 s too, only to compare tonight.
            let transcribeStart = Date()
            let compare = Self.compareCloud && context == .video ? cloudCompare(after: after, settings: settings) : nil
            let transcribedBy = live.engineName
            // On an Intel Mac the processor does the work: what the continuous transcription already
            // wrote is reused, and only the seconds after it are transcribed now (at most 45 s), so
            // the answer comes sooner and the model needs less memory (owner, 02/10).
            let words: [TimedWord]?
            if Parakeet.onProcessor {
                let clipEnd = clipStart.addingTimeInterval(clipLength)
                let earliest = clipEnd.addingTimeInterval(-min(clipLength, Self.quickCloudSeconds + after))
                let tailStart = live.isActive ? max(earliest, live.heardUntil.addingTimeInterval(-0.5)) : earliest
                let tailSeconds = max(1, clipEnd.timeIntervalSince(tailStart))
                let tail = Array(samples.suffix(Int(tailSeconds * rate)))
                let fresh = await Parakeet.shared.timedWords(tail, rate: rate, language: settings.heard,
                                                             clipStart: clipEnd.addingTimeInterval(-tailSeconds))
                let known = live.isActive ? live.timedWords(since: clipStart).filter { $0.start < tailStart } : []
                words = fresh.map { known + $0 }
            } else {
                words = await Parakeet.shared.timedWords(samples, rate: rate, language: settings.heard, clipStart: clipStart)
            }
            if words == nil {
                // The model couldn't load: kept, explained once it can (never another recogniser).
                keepForLater(String(localized: "Marked. The private model couldn't start: explained as soon as it's ready."))
                return
            }
            let conversation = Conversation.turns(others: words ?? [], mine: sorry?.live.timedWords(since: clipStart) ?? [], clipStart: clipStart)
            let hardness = Memory.shared.hardness
            // Ended within a natural reaction time (in a call: any time in the window), best first;
            // nothing that recent: the best of the whole clip.
            var ranked = Conversation.rank(conversation, tapAt: tapAt, usualDelay: store.usualDelay,
                                           freshWithin: context == .call ? nil : Self.reactionSeconds, hardness: hardness)
            if ranked.isEmpty {
                ranked = Conversation.rank(conversation, tapAt: tapAt, usualDelay: store.usualDelay, hardness: hardness)
            }
            var transcript = ""
            var turns: [Turn]? = nil
            var chosen: Int? = nil
            var alternative: Int? = nil
            // Two taps close together are two different sentences: the second never brings back the
            // one the first just showed (owner, 03/10).
            if let last = lastShown, Date().timeIntervalSince(last.date) < 30, ranked.count > 1,
               conversation[ranked[0].index].text == last.text {
                ranked.removeFirst()
            }
            if let best = ranked.first {
                lastShown = (conversation[best.index].text, Date())
                turns = conversation
                chosen = best.index
                alternative = ranked.dropFirst().first?.index
                transcript = conversation[best.index].text
                let t = conversation[best.index]
                overlap = conversation.contains { $0.isMine != t.isMine && $0.start < t.end - 0.3 && $0.end > t.start + 0.3 }
            }
            let transcribeMs = Int(Date().timeIntervalSince(transcribeStart) * 1000)
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try? FileManager.default.removeItem(at: clip)
                throw AfterhearError.noWords
            }
            let sent = Redactor.redact(transcript)
            // The sentence at once, its translation from this Mac a moment later (Apple's translator,
            // no network), then the explanation: one thing for the eyes at a time (owner, 02/10).
            if let chosen, chosen > 0 { step.before = conversation[chosen - 1].text }
            step.sentence = transcript
            progress(step)
            let heardLanguage = settings.heard, nativeLanguage = settings.native
            let quickTranslation = await withDeadline(2, { await Translator.translate(transcript, from: heardLanguage, to: nativeLanguage) })
            if let quickTranslation {
                step.translation = quickTranslation
                progress(step)
            }
            // How it was said, measured here, and the lines around it: for "maybe they meant" (§ 19.28).
            var tone = ""
            var linesBefore: [String] = [], linesAfter: [String] = []
            if let chosen {
                let t = conversation[chosen]
                linesBefore = conversation[max(0, chosen - 3)..<chosen].map(\.text)
                linesAfter = conversation[(chosen + 1)..<min(conversation.count, chosen + 3)].map(\.text)
                let onClip = (words ?? []).map { (text: $0.text, start: $0.start.timeIntervalSince(clipStart), end: $0.end.timeIntervalSince(clipStart)) }
                let inTurn = onClip.filter { $0.start >= t.start - 0.05 && $0.end <= t.end + 0.05 }
                let next = conversation.indices.contains(chosen + 1) ? conversation[chosen + 1].start : nil
                let (hi, hiRate) = audio.hiRing.last(clipLength)
                tone = ToneMeter.tags(samples: samples, rate: rate, turn: .init(start: t.start, end: t.end, words: inTurn),
                                      clipWords: onClip, next: next, voice: hi, voiceRate: hiRate,
                                      voiceStart: max(0, clipLength - (hiRate > 0 ? Double(hi.count) / hiRate : 0)))
            }
            let serverStart = Date()
            var offline = false
            let explanation: Explanation
            if !Reachability.shared.isOnline {
                // Offline: no waiting for an answer that can't come. Apple Intelligence where there is
                // one; otherwise it's saved and explained tonight, said plainly (owner, 02/10).
                if let quick = await OfflineExplainer.explain(transcript, settings: settings, source: source) {
                    explanation = quick
                } else {
                    explanation = Explanation(transcript: nil, translation: quickTranslation ?? "", intent: nil, pieces: [],
                                              provider: nil, model: nil, ms: nil)
                    step.savedOffline = true
                    step.savedReason = Self.whySaved(nil)
                    progress(step)
                }
                offline = true
            } else {
                do {
                    explanation = try await ExplainClient.explain(sent, settings: settings, known: known,
                                                                  struggling: store.struggling, watch: Memory.shared.watch,
                                                                  profile: store.listeningProfile, source: source, overlap: overlap,
                                                                  tone: tone, before: linesBefore, after: linesAfter)
                } catch {
                    // The server didn't answer: the model inside this Mac if there is one, else saved for later.
                    if let quick = await OfflineExplainer.explain(transcript, settings: settings, source: source) {
                        explanation = quick
                    } else {
                        explanation = Explanation(transcript: nil, translation: quickTranslation ?? "", intent: nil, pieces: [],
                                                  provider: nil, model: nil, ms: nil)
                        step.savedOffline = true
                        step.savedReason = Self.whySaved(error)
                        progress(step)
                    }
                    offline = true
                }
            }

            var moment = Moment(
                date: started,
                transcript: transcript,
                sent: sent,
                translation: explanation.translation,
                pieces: explanation.pieces,
                clipFile: clip.lastPathComponent,
                provider: explanation.model ?? settings.provider.rawValue,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                transcribeMs: transcribeMs,
                serverMs: Int(Date().timeIntervalSince(serverStart) * 1000),
                transcribedBy: transcribedBy
            )
            if offline { moment.offline = true }
            if mode != .silent, pausedAt == nil { moment.waitMs = Int(after * 1000) }
            moment.quickTranslation = quickTranslation
            moment.meant = explanation.meant
            if !tone.isEmpty { moment.tone = tone }
            moment.with = talkingWith
            if let intent = explanation.intent?.trimmingCharacters(in: .whitespaces), !intent.isEmpty { moment.intent = intent }
            if let call = CalendarWatch.shared.current {
                moment.call = call.id
                moment.callTitle = String(call.title.prefix(200))
                if moment.with == nil { moment.with = call.people.first }
            }
            moment.trigger = trigger
            moment.turns = turns
            moment.chosen = chosen
            moment.alternative = alternative
            moment.tapAt = tapAt
            moment.context = context == .other ? nil : context.rawValue
            if context == .video { moment.show = ContextDetector.show() }
            if let song {
                moment.context = "song"
                moment.show = String(song.label.prefix(200))
            }
            // Live captions in the call app know who spoke (experimental, needs Accessibility).
            if context == .call, moment.with == nil, let speaker = CaptionReader.recent().last(where: { $0.speaker != nil })?.speaker,
               let person = store.people.first(where: { speaker.lowercased().hasPrefix($0.name.lowercased()) }) {
                moment.with = person.name
            }
            if moment.call != nil && moment.context == nil { moment.context = "call" }
            // Text only in calls: the audio clip is not kept (a choice in Settings, or on the account).
            if moment.context == "call" && (UserDefaults.standard.bool(forKey: Key.callsTextOnly) || Memory.shared.callsTextOnly) {
                try? FileManager.default.removeItem(at: clip)
                moment.clipFile = nil
            }
            // Bad line: labelled as audio, and it doesn't count as a gap in your model.
            let badAudio = Clip.isBadAudio(samples)
            if badAudio { moment.label = .badAudio }
            store.add(moment)
            if let compare {
                let id = moment.id
                Task { @MainActor in
                    guard let heard = await compare.value,
                          var saved = self.store.moments.first(where: { $0.id == id }) else { return }
                    saved.cloudTranscript = heard
                    self.store.update(saved)
                }
            }
            Memory.shared.tapped()
            if !badAudio { Memory.shared.record("tap", pieces: moment.pieces, moment: moment) }
            AccentGuess.maybeSuggest(for: moment)
            // Offline and nothing to explain it with: the panel already says it's saved; the video goes on.
            if step.savedOffline {
                if paused { MediaKey.playPause() }
                panel.show(PanelView(phase: .progress(step)), autoHide: 6, width: narrow ? 300 : 380)
                return
            }
            switch mode {
            case .silent: break
            case .glance: panel.show(PanelView(phase: .glance(moment)), autoHide: 7, width: 300)
            case .full:
                prepare(moment)
                panel.show(PanelView(phase: .result(moment)), autoHide: 30)
            case .pause:
                prepare(moment)
                videoPaused = paused
                panel.show(PanelView(phase: .video(moment, paused: paused)), autoHide: nil)
            }
        } catch {
            if paused { MediaKey.playPause() }
            if !automatic { panel.show(PanelView(phase: .failed(error.localizedDescription)), autoHide: 5, width: 300) }
        }
    }

    /// The tap during a song: the line being sung a moment before it, from the synced lyrics, with its
    /// translation and explanation (owner, 03/10). False when the song has no timed lyrics.
    /// "Now" pauses the song (Continue, or the next tap, plays it again) and always shows the whole card,
    /// never the one-line glance (owner, 03/10). `pausedByYou`: you paused it yourself (the AirPods,
    /// the space bar), that pause was the tap.
    private func songMoment(trigger: String, mode: HelpMode, started: Date, settings: AppSettings,
                            pausedByYou: Bool = false) async -> Bool {
        guard let playing = NowPlaying.playing() else { return false }
        // The song simply ended: that's not a pause.
        if pausedByYou, let duration = playing.duration, playing.position > duration - 2 { return false }
        guard let lines = await Lyrics.synced(playing.song, duration: playing.duration), !lines.isEmpty else { return false }
        // You react a moment after the line: the one sung about 1.5 s before the tap.
        let target = max(0, playing.position - 1.5)
        let index = lines.lastIndex { $0.start <= target } ?? 0
        let turns = lines.indices.map { i in
            Turn(who: "loro", start: lines[i].start,
                 end: i + 1 < lines.count ? lines[i + 1].start : lines[i].start + 4, text: lines[i].text)
        }
        let transcript = lines[index].text
        let source = "song: \(playing.song.title) by \(playing.song.artist)"
        // The music stops while you read, as a video does.
        var paused = pausedByYou
        if mode != .silent, !pausedByYou, playing.isPlaying {
            NowPlaying.pause(playing.app)
            paused = true
        }
        if paused {
            songPaused = playing.app
            videoPaused = true
        }
        var step = PanelView.Progress(onDevice: true)
        step.song = true
        step.paused = paused
        func progress() { panel.show(PanelView(phase: .progress(step)), autoHide: nil, width: 380) }
        if mode == .silent {
            panel.show(PanelView(phase: .saved(String(localized: "Marked"))), autoHide: 1.5, width: 220)
        } else {
            if index > 0 { step.before = lines[index - 1].text }
            step.sentence = transcript
            progress()
        }
        let heardLanguage = settings.heard, nativeLanguage = settings.native
        let quickTranslation = await withDeadline(2, { await Translator.translate(transcript, from: heardLanguage, to: nativeLanguage) })
        if mode != .silent, let quickTranslation {
            step.translation = quickTranslation
            progress()
        }
        let sent = Redactor.redact(transcript)
        let known = Array(store.known) + Memory.shared.knownWell + Memory.shared.dictionary
        let serverStart = Date()
        var explanation: Explanation? = nil
        var offline = false
        var problem: Error? = nil
        if Reachability.shared.isOnline {
            do {
                explanation = try await ExplainClient.explain(sent, settings: settings, known: known, struggling: store.struggling,
                                                              watch: Memory.shared.watch, profile: store.listeningProfile, source: source,
                                                              overlap: false, tone: "",
                                                              before: lines[max(0, index - 2)..<index].map(\.text),
                                                              after: lines[(index + 1)..<min(lines.count, index + 3)].map(\.text))
            } catch {
                problem = error
            }
        }
        if explanation == nil {
            explanation = await OfflineExplainer.explain(transcript, settings: settings, source: source)
            offline = true
        }
        let result = explanation ?? Explanation(transcript: nil, translation: quickTranslation ?? "", intent: nil, pieces: [],
                                                provider: nil, model: nil, ms: nil)
        var moment = Moment(date: started, transcript: transcript, sent: sent, translation: result.translation,
                            pieces: result.pieces, clipFile: nil, provider: result.model ?? settings.provider.rawValue,
                            latencyMs: Int(Date().timeIntervalSince(started) * 1000), transcribeMs: nil,
                            serverMs: Int(Date().timeIntervalSince(serverStart) * 1000), transcribedBy: "lyrics")
        if offline { moment.offline = true }
        moment.quickTranslation = quickTranslation
        moment.meant = result.meant
        if let intent = result.intent?.trimmingCharacters(in: .whitespaces), !intent.isEmpty { moment.intent = intent }
        moment.trigger = trigger
        moment.turns = turns
        moment.chosen = index
        moment.alternative = index > 0 ? index - 1 : nil
        moment.tapAt = playing.position
        moment.context = "song"
        moment.show = String(playing.song.label.prefix(200))
        store.add(moment)
        Memory.shared.tapped()
        Memory.shared.record("tap", pieces: moment.pieces, moment: moment)
        if mode == .silent { return true }
        // Nothing to explain it with: say why, the real reason (owner, 03/10), and the song goes on.
        if explanation == nil {
            step.savedOffline = true
            step.savedReason = Self.whySaved(problem)
            if paused { resumeVideo() }
            panel.show(PanelView(phase: .progress(step)), autoHide: 6, width: 380)
            return true
        }
        panel.show(PanelView(phase: paused ? .video(moment, paused: true) : .result(moment)), autoHide: paused ? nil : 30)
        return true
    }

    /// You paused a video right after people spoke: "Didn't get that?", one click for the line.
    /// Small and gone in a few seconds, since you also pause for the door or the phone (owner, 03/10).
    func offerExplain(pausedAt: Date) {
        panel.show(PanelView(phase: .offer(pausedAt)), autoHide: 8, width: 300)
    }

    /// The app whose song Afterhear paused (or you paused, as a tap): Continue plays it again.
    private var songPaused: String?
    private var lineStop: Task<Void, Never>?

    /// "Play this line": the song again from just before the line, then it stops at the line's end
    /// while the card is open (owner, 03/10: Replay and Slow meant nothing without the audio).
    func playSongLine(_ moment: Moment) {
        guard let turns = moment.turns, let chosen = moment.chosen, turns.indices.contains(chosen),
              let playing = NowPlaying.playing(), moment.show == String(playing.song.label.prefix(200)) else { return }
        let line = turns[chosen]
        NowPlaying.play(playing.app, from: line.start - 0.4)
        songPaused = playing.app
        videoPaused = true
        lineStop?.cancel()
        lineStop = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((line.end - line.start + 0.8) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.videoPaused, self.songPaused == playing.app else { return }
            NowPlaying.pause(playing.app)
        }
    }

    /// Why a moment was saved for later instead of explained: the real reason, never "offline" when
    /// the Mac is online (owner, 03/10).
    static func whySaved(_ error: Error?) -> String {
        if !Reachability.shared.isOnline { return String(localized: "You're offline: saved. The explanation will be waiting for you tonight.") }
        switch error as? AfterhearError {
        case .signIn?, .missingCode?:
            return String(localized: "Saved. To get explanations, sign in: Settings → Account.")
        case .server(let code)?:
            switch code {
            case "bad_code", "bad_token", "sign_in": return String(localized: "Saved. Sign in again to get explanations: Settings → Account.")
            case "not_tester": return String(localized: "Saved. Your account isn't on the testers' list yet: explained once it is.")
            default: return String(localized: "Saved. Our server isn't answering right now: explained as soon as it's back.")
            }
        default:
            return String(localized: "Saved. Our server isn't answering right now: explained as soon as it's back.")
        }
    }

    /// Every minute: below 20% without the charger, stop live transcription; when the
    /// charger is back, start again and transcribe what was kept.
    func checkPower() {
        let low = Power.isLow
        guard low != lowBattery else { return }
        lowBattery = low
        live.setSaving(low)
        sorry?.live.setSaving(low)
        if !low, waiting > 0 { Task { await transcribeWaiting() } }
    }

    /// "Transcribe now?": the marks kept as sound, one by one, the last sentence before each tap.
    /// Every minute too, quietly: marks kept without a connection get explained once it's back.
    /// Marks also come here at once (§ 19.13): the whole clip, the server's recogniser, the ranking.
    /// Test (Settings, off by default): in a video ElevenLabs hears the last 45 s too. Its
    /// sentence is only kept, next to Parakeet's, to compare tonight (§ 19.25).
    static var compareCloud: Bool { false } // voices never leave (§ 19.26): the ElevenLabs test is gone

    private func cloudCompare(after: Double, settings: AppSettings) -> Task<String?, Never> {
        let (sound, soundRate) = audio.hiRing.last(Self.quickCloudSeconds + after)
        let length = soundRate > 0 ? Double(sound.count) / soundRate : 0
        let start = Date().addingTimeInterval(-length)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try? Clip.writeVoice(sound, rate: soundRate, to: url)
        let usual = store.usualDelay
        return Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: url) }
            guard length > 1, let result = await CloudTranscriber.transcribe(url, settings: settings) else { return nil }
            let turns = Conversation.turns(others: CloudTranscriber.timedWords(result, clipStart: start, clipLength: length),
                                           mine: [], clipStart: start)
            let tapAt = max(0, length - after)
            var ranked = Conversation.rank(turns, tapAt: tapAt, usualDelay: usual, freshWithin: Self.reactionSeconds,
                                           hardness: Memory.shared.hardness)
            if ranked.isEmpty { ranked = Conversation.rank(turns, tapAt: tapAt, usualDelay: usual, hardness: Memory.shared.hardness) }
            return ranked.first.map { turns[$0.index].text }
        }
    }

    private var upgrading = false

    /// Moments explained by the model inside the Mac, offline: Gemini explains them again now.
    func upgradeOffline() async {
        guard !upgrading else { return }
        upgrading = true
        defer { upgrading = false }
        let settings = AppSettings.current
        let known = Array(store.known) + Memory.shared.knownWell + Memory.shared.dictionary
        for moment in store.moments where moment.offline == true {
            let source = moment.show.map { moment.context == "song" ? "song: \($0)" : "video: \($0)" } ?? ""
            guard let explanation = try? await ExplainClient.explain(moment.sent, settings: settings, known: known,
                                                                    struggling: store.struggling, watch: Memory.shared.watch,
                                                                    profile: store.listeningProfile, source: source) else { return }
            guard var saved = store.moments.first(where: { $0.id == moment.id }) else { continue }
            saved.translation = explanation.translation
            saved.pieces = explanation.pieces
            saved.intent = explanation.intent
            saved.provider = explanation.model ?? settings.provider.rawValue
            saved.offline = nil
            store.update(saved)
        }
    }

    func transcribeWaiting(quiet: Bool = false) async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        let settings = AppSettings.current
        let known = Array(store.known) + Memory.shared.knownWell + Memory.shared.dictionary
        let marks = PendingMark.all
        guard !marks.isEmpty else { return }
        if !quiet { panel.show(PanelView(phase: .working), autoHide: nil, width: 300) }
        var finished = Set<UUID>()
        var done = 0
        for mark in marks {
            let url = store.clipsFolder.appendingPathComponent(mark.clipFile)
            guard FileManager.default.fileExists(atPath: url.path) else {
                finished.insert(mark.id)
                continue
            }
            let started = Date()
            let clipStart = mark.date.addingTimeInterval(-mark.tapAt)
            // Parakeet on this Mac only (§ 19.25): model not here yet, the mark keeps waiting.
            let transcribedBy = Parakeet.name(for: settings.heard)
            var words: [TimedWord]? = nil
            if let sound = Clip.read(url) {
                words = await Parakeet.shared.timedWords(sound.samples, rate: sound.rate, language: settings.heard, clipStart: clipStart)
            }
            guard let words else { continue }
            let turns = Conversation.turns(others: words, mine: [], clipStart: clipStart)
            let hardness = Memory.shared.hardness
            var ranked = Conversation.rank(turns, tapAt: mark.tapAt, usualDelay: store.usualDelay,
                                           freshWithin: mark.context == "call" ? nil : Self.reactionSeconds, hardness: hardness)
            if ranked.isEmpty { ranked = Conversation.rank(turns, tapAt: mark.tapAt, usualDelay: store.usualDelay, hardness: hardness) }
            guard let best = ranked.first else {
                // Nothing said in it: nothing to learn.
                try? FileManager.default.removeItem(at: url)
                finished.insert(mark.id)
                continue
            }
            let line = turns[best.index].text
            let transcribeMs = Int(Date().timeIntervalSince(started) * 1000)
            let serverStart = Date()
            let sent = Redactor.redact(line)
            let source = mark.show.map { mark.context == "song" ? "song: \($0)" : "video: \($0)" } ?? ""
            guard let explanation = try? await ExplainClient.explain(sent, settings: settings, known: known,
                                                                    struggling: store.struggling, watch: Memory.shared.watch,
                                                                    profile: store.listeningProfile, source: source) else { continue }
            var moment = Moment(date: mark.date, transcript: line, sent: sent, translation: explanation.translation,
                                pieces: explanation.pieces, clipFile: mark.clipFile,
                                provider: explanation.model ?? settings.provider.rawValue,
                                latencyMs: Int(Date().timeIntervalSince(started) * 1000), transcribeMs: transcribeMs,
                                serverMs: Int(Date().timeIntervalSince(serverStart) * 1000), transcribedBy: transcribedBy)
            moment.trigger = mark.trigger
            moment.context = mark.context
            moment.show = mark.show
            moment.call = mark.call
            moment.callTitle = mark.callTitle
            moment.with = mark.with
            moment.turns = turns
            moment.chosen = best.index
            moment.alternative = ranked.dropFirst().first?.index
            moment.tapAt = mark.tapAt
            if let intent = explanation.intent?.trimmingCharacters(in: .whitespaces), !intent.isEmpty { moment.intent = intent }
            if moment.context == "call" && (UserDefaults.standard.bool(forKey: Key.callsTextOnly) || Memory.shared.callsTextOnly) {
                try? FileManager.default.removeItem(at: url)
                moment.clipFile = nil
            }
            store.add(moment)
            Memory.shared.record("tap", pieces: moment.pieces, moment: moment)
            finished.insert(mark.id)
            done += 1
        }
        // Marks made while this ran stay in the queue.
        let left = PendingMark.all.filter { !finished.contains($0.id) }
        PendingMark.save(left)
        waiting = left.count
        if quiet {
            // New marks arrived meanwhile: work them out too.
            if left.contains(where: { mark in !marks.contains { $0.id == mark.id } }) {
                Task { await self.transcribeWaiting(quiet: true) }
            }
            return
        }
        panel.show(PanelView(phase: .saved(left.isEmpty ? String(localized: "Done: \(done) transcribed, in tonight's review") : String(localized: "\(done) transcribed, \(left.count) still waiting"))), autoHide: 4, width: 340)
    }

    private var draining = false

    /// True while a video is paused and its card is open: the next tap, or Continue, resumes it.
    @Published private(set) var videoPaused = false

    func resumeVideo() {
        panel.hide()
        lineStop?.cancel()
        if let app = songPaused {
            NowPlaying.resume(app)
        } else if videoPaused {
            MediaKey.playPause()
        }
        songPaused = nil
        videoPaused = false
    }

    /// The sentence before (-1) or after (+1) the one on screen, skipping your own (§ 19.1).
    nonisolated static func neighbor(_ turns: [Turn], from index: Int, by delta: Int) -> Int? {
        var i = index + delta
        while turns.indices.contains(i), turns[i].isMine { i += delta }
        return turns.indices.contains(i) ? i : nil
    }

    /// ‹ › in the card: explain the sentence before or after, in place.
    func step(_ momentID: UUID, by delta: Int) async {
        guard let moment = store.moments.first(where: { $0.id == momentID }), let turns = moment.turns,
              let current = moment.chosen, let next = Self.neighbor(turns, from: current, by: delta) else { return }
        await jump(momentID, to: next)
    }

    /// "Or maybe": explain that sentence instead, in place.
    func jump(_ momentID: UUID, to next: Int) async {
        guard let moment = store.moments.first(where: { $0.id == momentID }), let turns = moment.turns,
              turns.indices.contains(next) else { return }
        panel.show(PanelView(phase: .heard(turns[next].text)), autoHide: nil)
        await choose(turn: next, in: momentID)
        guard let updated = store.moments.first(where: { $0.id == momentID }) else { return }
        prepare(updated)
        if videoPaused {
            panel.show(PanelView(phase: .video(updated, paused: true)), autoHide: nil)
        } else {
            panel.show(PanelView(phase: .result(updated)), autoHide: 30)
        }
    }

    /// A word you clicked in the sentence: it's the one you didn't get, so it's explained first,
    /// even an everyday one (owner, 02/10). It also tells your model this word is hard for you.
    func explainWord(_ momentID: UUID, word: String) async {
        let clean = word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard !clean.isEmpty, var moment = store.moments.first(where: { $0.id == momentID }) else { return }
        if let i = moment.pieces.firstIndex(where: { Memory.key($0.text) == Memory.key(clean) }) {
            // Already explained: bring it to the top.
            let piece = moment.pieces.remove(at: i)
            moment.pieces.insert(piece, at: 0)
        } else {
            let settings = AppSettings.current
            guard let explanation = try? await ExplainClient.explain(moment.sent, settings: settings, known: [],
                                                                    struggling: store.struggling, profile: store.listeningProfile,
                                                                    focus: clean) else { return }
            let piece = explanation.pieces.first(where: { Memory.key($0.text).contains(Memory.key(clean)) }) ?? explanation.pieces.first
            guard var piece else { return }
            piece.guess = nil
            moment.pieces.removeAll { Memory.key($0.text) == Memory.key(piece.text) }
            moment.pieces.insert(piece, at: 0)
            Memory.shared.record("tap", pieces: [piece], moment: moment)
        }
        store.update(moment)
        if videoPaused {
            panel.show(PanelView(phase: .video(moment, paused: true)), autoHide: nil)
        } else {
            panel.show(PanelView(phase: .result(moment)), autoHide: 30)
        }
    }

    /// "It wasn't that one": explain the turn you picked instead, and learn your delay.
    func choose(turn index: Int, in momentID: UUID) async {
        guard var moment = store.moments.first(where: { $0.id == momentID }),
              let turns = moment.turns, turns.indices.contains(index) else { return }
        let settings = AppSettings.current
        let text = turns[index].text
        let sent = Redactor.redact(text)
        do {
            let explanation = try await ExplainClient.explain(sent, settings: settings, known: Array(store.known),
                                                              struggling: store.struggling, profile: store.listeningProfile)
            moment.transcript = text
            moment.sent = sent
            moment.translation = explanation.translation
            moment.pieces = explanation.pieces
            if moment.chosen != index { moment.alternative = moment.chosen }
            moment.chosen = index
            if let tapAt = moment.tapAt { moment.delay = max(0, tapAt - turns[index].end) }
            store.update(moment)
        } catch {
            panel.show(PanelView(phase: .failed(error.localizedDescription)), autoHide: 5, width: 300)
        }
    }

    /// Confirms the guess was right: this teaches Afterhear your usual delay.
    /// "Not in the list?": it was something you knew before and forgot. The strongest signal there is (§ 12.5).
    func relapse(_ item: Memory.Item, in momentID: UUID) {
        guard var moment = store.moments.first(where: { $0.id == momentID }) else { return }
        if !moment.pieces.contains(where: { Memory.key($0.text) == item.key }) {
            let piece = Piece(text: item.text, heardAs: nil, gloss: item.gloss, meaning: item.meaning ?? "",
                              note: String(localized: "You knew this before: it slipped away again, so it's back in your lessons."),
                              cause: item.cause ?? "unknown_word", level: item.level)
            moment.pieces.insert(piece, at: 0)
            store.update(moment)
        }
        Memory.shared.record("relapse", item: item, moment: moment)
    }

    private var lastShow: String?

    /// Back to a series: what slipped past you last time in it (§ 5.15).
    fileprivate func showRecap() {
        guard ContextDetector.current() == .video, let show = ContextDetector.show(), show != lastShow else { return }
        lastShow = show
        let before = store.moments.filter { $0.show == show && $0.date < Date().addingTimeInterval(-1800) }.flatMap(\.pieces).map(\.text)
        var seen = Set<String>()
        let words = before.filter { seen.insert($0.lowercased()).inserted }.prefix(4)
        guard words.count >= 2 else { return }
        panel.show(PanelView(phase: .saved(String(localized: "Last time in \(show): ") + words.joined(separator: " · "))), autoHide: 7, width: 380)
    }

    func refreshVocabulary() {
        var words = Memory.shared.dictionary + store.people.map(\.name)
        for call in CalendarWatch.shared.calls.prefix(6) {
            words += call.people
            words += call.title.split(separator: " ").map(String.init).filter { $0.count > 3 && $0.first?.isUppercase == true }
        }
        words += Memory.shared.items.values.filter { $0.reps > 0 }.sorted { $0.understanding < $1.understanding }.prefix(60).map(\.text)
        var seen = Set<String>()
        LiveTranscriber.vocabulary = words.filter { seen.insert($0.lowercased()).inserted }
        live.refreshVocabulary()
    }

    /// What the others said lately (for your model, and the songs).
    func theirWords(seconds: Double) -> String {
        live.text(last: seconds)
    }

    /// A line your model picked by itself (§ 18): a moment with the real voice, waiting for the quiz.
    func addModelMoment(_ piece: Piece, line: String, kind: ModelWatch.Kind, show: String?) {
        let started = Date()
        let (samples, rate) = audio.ring.last(75)
        let clipLength = rate > 0 ? Double(samples.count) / rate : 0
        let clipStart = started.addingTimeInterval(-clipLength)
        var clipName: String?
        let textOnly = kind == .call && (UserDefaults.standard.bool(forKey: Key.callsTextOnly) || Memory.shared.callsTextOnly)
        if !textOnly, clipLength > 1 {
            let url = store.newClipURL("m4a")
            let (voice, voiceRate) = audio.hiRing.last(clipLength)
            let wrote = voiceRate > 0 && !voice.isEmpty
                ? (try? Clip.writeVoice(voice, rate: voiceRate, to: url)) != nil
                : (try? Clip.writeVoice(samples, rate: rate, to: url)) != nil
            if wrote { clipName = url.lastPathComponent }
        }
        let turns = Conversation.turns(others: live.timedWords(since: clipStart), mine: sorry?.live.timedWords(since: clipStart) ?? [], clipStart: clipStart)
        let needle = " " + Memory.key(piece.text) + " "
        let chosen = turns.lastIndex { !$0.isMine && (" " + Memory.key($0.text) + " ").contains(needle) }
        var moment = Moment(date: started, transcript: String(line.prefix(600)), sent: Redactor.redact(String(line.prefix(600))),
                            translation: "", pieces: [piece], clipFile: clipName, provider: "model", latencyMs: 0)
        moment.trigger = "model"
        moment.context = kind.rawValue
        moment.show = show.map { String($0.prefix(200)) }
        if let chosen {
            moment.turns = turns
            moment.chosen = chosen
        }
        if kind == .call {
            let call = CalendarWatch.shared.current
            moment.with = talkingWith ?? call?.people.first
            moment.call = call?.id
            moment.callTitle = call.map { String($0.title.prefix(200)) }
        }
        store.add(moment)
        Memory.shared.record("model_catch", pieces: [piece], moment: moment)
    }

    /// The last minutes as turns, them and you, for the catch-up and the call coach.
    func recentTurns(seconds: Double) -> [Turn] {
        let start = Date().addingTimeInterval(-seconds)
        return Conversation.turns(others: live.timedWords(since: start), mine: sorry?.live.timedWords(since: start) ?? [], clipStart: start)
    }

    /// Your own microphone is being transcribed (the "listen to my voice" setting).
    var voiceIsOn: Bool { sorry?.isRunning ?? false }

    /// What you said in the last seconds (for "Say it yourself").
    func myRecentWords(seconds: Double) -> String {
        sorry?.live.text(last: seconds) ?? ""
    }

    /// Back a few seconds in the video itself, then play: the original voice again.
    func rewindVideo() {
        VideoControl.rewind()
        resumeVideo()
    }

    func confirm(_ momentID: UUID) {
        guard var moment = store.moments.first(where: { $0.id == momentID }),
              let turns = moment.turns, let chosen = moment.chosen, turns.indices.contains(chosen),
              let tapAt = moment.tapAt else { return }
        moment.delay = max(0, tapAt - turns[chosen].end)
        store.update(moment)
    }

    /// Restarts listening to your voice (e.g. after changing the keyword).
    /// Another language: its model (downloaded if needed), and the voices start over.
    func languageChanged() {
        live.configure(language: AppSettings.current.heard)
        restartVoice()
    }

    func restartVoice() {
        sorry?.stop()
        applyTriggers()
    }

    private var chooser: NSWindow?

    /// The last minutes as a chat: tap the piece you really missed.
    func showChooser(_ momentID: UUID) {
        panel.hide()
        let view = ChooseView(momentID: momentID).environmentObject(store)
        let window = chooser ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "What did you miss?")
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        chooser = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        if videoPaused { resumeVideo() } else { panel.hide() }
    }

    /// From the one-line glance to the full explanation.
    func expand(_ moment: Moment) {
        panel.show(PanelView(phase: .result(moment)), autoHide: 30)
    }

    private var stopTask: Task<Void, Never>?

    /// Plays the missed turn if the moment has a conversation, otherwise the whole clip.
    func play(_ moment: Moment, slow: Bool) {
        if let turns = moment.turns, let chosen = moment.chosen, turns.indices.contains(chosen) {
            play(moment, turn: turns[chosen], slow: slow)
        } else {
            play(moment, from: 0, to: nil, slow: slow)
        }
    }

    func play(_ moment: Moment, turn: Turn, slow: Bool) {
        play(moment, from: max(0, turn.start - 0.5), to: turn.end + 0.6, slow: slow)
    }

    private var playerURL: URL?

    /// The clip is a few minutes of audio (megabytes): open it once and keep it ready,
    /// so Replay and Slow start at once instead of reloading the file on every click.
    private func readyPlayer(_ moment: Moment) -> AVAudioPlayer? {
        guard let url = store.clipURL(moment) else { return nil }
        if let player, playerURL == url { return player }
        guard let fresh = try? AVAudioPlayer(contentsOf: url) else { return nil }
        fresh.enableRate = true
        fresh.prepareToPlay()
        player = fresh
        playerURL = url
        return fresh
    }

    /// Opens the clip in the background while the card is on screen.
    func prepare(_ moment: Moment) {
        _ = readyPlayer(moment)
    }

    private func play(_ moment: Moment, from: Double, to: Double?, slow: Bool) {
        guard let player = readyPlayer(moment) else { return }
        stopTask?.cancel()
        player.stop()
        player.rate = slow ? 0.6 : 1
        player.currentTime = min(from, max(0, player.duration - 0.1))
        player.prepareToPlay()
        player.play()
        if let to {
            let length = (to - from) / Double(player.rate)
            stopTask = Task { [weak player] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, length) * 1_000_000_000))
                if !Task.isCancelled { player?.stop() }
            }
        }
    }
}

/// Pause = tap (owner, 03/10). The AirPods' press, the space bar or the play key go to the app that
/// plays, never to Afterhear: so the pause itself is the signal. A song you pause mid-line: its line,
/// explained at once. A video you pause right after people spoke: a small "Didn't get that?",
/// because you also pause for the door or the phone.
extension AppModel {
    private static var songWasPlaying: Bool?
    private static var lastLoud: Date?
    private static var silentSince: Date?
    private static var offered = false

    var pauseIsTap: Bool {
        UserDefaults.standard.object(forKey: Key.pauseTap) == nil || UserDefaults.standard.bool(forKey: Key.pauseTap)
    }

    func watchPauses() {
        guard state == .listening, pauseIsTap, !busy, !videoPaused else {
            Self.songWasPlaying = nil
            Self.silentSince = nil
            return
        }
        // Spotify or Music: paused by you, not by us, with lyrics to read the line from.
        if let app = NowPlaying.runningPlayer(), let playing = NowPlaying.isPlaying(app) {
            let wasPlaying = Self.songWasPlaying
            Self.songWasPlaying = playing
            if wasPlaying == true, !playing, !NowPlaying.recentlyChangedByUs {
                Task { await self.songPausedByYou() }
                return
            }
            if playing { return }
        } else {
            Self.songWasPlaying = nil
        }
        watchVideoPause()
    }

    private func songPausedByYou() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        _ = await songMoment(trigger: "pause", mode: .full, started: Date(), settings: AppSettings.current, pausedByYou: true)
    }

    /// A video stops: the sound goes from voices to nothing at all (a paused player is perfectly
    /// silent, a quiet scene never is), and nobody pressed play/pause for us.
    private func watchVideoPause() {
        guard ContextDetector.current() == .video else {
            Self.silentSince = nil
            Self.lastLoud = nil
            return
        }
        let now = Date()
        let (recent, _) = audio.ring.last(0.3)
        let peak = recent.reduce(Float(0)) { max($0, abs($1)) }
        let stopped = audio.ring.idleSeconds > 0.4 || (!recent.isEmpty && peak < 0.0003)
        if !stopped, peak > 0.02 {
            Self.lastLoud = now
            Self.silentSince = nil
            if Self.offered { Self.offered = false; panel.hide() } // it plays again: the offer goes
            return
        }
        guard stopped else { Self.silentSince = nil; return }
        let since = Self.silentSince ?? now
        Self.silentSince = since
        guard !Self.offered, now.timeIntervalSince(since) >= 0.5,
              let loud = Self.lastLoud, since.timeIntervalSince(loud) < 0.8,
              !MediaKey.recentlyPressed else { return }
        // Voices just before the stop: the last seconds were someone talking, not a song or silence.
        guard Clip.loudness(audio.ring.last(4).samples) > 0.01 else { return }
        Self.offered = true
        Self.lastLoud = nil
        offerExplain(pausedAt: since)
    }
}

/// A small window that floats above Teams or Meet without stealing focus.
@MainActor
final class FloatingPanel {
    /// Top right, out of the way; or top centre, next to the camera, where your eyes already are.
    enum Position { case topRight, topCenter }
    private let position: Position
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    init(position: Position = .topRight) {
        self.position = position
    }

    func show<Content: View>(_ view: Content, autoHide seconds: Double?, width: CGFloat = 380) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: view.frame(width: width))
        panel.contentView = hosting
        let size = hosting.fittingSize
        panel.setContentSize(size)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = position == .topCenter ? frame.midX - size.width / 2 : frame.maxX - size.width - 16
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: frame.maxY - 12))
        }
        panel.orderFrontRegardless()

        hideTask?.cancel()
        if let seconds {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !Task.isCancelled { self?.hide() }
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        return panel
    }
}
