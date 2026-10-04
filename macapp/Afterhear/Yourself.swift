import SwiftUI

/// The brain of yourself (docs/BRAIN.md § 6), built from your call reports on this Mac:
/// 1. your phrasebook: what you say at work, the natural way;
/// 2. the memory: what was decided and what you said as fact, one line each, never the call;
/// 3. the answer: when someone asks you, a line with the answer the way you'd say it.
@MainActor
enum Yourself {
    struct Phrase: Hashable { let phrase: String; let note: String }
    struct Fact: Hashable { let text: String; let decided: Bool; let title: String; let date: Date }

    static func phrases(limit: Int = 12) -> [Phrase] {
        var seen = Set<String>()
        var out: [Phrase] = []
        func add(_ p: String, _ note: String) {
            let k = p.lowercased().trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, seen.insert(k).inserted { out.append(Phrase(phrase: p, note: note)) }
        }
        for saved in Reports.shared.all {
            guard let r = saved.report else { continue }
            for g in r.good_phrases ?? [] { add(g.phrase, g.situation) }
            for c in r.corrections { add(c.better, "instead of “\(c.you_said)”") }
            for m in r.missing_phrases { add(m.phrase, m.situation) }
            for w in r.words_you_looked_for ?? [] { add(w.word, w.meaning) }
        }
        return Array(out.prefix(limit))
    }

    /// Facts and decisions, with these people first (or from every call when nobody is named).
    static func facts(with people: [String] = [], limit: Int = 12) -> [Fact] {
        let reports = Reports.shared.all
        let theirs = people.isEmpty ? reports : reports.filter { !Set($0.people).isDisjoint(with: people) }
        var out: [Fact] = []
        for saved in theirs + (people.isEmpty ? [] : reports.filter { Set($0.people).isDisjoint(with: people) }) {
            guard let r = saved.report else { continue }
            out += (r.decisions ?? []).map { Fact(text: $0, decided: true, title: saved.title, date: saved.start) }
            out += (r.facts_you_said ?? []).map { Fact(text: $0, decided: false, title: saved.title, date: saved.start) }
        }
        var seen = Set<String>()
        return Array(out.filter { seen.insert($0.text.lowercased()).inserted }.prefix(limit))
    }
}

/// Before a call: what you said and decided last time with them, and your phrases.
struct YourselfCard: View {
    let people: [String]

    init(people: [String]) {
        self.people = people
    }

    var body: some View {
        let facts = Yourself.facts(with: people, limit: 5)
        let phrases = Yourself.phrases(limit: 5)
        if !facts.isEmpty || !phrases.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !facts.isEmpty {
                    Text("Last time").font(.caption).foregroundStyle(.secondary)
                    ForEach(facts, id: \.self) { f in
                        HStack(alignment: .firstTextBaseline) {
                            Text(f.text).font(.system(size: 13, weight: .semibold))
                            Text(f.decided ? "decided" : "you said").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !phrases.isEmpty {
                    Text("Your phrases").font(.caption).foregroundStyle(.secondary)
                    ForEach(phrases, id: \.self) { p in
                        HStack(alignment: .firstTextBaseline) {
                            Text(p.phrase).font(.system(size: 13, weight: .semibold))
                            Text(p.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
