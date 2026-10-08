import AppIntents
import Foundation
import UserNotifications

/// "Hey Siri, I didn't get that" (§ 14.2), the Action button, Back Tap: the same as a tap.
struct MarkIntent: AppIntent {
    static var title: LocalizedStringResource = "I didn't get that"
    static var description = IntentDescription("Marks the last minutes: LEXALIE finds what slipped past you tonight.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Sessions.shared.mark(source: "siri")
        return .result()
    }
}

/// Two taps (§ 19.5): "explain it now". Back Tap triple, or a Shortcut: the last seconds, explained in a notification.
struct NowIntent: AppIntent {
    static var title: LocalizedStringResource = "Explain it now"
    static var description = IntentDescription("Explains the last seconds at once, in a notification.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Sessions.shared.mark(source: "now")
        await Sessions.shared.now(source: "siri")
        return .result()
    }
}

/// Hold (§ 19.5): listening on or off, e.g. from the Action button. Turning on needs the app
/// in front for a moment (iOS never lets an app start the microphone from the background).
struct ToggleListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Listening on or off"
    static var description = IntentDescription("Starts listening, or stops it if LEXALIE is already listening.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await Sessions.shared.toggle(source: "shortcut")
        return .result()
    }
}

/// "It was a while ago": marks up to twenty minutes back (§ 11.3).
struct MarkEarlierIntent: AppIntent {
    static var title: LocalizedStringResource = "I missed something earlier"
    static var openAppWhenRun = false

    @Parameter(title: "Minutes ago", default: 10, inclusiveRange: (1, 30))
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        Sessions.shared.mark(source: "earlier", minutesAgo: Double(minutes), window: 5)
        return .result()
    }
}

/// Starting needs the app in front (iOS doesn't let apps turn the microphone on in the background).
struct StartListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Start listening"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await Sessions.shared.start()
        return .result()
    }
}

struct StopListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop listening"
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Sessions.shared.stop()
        return .result()
    }
}

/// "Hey Siri, ask LEXALIE" (block INSIEME 1, owner 08/10): Siri asks what you want to know, LEXALIE
/// looks in everything you listened to together and Siri says the answer. The answer is also given
/// back as text, so a shortcut can take it further (Siri does the action, LEXALIE gives the facts).
struct AskLexalieIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask LEXALIE"
    static var description = IntentDescription("A question about anything you heard with LEXALIE: what they meant, who or what it was, what was said and when.")
    static var openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What do you want to ask?"))
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard Account.shared.signedIn else {
            return .result(value: "", dialog: "Open LEXALIE and sign in with the account you use on the Mac.")
        }
        guard let answer = await Together.shared.ask(question) else {
            return .result(value: "", dialog: "I couldn't ask now. Try again in a moment.")
        }
        let text = answer.error == "no_sessions" ? "We haven't listened to anything together yet." : answer.answer
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct UhsideShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskLexalieIntent(), phrases: ["Ask \(.applicationName)", "\(.applicationName), a question"],
                    shortTitle: "Ask LEXALIE", systemImageName: "questionmark.bubble")
        AppShortcut(intent: MarkIntent(), phrases: ["I didn't get that in \(.applicationName)", "Mark it in \(.applicationName)"],
                    shortTitle: "I didn't get that", systemImageName: "hand.tap")
        AppShortcut(intent: NowIntent(), phrases: ["Explain it now in \(.applicationName)"],
                    shortTitle: "Explain it now", systemImageName: "text.bubble")
        AppShortcut(intent: ToggleListeningIntent(), phrases: ["Turn \(.applicationName) on or off"],
                    shortTitle: "Listening on or off", systemImageName: "waveform.circle")
        AppShortcut(intent: MarkEarlierIntent(), phrases: ["I missed something earlier in \(.applicationName)"],
                    shortTitle: "Earlier", systemImageName: "clock.arrow.circlepath")
        AppShortcut(intent: StartListeningIntent(), phrases: ["Start listening with \(.applicationName)", "I'm out with \(.applicationName)"],
                    shortTitle: "Start listening", systemImageName: "waveform")
        AppShortcut(intent: StopListeningIntent(), phrases: ["Stop listening with \(.applicationName)"],
                    shortTitle: "Stop listening", systemImageName: "stop.circle")
    }
}

/// Focus modes (§ 11.11): e.g. "Travel" = help me live with notifications, the others = silent,
/// and "offer to listen" when the Focus turns on.
struct UhsideFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "LEXALIE"
    static var description = IntentDescription("Silent, or help me live, in this Focus.")

    @Parameter(title: "Help me live (notifications)", default: false)
    var liveHelp: Bool

    @Parameter(title: "Offer to start listening", default: false)
    var offer: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: liveHelp ? "Help me live" : "Silent", subtitle: offer ? "Offers to listen" : nil)
    }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(liveHelp, forKey: K.focusLiveHelp)
        if offer {
            let content = UNMutableNotificationContent()
            content.title = "Listen with LEXALIE?"
            content.body = liveHelp ? "Help me live is on: a short note when you mark." : "Silent: the lesson comes tomorrow."
            content.categoryIdentifier = "OFFER"
            content.userInfo = ["kind": "offer", "title": "Out"]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "focus-offer", content: content, trigger: nil))
        }
        return .result()
    }
}
