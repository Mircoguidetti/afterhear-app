import Foundation

/// The clip of a tap, transcribed by the best recogniser on the server (api/transcribe,
/// docs/BRAIN.md § 19.21). The Mac's own recogniser listens all the time and answers at once;
/// this one hears only the minutes before a tap, and it's the one we trust for the sentence.
/// Off with "Best accuracy" off in Settings, or without a connection: the Mac's own result stays.
enum CloudTranscriber {
    struct Word: Decodable { let text: String; let start: Double; let end: Double; let speaker: String? }
    struct Result: Decodable { let provider: String; let text: String; let words: [Word]; let ms: Int? }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: Key.cloudTranscription) == nil || UserDefaults.standard.bool(forKey: Key.cloudTranscription)
    }

    static func transcribe(_ clip: URL, settings: AppSettings) async -> Result? {
        guard enabled, !settings.code.trimmingCharacters(in: .whitespaces).isEmpty,
              let base = URL(string: settings.server.trimmingCharacters(in: .whitespaces)),
              let audio = try? Data(contentsOf: clip), audio.count < 2_900_000 else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("api/transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(settings.code.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-lexalie-code")
        let body: [String: Any] = [
            "audio": audio.base64EncodedString(),
            "mime": clip.pathExtension == "wav" ? "audio/wav" : "audio/mp4",
            "language": settings.heard.rawValue,
            "vocabulary": Array(LiveTranscriber.vocabulary.prefix(100)),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(Result.self, from: data) else { return nil }
        return result
    }

    /// The words as the Mac's recogniser gives them, on the clock of the clip. Providers that
    /// give only text get their words spread over the clip, ending where the clip ends.
    static func timedWords(_ result: Result, clipStart: Date, clipLength: Double) -> [TimedWord] {
        if !result.words.isEmpty {
            return result.words.map { TimedWord(start: clipStart.addingTimeInterval($0.start), end: clipStart.addingTimeInterval($0.end), text: $0.text) }
        }
        let parts = result.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return [] }
        // About 2.7 words a second of speech, ending at the end of the clip.
        let span = min(clipLength, Double(parts.count) / 2.7)
        let step = span / Double(parts.count)
        let from = clipStart.addingTimeInterval(clipLength - span)
        return parts.enumerated().map { i, w in
            TimedWord(start: from.addingTimeInterval(Double(i) * step), end: from.addingTimeInterval(Double(i + 1) * step), text: w)
        }
    }
}

/// Waits for `work` at most `seconds`; nil when it takes longer (the work keeps going, unused).
func withDeadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
