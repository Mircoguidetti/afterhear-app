import Foundation

/// Which sentence did you miss? (docs/BRAIN.md § 19.3, layer 4 "Trovare il pezzo").
///
/// The tap comes late, so the last sentence is often the wrong one. Every sentence before
/// the tap gets a score from the signs a missed line leaves behind:
/// - close to "tap minus your usual delay";
/// - a question to you, then a silence;
/// - you answered with "yeah, yeah", a laugh, or changed the subject;
/// - you answered something right before tapping (you answered while guessing);
/// - it has expressions you're still learning, or none you know well;
/// - what your model says about it, when it looked (the likelihood from /api/spot).
///
/// Foundation only: the Mac, the iPhone and the test bench (bench/) use the same file.
enum Ranking {
    struct Line {
        var start: Double
        var end: Double
        var text: String
        var mine: Bool
    }

    struct Scored {
        var index: Int
        var score: Double
        /// Why, for the bench and for debugging ("near", "question", "pause", "yeah", …).
        var reasons: [String]
    }

    struct Weights {
        var near = 0.35
        var question = 0.1
        var pause = 0.15
        var yeah = 0.25
        var laugh = 0.1
        var topicChange = 0.15
        var answered = 0.2
        var hard = 0.2
        var model = 0.4
    }

    /// Their sentences said before the tap, best first, the one still going on at the tap included.
    /// What counts is when you missed it (the tap minus your reaction time), not the tap itself:
    /// tapping 1–3 s into the next sentence still means the one before (owner, 03/10); tapping well
    /// into a long sentence means that one.
    /// - tapAt: seconds of the tap on the same clock as the lines.
    /// - usualDelay: your learned delay between the missed words and the tap.
    /// - freshWithin: only lines that ended at most this many seconds before the tap.
    /// - hardness: 0…1 for a sentence (expressions you're learning up, the ones you know well down).
    /// - likelihood: your model's guess for a sentence, if it looked.
    static func rank(_ lines: [Line], tapAt: Double, usualDelay: Double? = nil, freshWithin: Double? = nil,
                     hardness: ((String) -> Double)? = nil, likelihood: ((Int) -> Double?)? = nil,
                     weights w: Weights = Weights()) -> [Scored] {
        let theirs = lines.indices.filter {
            !lines[$0].mine && lines[$0].start < tapAt && lines[$0].end >= tapAt - (freshWithin ?? .infinity)
        }
        guard !theirs.isEmpty else { return [] }
        let delay = usualDelay ?? 2.5
        let target = tapAt - delay
        // The farther back the tap usually comes, the wider "close" is.
        // Your learned delay is a good guess: closeness weighs most, with a margin that grows a
        // little with it (a tap two minutes late is a few seconds less precise). No learned delay
        // yet: closeness is only a hint.
        let scale = usualDelay == nil ? 6 : max(3, delay * 0.25)
        let lastMine = lines.indices.last { lines[$0].mine && lines[$0].end <= tapAt + 0.5 }
        let answered = lastMine.flatMap { m in theirs.last { $0 < m } }

        var out: [Scored] = []
        for i in theirs {
            let line = lines[i]
            var score = 0.0
            var why: [String] = []
            // How far the moment you missed it is from this sentence: zero inside it. Nobody misses a
            // sentence in its first second (there isn't enough of it yet), so it counts from there.
            let from = line.start + min(1.0, (line.end - line.start) / 2)
            let off = target < from ? from - target : max(0, target - line.end)
            let near = exp(-off / scale)
            // With your delay learned, timing leads and the reactions only break near-ties;
            // without it, timing is one hint among the others.
            score += (usualDelay == nil ? w.near : 2.0) * near
            if near > 0.5 { why.append("near") }

            let question = isQuestion(line.text)
            if question { score += w.question; why.append("question") }
            let next = lines.indices.first { $0 > i }
            let silence = next.map { lines[$0].start - line.end } ?? (tapAt - line.end)
            if silence >= 3 {
                score += w.pause * (question ? 1.5 : 1)
                why.append("pause")
            }
            // Your first words after it, within a few seconds.
            if let reply = lines.indices.first(where: { $0 > i && lines[$0].mine }), lines[reply].start - line.end < 8 {
                let text = lines[reply].text
                if isYeah(text) { score += w.yeah; why.append("yeah") }
                if isLaugh(text) { score += w.laugh; why.append("laugh") }
                if question, !isYeah(text), !isLaugh(text), shared(line.text, text) == 0, words(text).count >= 3 {
                    score += w.topicChange
                    why.append("topic")
                }
            }
            if i == answered { score += w.answered; why.append("answered") }
            if let h = hardness?(line.text) {
                score += w.hard * min(max(h, 0), 1)
                if h > 0.5 { why.append("hard") }
            }
            if let l = likelihood?(i) {
                score += w.model * min(max(l, 0), 1)
                if l >= 0.55 { why.append("model") }
            }
            out.append(Scored(index: i, score: score, reasons: why))
        }
        return out.sorted { $0.score > $1.score || ($0.score == $1.score && $0.index > $1.index) }
    }

    static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix("?") { return true }
        let first = t.split(separator: " ").first.map(String.init) ?? ""
        return ["what", "why", "how", "when", "where", "who", "do", "does", "did", "can", "could",
                "would", "will", "are", "is", "have", "has", "shall", "should", "fancy"].contains(first)
            && t.split(separator: " ").count <= 20
    }

    /// "Yeah, yeah", "right, right", "sure", "mhm": short agreement that often hides a guess.
    static func isYeah(_ text: String) -> Bool {
        let w = words(text)
        guard !w.isEmpty, w.count <= 4 else { return false }
        let fillers: Set<String> = ["yeah", "yes", "yep", "right", "sure", "ok", "okay", "mhm", "mm", "uh", "huh",
                                    "totally", "exactly", "absolutely", "definitely", "cool", "nice", "great", "true"]
        return w.allSatisfy { fillers.contains($0) }
    }

    static func isLaugh(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("haha") || t.contains("ha ha") || t.contains("hehe") || t.contains("laugh") || t.contains("lol")
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
    }

    private static let stop: Set<String> = ["the", "and", "you", "that", "this", "what", "for", "are", "was", "but",
                                            "with", "have", "not", "they", "your", "just", "about", "there", "it's", "i'm"]

    private static func shared(_ a: String, _ b: String) -> Int {
        let x = Set(words(a).filter { $0.count > 2 && !stop.contains($0) })
        let y = Set(words(b).filter { $0.count > 2 && !stop.contains($0) })
        return x.intersection(y).count
    }
}
