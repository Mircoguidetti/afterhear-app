import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Your own question about what you just heard (owner, 07/10): "who's the singer?", "what did she mean
/// before?". One question, one answer, never a chat. Ready questions one click away; in a video or a
/// podcast you can also say it (recognised on this Mac) and the answer is said in your headphones; in a
/// call it's only written, since you may not be muted and the others would hear you.
@MainActor
final class Ask {
    static let shared = Ask()
    static let label = "⌃⌥Q"

    enum Ready: String, CaseIterable, Identifiable {
        case meant, forMe, who, singer
        var id: String { rawValue }

        var label: String {
            switch self {
            case .meant: String(localized: "What did they mean?")
            case .forMe: String(localized: "Was it for me?")
            case .who: String(localized: "Who or what is it?")
            case .singer: String(localized: "Who's singing?")
            }
        }

        /// What goes to our server, in English: it answers in your language.
        var question: String {
            switch self {
            case .meant: "What did they mean in the last thing they said? Say the point, in plain words."
            case .forMe: "Was the last thing said addressed to me ([tu])? If so, what was I asked or asked to do? Never suggest an answer."
            case .who: "Who or what is the name or term just mentioned? One line."
            case .singer: "Who is singing?"
            }
        }
    }

    /// The ready questions for where you are.
    static func ready(for context: AppContext, song: Bool) -> [Ready] {
        if context == .call { return [.meant, .forMe, .who] }
        return song ? [.singer, .meant] : [.meant, .who]
    }

    private struct Reply: Decodable {
        let answer: String
        let say: String?
    }

    func answer(_ ready: Ready, context: AppContext) async -> String {
        if ready == .singer { return singer() }
        return await ask(ready.question, context: context)
    }

    /// One question about the last minutes. From a call only the last few lines go, without names;
    /// from a video or a song, the last two minutes and a half (they are public).
    func ask(_ question: String, context: AppContext, speak: Bool = true) async -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "" }
        AppModel.syncRedactor()
        let call = context == .call
        let turns = AppModel.shared.recentTurns(seconds: call ? 90 : 150)
        let lines = turns.suffix(call ? 8 : 30).map { ($0.isMine ? "[tu]: " : "") + Redactor.redact($0.text, publicMedia: !call) }
        guard !lines.isEmpty else { return String(localized: "Nothing heard in the last few minutes.") }
        let song = call ? nil : NowPlaying.current()
        let source = call ? "call" : song.map { "song: \($0.title) by \($0.artist)" } ?? ContextDetector.show().map { "video: \($0)" } ?? ""
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "askAsked") + 1, forKey: "askAsked")
        do {
            let reply: Reply = try await CoachClient.post("api/why", [
                "text": String(lines.joined(separator: "\n").suffix(3800)),
                "question": "ask",
                "ask": String((call ? Redactor.redact(q) : q).prefix(300)),
                "source": source,
            ])
            if speak, !call {
                let line = reply.say?.trimmingCharacters(in: .whitespaces) ?? ""
                EarFlow.shared.sayIfHeadphones(line.isEmpty ? reply.answer : line)
            }
            return reply.answer
        } catch {
            return String(localized: "Couldn't explain it now.")
        }
    }

    // MARK: Ask LEXALIE, over everything you listened to together (block INSIEME 1)

    struct Quote: Identifiable {
        let id = UUID()
        let sentence: String
        let place: String
        let voice: URL?
    }

    struct Found {
        let answer: String
        let quotes: [Quote]
    }

    private struct AllReply: Decodable {
        struct Q: Decodable { let session_id: String; let title: String; let kind: String; let started_at: String; let idx: Int; let sentence: String }
        let found: Bool
        let answer: String
        let quotes: [Q]
        let reason: String
        let looked_in: [String]?
        let error: String?
    }

    /// A question about anything you heard with LEXALIE, without saying where: "what did Tom mean about
    /// the budget?", "what's Firebase?", "what did she say at the end of the film?". Signed in, our server
    /// looks in your account (the session going on now included); otherwise this Mac sends its own
    /// sessions. Names never reach Gemini; they come back here.
    func askAll(_ question: String) async -> Found {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Found(answer: "", quotes: []) }
        AppModel.syncRedactor()
        var names = Array(Redactor.privateNames.prefix(250))
        if !Redactor.me.isEmpty { names.append(Redactor.me) }
        var body: [String: Any] = [
            "question": String(q.prefix(1000)), "names": names, "profile": Profile.shared.summary,
            "now": ISO8601DateFormatter.localNow(),
        ]
        if let live = Sessions.shared.current { body["live"] = live.id.uuidString.lowercased() }
        if Account.shared.signedIn {
            await SessionSync.shared.flushLive()
        } else {
            body["sessions"] = Sessions.shared.inline(limit: 15)
        }
        do {
            let reply: AllReply = try await CoachClient.post("api/ask", body)
            if reply.error == "no_sessions" { return Found(answer: String(localized: "We haven't listened to anything together yet."), quotes: []) }
            let quotes = reply.quotes.map { q -> Quote in
                let when = Sync.parseDate(q.started_at).map { $0.formatted(.dateTime.weekday(.wide).hour().minute()) } ?? ""
                let place = [when, q.title].filter { !$0.isEmpty }.joined(separator: " · ")
                return Quote(sentence: q.sentence, place: place, voice: Sessions.shared.voice(session: q.session_id, line: q.idx))
            }
            Questions.shared.add(.init(question: q, answer: reply.answer, reason: reply.reason, sessions: reply.looked_in ?? []))
            return Found(answer: reply.answer, quotes: quotes)
        } catch {
            return Found(answer: String(localized: "Couldn't explain it now."), quotes: [])
        }
    }

    /// The song is known on this Mac (Spotify, Music or Shazam): no server.
    private func singer() -> String {
        guard let song = NowPlaying.current() else { return String(localized: "I don't recognise this song.") }
        let line = song.label
        EarFlow.shared.sayIfHeadphones(line)
        return line
    }

    // MARK: The window

    private var window: KeyPanel?
    private var pausedVideo = false

    /// ⌃⌥Q: a small window near the camera, ready to type. In a video it waits for you.
    func open(context: AppContext? = nil) {
        let context = context ?? ContextDetector.current()
        if context == .video, !AppModel.shared.videoPaused, AppModel.shared.soundPlaying, MediaKey.playPause() { pausedVideo = true }
        let panel = window ?? Self.makePanel()
        window = panel
        let song = context != .call && NowPlaying.current() != nil
        let hosting = NSHostingView(rootView: AskView(context: context, song: song).frame(width: 460))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - hosting.fittingSize.width / 2, y: frame.maxY - 12))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// The window grew (an answer came): keep its top where it was.
    func fit() {
        guard let panel = window, let view = panel.contentView else { return }
        let top = panel.frame.maxY
        panel.setContentSize(view.fittingSize)
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    func close() {
        window?.orderOut(nil)
        if pausedVideo {
            pausedVideo = false
            MediaKey.playPause()
        }
    }

    private static func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        // Never in a screen share (F1).
        panel.sharingType = .none
        return panel
    }
}

