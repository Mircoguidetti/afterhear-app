import Foundation

/// A song's words with their times. For songs the line comes from the lyrics at the song's position,
/// never from listening to the singer (owner, 03/10): exact, instant, and nothing to transcribe.
/// LRCLIB for now (free, open, time-synced lyrics); a licensed source (Musixmatch, LyricFind) before launch.
@MainActor
enum Lyrics {
    struct Line: Equatable {
        let start: Double
        let text: String
    }

    private static var cache: [String: [Line]] = [:]
    private static var missing: Set<String> = []

    /// The synced lyrics of a song, or nil when there are none (an instrumental, a song nobody timed).
    static func synced(_ song: NowPlaying.Song, duration: Double?) async -> [Line]? {
        let key = (song.artist + "|" + song.title).lowercased()
        if let lines = cache[key] { return lines }
        if missing.contains(key) { return nil }
        var found: String? = nil
        if let exact = await fetch("https://lrclib.net/api/get", [
            URLQueryItem(name: "track_name", value: song.title),
            URLQueryItem(name: "artist_name", value: song.artist),
        ] + (duration.map { [URLQueryItem(name: "duration", value: String(Int($0.rounded())))] } ?? [])) {
            found = (try? JSONSerialization.jsonObject(with: exact) as? [String: Any])?["syncedLyrics"] as? String
        }
        if found == nil, let list = await fetch("https://lrclib.net/api/search", [
            URLQueryItem(name: "track_name", value: song.title),
            URLQueryItem(name: "artist_name", value: song.artist),
        ]), let results = (try? JSONSerialization.jsonObject(with: list)) as? [[String: Any]] {
            found = results.lazy.compactMap { $0["syncedLyrics"] as? String }.first { !$0.isEmpty }
        }
        guard let lrc = found else {
            missing.insert(key)
            return nil
        }
        let lines = parse(lrc)
        guard !lines.isEmpty else {
            missing.insert(key)
            return nil
        }
        cache[key] = lines
        return lines
    }

    /// "[01:23.45] the words" → (83.45, "the words"); empty lines (instrumental breaks) are left out.
    nonisolated static func parse(_ lrc: String) -> [Line] {
        var out: [Line] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let stamp = rest[rest.index(after: rest.startIndex)..<close]
                let parts = stamp.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1].replacingOccurrences(of: ",", with: ".")) {
                    times.append(m * 60 + s)
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            out += times.map { Line(start: $0, text: text) }
        }
        return out.sorted { $0.start < $1.start }
    }

    private static func fetch(_ base: String, _ query: [URLQueryItem]) async -> Data? {
        guard var parts = URLComponents(string: base) else { return nil }
        parts.queryItems = query
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("LEXALIE (https://asaid-nine.vercel.app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
