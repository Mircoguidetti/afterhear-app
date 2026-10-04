import AVFoundation
import Foundation

/// A suggestion for someone's accent from a few seconds of their voice (docs/BRAIN.md § 7.3).
/// Only with a moment's clip that is already on this Mac; the audio goes to the AI once,
/// is not stored, and you confirm or change the suggestion.
@MainActor
enum AccentGuess {
    struct Guess: Decodable { let accent: String; let confidence: Double; let cue: String }

    /// Suggestions waiting for you, per person ("Sarah": "Scottish · rolled r").
    static var pending: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "accentSuggestions") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "accentSuggestions") }
    }
    private static var tried: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "accentTried") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "accentTried") }
    }

    /// After a moment with someone whose accent you haven't picked: guess it once.
    static func maybeSuggest(for moment: Moment) {
        let accent = moment.with.flatMap { AppModel.shared.store.accent(of: $0) }
        guard let name = moment.with, accent == nil || accent == "Other / not sure",
              !tried.contains(name), pending[name] == nil else { return }
        tried.insert(name)
        Task { await suggest(name: name, from: moment) }
    }

    @discardableResult
    static func suggest(name: String, from moment: Moment? = nil) async -> Guess? {
        let store = AppModel.shared.store
        let source = moment ?? store.moments.first { $0.with == name && store.clipURL($0) != nil }
        guard let source, let url = store.clipURL(source), let wav = theirVoice(url, moment: source) else { return nil }
        guard let guess: Guess = try? await CoachClient.post("api/accent", ["audio": wav.base64EncodedString()]),
              guess.confidence >= 0.55, guess.accent != "Other / not sure" else { return nil }
        pending[name] = "\(guess.accent) · \(guess.cue)"
        return guess
    }

    static func accept(_ name: String) {
        guard let s = pending[name], let accent = s.components(separatedBy: " · ").first else { return }
        AppModel.shared.store.upsertPerson(Person(name: name, accent: accent))
        pending[name] = nil
    }

    static func reject(_ name: String) { pending[name] = nil }

    /// Up to ten seconds of the other person (the turn you missed), as a small WAV.
    private static func theirVoice(_ url: URL, moment: Moment) -> Data? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        var from = 0.0, to = min(Double(file.length) / rate, 10)
        if let turns = moment.turns, let i = moment.chosen, turns.indices.contains(i), !turns[i].isMine {
            from = turns[i].start
            to = min(turns[i].end, from + 10)
        }
        let start = AVAudioFramePosition(from * rate), count = AVAudioFrameCount(max(0, (to - from) * rate))
        guard count > AVAudioFrameCount(rate), let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
        file.framePosition = start
        guard (try? file.read(into: buffer, frameCount: count)) != nil, let channel = buffer.floatChannelData?[0] else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: out) }
        guard (try? Clip.write(samples, rate: rate, to: out)) != nil else { return nil }
        return try? Data(contentsOf: out)
    }
}
