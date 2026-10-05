import SwiftUI

/// The evening: relive each moment. Listen, try, reveal, then "I know it" or "again".
/// "Again" brings it back tomorrow; "I know it" in 3, 7, then 21 days.
struct ReviewView: View {
    /// A fixed set (a call's lesson, a prep) instead of today's queue, due or not.
    var only: [UUID]? = nil
    var title: String? = nil

    init(only: [UUID]? = nil, title: String? = nil) {
        self.only = only
        self.title = title
    }

    @EnvironmentObject private var store: Store
    @State private var queue: [Moment] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var knownCount = 0
    @State private var againCount = 0
    /// Tonight's step test (I3): three moments.
    @State private var ladder: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if index < queue.count {
                let moment = queue[index]
                header(moment)
                if revealed { reveal(moment) }
                else if ladder.contains(moment.id) { EarLadder(moment: moment) { revealed = true }.id(moment.id) }
                else { listen(moment) }
                Spacer(minLength: 0)
                buttons(moment)
            } else {
                done
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 560)
        .onAppear(perform: load)
    }

    private func load() {
        if let only {
            queue = store.moments.filter { only.contains($0.id) }.sorted { $0.date < $1.date }
        } else {
            queue = store.reviewQueue
        }
        index = 0
        revealed = false
        knownCount = 0
        againCount = 0
        ladder = EarLadder.picks(queue, store: store)
        if let first = queue.first { playIfPlain(first) }
    }

    /// The step test plays its own sound.
    private func playIfPlain(_ moment: Moment) {
        if !ladder.contains(moment.id) { AppModel.shared.play(moment, slow: false) }
    }

    private func header(_ moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(index), total: Double(max(queue.count, 1))).tint(Brand.signal)
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(Brand.accent) }
            HStack {
                Text("\(index + 1) / \(queue.count)").font(.caption.monospacedDigit())
                Spacer()
                Text(context(moment)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func context(_ moment: Moment) -> String {
        var parts = [moment.date.formatted(date: .abbreviated, time: .shortened)]
        if let with = moment.with { parts.append(String(localized: "with \(with)")) }
        if moment.trigger == "sorry" { parts.append(String(localized: "you said \"sorry?\"")) }
        if (moment.step ?? 0) > 0 || moment.review == .again { parts.append("review") }
        return parts.joined(separator: " · ")
    }

    private func listen(_ moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Listen again. Can you catch what they said?").font(.title3.weight(.semibold))
            HStack {
                Button { AppModel.shared.play(moment, slow: false) } label: { Label("Replay", systemImage: "play.fill") }
                Button { AppModel.shared.play(moment, slow: true) } label: { Label("Slow", systemImage: "tortoise.fill") }
            }
            .controlSize(.large)
            .disabled(store.clipURL(moment) == nil)
            if store.clipURL(moment) == nil {
                Text("The audio for this moment has already been deleted (it's kept \(Store.clipDays) days).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reveal(_ moment: Moment) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let current = store.moments.first(where: { $0.id == moment.id }) ?? moment
                Text(current.transcript).font(.system(size: 20))
                // Test (§ 19.25): the same sentence as ElevenLabs heard it, to see who got it right.
                if let cloud = current.cloudTranscript, !cloud.isEmpty, cloud != current.transcript {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On your device: \(current.transcript)").font(.callout)
                        Text("ElevenLabs: \(cloud)").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                }
                Text("«\(current.translation)»").foregroundStyle(.secondary)
                if let intent = current.intent, !intent.isEmpty {
                    Label(intent, systemImage: "eye").font(.callout.weight(.medium)).foregroundStyle(Brand.accent)
                }
                ForEach(Array(current.pieces.enumerated()), id: \.offset) { _, piece in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(piece.text).font(.headline)
                            Spacer()
                            Text(piece.causeLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(piece.meaning)
                        if let subtext = piece.subtext, !subtext.isEmpty { Text("Really means: \(subtext)").font(.callout.weight(.medium)) }
                        if !piece.note.isEmpty { Text(piece.note).font(.callout).foregroundStyle(.secondary) }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Brand.signal).frame(width: 3) }
                }
                if moment.turns != nil {
                    Button("Not this one? Pick the right piece") { AppModel.shared.showChooser(moment.id) }
                }
                Divider()
                PracticeView(moment: current).id(current.id)
                if moment.trigger == "hesitation" {
                    // LEXALIE noticed a long pause after a question. Only you know why (§ 1.7).
                    HStack {
                        Text("You paused here. Was it the language?").font(.callout)
                        Button("Yes, the language") { store.setLabel(nil, for: moment.id) }
                        Button("No, I was thinking") { notLanguage(moment) }
                    }
                    .controlSize(.small)
                }
                WhoSaidIt(moment: moment)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func buttons(_ moment: Moment) -> some View {
        if revealed {
            HStack {
                Button("Again") { answer(.again, moment) }
                    .keyboardShortcut("1", modifiers: [])
                Spacer()
                Button("I know it") { answer(.known, moment) }
                    .keyboardShortcut("2", modifiers: [])
                    .tint(Brand.accent)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        } else if !ladder.contains(moment.id) {
            Button("Reveal") { revealed = true }
                .keyboardShortcut(.space, modifiers: [])
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
        }
    }

    /// Not a language problem: it never comes back and your model isn't touched.
    private func notLanguage(_ moment: Moment) {
        store.dismiss(moment.id)
        index += 1
        revealed = false
        if index < queue.count { playIfPlain(queue[index]) }
    }

    private func answer(_ review: Review, _ moment: Moment) {
        store.setReview(review, for: moment.id)
        Memory.shared.record(review == .known ? "review_known" : "review_again", pieces: moment.pieces, moment: moment)
        if review == .known { knownCount += 1 } else { againCount += 1 }
        index += 1
        revealed = false
        if index < queue.count { playIfPlain(queue[index]) }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(only == nil ? String(localized: "Done for today.") : String(localized: "Done.")).font(.largeTitle.weight(.semibold))
            if queue.isEmpty {
                Text("Nothing to review right now.").foregroundStyle(.secondary)
            } else {
                Text("\(knownCount) you know · \(againCount) back tomorrow").font(.title3)
            }
            AccentQuestion(names: queue.compactMap(\.with))
            weeks
            Spacer()
            Button("Start again") { load() }.disabled(only == nil && store.reviewQueue.isEmpty)
        }
    }

    /// Taps per hour of listening, week by week: the help that fades.
    private var weeks: some View {
        let rows = store.weeklyRates()
        let rates = rows.map { $0.hours > 0 ? Double($0.taps) / $0.hours : 0 }
        let top = max(rates.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Moments per hour of listening").font(.headline)
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    VStack(spacing: 4) {
                        Text(row.hours > 0 ? String(format: "%.1f", rates[i]) : "–").font(.caption.monospacedDigit())
                        RoundedRectangle(cornerRadius: 4)
                            .fill(i == rows.count - 1 ? Brand.signal : Color.secondary.opacity(0.3))
                            .frame(width: 44, height: max(4, 90 * rates[i] / top))
                        Text(row.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// "What accent does Sarah have?", asked once per person whose accent is missing (F2): the accent
/// comes from you, never from their voice.
private struct AccentQuestion: View {
    let names: [String]
    @EnvironmentObject private var store: Store
    @AppStorage("accentAsked") private var askedRaw = ""

    private var asked: Set<String> { Set(askedRaw.split(separator: "\n").map(String.init)) }

    private var name: String? {
        var seen = Set<String>()
        return names.first { name in
            guard seen.insert(name).inserted, !asked.contains(name) else { return false }
            let accent = store.accent(of: name)
            return accent == nil || Person.english(accent ?? "") == "Other / not sure"
        }
    }

    var body: some View {
        if let name {
            VStack(alignment: .leading, spacing: 8) {
                Text("What accent does \(name) have?").font(.headline)
                FlowButtons(name: name, choose: { accent in
                    store.upsertPerson(Person(name: name, accent: accent))
                    remember(name)
                })
                Button("I don't know") { remember(name) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private func remember(_ name: String) {
        askedRaw = (asked.union([name])).sorted().joined(separator: "\n")
    }

    private struct FlowButtons: View {
        let name: String
        let choose: (String) -> Void
        var body: some View {
            let accents = Person.accents.filter { $0 != "Other / not sure" }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(accents, id: \.self) { accent in
                    Button(Person.label(accent)) { choose(accent) }.controlSize(.small)
                }
            }
        }
    }
}
