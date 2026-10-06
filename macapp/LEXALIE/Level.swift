import Foundation

/// How well you understand, never asked (owner, 06/10 night): an estimate the explanation uses to
/// pick what to explain. It starts at B2 (who follows calls in another language is usually there) and
/// moves only with what you do inside a card: a word you open, or another piece you pick, says "this
/// was hard"; "I knew it" says the opposite and weighs more, because being treated as a beginner is
/// the mistake that annoys the most. The sentence you tapped never moves it: not hearing a fast
/// sentence is your ear (EarProfile), not how much of the language you know.
enum LevelEstimate {
    static let scale = ["A2", "B1", "B2", "C1", "C2"]
    private static let scoreKey = "levelScore", countKey = "levelSignals", streakKey = "levelKnewStreak"

    /// 0 = A2 … 4 = C2.
    static var score: Double {
        let d = UserDefaults.standard
        // An answer given before the question went away is a better start than B2.
        guard d.object(forKey: scoreKey) != nil else { return Double(scale.firstIndex(of: d.string(forKey: Key.level) ?? "") ?? 2) }
        return d.double(forKey: scoreKey)
    }

    static var signals: Int { UserDefaults.standard.integer(forKey: countKey) }

    /// The estimate as the explanation reads it ("B2").
    static var current: String { scale[min(max(Int(score.rounded()), 0), scale.count - 1)] }

    /// How far to trust it, for the explanation: guessed at first, then from your cards.
    static var reliability: String { signals < 10 ? "guessed" : signals < 40 ? "some" : "solid" }

    /// "I knew it" on a card's piece.
    static func knew(_ piece: Piece) {
        let d = UserDefaults.standard
        let streak = d.integer(forKey: streakKey) + 1
        // Knowing something at or above the estimate says more than knowing something easy.
        var step = level(of: piece) >= score ? 0.25 : 0.1
        // Three in a row: the estimate was too low, fix it at once.
        if streak >= 3 { step += 0.5 }
        d.set(streak >= 3 ? 0 : streak, forKey: streakKey)
        move(by: step)
    }

    /// A piece you opened, or picked instead of the one shown: it was hard for you.
    static func hard(_ piece: Piece) {
        UserDefaults.standard.set(0, forKey: streakKey)
        // Only a word you didn't know, at or below the estimate, says it's too high. Idioms and
        // references are hard for most people; the rest (speed, connected speech, voices) is the ear.
        guard piece.cause == "unknown_word", level(of: piece) <= score else { return }
        move(by: -0.1)
    }

    private static func level(of piece: Piece) -> Double {
        Double(scale.firstIndex(of: piece.level ?? "") ?? Int(score.rounded()))
    }

    private static func move(by delta: Double) {
        let d = UserDefaults.standard
        d.set(min(max(score + delta, 0), Double(scale.count - 1)), forKey: scoreKey)
        d.set(signals + 1, forKey: countKey)
    }
}
