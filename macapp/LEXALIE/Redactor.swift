import Foundation
import NaturalLanguage

/// Removes names, places, companies, emails and numbers before anything leaves
/// the Mac. The AI needs to explain "heads-up", not to know who Tom is.
enum Redactor {
    static func redact(_ text: String) -> String {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: [(Range<String.Index>, String)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            switch tag {
            case .personalName?: found.append((range, "[nome]"))
            case .placeName?: found.append((range, "[luogo]"))
            case .organizationName?: found.append((range, "[azienda]"))
            default: break
            }
            return true
        }
        var out = text
        for (range, placeholder) in found.reversed() {
            out.replaceSubrange(range, with: placeholder)
        }
        out = out.replacingOccurrences(of: #"[\w.+-]+@[\w-]+\.[\w.]+"#, with: "[email]", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\+?\d[\d \-.,]{1,}\d"#, with: "[numero]", options: .regularExpression)
        return out
    }
}
