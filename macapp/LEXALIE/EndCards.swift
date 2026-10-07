import SwiftUI

/// The card at the end (block CTX and Claude Chat's board, owner 06/10 night). When a video, an episode
/// or a call ends: at most one card, and only with something worth it; otherwise silence. It replaces
/// the notifications ("Five minutes now?", the quiz after a video): nothing arrives as a notification.
struct EndCard {
    struct Item: Identifiable {
        enum Kind { case rewound, spotted, open, laughed, refrain }
        let id = UUID()
        let kind: Kind
        /// "You went back here", "Still open for you", "Why they laughed".
        let label: String
        /// The words as they were said.
        let quote: String?
        /// What it is, or what it means, in your language.
        let detail: String?
        /// The moment behind it, for Replay and "I knew it".
        let moment: UUID?
        /// A refrain's term, explained only if you ask ("What is it?").
        var term: String? = nil
    }

    let title: String
    var items: [Item]
    /// Your next call, when it's close: "In 25 min: Lisbon team".
    var next: Call? = nil
    /// The call report, when you turned it on.
    var reportID: String? = nil
}

@MainActor
enum EndCards {
    private static let panel = FloatingPanel(position: .topRight)
    /// Left alone, it goes after this long: everything on it is in tonight's moments anyway.
    static let stays: Double = 25

    static func show(_ card: EndCard) {
        guard !card.items.isEmpty || card.next != nil else { return }
        panel.show(EndCardView(card: card), autoHide: stays, width: 420)
    }

    static func hide() { panel.hide() }

    // MARK: After a video or an episode

    /// The sentences you went back to (explained now), then what a local got and you probably didn't
    /// (your model's catches, when "Watch with me" was on). Music: never, only the tap (CTX 4).
    static func afterWatching(title: String?, since: Date) async {
        var items: [EndCard.Item] = []
        for rewind in RewindWatch.shared.take(since: since).prefix(2) {
            guard let moment = await AppModel.shared.explainSaved(rewind.moment), let piece = moment.pieces.first else { continue }
            let label = rewind.times > 1 ? String(localized: "You went back \(rewind.times) times here") : String(localized: "You went back here")
            items.append(.init(kind: .rewound, label: label, quote: moment.transcript,
                               detail: detail(piece, practice: moment.inPractice), moment: moment.id))
        }
        let spotted = ModelWatch.shared.quiz(since: since).filter { $0.pieces.first != nil }.prefix(3)
        let local = spotted.filter { ["cultural", "idiom", "subtext"].contains($0.pieces[0].cause) }.count >= 2
        for moment in spotted {
            let piece = moment.pieces[0]
            items.append(.init(kind: .spotted, label: local ? String(localized: "What a local got") : piece.causeLabel,
                               quote: moment.transcript, detail: detail(piece, practice: moment.inPractice), moment: moment.id))
        }
        if let refrain = refrainItem(context: "video") { items.append(refrain) }
        let name = title ?? String(localized: "the video")
        show(EndCard(title: local ? String(localized: "3 things a local got · \(name)") : String(localized: "After \(name)"),
                     items: items, next: nextCall()))
    }

    // MARK: After a call

    /// What's still open for you (a request with your name, a question you didn't really answer), why
    /// they laughed (only if the words before were heard well), and your next call if it's close.
    static func afterCall(open: [String], laughed: String?, with people: [String], reportID: String?) async {
        var items: [EndCard.Item] = open.prefix(2).map { line in
            EndCard.Item(kind: .open, label: String(localized: "Still open for you"), quote: line, detail: nil, moment: nil)
        }
        if let laughed {
            let id = AppModel.shared.addLaughMoment(line: laughed)
            if let moment = await AppModel.shared.explainSaved(id, tone: "laughter right after"),
               let why = [moment.meant?.text, moment.inPractice, moment.pieces.first?.meaning].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                items.append(.init(kind: .laughed, label: String(localized: "Why they laughed"), quote: moment.transcript,
                                   detail: linked(why), moment: moment.id))
            }
        }
        // Your team's jargon: what keeps coming back in your calls (CTX 1, RIC 3).
        if let refrain = refrainItem(context: "call") { items.append(refrain) }
        let who = people.isEmpty ? String(localized: "your call") : ListFormatter.localizedString(byJoining: people)
        show(EndCard(title: String(localized: "After the call with \(who)"), items: items, next: nextCall(), reportID: reportID))
    }

    /// One refrain at most, and only when it really comes back (Nodes.refrain).
    static func refrainItem(context: String?) -> EndCard.Item? {
        guard let r = Nodes.shared.refrain(in: context) else { return nil }
        Nodes.shared.markShown(r.node.key)
        let places = r.sources.prefix(3).joined(separator: ", ")
        return EndCard.Item(kind: .refrain, label: String(localized: "Comes back often · \(r.times) times this week"),
                            quote: r.node.text, detail: String(localized: "Heard in: \(places)"), moment: nil, term: r.node.text)
    }

    /// The next call within the hour: the card says it, instead of one more notification.
    static func nextCall(within minutes: Double = 60) -> Call? {
        let now = Date()
        return CalendarWatch.shared.calls.filter { $0.start > now && $0.start < now.addingTimeInterval(minutes * 60) }
            .min { $0.start < $1.start }
    }

    /// "It's from The Office: you watched it on Thursday" when the explanation names something you saw.
    private static func linked(_ text: String) -> String {
        guard let found = Nodes.shared.watched(in: text) else { return text }
        let title = found.title, day = found.at.formatted(.dateTime.weekday(.wide))
        return text + "\n" + String(localized: "You watched \(title) on \(day).")
    }

    private static func detail(_ piece: Piece, practice: String?) -> String {
        let what = piece.gloss.map { "\(piece.text): \($0) · \(piece.meaning)" } ?? "\(piece.text): \(piece.meaning)"
        guard let practice, !practice.isEmpty else { return linked(what) }
        return linked(what + "\n" + String(localized: "In practice: \(practice)"))
    }
}

