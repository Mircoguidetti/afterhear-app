import AVFoundation
import Foundation

/// "What they told you to do" (block COSA 7, owner 07/10 evening): at the end of a call or of a
/// conversation heard in person, only what someone asked or told *you* to do, with their own words, the
/// real voice to hear again and what they meant. Never the group's tasks, never a summary, never your
/// own notes: no boxes to tick, no reminders, no dates in a calendar (the comprehension test: "did I
/// understand?", not "remind me").
enum Told {
    struct Item: Codable, Hashable {
        let quote: String
        let meaning: String
        let unsure: Bool
    }

    private struct Answer: Decodable { let items: [Item] }

    /// A sentence that may be a request or an instruction, in the languages LEXALIE hears. Only these
    /// keep their voice for the end (a few seconds each, on this Mac, gone after 7 days).
    static let cue = [
        #"\b(can you|could you|would you|will you|please|send|share|bring|take|come back|call|check|pay|sign|book|make sure|don't forget|you need to|you have to|you should|you'll need|let me know|get back|by (monday|tuesday|wednesday|thursday|friday|tomorrow|tonight|next week))\b"#,
        #"\b(puoi|potresti|può|mi mandi|porti|porta|prenda|prendi|torni|torna|deve|devi|si ricordi|ricordati|firmi|paghi|chiami|entro (lunedì|martedì|mercoledì|giovedì|venerdì|domani))\b"#,
        #"\b(puedes|podrías|puede|tómese|tómelo|tómela|tome|toma|traiga|trae|vuelva|vuelve|tiene que|tienes que|debe|debes|pida|firme|pague|llame|no (conduzca|olvide))\b"#,
        #"\b(pouvez-vous|peux-tu|prenez|apportez|revenez|il faut|vous devez|tu dois|n'oubliez pas|signez|payez|appelez)\b"#,
        #"\b(können sie|kannst du|nehmen sie|bringen sie|kommen sie|müssen sie|musst du|vergessen sie nicht|unterschreiben sie|rufen sie)\b"#,
        #"\b(pode|podes|tome|traga|volte|tem que|tens de|deve|não se esqueça|assine|pague|ligue)\b"#,
        #"(можете|можешь|возьмите|принесите|приходите|нужно|надо|не забудьте|подпишите|позвоните)"#,
    ].joined(separator: "|")

    static func looksLikeRequest(_ text: String) -> Bool {
        text.lowercased().range(of: cue, options: .regularExpression) != nil
    }

    /// The server's answer for these lines (theirs only), or nil when it can't be reached.
    @MainActor static func ask(lines: [String], source: String) async -> [Item]? {
        AppModel.syncRedactor()
        let sent = lines.suffix(300).map { String(Redactor.redact($0).prefix(1200)) }.filter { !$0.isEmpty }
        guard !sent.isEmpty else { return [] }
        guard let answer: Answer = try? await CoachClient.post("api/told", ["lines": sent, "source": source]) else { return nil }
        return Array(answer.items.prefix(3))
    }

    /// The line it came from, as it was said (names and numbers back): the most words in common.
    static func origin(of quote: String, in lines: [String]) -> String? {
        let words = Set(tokens(quote))
        guard !words.isEmpty else { return nil }
        let best = lines.map { line -> (String, Double) in
            let have = Set(tokens(line))
            return (line, Double(words.intersection(have).count) / Double(words.count))
        }.max { $0.1 < $1.1 }
        // Placeholders ([nome], [numero]) never match: 0.5 of the words is enough.
        guard let best, best.1 >= 0.5 else { return nil }
        return best.0
    }

    /// The meaning with the numbers put back, in order, from the line as it was said.
    static func restore(_ meaning: String, from line: String?) -> String {
        guard let line, meaning.contains("[numero]") else { return meaning }
        var numbers = line.matches(#"\+?\d[\d \-.,:]*\d|\d"#)
        var out = meaning
        while let range = out.range(of: "[numero]"), !numbers.isEmpty {
            out.replaceSubrange(range, with: numbers.removeFirst())
        }
        return out
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }
}

private extension String {
    func matches(_ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { Range($0.range, in: self).map { String(self[$0]) } }
    }
}

/// The real voice of the sentences that may be requests, kept for the end card's Replay. On this Mac
/// only, in a folder of its own; anything older than 7 days goes at launch (the 7 days of the
/// conversation around a tap, owner 06/10).
@MainActor
final class ToldVoice {
    static let shared = ToldVoice()
    private var kept: [(line: String, url: URL)] = []
    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LEXALIE/told", isDirectory: true)
    private var player: AVAudioPlayer?

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let limit = Date().addingTimeInterval(-7 * 86_400)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < limit { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Keeps the sound of one of their turns, heard `turn.start…turn.end` seconds after `clipStart`.
    func keep(_ turn: Turn, clipStart: Date) {
        guard kept.count < 60, !kept.contains(where: { $0.line == turn.text }) else { return }
        let now = Date()
        let from = now.timeIntervalSince(clipStart.addingTimeInterval(turn.start)) + 0.3
        let to = now.timeIntervalSince(clipStart.addingTimeInterval(turn.end)) - 0.4
        guard from > 0, from < SystemAudio.hiSeconds, from - max(0, to) < 30 else { return }
        let (samples, rate) = AppModel.shared.recentVoice(seconds: from)
        guard rate > 0, !samples.isEmpty else { return }
        let drop = Int(max(0, to) * rate)
        let voice = Array(samples.prefix(max(0, samples.count - drop)))
        guard voice.count > Int(rate * 0.5) else { return }
        let url = folder.appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try Clip.write(voice, rate: rate, to: url)
            kept.append((turn.text, url))
        } catch {}
    }

    /// The kept voice whose words are this line's.
    func voice(for line: String?) -> URL? {
        guard let line else { return nil }
        return kept.first { $0.line == line }?.url
    }

    func play(_ url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    /// A new call or conversation starts: the list (not the files) starts again.
    func reset() { kept.removeAll() }
}
