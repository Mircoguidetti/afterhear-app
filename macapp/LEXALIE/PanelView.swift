import SwiftUI

/// What appears next to the meeting: only the piece you missed.
struct PanelView: View {
    /// The card's second word, opened with one touch.
    @State var moreWords = false
    enum Phase {
        case saved(String)
        /// Battery low: the mark is kept as sound. "Transcribe now?"
        case waiting(Int)
        case glance(Moment)
        case working
        case result(Moment)
        case failed(String)
        /// The sentence is ready, the explanation is on its way.
        case heard(String)
        /// A paused video: the explanation, then Continue.
        case video(Moment, paused: Bool)
        /// "Now", step by step: the sentence as soon as it's heard, and the place where the
        /// explanation is coming, so nobody takes the sentence for the whole answer (owner, 02/10).
        case progress(Progress)
        /// You paused a video right after people spoke: "Didn't get that?" (pause = tap, owner 03/10).
        case offer(Date)
    }

    struct Progress {
        /// Heard by the model on this device: shown as "Stays on your device".
        var onDevice: Bool
        var sentence: String? = nil
        /// The line before, quietly, as in the explanation.
        var before: String? = nil
        var paused = false
        var pauseFailed = false
        /// The translation from this Mac, under the sentence.
        var translation: String? = nil
        /// Offline and nothing to explain it with: saved, explained tonight.
        var savedOffline = false
        /// While the sentence is still being said: the words so far, in grey.
        var heardSoFar: String? = nil
        /// Why it was saved instead of explained, said as it is (offline, signed out, server down).
        var savedReason: String? = nil
        /// A line of a song: "Song paused", not "Video paused".
        var song = false
    }

    let phase: Phase

