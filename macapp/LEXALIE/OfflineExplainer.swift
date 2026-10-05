import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// No connection (a plane): a quick explanation from the language model inside the Mac
/// (Apple Intelligence, macOS 26, Apple silicon), so "now" still answers something useful.
/// Simpler than Gemini, and marked as such: Gemini rewrites it once you're back online
/// (AppModel.upgradeOffline, docs/BRAIN.md § 19.25). Older Macs: nil, the moment waits.
enum OfflineExplainer {
    static func explain(_ sentence: String, settings: AppSettings, source: String) async -> Explanation? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return await AppleModel.explain(sentence, settings: settings, source: source) }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct OfflinePiece {
    @Guide(description: "The word or expression from the sentence that a learner would miss, exactly as written in the sentence")
    var text: String
    @Guide(description: "One to four words: its meaning in the learner's language")
    var gloss: String
    @Guide(description: "One short sentence in the learner's language: what it means here")
    var meaning: String
}

@available(macOS 26.0, *)
@Generable
struct OfflineAnswer {
    @Guide(description: "The whole sentence translated naturally into the learner's language")
    var translation: String
    @Guide(description: "What the speaker really meant, if it differs from the words; otherwise empty")
    var intent: String
    @Guide(description: "The one to three hardest words or expressions, most important first", .maximumCount(3))
    var pieces: [OfflinePiece]
}

@available(macOS 26.0, *)
private enum AppleModel {
    static func explain(_ sentence: String, settings: AppSettings, source: String) async -> Explanation? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let native = settings.native.english
        let heard = settings.heard.english
        let session = LanguageModelSession(instructions: """
            You help someone who is learning \(heard) and speaks \(native). They just missed a sentence \
            they heard. Explain it in \(native), briefly and simply: the translation, and the words or \
            expressions that made it hard (idioms, slang, phrasal verbs, words a learner wouldn't know).
            """)
        var prompt = "The sentence: \"\(sentence)\""
        if !source.isEmpty { prompt += "\nWhere it was heard: \(source)" }
        guard let answer = try? await session.respond(to: prompt, generating: OfflineAnswer.self).content else { return nil }
        let pieces = answer.pieces.filter { !$0.text.isEmpty }.map {
            Piece(text: $0.text, heardAs: nil, gloss: $0.gloss, meaning: $0.meaning, note: "", cause: "unknown_word", level: nil)
        }
        let intent = answer.intent.trimmingCharacters(in: .whitespacesAndNewlines)
        return Explanation(transcript: nil, translation: answer.translation, intent: intent.isEmpty ? nil : intent,
                           pieces: pieces, provider: "apple", model: "apple-offline", ms: nil)
    }
}
#endif
