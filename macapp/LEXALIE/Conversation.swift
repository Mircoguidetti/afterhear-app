import Foundation

/// One stretch of speech by the same side: "loro" (the Mac's sound) or "tu" (your microphone).
struct Turn: Codable, Hashable {
    var who: String
    /// Seconds from the start of the moment's clip.
    var start: Double
    var end: Double
    var text: String

    var isMine: Bool { who == "tu" }
}

/// Builds the last minutes of conversation and guesses which piece you missed.
/// The tap usually comes late: a few seconds after a video, a minute after
/// answering the CEO, after you've replied to the waiter. So we look at the
/// whole conversation, not just the last seconds.
enum Conversation {
    /// Silence longer than this starts a new turn.
    static let gap: TimeInterval = 1.2

    static func turns(others: [TimedWord], mine: [TimedWord], clipStart: Date) -> [Turn] {
        let theirs = group(others, who: "loro", clipStart: clipStart)
        // With speakers on, the microphone also hears the others: drop "tu" turns
        // that mostly repeat what the Mac played at the same time.
        let ours = group(mine, who: "tu", clipStart: clipStart).filter { turn in
            let words = Set(normalized(turn.text))
            guard !words.isEmpty else { return false }
            let overlapping = theirs.filter { $0.start < turn.end + 2 && $0.end > turn.start - 2 }
            let heard = Set(overlapping.flatMap { normalized($0.text) })
            return Double(words.intersection(heard).count) / Double(words.count) < 0.5
        }
        return (joinTails(theirs) + ours).sorted { $0.start < $1.start }
    }

    /// A sentence cut in two by a breath or by its length keeps its two halves together, so the tap
    /// offers the whole sentence and not its tail (comprehension bench, 08/10: "households.", "typical
    /// early in the life of an engine activity", "And then I can add to it" were offered in place of
    /// the sentence with the name or the word in it, 11 cards in 160).
    static func joinTails(_ turns: [Turn]) -> [Turn] {
        var out: [Turn] = []
        for turn in turns {
            if var last = out.last, isTail(turn, of: last) {
                last.end = max(last.end, turn.end)
                last.text += " " + turn.text
                out[out.count - 1] = last
            } else {
                out.append(turn)
            }
        }
        return out
    }

    /// This piece carries on the one before, a moment later. When the one before stopped mid-sentence
    /// (no full stop): it starts in lower case, the one before ended on a comma or a joining word, or it's
    /// a few words. When the recogniser put a full stop in the middle ("…compared to theirs? And | the tire
    /// category overall"): it is short and starts in lower case or with a joining word. Tried on the 373
    /// taps of the bench (08/10): sentence first 176 → 183 of 204, the name in it 24 → 28 of 38.
    private static func isTail(_ turn: Turn, of last: Turn) -> Bool {
        guard turn.who == last.who, turn.start - last.end < tailGap else { return false }
        let words = turn.text.split(separator: " ").count
        guard last.text.split(separator: " ").count + words <= joinedWords else { return false }
        let first = turn.text.trimmingCharacters(in: .whitespaces).first
        let firstWord = (turn.text.lowercased().split(separator: " ").first.map(String.init) ?? "")
            .trimmingCharacters(in: .punctuationCharacters)
        let lastWord = (last.text.lowercased().split(separator: " ").last.map(String.init) ?? "")
            .trimmingCharacters(in: .punctuationCharacters)
        if endsSentence(last.text) {
            return words <= 20 && (first?.isLowercase == true || joining.contains(firstWord))
        }
        return first?.isLowercase == true || last.text.hasSuffix(",") || joining.contains(lastWord) || words <= 8
    }

    /// Seconds: a longer pause than the grouping one still belongs to the same sentence when it carries on.
    static let tailGap: TimeInterval = 2.5
    /// At most this many words in a sentence put back together.
    static let joinedWords = 48
    private static let joining: Set<String> = ["and", "but", "or", "so", "because", "that", "which", "who", "the", "a",
                                               "of", "to", "with", "for", "in", "on", "uh", "um"]

    /// The index of the most likely missed turn (always one of theirs), or nil.
    /// - tapAt: seconds from clip start when you tapped.
    /// - usualDelay: your learned delay between the missed words and the tap, if known.
    /// - freshWithin: when set, only pieces that ended at most this many seconds before the tap.
    static func guess(_ turns: [Turn], tapAt: Double, usualDelay: Double?, freshWithin: Double? = nil,
                      hardness: ((String) -> Double)? = nil) -> Int? {
        rank(turns, tapAt: tapAt, usualDelay: usualDelay, freshWithin: freshWithin, hardness: hardness).first?.index
    }