    var body: some View {
        switch phase {
        case .saved(let text):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.paper)
                Text(text).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.onyx))
            .foregroundStyle(Brand.paper)
        case .glance(let moment):
            glance(moment)
        case .offer(let pausedAt):
            HStack(spacing: 8) {
                Text("Didn't get that?").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 6)
                Button {
                    Task { @MainActor in await AppModel.shared.captureMoment(trigger: "pause", now: true, pausedAt: pausedAt) }
                } label: {
                    Text("Explain").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Brand.accent))
                        .foregroundStyle(Brand.onyx)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.onyx))
            .foregroundStyle(Brand.paper)
        case .waiting(let count):
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Marked · battery low").font(.system(size: 13, weight: .medium))
                    Text("Sound kept. Transcribed when you charge.").font(.system(size: 11)).foregroundStyle(Brand.paper.opacity(0.6))
                }
                Spacer(minLength: 6)
                Button(count > 1 ? String(localized: "Transcribe now (\(count))") : String(localized: "Transcribe now")) {
                    Task { @MainActor in await AppModel.shared.transcribeWaiting() }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.onyx))
            .foregroundStyle(Brand.paper)
        default:
            card
        }
    }

    /// One glance during the conversation: "dodgy → losco". Click for the rest.
    private func glance(_ moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if moment.pieces.isEmpty {
                Text("✓ Marked · it was just fast").font(.system(size: 13)).foregroundStyle(Brand.paper.opacity(0.8))
            }
            ForEach(Array(moment.pieces.prefix(2).enumerated()), id: \.offset) { _, piece in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(piece.text).font(.system(size: 17, weight: .semibold)).foregroundStyle(Brand.paper)
                    Text("→").foregroundStyle(Brand.paper.opacity(0.4))
                    Text(piece.gloss ?? piece.meaning).font(.system(size: 16)).lineLimit(1)
                }
            }
            if let intent = moment.intent, !intent.isEmpty {
                Text("They mean: \(intent)").font(.system(size: 13)).foregroundStyle(Brand.paper.opacity(0.8)).lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.onyx))
        .foregroundStyle(Brand.paper)
        .contentShape(Rectangle())
        .onTapGesture { AppModel.shared.expand(moment) }
        .help("Click for the full explanation")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Who it's from, without taking the eye off the sentence: the word in a light grey (owner, 05/10).
                Wordmark(size: 10.5, color: Brand.paper.opacity(0.42))
                Spacer()
                Button {
                    AppModel.shared.closePanel()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.paper.opacity(0.6))
                .help("Close")
            }
            content
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.onyx))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1)))
        .foregroundStyle(Brand.paper)
        .environment(\.colorScheme, .dark)
    }

    /// The sentence as heard, with the pieces to learn in the accent colour.
    private func highlighted(_ moment: Moment) -> AttributedString {
        var text = AttributedString(moment.transcript)
        text.foregroundColor = Brand.paper.opacity(0.85)
        for piece in moment.pieces {
            if let range = text.range(of: piece.heardAs ?? piece.text, options: [.caseInsensitive, .diacriticInsensitive])
                ?? text.range(of: piece.text, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].foregroundColor = Brand.paper
                text[range].underlineStyle = Text.LineStyle(pattern: .solid, color: Brand.line)
                text[range].font = .system(size: 16, weight: .semibold)
            }
        }
        return text
    }

    private func timing(_ moment: Moment) -> String {
        func seconds(_ ms: Int) -> String { String(format: "%.1f s", Double(ms) / 1000) }
        guard let mac = moment.transcribeMs, let server = moment.serverMs else { return seconds(moment.latencyMs) }
        if moment.transcribedBy == "gemini-audio" { return "\(seconds(moment.latencyMs)) · Gemini audio" }
        let by = moment.transcribedBy ?? ""
        let where_ = by.hasPrefix("cloud:") ? String(by.dropFirst(6).split(separator: ":").first ?? "cloud") : by.hasPrefix("parakeet") ? String(localized: "on device") : by == "apple-new" ? "Mac (new)" : by == "mac-live" || by == "apple-old" ? "Mac live" : "Mac"
        return "\(seconds(moment.latencyMs)) · \(where_) \(seconds(mac)) · AI \(seconds(server))"
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .saved, .glance, .waiting, .offer:
            EmptyView()
        case .working:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Replaying the last seconds…").font(.system(size: 14))
            }
        case .failed(let message):
            Text(message).font(.system(size: 14)).foregroundStyle(Brand.paper.opacity(0.85))
        case .heard(let sentence):
            Text(sentence).font(.system(size: 16)).foregroundStyle(Brand.paper.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Explaining…").font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.6))
            }
        case .video(let moment, let paused):
            explanation(moment)
            if paused {
                HStack {
                    // Short, never cut (owner, 03/10): the shortcut lives in the Continue button's tooltip.
                    Text(moment.context == "song" ? String(localized: "Song paused") : String(localized: "Video paused")).font(.system(size: 11)).foregroundStyle(Brand.paper.opacity(0.5))
                        .lineLimit(1).fixedSize()
                    Spacer()
                    if moment.context != "song" {
                        Button { AppModel.shared.rewindVideo() } label: {
                            Text("⟲ Back 10 s").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().stroke(Brand.accent.opacity(0.6)))
                                .foregroundStyle(Brand.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Rewind the video and play: hear the real voice again")
                    }
                    Button { AppModel.shared.resumeVideo() } label: {
                        Text("Continue ▸").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Brand.accent))
                            .foregroundStyle(Brand.onyx)
                    }
                    .buttonStyle(.plain)
                    .help("Or \(DoubleTapOption.label)")
                }
                .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't pause the video. LEXALIE presses play/pause for you: it needs Accessibility (System Settings → Privacy & Security). Or turn off \"Pause the video\" in Settings.")
                        .font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility") { MediaKey.openSettings() }.controlSize(.small)
                }
            }
        case .progress(let step):
            ProgressSteps(step: step)
        case .result(let moment):
            explanation(moment)
        }
    }

    /// One word or phrase of the card: the words, what they mean here, how to catch them next time.
    @ViewBuilder private func pieceView(_ piece: Piece) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(piece.text).font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.paper)
                Spacer(minLength: 8)
                Text(piece.guess == true ? String(localized: "Maybe this one?") : piece.causeLabel)
                    .font(.system(size: 11)).foregroundStyle(Brand.paper.opacity(0.5))
            }
            Text(piece.gloss.map { "\($0) · \(piece.meaning)" } ?? piece.meaning).font(.system(size: 14))
            if let subtext = piece.subtext, !subtext.isEmpty {
                Text("Really means: \(subtext)").font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.paper.opacity(0.9))
            }
            if !piece.note.isEmpty {
                Text(piece.note).font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.6))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Show the translation right away? Yes when you're still getting there, or if you asked for it always.
    private static var translationOpen: Bool {
        let level = UserDefaults.standard.string(forKey: Key.level) ?? "B2"
        return ["A2", "B1"].contains(level) || UserDefaults.standard.bool(forKey: Key.translationAlways)
    }

    /// Only the sentence and its translation, when you chose so in Settings.
    private static var explains: Bool {
        UserDefaults.standard.object(forKey: Key.nowExplain) == nil || UserDefaults.standard.bool(forKey: Key.nowExplain)
    }

    /// One look, one order (owner, 02/10): the sentence as a subtitle, its translation under it, then
    /// the explanation below a line. Few buttons, no labels about who did what.
    @ViewBuilder private func explanation(_ moment: Moment) -> some View {
        Group {
            // A tap long after the words: say when they were said (owner, 03/10).
            if let turns = moment.turns, let chosen = moment.chosen, turns.indices.contains(chosen),
               let tapAt = moment.tapAt, tapAt - turns[chosen].end >= 30 {
                let ago = Int(tapAt - turns[chosen].end)
                Text(ago >= 90 ? String(localized: "Said \(Int((Double(ago) / 60).rounded())) min ago") : String(localized: "Said \(ago) s ago"))
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.paper.opacity(0.45))
            }
            if let turns = moment.turns, let chosen = moment.chosen, chosen > 0, turns.indices.contains(chosen - 1),
               moment.alternative != chosen - 1 {
                Text(turns[chosen - 1].text)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.paper.opacity(0.4))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ClickableSentence(moment: moment)
            TranslationLine(text: moment.quickTranslation ?? moment.translation, open: Self.translationOpen)
            if Self.explains {
                Divider().overlay(Color.white.opacity(0.12))
                // One card (block P2, owner 06/10): the hardest word, then "in practice", the point in plain
                // words. A second word only one touch away; "maybe they meant" only where there's no such line.
                if let piece = moment.pieces.first { pieceView(piece) }
                if let practice = moment.inPractice?.trimmingCharacters(in: .whitespacesAndNewlines), !practice.isEmpty {
                    Text("In practice: \(practice)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.paper)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let meant = moment.meant, meant.shown {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "sparkles").font(.system(size: 11))
                            Text("Maybe they meant: \(meant.text)").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Brand.accent)
                        if !meant.alternative.isEmpty {
                            Text("Or: \(meant.alternative)").font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.55))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .help(meant.evidence)
                }
                if moment.pieces.count > 1 {
                    if moreWords {
                        pieceView(moment.pieces[1])
                    } else {
                        Button { moreWords = true } label: {
                            Text("Also: \(moment.pieces[1].text)").font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if moment.pieces.isEmpty, moment.offline == true {
                    Text("Saved. The explanation will be waiting for you tonight.")
                        .font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.6))
                } else if moment.offline == true {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "airplane").font(.system(size: 11))
                        Text("Quick explanation from this Mac. The full one comes as soon as our server answers.").font(.system(size: 12))
                    }
                    .foregroundStyle(Brand.paper.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Not this one? The others it could be, one touch away; ‹ › go further (owner, 05/10).
            if let turns = moment.turns {
                let list = (moment.others ?? moment.alternative.map { [$0] } ?? [])
                    .filter { $0 != moment.chosen && turns.indices.contains($0) }.prefix(3)
                ForEach(Array(list), id: \.self) { i in
                    Button { Task { await AppModel.shared.jump(moment.id, to: i) } } label: {
                        Text(turns[i].text)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.paper.opacity(0.7))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Explain this sentence instead")
                }
            }
            HStack(spacing: 8) {
                if let turns = moment.turns, let chosen = moment.chosen {
                    Button { Task { await AppModel.shared.step(moment.id, by: -1) } } label: { Image(systemName: "chevron.left") }
                        .disabled(AppModel.neighbor(turns, from: chosen, by: -1) == nil)
                        .help("The sentence before")
                    Button { Task { await AppModel.shared.step(moment.id, by: 1) } } label: { Image(systemName: "chevron.right") }
                        .disabled(AppModel.neighbor(turns, from: chosen, by: 1) == nil)
                        .help("The sentence after")
                }
                if moment.context == "song" && moment.clipFile == nil {
                    // A song has no recording of ours: the song itself, from that line (owner, 03/10).
                    Button("Play this line") { AppModel.shared.playSongLine(moment) }
                        .help("The song again from this line, in Spotify or Music")
                } else {
                    Button("Replay") { AppModel.shared.play(moment, slow: false) }
                    Button("Slow") { AppModel.shared.play(moment, slow: true) }
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }
}

/// The sentence as a subtitle, every word clickable: click the one you didn't get and it's explained
/// first (owner, 02/10). The pieces to learn are in the accent colour.
private struct ClickableSentence: View {
    let moment: Moment
    @State private var asking: String?

    var body: some View {
        let hard = Set(moment.pieces.flatMap { ($0.heardAs ?? $0.text).lowercased().split(separator: " ").map(String.init) })
        FlowLayout(spacing: 4, lineSpacing: 2) {
            ForEach(Array(moment.transcript.split(separator: " ").enumerated()), id: \.offset) { _, word in
                let w = String(word)
                let key = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
                Button {
                    asking = w
                    Task {
                        await AppModel.shared.explainWord(moment.id, word: w)
                        asking = nil
                    }
                } label: {
                    Text(w)
                        .font(.system(size: 18, weight: hard.contains(key) ? .semibold : .regular))
                        .foregroundStyle(hard.contains(key) ? Brand.paper : Brand.paper.opacity(0.55))
                        .opacity(asking == w ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .help("Didn't get this word? Click it.")
            }
        }
    }
}

/// The translation under the sentence: open, or one click away at B2/C1.
private struct TranslationLine: View {
    let text: String
    let open: Bool
    @State private var shown = false

    var body: some View {
        if !text.isEmpty {
            if open || shown {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.paper.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Show translation") { shown = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.paper.opacity(0.45))
            }
        }
    }
}

/// Words that wrap like text, each one its own button.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 340
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// "Now", step by step: Heard → Explaining. The sentence comes first; grey lines pulse where the
/// explanation will be, so it's clear more is on its way (owner, 02/10).
private struct ProgressSteps: View {
    let step: PanelView.Progress
    @State private var pulse = false
    @State private var tied: CGFloat = 0
    private var explains: Bool {
        UserDefaults.standard.object(forKey: Key.nowExplain) == nil || UserDefaults.standard.bool(forKey: Key.nowExplain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                stage(step.sentence == nil ? String(localized: "Listening back…") : String(localized: "Heard"), done: step.sentence != nil, active: step.sentence == nil)
                if step.savedOffline {
                    stage(String(localized: "Saved for tonight"), done: true, active: false)
                } else if explains {
                    stage(String(localized: "Explaining"), done: false, active: step.sentence != nil)
                }
                Spacer(minLength: 0)
            }
            if let before = step.before, !before.isEmpty {
                Text(before)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.paper.opacity(0.4))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sentence = step.sentence {
                Text(sentence)
                    .font(.system(size: 18))
                    .foregroundStyle(Brand.paper)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                if let translation = step.translation {
                    Text(translation)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.paper.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            } else if let soFar = step.heardSoFar {
                Text(soFar)
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.paper.opacity(0.45))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ghost(width: 0.9)
            }
            if step.savedOffline {
                // Offline: "saved", and nobody waits for what can't come (owner, 02/10).
                HStack(spacing: 10) {
                    Text(step.savedReason ?? String(localized: "You're offline: saved. The explanation will be waiting for you tonight."))
                        .font(.system(size: 13)).foregroundStyle(Brand.paper.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onAppear { withAnimation(.easeInOut(duration: 0.9)) { tied = 1 } }
            } else if explains {
                VStack(alignment: .leading, spacing: 7) {
                    ghost(width: 0.75)
                    ghost(width: 0.95)
                    ghost(width: 0.55)
                }
            }
            HStack(spacing: 12) {
                if step.onDevice {
                    Label("Stays on your device", systemImage: "lock.fill")
                }
                if step.paused {
                    Label(step.song ? String(localized: "Song paused") : String(localized: "Video paused"), systemImage: "pause.fill")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(Brand.paper.opacity(0.5))
            if step.pauseFailed {
                HStack(spacing: 8) {
                    Text("Couldn't pause the video.").font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.7))
                    Button("Open Accessibility") { MediaKey.openSettings() }.controlSize(.small)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: step.sentence)
        .animation(.easeOut(duration: 0.25), value: step.translation)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func stage(_ title: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Brand.paper.opacity(0.3), lineWidth: 1).frame(width: 9, height: 9)
                if done {
                    Circle().fill(Brand.paper).frame(width: 9, height: 9).shadow(color: Brand.paper.opacity(0.7), radius: 4)
                } else if active {
                    Circle().fill(Brand.paper.opacity(pulse ? 0.9 : 0.25)).frame(width: 9, height: 9).shadow(color: Brand.paper.opacity(pulse ? 0.6 : 0), radius: 4)
                }
            }
            Text(title)
                .font(.system(size: 12, weight: active || done ? .semibold : .regular))
                .foregroundStyle(Brand.paper.opacity(done || active ? 0.9 : 0.4))
        }
    }

    /// A grey line where text is coming.
    private func ghost(width: CGFloat) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4)
                .fill(Brand.paper.opacity(pulse ? 0.16 : 0.07))
                .frame(width: geo.size.width * width, height: 10)
        }
        .frame(height: 10)
    }
}
