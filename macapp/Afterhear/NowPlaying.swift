import AppKit
import ShazamKit

/// Which song is playing, and where (docs/BRAIN.md § 17.1): from Spotify or Apple Music on
/// this Mac, or recognised from the microphone when it plays from a speaker (Shazam).
/// Only the title and the artist are read; nothing is sent anywhere by this.
enum NowPlaying {
    struct Song: Equatable, Codable {
        let title: String
        let artist: String
        var label: String { artist.isEmpty ? title : "\(title) — \(artist)" }
    }

    private static let players = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]

    /// A song playing right now in Spotify or Music (asks macOS once for permission to read it).
    static func current() -> Song? {
        guard UserDefaults.standard.bool(forKey: Key.songs) else { return nil }
        if let heard = heard, Date().timeIntervalSince(heard.at) < 240 { return heard.song }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for (id, app) in players where running.contains(id) {
            let source = "tell application \"\(app)\" to if player state is playing then return (name of current track) & linefeed & (artist of current track)"
            var error: NSDictionary?
            guard let out = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue, !out.isEmpty else { continue }
            let parts = out.components(separatedBy: "\n")
            return Song(title: String(parts[0].prefix(120)), artist: String((parts.count > 1 ? parts[1] : "").prefix(120)))
        }
        return nil
    }

    /// The last song Shazam recognised from the room (a speaker, Alexa, the radio).
    private static var heard: (song: Song, at: Date)?

    /// "What's this song?": listens through the microphone for a few seconds.
    /// Needs the ShazamKit service on the app's Apple Developer identifier.
    static func identify() async -> Song? {
        guard #available(macOS 14.0, *) else { return nil }
        let session = SHManagedSession()
        let result = await session.result()
        guard case .match(let match) = result, let item = match.mediaItems.first, let title = item.title else { return nil }
        let song = Song(title: title, artist: item.artist ?? "")
        heard = (song, Date())
        return song
    }
}