/// The end card itself: white or dark like the Mac, one accent for the labels.
struct EndCardView: View {
    let card: EndCard
    @State private var done: Set<UUID> = []
    @State private var explained: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(card.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.paper.opacity(0.6)).lineLimit(1)
                Spacer()
                Button { EndCards.hide() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Brand.paper.opacity(0.6)).help("Close")
            }
            .padding(.bottom, 10)
            ForEach(Array(card.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().overlay(Brand.paper.opacity(0.1)).padding(.vertical, 12) }
                row(item)
            }
            if let next = card.next {
                Divider().overlay(Brand.paper.opacity(0.1)).padding(.vertical, 12)
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                    let minutes = max(1, Int(next.start.timeIntervalSinceNow / 60))
                    Text("In \(minutes) min: \(next.who).").lineLimit(1)
                    Spacer()
                    Button("Get ready") { CalendarWatch.shared.openPrep(next); EndCards.hide() }.buttonStyle(.link)
                }
                .font(.system(size: 12))
                .foregroundStyle(Brand.paper.opacity(0.75))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.onyx))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.paper.opacity(0.08)))
        .foregroundStyle(Brand.paper)
    }

    @ViewBuilder private func row(_ item: EndCard.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.line)
            if let quote = item.quote, !quote.isEmpty {
                Text("“\(quote)”").font(.system(size: 15, design: .serif)).fixedSize(horizontal: false, vertical: true)
            }
            if let detail = item.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 13)).foregroundStyle(Brand.paper.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            if let what = explained[item.id] {
                Text(what).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                if item.kind == .refrain, let term = item.term, explained[item.id] == nil {
                    Button("What is it?") {
                        Task { explained[item.id] = await AppModel.shared.explainTerm(term) ?? String(localized: "Couldn't explain it now.") }
                    }
                } else if item.kind == .open {
                    // "I handled it": gone, and LEXALIE learns what matters to you.
                    Button(done.contains(item.id) ? String(localized: "Noted") : String(localized: "I handled it")) { done.insert(item.id) }
                } else if let id = item.moment, let moment = AppModel.shared.store.moments.first(where: { $0.id == id }) {
                    if let piece = moment.pieces.first {
                        Button(done.contains(item.id) ? String(localized: "Noted: it won't come back") : String(localized: "I knew it")) {
                            guard !done.contains(item.id) else { return }
                            done.insert(item.id)
                            AppModel.shared.knew(piece, in: moment)
                        }
                    }
                    if moment.clipFile != nil { Button("Replay") { AppModel.shared.play(moment, slow: false) } }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Brand.paper.opacity(0.6))
        }
    }
}

/// Going back in a video (block R): the same sentence heard again within a minute and a half means you
/// rewound to hear it, so it's the one you missed. It reads the words LEXALIE already hears, not the
/// player (macOS doesn't let other apps read it) and not the screen.
@MainActor
final class RewindWatch {
    static let shared = RewindWatch()

    struct Rewind { let moment: UUID; var times: Int; let at: Date }

    private var heard: [(words: Set<String>, text: String, at: Date)] = []
    private var rewinds: [Rewind] = []

    /// Every tick while a video plays, with the last minute as turns.
    func observe(_ turns: [Turn], since start: Date, show: String?) {
        let now = Date()
        heard.removeAll { now.timeIntervalSince($0.at) > 90 }
        for turn in turns where !turn.isMine {
            let words = Set(Memory.key(turn.text).split(separator: " ").map(String.init))
            // Short lines repeat by themselves ("yeah, yeah"): only real sentences count.
            guard words.count >= 6 else { continue }
            let at = start.addingTimeInterval(turn.start)
            // The same occurrence seen again in the next window is not a rewind.
            if heard.contains(where: { abs($0.at.timeIntervalSince(at)) < 4 && Self.same($0.words, words) }) { continue }
            if let first = heard.first(where: { Self.same($0.words, words) && at.timeIntervalSince($0.at) >= 4 }) {
                if let i = rewinds.firstIndex(where: { now.timeIntervalSince($0.at) < 120 && Self.same(Set(Memory.key(first.text).split(separator: " ").map(String.init)), words) }) {
                    rewinds[i].times += 1
                } else {
                    rewinds.append(Rewind(moment: AppModel.shared.addRewindMoment(line: first.text, show: show), times: 1, at: now))
                }
            }
            heard.append((words, turn.text, at))
        }
    }

    /// The rewinds of this session, most rewound first; they're handed over once.
    func take(since: Date) -> [Rewind] {
        let mine = rewinds.filter { $0.at >= since }.sorted { $0.times > $1.times }
        rewinds.removeAll { $0.at >= since }
        return mine
    }

    private static func same(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let union = a.union(b).count
        return union > 0 && Double(a.intersection(b).count) / Double(union) >= 0.8
    }
}
