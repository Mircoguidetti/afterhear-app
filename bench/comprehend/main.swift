import Foundation

// The comprehension bench (bench/comprehend.py): what a real recogniser heard before a tap goes
// through the same Conversation.swift, Ranking.swift and Redactor.swift as the Mac app, and comes
// out as the sentences it would offer, each with the lines around it as AppModel.captureMoment
// sends them to /api/explain (names and numbers already removed).
//
//   swiftc -O macapp/LEXALIE/Ranking.swift macapp/LEXALIE/Conversation.swift macapp/LEXALIE/Redactor.swift \
//       bench/comprehend/main.swift -o comprehend
//   ./comprehend taps.json   (one JSON line per tap)

/// As in LiveTranscriber.swift, which can't come here (it needs FluidAudio).
struct TimedWord {
    let start: Date
    let end: Date
    let text: String
}

struct Tap: Decodable {
    let id: String
    /// [start, end, text], seconds from the clip's start.
    let words: [[String]]
    let tapAt: Double
}

struct Offered: Encodable {
    let start: Double
    let end: Double
    let text: String
    /// What leaves the Mac: Redactor.redact of the sentence and of the lines around it.
    let sent: String
    let before: [String]
    let after: [String]
}

struct Out: Encodable {
    let id: String
    let offered: [Offered]
}

let path = CommandLine.arguments.dropFirst().first ?? "taps.json"
let taps = try JSONDecoder().decode([Tap].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let clipStart = Date(timeIntervalSince1970: 1_000_000)
let encoder = JSONEncoder()
for tap in taps {
    let words = tap.words.compactMap { w -> TimedWord? in
        guard w.count == 3, let s = Double(w[0]), let e = Double(w[1]) else { return nil }
        return TimedWord(start: clipStart.addingTimeInterval(s), end: clipStart.addingTimeInterval(e), text: w[2])
    }
    let turns = Conversation.turns(others: words, mine: [], clipStart: clipStart)
    // As AppModel.captureMoment in a call, for a new user (no usual delay, no hardness learned yet).
    let ranked = Conversation.offer(turns, tapAt: tap.tapAt, usualDelay: nil, freshWithin: nil)
    let offered = ranked.prefix(3).map { r -> Offered in
        let i = r.index, t = turns[i]
        // As ExplainClient: the last 3 lines before, the next 2, each cut to 300 characters.
        let before = turns[max(0, i - 3)..<i].map { String(Redactor.redact($0.text).prefix(300)) }
        let after = turns[(i + 1)..<min(turns.count, i + 3)].map { String(Redactor.redact($0.text).prefix(300)) }
        return Offered(start: t.start, end: t.end, text: t.text, sent: Redactor.redact(t.text), before: before, after: after)
    }
    print(String(data: try encoder.encode(Out(id: tap.id, offered: Array(offered))), encoding: .utf8)!)
}
