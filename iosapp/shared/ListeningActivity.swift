import ActivityKit
import AppIntents
import Foundation

/// The Live Activity while Afterhear listens (docs/BRAIN.md § 11.12): on the Lock Screen and in
/// the Dynamic Island, always, so it never listens in secret. It also holds the Mark button.
struct ListeningAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var marks: Int
        var liveHelp: Bool
    }
    var startedAt: Date
    var title: String
}

/// The Mark button on the Lock Screen and in the Dynamic Island: it runs in the app.
struct MarkFromActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark it"
    static var description = IntentDescription("Something just slipped past you: Afterhear finds it tonight.")
    static var openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await MainActor.run { Sessions.shared.mark(source: "lock_screen") }
        #endif
        return .result()
    }
}
