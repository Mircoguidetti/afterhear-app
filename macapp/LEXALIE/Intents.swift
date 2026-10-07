import AppIntents
import MediaPlayer

/// "Hey Siri, I didn't get that" (docs/BRAIN.md § 14.2): the same as a tap, with your voice,
/// from the couch. Siri's own detector is already listening, so it costs no battery.
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "I didn't get that"
    static var description = IntentDescription("Marks what was just said, like a tap: LEXALIE explains it now or tonight.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppModel.shared.captureMoment(trigger: "siri")
        return .result()
    }
}

/// "Hey Siri, ask LEXALIE": one question about what you just heard (07/10). Siri listens and answers
/// out loud, so nothing of ours opens the microphone.
struct AskIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask about what I just heard"
    static var description = IntentDescription("One question about the last minutes: what they meant, who or what it was, who's singing.")
    static var openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What do you want to know?"))
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await Ask.shared.ask(question, context: ContextDetector.current(), speak: false)
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

struct UhsideShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MarkMomentIntent(), phrases: [
            "I didn't get that in \(.applicationName)",
            "\(.applicationName), what did they say",
            "Mark it in \(.applicationName)",
        ])
        AppShortcut(intent: AskIntent(), phrases: [
            "Ask \(.applicationName)",
            "\(.applicationName), a question",
        ])
    }
}

/// A squeeze on the AirPods stem (or the play/pause key): help me now (§ 14.4, opt-in).
/// While it's on, LEXALIE is the "now playing" app, so the press reaches it instead of the
/// video; videos are then not paused automatically.
@MainActor
final class RemoteTap {
    static let shared = RemoteTap()
    private var target: Any?

    var isOn: Bool { target != nil }

    func apply() {
        let center = MPRemoteCommandCenter.shared()
        let wanted = UserDefaults.standard.bool(forKey: Key.airpods)
        if wanted, target == nil {
            let handler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { _ in
                // A squeeze is "help me now" (owner, 03/10): it reaches LEXALIE when nothing else plays.
                // While the ear speaks, it's "more" (07/10).
                Task { @MainActor in
                    if EarFlow.shared.running { EarFlow.shared.press(.more); return }
                    await AppModel.shared.captureMoment(trigger: "airpods", now: true)
                }
                return .success
            }
            target = center.togglePlayPauseCommand.addTarget(handler: handler)
            center.playCommand.addTarget(handler: handler)
            center.pauseCommand.addTarget(handler: handler)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: String(localized: "LEXALIE is listening with you")]
            MPNowPlayingInfoCenter.default().playbackState = .playing
        } else if !wanted, target != nil {
            center.togglePlayPauseCommand.removeTarget(nil)
            center.playCommand.removeTarget(nil)
            center.pauseCommand.removeTarget(nil)
            target = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }
}