/// A floating window you can type in without LEXALIE taking over the screen.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct AskView: View {
    let context: AppContext
    let song: Bool
    @State private var text = ""
    @State private var answer: String?
    @State private var quotes: [Ask.Quote] = []
    @State private var asking = false
    @StateObject private var voice = SpokenQuestion()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ask LEXALIE").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Ask.shared.close() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Brand.paper.opacity(0.6))
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                ForEach(Ask.ready(for: context, song: song)) { ready in
                    Button { run { await Ask.shared.answer(ready, context: context) } } label: {
                        Text(ready.label).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(Brand.line.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                TextField("Anything you heard, even days ago", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Brand.paper.opacity(0.06)))
                // Spoken, recognised on this Mac; never in a call (you may not be muted).
                if context != .call, voice.available {
                    Button {
                        if voice.listening { voice.stop() } else {
                            voice.start { heard in
                                text = heard
                                send()
                            }
                        }
                    } label: {
                        Image(systemName: voice.listening ? "stop.circle.fill" : "mic.fill").font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.line)
                    .help(voice.listening ? String(localized: "Stop") : String(localized: "Say it"))
                }
            }
            if voice.listening, !voice.heard.isEmpty {
                Text(voice.heard).font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.6))
            }
            if asking {
                ProgressView().controlSize(.small)
            } else if let answer {
                Text(answer).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                ForEach(quotes) { quote in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("“\(quote.sentence)”").font(.system(size: 13, design: .serif)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            if !quote.place.isEmpty { Text(quote.place).font(.system(size: 11)).foregroundStyle(Brand.paper.opacity(0.55)) }
                            if let voice = quote.voice {
                                Button("Replay") { ToldVoice.shared.play(voice) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Brand.line)
                            }
                        }
                    }
                }
            }
            if context == .call {
                Text("Written only: in a call your voice could reach the others.")
                    .font(.system(size: 11)).foregroundStyle(Brand.paper.opacity(0.5))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.onyx))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.paper.opacity(0.08)))
        .foregroundStyle(Brand.paper)
        .onAppear { focused = true }
    }

    /// Your own question goes over everything you listened to together; the ready ones are about just now.
    private func send() {
        let q = text
        guard !asking, !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        asking = true
        Task { @MainActor in
            let found = await Ask.shared.askAll(q)
            answer = found.answer
            quotes = found.quotes
            asking = false
            Ask.shared.fit()
        }
    }

    private func run(_ work: @escaping () async -> String) {
        guard !asking else { return }
        asking = true
        Task { @MainActor in
            let a = await work()
            answer = a
            quotes = []
            asking = false
            Ask.shared.fit()
        }
    }
}

/// A question said out loud, recognised on this Mac only (Apple's recogniser, on device): the voice
/// never leaves the Mac. Where this Mac can't do it on device, the microphone button isn't there.
@MainActor
final class SpokenQuestion: ObservableObject {
    @Published var listening = false
    @Published var heard = ""
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var done: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: AppSettings.current.native.rawValue))
    }

    var available: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func start(_ onDone: @escaping (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { return }
                self.begin(onDone)
            }
        }
    }

    private func begin(_ onDone: @escaping (String) -> Void) {
        guard !listening, let recognizer, recognizer.supportsOnDeviceRecognition else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return
        }
        heard = ""
        done = onDone
        listening = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                if let text { self.heard = text }
                if final || error != nil { self.finish() }
            }
        }
        // At most eight seconds.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if self.listening { self.stop() }
        }
    }

    func stop() {
        request?.endAudio()
        // The recogniser gives its final words a moment after the end.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.finish()
        }
    }

    private func finish() {
        guard listening else { return }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = done
        done = nil
        if !text.isEmpty { callback?(text) }
    }
}
