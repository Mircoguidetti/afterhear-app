import AVFoundation
import SwiftUI

struct RootView: View {
    @State private var tab = 0
    @AppStorage("gesturesSeen") private var gesturesSeen = false

    var body: some View {
        if !gesturesSeen {
            GestureGuide { gesturesSeen = true }
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            OutView().tabItem { Label("Out", systemImage: "waveform") }.tag(0)
            EveningView().tabItem { Label("Tonight", systemImage: "moon") }.tag(1)
            ProgressStoryView().tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }.tag(3)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
    }
}

/// Out there: one tap to listen, one tap to mark. Silent by default (§ 11.1).
struct OutView: View {
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var night: Night

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if let s = sessions.current {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform").foregroundStyle(Brand.accent)
                            Text("Listening · \(s.title)").font(.headline)
                        }
                        Text("Since \(s.start.formatted(date: .omitted, time: .shortened)) · \(s.bookmarks.count) marked").foregroundStyle(.secondary)
                        Text("Nothing is transcribed now. Only the last 30 minutes stay, and the minutes near your marks.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    GestureSurface(listening: true)
                    if let help = sessions.nowLine {
                        Text(help).font(.headline).multilineTextAlignment(.center)
                            .padding(12).frame(maxWidth: .infinity)
                            .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
                            .onTapGesture { sessions.nowLine = nil }
                    }
                    Text("It was earlier").font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        ForEach([5.0, 10.0, 20.0], id: \.self) { m in
                            Button("\(Int(m)) min ago") { sessions.mark(source: "earlier", minutesAgo: m, window: 5) }
                                .buttonStyle(.bordered)
                        }
                    }
                    Spacer()
                    Button("Stop listening", role: .destructive) { sessions.stop(); Haptics.off() }
                } else {
                    Spacer()
                    Text("Out there, you just answer.").font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center)
                    Text("LEXALIE listens quietly. When something slips past you, tap: here, on your Watch, on the Lock Screen, or say \"sorry?\". Tomorrow, over coffee, it teaches you exactly that.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    GestureSurface(listening: false)
                    Button {
                        Task { await sessions.start(tv: true) }
                    } label: {
                        Label("Watching TV: listen with me", systemImage: "tv").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    Text("Put the phone near the TV. No need to tap: your model picks the lines you probably missed, and after the film you get a quiz.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if AppAudio.isAvailable {
                        Button {
                            Task { await sessions.start(apps: true) }
                        } label: {
                            Label("Listen to this iPhone's apps", systemImage: "app.badge").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("On a phone call nobody can listen, not even LEXALIE: tap anyway to mark, then share Apple's recording of the call to LEXALIE.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                    if !night.pending.isEmpty { TranscribeCard() }
                }
                if let m = sessions.message {
                    Text(m).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                        .onTapGesture { sessions.message = nil }
                }
            }
            .padding(20)
            .navigationTitle("LEXALIE")
        }
    }
}

/// The three gestures on the screen (§ 19.5): one tap marks, two taps explain it now,
/// hold for two seconds to turn listening on or off.
struct GestureSurface: View {
    let listening: Bool
    @EnvironmentObject private var sessions: Sessions
    @State private var lastTap = Date.distantPast
    @State private var holding = false
    @State private var tied = 0

    var body: some View {
        VStack(spacing: 6) {
            Text(listening ? "I didn't get that" : "Hold to listen")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: listening ? 150 : 90)
                .background(RoundedRectangle(cornerRadius: 18).fill(listening ? Brand.accent : Brand.card))
                .foregroundStyle(listening ? Brand.onyx : Color.white)
                .scaleEffect(holding ? 0.96 : 1)
                .animation(.easeOut(duration: 0.2), value: holding)
                .overlay(alignment: .bottom) {
                    KnotTie(color: Brand.onyx.opacity(0.8), trigger: tied).frame(width: 64).padding(.bottom, 16)
                }
                .contentShape(Rectangle())
                .onTapGesture { tapped() }
                .onLongPressGesture(minimumDuration: 2, pressing: { holding = $0 }) {
                    holding = false
                    Task { await sessions.toggle(source: "screen") }
                }
            Text(listening ? "Tap: mark · Two taps: explain now · Hold: stop" : "Or tap once to start.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func tapped() {
        guard listening else {
            Task { await sessions.toggle(source: "screen") }
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastTap) < 0.5 {
            lastTap = .distantPast
            Task { sessions.nowLine = await sessions.now(source: "screen") }
        } else {
            lastTap = now
            sessions.mark(source: "tap")
            tied += 1
        }
    }
}

/// First launch (§ 19.10): the three gestures, one card each, with Skip. Again from Settings.
struct GestureGuide: View {
    let done: () -> Void
    @State private var page = 0
    @State private var tried = false

