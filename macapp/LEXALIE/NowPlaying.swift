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

    /// On unless turned off in Settings: songs are explained from their lyrics (owner, 03/10).
    static var following: Bool {
        UserDefaults.standard.object(forKey: Key.songs) == nil || UserDefaults.standard.bool(forKey: Key.songs)
    }

    /// The song in Spotify or Music with where it is, in seconds, how long it is, which app plays it
    /// and whether it's playing: the tap's line is read from the lyrics at that point. Paused counts too
    /// (a press on the AirPods pauses first).
    static func playing() -> (song: Song, position: Double, duration: Double?, app: String, isPlaying: Bool)? {
        guard following else { return nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for (id, app) in players where running.contains(id) {
            let source = "tell application \"\(app)\" to if player state is not stopped then return (name of current track) & linefeed & (artist of current track) & linefeed & (player position as string) & linefeed & ((duration of current track) as string) & linefeed & (player state as string)"
            var error: NSDictionary?
            guard let out = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue, !out.isEmpty else { continue }
            let parts = out.components(separatedBy: "\n")
            guard parts.count >= 3, let position = Double(parts[2].replacingOccurrences(of: ",", with: ".")) else { continue }
            var duration = parts.count > 3 ? Double(parts[3].replacingOccurrences(of: ",", with: ".")) : nil
            // Spotify gives the length in milliseconds, Music in seconds.
            if app == "Spotify", let d = duration { duration = d / 1000 }
            let isPlaying = parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespaces).lowercased() == "playing" : true
            return (Song(title: String(parts[0].prefix(120)), artist: String(parts[1].prefix(120))), position, duration, app, isPlaying)
        }
        return nil
    }

    /// Spotify or Music, when one of them is open.
    static func runningPlayer() -> String? {
        guard following else { return nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return players.first { running.contains($0.0) }?.1
    }

    /// Playing, paused, or nil when nothing is loaded: read every half second to notice a pause.
    static func isPlaying(_ app: String) -> Bool? {
        var error: NSDictionary?
        // Asked twice a second: never wait on a busy player for more than a second.
        let source = "with timeout of 1 second\ntell application \"\(app)\" to return (player state as string)\nend timeout"
        guard let state = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue?.lowercased() else { return nil }
        if state.hasPrefix("playing") { return true }
        if state.hasPrefix("paused") { return false }
        return nil
    }

    /// When LEXALIE itself last paused or played the music: that pause is not yours.
    private(set) static var changedByUs: Date?

    static var recentlyChangedByUs: Bool {
        changedByUs.map { Date().timeIntervalSince($0) < 2.5 } ?? false
    }

    static func pause(_ app: String) {
        changedByUs = Date()
        send("pause", to: app)
    }

    static func resume(_ app: String) {
        changedByUs = Date()
        send("play", to: app)
    }

    /// "Play this line": the song from a moment before the line, in the app that plays it.
    static func play(_ app: String, from seconds: Double) {
        changedByUs = Date()
        send("set player position to \(String(format: "%.2f", max(0, seconds)))", to: app)
        send("play", to: app)
    }

    @discardableResult
    private static func send(_ command: String, to app: String) -> Bool {
        var error: NSDictionary?
        _ = NSAppleScript(source: "tell application \"\(app)\" to \(command)")?.executeAndReturnError(&error)
        return error == nil
    }

    /// A song playing right now in Spotify or Music (asks macOS once for permission to read it).
    static func current() -> Song? {
        guard following else { return nil }
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
