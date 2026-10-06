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

    static func redact(_ text: String, publicMedia: Bool = false) -> String {
        var out = text
        if publicMedia {
            return out.replacingOccurrences(of: #"[\w.+-]+@[\w-]+\.[\w.]+"#, with: "[email]", options: .regularExpression)
        }
        let myName = me.trimmingCharacters(in: .whitespaces)
        if myName.count >= 2 {
            out = out.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: myName))\\b", with: "[tu]",
                                           options: [.regularExpression, .caseInsensitive])
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
        out = out.replacingOccurrences(of: #"\+?\d[\d \-.,]{1,}\d"#, with: "[numero]", options: .regularExpression)
        return out
    }

    /// One of your own names, whole or as one of its words ("Phoenix" in "Project Phoenix").
    private static func isPrivate(_ name: String) -> Bool {
        let lower = name.lowercased()
        if privateNames.contains(lower) { return true }
        return lower.split(separator: " ").contains { privateNames.contains(String($0)) }
    }
}