    private let pages: [(icon: String, title: String, text: String)] = [
        ("hand.tap", "One tap: mark", "Something slipped past you? Tap: here, on your Watch or on your AirPods. A light tick, nothing on screen. Tonight LEXALIE finds exactly that line."),
        ("hand.tap.fill", "Two taps: now", "Need it right away? Tap twice. One line comes back: on your wrist, or in a notification."),
        ("waveform", "Hold: on or off", "Hold for two seconds to start or stop listening. Two short taps mean on; one long buzz means off. The wave shows whenever LEXALIE listens."),
        ("iphone.gen3", "Without taking the phone out", "In Settings → Accessibility → Touch → Back Tap: Double Tap = \"I didn't get that\", Triple Tap = \"Explain it now\". The Action button can be \"Listening on or off\"."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button("Skip") { done() }.foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: pages[page].icon).font(.system(size: 56)).foregroundStyle(Brand.accent)
            Text(pages[page].title).font(.title.weight(.semibold))
            Text(pages[page].text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if page == 0 {
                // Try it: the feel of a mark.
                Text(tried ? "Marked ✓" : "Try it: tap here")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(RoundedRectangle(cornerRadius: 16).fill(tried ? Brand.accent : Brand.card))
                    .foregroundStyle(tried ? Brand.onyx : Color.white)
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        tried = true
                    }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle().fill(i == page ? Brand.accent : Color.white.opacity(0.2)).frame(width: 7, height: 7)
                }
            }
            Button(page == pages.count - 1 ? "Got it" : "Next") {
                if page == pages.count - 1 { done() } else { page += 1 }
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Brand.onyx)
        }
        .padding(24)
    }
}

