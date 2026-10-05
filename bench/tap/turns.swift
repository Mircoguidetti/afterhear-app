import Foundation

// The tap bench (bench/tap.py): the words a real recogniser heard in a clip go through the same
// Conversation.swift and Ranking.swift as the Mac app, and come out as the sentences it would offer.
//
//   swiftc -O macapp/Afterhear/Ranking.swift macapp/Afterhear/Conversation.swift bench/tap/turns.swift -o turns
//   ./turns cases.json   (one JSON line per case)

/// As in LiveTranscriber.swift, which can't come here (it needs FluidAudio).
struct TimedWord {
    let start: Date
    let end: Date
    let text: String
}

struct Case: Decodable {
    let id: String
    /// [start, end, text], seconds from the clip's start.
    let words: [[String]]
    let tapAt: Double
    let fresh: Double?
    let delay: Double?
}

struct Offered: Encodable {
    let start: Double
    let end: Double
    let text: String
}

struct Out: Encodable {
    let id: String
    let turns: Int
    let top: [Offered]
    let micros: Int
}

let path = CommandLine.arguments.dropFirst().first ?? "cases.json"
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let clipStart = Date(timeIntervalSince1970: 1_000_000)
let encoder = JSONEncoder()
for c in cases {
    let words = c.words.compactMap { w -> TimedWord? in
        guard w.count == 3, let s = Double(w[0]), let e = Double(w[1]) else { return nil }
        return TimedWord(start: clipStart.addingTimeInterval(s), end: clipStart.addingTimeInterval(e), text: w[2])
    }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let turns = Conversation.turns(others: words, mine: [], clipStart: clipStart)
    // As AppModel.captureMoment: the fresh ones first; nothing that recent, the whole clip.
    var ranked = Conversation.rank(turns, tapAt: c.tapAt, usualDelay: c.delay, freshWithin: c.fresh)
    if ranked.isEmpty { ranked = Conversation.rank(turns, tapAt: c.tapAt, usualDelay: c.delay) }
    let micros = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1000)
    let top = ranked.prefix(3).map { Offered(start: turns[$0.index].start, end: turns[$0.index].end, text: turns[$0.index].text) }
    print(String(data: try encoder.encode(Out(id: c.id, turns: turns.count, top: top, micros: micros)), encoding: .utf8)!)
}
