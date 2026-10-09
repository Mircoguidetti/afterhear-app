import Foundation
import NaturalLanguage

/// What leaves the Mac. The AI needs to explain "heads-up", not to know who Tom is.
/// - In a call (or anywhere we can't tell): people's names become [nome], numbers [numero], emails
///   [email]. Your own first name becomes [tu], so the card can say "it was for you" without your name
///   ever leaving the Mac (P3). Companies, products and places stay, so "who / what is it" can be
///   answered, unless they are among your own names (P4, privacy road A, owner 06/10).
/// - In a video, a podcast, a series or a song everything said is public already: only emails go.
enum Redactor {
    /// Your first name (Settings → "Your first name"), set by the app.
    static var me = ""
    /// Names that are yours only, set by the app: the people you talk with, your words (Settings), the
    /// guests of your calls. They never leave the Mac, even when they look like a company or a place.
    static var privateNames: Set<String> = []

    /// `keepNumbers`: a deal call (owner, 09/10): the figures are the point, and they are the company's,
    /// not anyone's private data; people's names still go.
    static func redact(_ text: String, publicMedia: Bool = false, keepNumbers: Bool = false) -> String {
        var out = text
        if publicMedia {
            return out.replacingOccurrences(of: #"[\w.+-]+@[\w-]+\.[\w.]+"#, with: "[email]", options: .regularExpression)
        }
        let myName = me.trimmingCharacters(in: .whitespaces)
        if myName.count >= 2 {
            out = out.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: myName))\\b", with: "[tu]",
                                           options: [.regularExpression, .caseInsensitive])
            // The recogniser spells your name one letter off ("Marcus" for Markus, "Rayner" for Rainer):
            // a capitalised word that close to a name of 5 letters or more is still you (bench 08/10).
            if myName.count >= 5 {
                let mine = myName.lowercased()
                let close = out.split(separator: " ").map(String.init).filter { token in
                    let word = token.trimmingCharacters(in: .punctuationCharacters)
                    return word.first?.isUppercase == true && word.lowercased() != mine && oneOff(word.lowercased(), mine)
                }
                for word in Set(close.map { $0.trimmingCharacters(in: .punctuationCharacters) }) {
                    out = out.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", with: "[tu]",
                                                   options: .regularExpression)
                }
            }
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = out
        var found: [(Range<String.Index>, String)] = []
        tagger.enumerateTags(in: out.startIndex..<out.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            let name = String(out[range])
            switch tag {
            case .personalName?: if name != "tu" { found.append((range, "[nome]")) }
            case .placeName?: if isPrivate(name) { found.append((range, "[luogo]")) }
            case .organizationName?: if isPrivate(name) { found.append((range, "[azienda]")) }
            default: break
            }
            return true
        }
        for (range, placeholder) in found.reversed() {
            out.replaceSubrange(range, with: placeholder)
        }
        out = out.replacingOccurrences(of: #"[\w.+-]+@[\w-]+\.[\w.]+"#, with: "[email]", options: .regularExpression)
        // A model or a code glued to letters ("A320", "LEAP-1A", "K3") or followed by one in capitals
        // ("737 MAX") is a product, not a private number: it stays, so "who or what" can say which.
        if keepNumbers { return out }
        out = out.replacingOccurrences(of: #"(?<![\p{L}\d-])\+?\d[\d \-.,]{1,}\d(?![\d\p{L}-]|\s+\p{Lu}{2,}\b)"#,
                                       with: "[numero]", options: .regularExpression)
        return out
    }

    /// One letter changed, added or missing, and the same first letter.
    static func oneOff(_ first: String, _ second: String) -> Bool {
        let a = Array(first), b = Array(second)
        guard a.first == b.first, abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if a.count < b.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    /// One of your own names, whole or as one of its words ("Phoenix" in "Project Phoenix").
    private static func isPrivate(_ name: String) -> Bool {
        let lower = name.lowercased()
        if privateNames.contains(lower) { return true }
        return lower.split(separator: " ").contains { privateNames.contains(String($0)) }
    }
}
