import AppIntents

/// What the Action Button runs. It doesn't open the app: it asks the running
/// listener for the last seconds, which is the whole point of the test.
struct ExplainIntent: AppIntent {
    static let title: LocalizedStringResource = "Cosa ha detto?"
    static let description = IntentDescription("Trascrive gli ultimi secondi ascoltati da Encore.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await Engine.shared.trigger(source: "Tasto Azione")
        return .result()
    }
}

struct EncoreShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ExplainIntent(),
            phrases: ["Cosa ha detto con \(.applicationName)"],
            shortTitle: "Cosa ha detto?",
            systemImageName: "ear"
        )
    }
}