/// "Transcribe now" with its cost (§ 13.6); automatic on the charger otherwise.
struct TranscribeCard: View {
    @EnvironmentObject private var night: Night

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(night.pending.count) \(night.pending.count == 1 ? "evening" : "evenings") to transcribe · \(night.pendingMinutes) min of audio")
                .font(.headline)
            Text(night.charging ? "Charging: it'll happen by itself tonight, or now." : "Tonight on the charger, by itself. Or now: about \(night.batteryCost)% of your battery.")
                .font(.footnote).foregroundStyle(.secondary)
            if let p = night.progress { Text(p).font(.footnote) }
            Button(night.running ? "Working…" : "Transcribe now") { Task { await night.run(auto: false) } }
                .buttonStyle(.bordered).disabled(night.running)
            if !night.charging && night.battery < 30 {
                Text("Battery under 30%: better on the charger.").font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The morning after (§ 11.10): "at dinner (21:10–21:40) you marked something: was it one of these?"
struct EveningView: View {
    @EnvironmentObject private var night: Night
    @State private var player: AVAudioPlayer?
    @State private var sent: String?

    var body: some View {
        NavigationStack {
            List {
                if !night.pending.isEmpty { Section { TranscribeCard() } }
                if let sent { Section { Text(sent).font(.footnote).foregroundStyle(.secondary) } }
                ForEach(night.evenings.filter { $0.open > 0 }) { e in
                    Section("\(e.title) · \(e.start.formatted(date: .abbreviated, time: .shortened))–\(e.end.formatted(date: .omitted, time: .shortened))") {
                        ForEach(e.marks.filter { !$0.resolved }) { m in MarkRow(evening: e, mark: m, play: play, done: done) }
                        ForEach(e.unmarked.filter { !e.unmarkedDone.contains($0.id) }) { c in UnmarkedRow(evening: e, candidate: c, play: play, done: done) }
                        ForEach(e.pauses.filter { !$0.resolved }) { p in PauseRow(evening: e, pause: p, done: done) }
                    }
                }
                if night.evenings.allSatisfy({ $0.open == 0 }) && night.pending.isEmpty {
                    Text("Nothing waiting. Go out, tap when something slips past you: the lesson comes tomorrow.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tonight")
        }
    }

    private func play(_ clip: String?) {
        guard let clip else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player = try? AVAudioPlayer(contentsOf: Night.clips.appendingPathComponent(clip))
        player?.play()
    }

    private func done(_ e: Evening, _ note: String?) {
        Night.shared.update(e)
        if let note { sent = note }
    }
}

/// One mark: the model's candidates first; if none of them, the whole window (only on this phone).
struct MarkRow: View {
    let evening: Evening
    let mark: Evening.Mark
    let play: (String?) -> Void
    let done: (Evening, String?) -> Void
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("At \(mark.bookmark.at.formatted(date: .omitted, time: .shortened)) you marked something. Was it one of these?")
                .font(.subheadline.weight(.semibold))
            ForEach(mark.candidates) { c in
                HStack(alignment: .top) {
                    Button { play(c.clip) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless).disabled(c.clip == nil)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.piece.text).font(.body.weight(.semibold))
                        Text("“\(c.line.text)”").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("This") { pick(c) }.buttonStyle(.bordered)
                }
            }
            if showAll || mark.candidates.isEmpty {
                Text("Pick the sentence you missed:").font(.footnote).foregroundStyle(.secondary)
                ForEach(mark.lines) { line in
                    Button { explain(line) } label: { Text(line.text).font(.footnote).multilineTextAlignment(.leading) }.buttonStyle(.borderless)
                }
            } else {
                Button("None of these") { showAll = true }.font(.footnote)
            }
            Button("Never mind") { resolve(nil) }.font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func pick(_ c: Evening.Candidate) {
        let id = UUID().uuidString.lowercased()
        let row = MomentRow(id: id, occurred_at: c.line.at, trigger: mark.bookmark.source == "phrase" ? "sorry" : "tap", person_name: nil,
                            transcript: c.line.text, sent: Redactor.redact(c.line.text), translation: "", pieces: [c.piece],
                            label: nil, review: nil, step: 0, provider: "iphone", intent: nil, show: nil)
        Memory.shared.record("tap", pieces: [c.piece], momentID: id)
        Task {
            let ok = (try? await MomentRow.upload([row])) != nil
            resolve(ok ? "“\(c.piece.text)” is in tonight's lessons, on the web and your Mac." : "Saved here; sign in to send it to your lessons.")
        }
    }

    private func explain(_ line: Evening.Line) {
        Task {
            guard let e = try? await Api.explain(line.text) else { resolve("The explanation didn't arrive: check your tester code."); return }
            let id = UUID().uuidString.lowercased()
            let row = MomentRow(id: id, occurred_at: line.at, trigger: "tap", person_name: nil, transcript: line.text, sent: Redactor.redact(line.text),
                                translation: e.translation, pieces: e.pieces, label: nil, review: nil, step: 0, provider: "iphone", intent: e.intent, show: nil)
            Memory.shared.record("tap", pieces: e.pieces, momentID: id)
            _ = try? await MomentRow.upload([row])
            resolve(e.pieces.first.map { "\($0.text): \($0.gloss ?? $0.meaning)" } ?? e.translation)
        }
    }

    private func resolve(_ note: String?) {
        var e = evening
        if let i = e.marks.firstIndex(where: { $0.id == mark.id }) { e.marks[i].resolved = true }
        done(e, note)
    }
}

/// "Did you get this? It was a particular slang" (§ 11.8): yes = well done, no = tonight's lesson.
struct UnmarkedRow: View {
    let evening: Evening
    let candidate: Evening.Candidate
    let play: (String?) -> Void
    let done: (Evening, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { play(candidate.clip) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless).disabled(candidate.clip == nil)
                Text("At \(candidate.line.at.formatted(date: .omitted, time: .shortened)) someone said “\(candidate.line.text)”").font(.footnote)
            }
            Text("Did you get **\(candidate.piece.text)**?")
            HStack {
                Button("No") { answer(false) }.buttonStyle(.bordered)
                Button("Yes, I got it") { answer(true) }.buttonStyle(.borderedProminent).foregroundStyle(Brand.onyx)
            }
        }
        .padding(.vertical, 6)
    }

    private func answer(_ got: Bool) {
        var e = evening
        e.unmarkedDone.insert(candidate.id)
        Memory.shared.record(got ? "quiz_yes" : "quiz_no", pieces: [candidate.piece])
        if got {
            done(e, "Nice: you got “\(candidate.piece.text)” without help.")
        } else {
            let row = MomentRow(id: UUID().uuidString.lowercased(), occurred_at: candidate.line.at, trigger: "model", person_name: nil,
                                transcript: candidate.line.text, sent: Redactor.redact(candidate.line.text), translation: "", pieces: [candidate.piece],
                                label: nil, review: "again", step: 0, provider: "iphone", intent: nil, show: nil)
            Task { _ = try? await MomentRow.upload([row]) }
            done(e, "“\(candidate.piece.text)”: \(candidate.piece.gloss ?? candidate.piece.meaning). It's in your lessons.")
        }
    }
}

/// A long pause after a question (§ 11.5): was it the language, or were you just thinking?
struct PauseRow: View {
    let evening: Evening
    let pause: Evening.Pause
    let done: (Evening, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("At \(pause.question.at.formatted(date: .omitted, time: .shortened)), \(Int(pause.seconds)) seconds of silence after “\(pause.question.text)”. Was it the language?")
                .font(.footnote)
            HStack {
                Button("I was thinking") { close(nil) }.buttonStyle(.bordered)
                Button("The language") { language() }.buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    private func language() {
        Task {
            if let e = try? await Api.explain(pause.question.text) {
                let row = MomentRow(id: UUID().uuidString.lowercased(), occurred_at: pause.question.at, trigger: "hesitation", person_name: nil,
                                    transcript: pause.question.text, sent: Redactor.redact(pause.question.text), translation: e.translation,
                                    pieces: e.pieces, label: nil, review: nil, step: 0, provider: "iphone", intent: e.intent, show: nil)
                _ = try? await MomentRow.upload([row])
                close("The question is in your lessons: \(e.translation)")
            } else {
                close(nil)
            }
        }
    }

    private func close(_ note: String?) {
        var e = evening
        if let i = e.pauses.firstIndex(where: { $0.id == pause.id }) { e.pauses[i].resolved = true }
        done(e, note)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var account: Account
    @AppStorage(K.code) private var code = ""
    @AppStorage(K.server) private var server = "https://asaid-nine.vercel.app"
    @AppStorage(K.webApp) private var webApp = "https://asaid-cx6u.vercel.app"
    @AppStorage(K.heard) private var heard = "en-GB"
    @AppStorage(K.native) private var native = "it"
    @AppStorage(K.level) private var level = "B2"
    @AppStorage(K.keepEvening) private var keepEvening = false
    @AppStorage(K.phraseTaps) private var phraseTaps = false
    @AppStorage(K.liveHelp) private var liveHelp = false
    @AppStorage(K.autoNight) private var autoNight = true
    @AppStorage(K.stopOnLeave) private var stopOnLeave = false
    @AppStorage(K.offerAtEvents) private var offerAtEvents = true
    @AppStorage(K.airpods) private var airpods = false
    @AppStorage(K.maxHours) private var maxHours = 4.0
    @AppStorage(K.nowWhere) private var nowWhere = "auto"
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Gestures") {
                    Text("One tap marks. Two taps explain it now. Hold for two seconds: listening on or off.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Two taps answer", selection: $nowWhere) {
                        Text("Where I tapped").tag("auto")
                        Text("On the iPhone").tag("iphone")
                        Text("On the Watch").tag("watch")
                        Text("A voice in my ear").tag("voice")
                    }
                    Button("Show me the gestures again") { UserDefaults.standard.set(false, forKey: "gesturesSeen") }
                }
                Section("Account") {
                    if let s = account.session {
                        Text(s.email ?? "Signed in")
                        Button("Sign out", role: .destructive) { account.signOut() }
                    } else {
                        Button("Continue with Google") { account.signInWithGoogle() }
                        TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        SecureField("Password (optional)", text: $password)
                        Button(password.isEmpty ? "Email me a link" : "Sign in") {
                            Task { if password.isEmpty { await account.sendMagicLink(email: email) } else { await account.signIn(email: email, password: password) } }
                        }
                    }
                    if let m = account.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Out there") {
                    Toggle("Say \"sorry?\" to mark (on this iPhone, uses more battery)", isOn: $phraseTaps)
                    Toggle("Squeeze the AirPods to mark", isOn: $airpods)
                    Toggle("Help me live: a short note when I mark (for a close friend, travelling alone)", isOn: $liveHelp)
                    Toggle("Offer to listen at my calendar events", isOn: $offerAtEvents).onChange(of: offerAtEvents) { _, _ in Sessions.shared.offerAtEvents() }
                    Toggle("Stop when I leave the place", isOn: $stopOnLeave)
                    Stepper("Stop after \(Int(maxHours)) hours at most", value: $maxHours, in: 1...8)
                    Text("Silent by default: no screen, no notifications. Focus modes can switch \"help me live\" on (e.g. Travel): Settings → Focus → Focus Filters → LEXALIE.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Private transcription") {
                    PrivateModelRow()
                    VoiceRow()
                    Text("Everything you hear is turned into text on this iPhone, never on a server. Your voice's fingerprint lets the evening skip your own words and offer only what the others said. It's a few numbers, kept on this iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("At night") {
                    Toggle("Keep the whole evening, to find what I missed without tapping (people around you should know)", isOn: $keepEvening)
                    Toggle("Transcribe by itself on the charger", isOn: $autoNight)
                    Text("During the day LEXALIE only records, compressed and encrypted on this iPhone. At night, on the charger, the iPhone transcribes the minutes around your marks by itself. Only a few sentences without names go to the AI. Then the audio is deleted: only the hard pieces stay.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Languages") {
                    Picker("Language you hear", selection: $heard) {
                        Text("English (UK)").tag("en-GB"); Text("English (US)").tag("en-US"); Text("French").tag("fr-FR"); Text("Spanish").tag("es-ES"); Text("German").tag("de-DE")
                    }
                    .onChange(of: heard) { _, _ in Task { await Private.shared.prepare() } }
                    Picker("Explanations in", selection: $native) {
                        Text("Italiano").tag("it"); Text("English").tag("en"); Text("Español").tag("es"); Text("Français").tag("fr"); Text("Deutsch").tag("de"); Text("Português").tag("pt"); Text("Русский").tag("ru")
                    }
                    Picker("Your level", selection: $level) { ForEach(["A2", "B1", "B2", "C1"], id: \.self) { Text($0).tag($0) } }
                }
                Section("Tester access") {
                    SecureField("Tester code", text: $code)
                    TextField("Server", text: $server).textInputAutocapitalization(.never)
                    TextField("Web app", text: $webApp).textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// The private recogniser: ready, or downloading, or "Download now" (also on mobile data).
private struct PrivateModelRow: View {
    @State private var status = Private.status
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stays on your device")
                Text(Private.isDownloaded ? "Ready" : status.label).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if !Private.isDownloaded && status != .downloading {
                Button("Download now") { Task { await Private.shared.prepare(anyNetwork: true) } }
            }
        }
        .onReceive(timer) { _ in status = Private.status }
    }
}

/// "Teach LEXALIE your voice": 20 seconds of you talking, once.
private struct VoiceRow: View {
    @State private var recording = false
    @State private var message: String?
    @State private var known = Private.fingerprint != nil
    @State private var recorder: AVAudioRecorder?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(recording ? "Listening… keep talking" : known ? "Teach LEXALIE your voice again" : "Teach LEXALIE your voice (20 seconds)") {
                Task { await record() }
            }
            .disabled(recording)
            if recording || message == nil {
                Text(recording ? "Talk normally: what you did today, anything." : known ? "Your voice is known." : "So the evening only shows what the others said.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @MainActor private func record() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "LEXALIE needs the microphone: Settings → LEXALIE."
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice.m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? AVAudioSession.sharedInstance().setActive(true)
        recorder = r
        message = nil
        recording = r.record(forDuration: 20)
        guard recording else { message = "Couldn't start the microphone."; return }
        try? await Task.sleep(nanoseconds: 20_500_000_000)
        recording = false
        recorder = nil
        message = "Learning your voice…"
        defer { try? FileManager.default.removeItem(at: url) }
        guard let sound = Private.read(url), await Private.shared.learnVoice(sound) else {
            message = "Didn't work: try again somewhere quiet."
            return
        }
        await Private.shared.release()
        known = true
        message = "Done. Your voice stays on this iPhone."
    }
}
