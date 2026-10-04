import Foundation

// The test bench's view of the brain (docs/BRAIN.md § 19.18): it reads conversations with
// a known missed sentence and simulated taps, ranks with the same Ranking.swift as the apps,
// and prints one JSON line per tap. bench/run.py turns them into the metrics.
//
//   swiftc -O macapp/Afterhear/Ranking.swift bench/main.swift -o rank && ./rank cases.json

struct Case: Decodable {
    struct L: Decodable { let start: Double; let end: Double; let text: String; let mine: Bool? }
    struct Tap: Decodable { let at: Double; let delay: Double?; let label: String? }
    let name: String
    let lines: [L]
    /// Index of the sentence that was really missed.
    let truth: Int
    let taps: [Tap]
    /// Expressions the listener is learning (hardness 1) and knows well (0.15).
    let learning: [String]?
    let known: [String]?
}

struct Out: Encodable {
    let name: String
    let tap: String
    let truth: Int
    let rank: Int?
    let top: [Int]
    let reasons: [String]
    let micros: Int
}

func key(_ s: String) -> String { Ranking.words(s).joined(separator: " ") }

let path = CommandLine.arguments.dropFirst().first ?? "bench/cases.json"
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let encoder = JSONEncoder()
for c in cases {
    let lines = c.lines.map { Ranking.Line(start: $0.start, end: $0.end, text: $0.text, mine: $0.mine ?? false) }
    let learning = (c.learning ?? []).map(key)
    let known = (c.known ?? []).map(key)
    let hardness: ((String) -> Double)? = c.learning == nil && c.known == nil ? nil : { text in
        let k = " " + key(text) + " "
        if learning.contains(where: { k.contains(" " + $0 + " ") }) { return 1 }
        if known.contains(where: { k.contains(" " + $0 + " ") }) { return 0.15 }
        return 0.4
    }
    for tap in c.taps {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let ranked = Ranking.rank(lines, tapAt: tap.at, usualDelay: tap.delay, hardness: hardness)
        let micros = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1000)
        let position = ranked.firstIndex { $0.index == c.truth }.map { $0 + 1 }
        let out = Out(name: c.name, tap: tap.label ?? String(format: "%.0fs", tap.at), truth: c.truth, rank: position,
                      top: ranked.prefix(3).map(\.index), reasons: ranked.first?.reasons ?? [], micros: micros)
        print(String(data: try encoder.encode(out), encoding: .utf8)!)
    }
}
