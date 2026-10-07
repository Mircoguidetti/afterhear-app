import SwiftUI

/// What goes on top of the card (owner and Claude Chat, 07/10). One sentence can have more than one
/// problem, so the card doesn't pick one type: it puts the most important on top, the second under it,
/// the rest in "Also". The order is fixed: it was for you (someone waits for an answer), you didn't
/// hear it (a word you didn't hear you can't understand), a word or an idiom, who or what it is, the
/// tone. When the Mac and the explanation don't agree, or nothing is sure, the plain card: it already
/// has everything, in the standard order. A card with the wrong shape is worse than a plain one.
enum CardShape: Equatable {
    case forYou, heard, word, who, tone, plain

    static let hearing: Set<String> = ["connected_speech", "speed_accent", "known_not_recognized", "overlapping_voices"]

    /// The shapes that passed their bar in the comprehension test (P6, 07/10): heard 94, word 89, meant
    /// 70. "It was for you" (62 of 70) and "who or what" (37 of 70) wait for the next measure; until
    /// then their card is the plain one. A wrong shape is worse than none.
    static var passed: Set<CardShape> = [.heard, .word, .tone]

    static func of(_ m: Moment) -> CardShape {
        let shape = raw(m)
        return passed.contains(shape) ? shape : .plain
    }

    /// The shape before the bar: what the explanation and the Mac say.
    static func raw(_ m: Moment) -> CardShape {
        if let f = m.forYou?.trimmingCharacters(in: .whitespaces), !f.isEmpty { return .forYou }
        guard let first = m.pieces.first, first.guess != true else { return .plain }
        let tone = !(m.toneLabel ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if hearing.contains(first.cause) {
            // Only when the Mac agrees: a rewind, voices on top of each other, fast speech, or how it sounds.
            let fast = (m.signals?.syllablesPerSecond ?? 0) >= 5.5
            let agreed = m.trigger == "rewind" || m.signals?.overlap == true || fast || !(m.soundsLike ?? "").isEmpty
            return agreed ? .heard : .plain
        }
        switch first.cause {
        case "unknown_word", "idiom", "numbers": return .word
        case "cultural": return .who
        case "subtext": return tone ? .tone : .plain
        default: return tone && m.meant?.shown == true ? .tone : .plain
        }
    }

    /// The label on top, in your language; none on the plain card.
    func label(_ m: Moment) -> String? {
        switch self {
        case .forYou: return String(localized: "It was for you")
        case .heard: return String(localized: "You didn't catch it")
        case .word:
            switch m.pieces.first?.cause {
            case "idiom": return String(localized: "Idiom")
            case "numbers": return String(localized: "Numbers")
            default: return String(localized: "New word")
            }
        case .who: return String(localized: "Who or what it is")
        case .tone: return m.toneLabel?.trimmingCharacters(in: .whitespaces)
        case .plain: return nil
        }
    }
}

/// The card gets shorter for the kinds of gap you now handle (idea 8, 07/10): after five "I knew it"
/// and hardly any "Also" opened for one cause, only "In practice" stays. "Now this is enough" shows once.
enum ShortCards {
    private static func key(_ cause: String) -> String { "shortCard.\(cause)" }

    static func knew(_ cause: String) { bump(cause, knew: 1, opened: 0) }
    static func opened(_ cause: String) { bump(cause, knew: 0, opened: 1) }

    static func isShort(_ cause: String?) -> Bool {
        guard let cause else { return false }
        let v = UserDefaults.standard.array(forKey: key(cause)) as? [Int] ?? [0, 0]
        return v[0] >= 5 && Double(v[0]) / Double(max(v[0] + v[1], 1)) >= 0.8
    }

    /// "Now this is enough", once per cause.
    static func announce(_ cause: String) -> Bool {
        let k = key(cause) + ".said"
        guard !UserDefaults.standard.bool(forKey: k) else { return false }
        UserDefaults.standard.set(true, forKey: k)
        return true
    }

    private static func bump(_ cause: String, knew: Int, opened: Int) {
        var v = UserDefaults.standard.array(forKey: key(cause)) as? [Int] ?? [0, 0]
        v[0] += knew
        v[1] += opened
        UserDefaults.standard.set(v, forKey: key(cause))
    }
}

/// "Why?" on a card: one step further, once, with ready questions; never a chat (07/10). Each one is a
/// call to our server, counted apart.
struct WhyRow: View {
    let moment: Moment
    let shape: CardShape
    @State private var asked = false
    @State private var choosing = false
    @State private var answer: String?

    private struct Reply: Decodable { let answer: String }

    private var questions: [(id: String, label: String)] {
        var q: [(String, String)] = []
        if shape == .tone || moment.pieces.first?.cause == "subtext" || moment.tone?.contains("laugh") == true {
            q.append(("funny", String(localized: "Why is it funny?")))
        }
        if moment.pieces.first?.cause == "idiom" { q.append(("why", String(localized: "Why do they say it?"))) }
        q.append(("common", String(localized: "Is it said often?")))
        return Array(q.prefix(2))
    }

    var body: some View {
        if let answer {
            Text(answer).font(.system(size: 13)).foregroundStyle(Brand.paper.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        } else if choosing {
            HStack(spacing: 12) {
                ForEach(questions, id: \.id) { q in
                    Button(q.label) { Task { await ask(q.id) } }.buttonStyle(.plain).foregroundStyle(Brand.line)
                }
            }
            .font(.system(size: 12, weight: .medium))
        } else if !asked {
            Button("Why?") { choosing = true }.buttonStyle(.plain).foregroundStyle(Brand.line).font(.system(size: 12.5, weight: .medium))
        }
    }

    private func ask(_ id: String) async {
        asked = true
        choosing = false
        let count = UserDefaults.standard.integer(forKey: "whyAsked")
        UserDefaults.standard.set(count + 1, forKey: "whyAsked")
        let reply: Reply? = try? await CoachClient.post("api/why", [
            "text": String(moment.sent.prefix(600)), "piece": moment.pieces.first?.text ?? "", "question": id,
        ])
        answer = reply?.answer ?? String(localized: "Couldn't explain it now.")
    }
}