    /// Every turn of theirs, best guess first, with the signs that point to it (Ranking).
    static func rank(_ turns: [Turn], tapAt: Double, usualDelay: Double?, freshWithin: Double? = nil,
                     hardness: ((String) -> Double)? = nil) -> [Ranking.Scored] {
        let lines = turns.map { Ranking.Line(start: $0.start, end: $0.end, text: $0.text, mine: $0.isMine) }
        return Ranking.rank(lines, tapAt: tapAt, usualDelay: usualDelay, freshWithin: freshWithin, hardness: hardness)
    }

    /// What a tap offers (owner, 05/10): first, always what was just said, the last sentence of the
    /// others before the tap (a "yeah" or a laugh doesn't count; your own words never do: if you
    /// answered, it's what they said before your answer). Then, one touch away, the sentences around
    /// the moment you usually miss things in this situation (usualDelay, learned per context), and
    /// further back in order.
    static func offer(_ turns: [Turn], tapAt: Double, usualDelay: Double?, freshWithin: Double? = nil,
                      hardness: ((String) -> Double)? = nil) -> [Ranking.Scored] {
        let theirs = turns.indices.filter { !turns[$0].isMine && turns[$0].start < tapAt }
        guard !theirs.isEmpty else { return [] }
        let filler: (Int) -> Bool = { Ranking.isYeah(turns[$0].text) || Ranking.isLaugh(turns[$0].text) }
        let latest = theirs.last(where: { !filler($0) }) ?? theirs.last!
        var out: [Ranking.Scored] = []
        // A piece that began less than a second before the tap is the answer starting, not what you
        // missed: the sentence just before it comes first (comprehension bench P1, 06/10: "I think",
        // "Sure, John" were shown instead of the question 3 times in 4). The piece keeps its place in
        // the ranking, so the sentences around your usual delay stay one touch away (tap bench).
        if tapAt - turns[latest].start < justStarted,
           let before = theirs.last(where: { $0 < latest && !filler($0) }),
           turns[latest].start - turns[before].end < 2.5 {
            out.append(Ranking.Scored(index: before, score: 1, reasons: ["latest", "before the answer"]))
        } else {
            out.append(Ranking.Scored(index: latest, score: 1, reasons: ["latest"]))
        }
        var rest = rank(turns, tapAt: tapAt, usualDelay: usualDelay, freshWithin: freshWithin, hardness: hardness)
        if rest.isEmpty { rest = rank(turns, tapAt: tapAt, usualDelay: usualDelay, hardness: hardness) }
        let shown = Set(out.map(\.index))
        out += rest.filter { !shown.contains($0.index) && !filler($0.index) }
        // Anything the ranking left out, most recent first, so going back never runs dry.
        let seen = Set(out.map(\.index))
        out += theirs.reversed().filter { !seen.contains($0) }.map { Ranking.Scored(index: $0, score: 0, reasons: ["earlier"]) }
        return out
    }

    /// Seconds: a piece of theirs that began this close to the tap is someone starting to answer.
    static let justStarted: Double = 1.0

    /// A turn longer than this is cut at the next small pause: one sentence on screen, not a speech.
    static let longTurnWords = 28

    private static func group(_ words: [TimedWord], who: String, clipStart: Date) -> [Turn] {
        var turns: [Turn] = []
        for word in words {
            let start = word.start.timeIntervalSince(clipStart)
            let end = word.end.timeIntervalSince(clipStart)
            // A new piece starts after a pause, after the end of a sentence, or when it gets too long.
            let sentenceEnded = turns.last.map { endsSentence($0.text) } ?? false
            let tooLong = turns.last.map { $0.text.split(separator: " ").count >= longTurnWords && start - $0.end > 0.25 } ?? false
            let wayTooLong = turns.last.map { $0.text.split(separator: " ").count >= longTurnWords * 3 / 2 } ?? false
            if var last = turns.last, start - last.end < gap, !sentenceEnded, !tooLong, !wayTooLong {
                last.end = max(last.end, end)
                last.text += " " + word.text
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(who: who, start: max(0, start), end: end, text: word.text))
            }
        }
        return turns
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!…。？！".contains(last)
    }

    /// Splits free text (from a fresh transcription) into sentences.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            current += (current.isEmpty ? "" : " ") + word
            if endsSentence(current) || current.split(separator: " ").count >= longTurnWords {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func normalized(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 2 }
    }
}
