import Foundation

/// The end-of-session card, always (block INSIEME 2): when a call, a video, a podcast or a
/// conversation ends, our server picks in one call the 3–4 moments you most likely missed or that
/// matter to you, and explains each; plus what they asked you and the questions left open. The free
/// test of 08/10 showed a score on the Mac alone finds 9% of the bench's hard moments, so Gemini picks
/// (afterhear-app bench/endscore.py). What leaves the Mac: their lines without names and numbers in a
/// call (a video is public), the lines you tapped, a short profile. Your taps are always on it.
@MainActor
enum SessionCard {
    struct Answer: Decodable {
        struct Moment: Decodable {
            let line: Int
            let sentence: String
            let why: String
            let meaning: String
            let numbers: String
            let negation: String
            let terms: [Sessions.Term]
            let unsure: Bool
        }
        struct Item: Decodable { let line: Int; let sentence: String; let meaning: String }
        let moments: [Moment]
        let asked_you: [Item]
        let open_questions: [Item]
    }

    static let tapTriggers: Set<String> = ["tap", "airpods", "siri", "sorry", "menu", "watch"]

    /// The lines you tapped: the moment's own words, else the line that ended just before the tap.
    static func taps(in s: Sessions.Session) -> [Int] {
        let end = s.end ?? Date()
        let marks = AppModel.shared.store.moments.filter { !$0.isModel && $0.date >= s.start && $0.date <= end && tapTriggers.contains($0.trigger ?? "tap") }
        var out: [Int] = []
        for mark in marks {
            let texts = s.lines.map(\.text)
            if let origin = Told.origin(of: mark.transcript, in: texts), let line = s.lines.first(where: { $0.text == origin }) {
                out.append(line.i)
                continue
            }
            let at = mark.date.timeIntervalSince(s.start)
            if let line = s.lines.last(where: { $0.start <= at - 1 && at - $0.end < 15 }) { out.append(line.i) }
        }
        return Array(Set(out)).sorted().suffix(8)
    }

    /// Asks for the card and keeps it in the session (with the voice of each moment). Nil when the
    /// server can't be reached: the session is kept anyway, without a card.
    static func make(_ session: Sessions.Session) async -> Sessions.Session? {
        var s = session
        AppModel.syncRedactor()
        let publicMedia = s.kind != "call" && s.kind != "in_person"
        let lines: [[String: Any]] = s.lines.suffix(2500).map {
            ["i": $0.i, "who": "them", "text": String(Redactor.redact($0.text, publicMedia: publicMedia).prefix(1200))] as [String: Any]
        }
        let explained = Nodes.shared.nodes.values.filter { $0.explained != nil }.map(\.text).prefix(100)
        let tapped = taps(in: s)
        guard let answer: Answer = try? await CoachClient.post("api/endcard", [
            "lines": lines, "taps": tapped, "kind": s.kind, "profile": Profile.shared.summary,
            "discarded": Profile.shared.data.discarded, "explained": Array(explained),
        ]) else { return nil }
        let original = Dictionary(uniqueKeysWithValues: s.lines.map { ($0.i, $0.text) })
        s.card = answer.moments.compactMap { m in
            guard let text = original[m.line] else { return nil }
            let sentence = m.sentence.contains("[") ? text : m.sentence
            return Sessions.CardMoment(line: m.line, sentence: sentence, why: m.why, meaning: Sessions.restore(m.meaning, from: text),
                                       numbers: Sessions.restore(m.numbers, from: text), negation: Sessions.restore(m.negation, from: text),
                                       terms: m.terms, unsure: m.unsure, source: tapped.contains(m.line) ? "tap" : m.why == "asked" ? "asked" : "picked",
                                       glossary: Nodes.shared.glossaryLine(for: text))
        }
        s.asked = answer.asked_you.compactMap { a in original[a.line].map { Sessions.Asked(line: a.line, sentence: $0, meaning: Sessions.restore(a.meaning, from: $0), open: false) } }
            + answer.open_questions.compactMap { a in original[a.line].map { Sessions.Asked(line: a.line, sentence: $0, meaning: Sessions.restore(a.meaning, from: $0), open: true) } }
        s.cardMade = true
        for m in s.card where m.source == "tap" { Profile.shared.tapped(m.why) }
        await Sessions.shared.cutClips(&s)
        Sessions.shared.update(s)
        return s
    }

    /// The card's lines, the way the end card shows them.
    static func items(_ s: Sessions.Session) -> [EndCard.Item] {
        var items: [EndCard.Item] = s.card.filter { !$0.discarded }.map { m in
            var item = EndCard.Item(kind: .picked, label: label(m), quote: m.sentence, detail: detail(m), moment: nil)
            item.session = s.id
            item.cardMoment = m.id
            item.voice = Sessions.shared.clipURL(s, m)
            item.unsure = m.unsure
            return item
        }
        for a in s.asked {
            var item = EndCard.Item(kind: a.open ? .open : .told, label: a.open ? String(localized: "Nobody answered") : String(localized: "They asked you"),
                                    quote: a.sentence, detail: a.meaning, moment: nil)
            item.voice = ToldVoice.shared.voice(for: a.sentence)
            items.append(item)
        }
        return items
    }

    static func label(_ m: Sessions.CardMoment) -> String {
        switch m.why {
        case "tap": String(localized: "You tapped here")
        case "word": String(localized: "A word you may not know")
        case "acronym": String(localized: "An acronym")
        case "name": String(localized: "Who or what it is")
        case "meant": String(localized: "What they meant")
        case "numbers": String(localized: "The numbers")
        case "negation": String(localized: "Careful: a negation")
        case "joke": String(localized: "Why they laughed")
        case "speed": String(localized: "Said fast")
        case "asked": String(localized: "They asked you")
        default: String(localized: "Maybe you missed this")
        }
    }

    static func detail(_ m: Sessions.CardMoment) -> String {
        var out = [m.meaning]
        if !m.numbers.isEmpty { out.append(m.numbers) }
        if !m.negation.isEmpty { out.append(m.negation) }
        for t in m.terms {
            if t.isPublic, !t.meaning.isEmpty { out.append("\(t.term): \(t.meaning)") }
            else if !t.isPublic { out.append(String(localized: "\(t.term): nobody explained it in this session")) }
        }
        if let g = m.glossary, !g.isEmpty { out.append(String(localized: "Explained before: \(g)")) }
        return out.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension Sessions {
    /// "Not important" on the card: gone from it, here and on every device, and the profile learns.
    func discard(_ session: UUID, _ moment: UUID) {
        guard var s = sessions.first(where: { $0.id == session }), let k = s.card.firstIndex(where: { $0.id == moment }) else { return }
        s.card[k].discarded = true
        Profile.shared.discarded(s.card[k].sentence, why: s.card[k].why)
        update(s)
    }

    /// "I knew it": the profile learns it, the moment stays.
    func knew(_ session: UUID, _ moment: UUID) {
        guard var s = sessions.first(where: { $0.id == session }), let k = s.card.firstIndex(where: { $0.id == moment }) else { return }
        s.card[k].knew = true
        Profile.shared.knew(s.card[k].terms.first?.term ?? s.card[k].sentence)
        update(s)
    }
}
