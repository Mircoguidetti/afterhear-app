import Foundation
import NaturalLanguage

/// The memory of what you heard (block MEM): a small map on this Mac of the names, places, companies
/// and acronyms you hear, with where and when, and whether you reacted. Only these nodes, never the
/// text around them; they fade after 60 days and one click deletes them all (Settings). From them come
/// the refrains (block RIC): "Project Phoenix, 4 times this week, from 3 places".
@MainActor
final class Nodes {
    static let shared = Nodes()

    struct Sighting: Codable {
        let at: Date
        /// The video's title or the call's title: only on this Mac.
        let source: String
        let context: String
    }

    struct Node: Codable {
        let key: String
        var text: String
        /// "person", "place", "org", "acronym".
        let kind: String
        var sightings: [Sighting]
        /// You tapped on it, or went back to it.
        var reacted = false
        /// Last time a card showed it as a refrain: never twice in three days.
        var shownAt: Date? = nil
        /// The glossary (08/10): the one sentence where someone explained this acronym or project name
        /// ("CMS, which stands for…"), with where and when. Only that sentence, only on this Mac.
        var explained: Explained? = nil
    }

    struct Explained: Codable {
        let sentence: String
        let at: Date
        let source: String
    }

    private(set) var nodes: [String: Node] = [:]
    private var lastScan = Date()
    private var dirty = false
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LEXALIE/nodes.json")

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Node].self, from: data) {
            let limit = Date().addingTimeInterval(-60 * 86_400)
            nodes = Dictionary(saved.compactMap { node -> (String, Node)? in
                var node = node
                node.sightings.removeAll { $0.at < limit }
                return node.sightings.isEmpty ? nil : (node.key, node)
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Every tick while a video or a call plays: the lines finished since the last look, through Apple's
    /// tagger on this Mac. Nothing leaves the Mac.
    func scan(_ turns: [Turn], since start: Date, context: String, source: String) {
        let fresh = turns.filter { !$0.isMine && start.addingTimeInterval($0.end) > lastScan }
        lastScan = Date()
        for turn in fresh {
            for (text, kind) in Self.extract(turn.text) {
                let key = Memory.key(text)
                guard key.count >= 2 else { continue }
                var node = nodes[key] ?? Node(key: key, text: text, kind: kind, sightings: [])
                if kind != "person", Self.explains(turn.text, term: text) {
                    node.explained = Explained(sentence: String(turn.text.prefix(300)), at: Date(), source: String(source.prefix(120)))
                    nodes[key] = node
                    dirty = true
                }
                // The same name twice in a minute is one sighting.
                if let last = node.sightings.last, last.source == source, Date().timeIntervalSince(last.at) < 60 { continue }
                node.sightings.append(Sighting(at: Date(), source: String(source.prefix(120)), context: context))
                nodes[key] = node
                dirty = true
            }
        }
        if dirty { save() }
    }

    /// Names, places and companies (Apple's tagger), and acronyms ("CMS", "EOD").
    static func extract(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            switch tag {
            case .personalName?: out.append((String(text[range]), "person"))
            case .placeName?: out.append((String(text[range]), "place"))
            case .organizationName?: out.append((String(text[range]), "org"))
            default: break
            }
            return true
        }
        let common: Set<String> = ["I", "OK", "TV", "US", "UK", "AM", "PM", "ID", "OH", "AI"]
        if let regex = try? NSRegularExpression(pattern: #"\b[A-Z]{2,5}s?\b"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(match.range, in: text) else { continue }
                let word = String(text[r])
                if !common.contains(word), !out.contains(where: { $0.0 == word }) { out.append((word, "acronym")) }
            }
        }
        return out
    }

    /// Someone says what the term is: "X stands for", "X, which means", "by X I mean", "what we call X",
    /// "X sta per", "X, cioè" (the languages of the app's calls, the most common forms).
    nonisolated static func explains(_ text: String, term: String) -> Bool {
        let t = NSRegularExpression.escapedPattern(for: term)
        let forms = [
            "\\b\(t)\\b,? (which |that )?(stands for|means|is short for|is what we call|refers to)\\b",
            "\\bby \(t) (I|we) mean\\b", "\\bwhat we call \(t)\\b", "\\b\(t),? (i\\.e\\.|that is|meaning)\\b",
            "\\b\(t),? (che )?(sta per|significa|vuol dire|cioè)\\b", "\\b\(t),? (c'est-à-dire|signifie|veut dire)\\b",
            "\\b\(t),? (o sea|significa|quiere decir)\\b", "\\b\(t),? (das heißt|bedeutet|steht für)\\b",
        ]
        return forms.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// The glossary on a card: a term in this sentence that someone explained earlier (not in the last
    /// two minutes: that's this very sentence), most recent first. Nil when nothing was explained.
    func explanation(in text: String) -> (term: String, explained: Explained)? {
        let key = Memory.key(text)
        let found = nodes.values.compactMap { node -> (String, Explained)? in
            guard node.kind != "person", node.key.count >= 2, let e = node.explained,
                  Date().timeIntervalSince(e.at) > 120, " \(key) ".contains(" \(node.key) ") else { return nil }
            return (node.text, e)
        }
        return found.max { $0.1.at < $1.1.at }.map { (term: $0.0, explained: $0.1) }
    }

    /// The line the card shows: "CMS · said on Tuesday in Weekly sync: “CMS, which stands for …”".
    func glossaryLine(for text: String) -> String? {
        guard let found = explanation(in: text) else { return nil }
        let term = found.term, e = found.explained
        let day = e.at.formatted(.dateTime.weekday(.wide))
        let place = e.source.isEmpty ? "" : " · \(e.source)"
        return "\(term) · \(day)\(place): “\(e.sentence)”"
    }

    /// You tapped on something with this name in it.
    func reacted(_ texts: [String]) {
        for text in texts {
            for (key, node) in nodes where node.key.count >= 3 && Memory.key(text).contains(key) {
                nodes[key]?.reacted = true
                dirty = true
            }
        }
        if dirty { save() }
    }

    struct Refrain {
        let node: Node
        let times: Int
        let sources: [String]
    }

    /// What keeps coming back this week from at least two places, and you don't seem to know: at most
    /// one, almost never (a wrong refrain is worse than silence). Colleagues' names never: you know them.
    func refrain(in context: String? = nil) -> Refrain? {
        let week = Date().addingTimeInterval(-7 * 86_400)
        let known = AppModel.shared.store.known
        let candidates = nodes.values.compactMap { node -> Refrain? in
            guard !Redactor.privateNames.contains(node.key), !known.contains(node.key),
                  node.shownAt.map({ Date().timeIntervalSince($0) > 3 * 86_400 }) ?? true else { return nil }
            let recent = node.sightings.filter { $0.at >= week && (context == nil || $0.context == context) }
            // A person's name only from videos: in calls it's a colleague.
            if node.kind == "person", recent.contains(where: { $0.context == "call" }) { return nil }
            let sources = Array(Set(recent.map(\.source)))
            guard recent.count >= 3, sources.count >= 2 else { return nil }
            return Refrain(node: node, times: recent.count, sources: sources)
        }
        // The one you reacted to wins, then the one heard most.
        return candidates.max { ($0.node.reacted ? 1 : 0, $0.times) < ($1.node.reacted ? 1 : 0, $1.times) }
    }

    /// Links between sources (RIC 4): a title you watched in the last month that this explanation
    /// names ("That's what she said" → The Office), with the day you watched it. Only an exact title.
    func watched(in text: String) -> (title: String, at: Date)? {
        let lower = text.lowercased()
        var seen: [String: Date] = [:]
        for moment in AppModel.shared.store.moments where moment.date > Date().addingTimeInterval(-30 * 86_400) {
            if let show = moment.show, show.count >= 4 { seen[show] = max(seen[show] ?? .distantPast, moment.date) }
        }
        for node in nodes.values {
            for s in node.sightings where s.context == "video" && s.source.count >= 4 { seen[s.source] = max(seen[s.source] ?? .distantPast, s.at) }
        }
        return seen.filter { lower.contains($0.key.lowercased()) }.max { $0.key.count < $1.key.count }.map { ($0.key, $0.value) }
    }

    func markShown(_ key: String) {
        nodes[key]?.shownAt = Date()
        dirty = true
        save()
    }

    /// Settings: forget every name and term LEXALIE noticed.
    func deleteAll() {
        nodes = [:]
        dirty = true
        save()
    }

    private func save() {
        dirty = false
        if let data = try? JSONEncoder().encode(Array(nodes.values)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
