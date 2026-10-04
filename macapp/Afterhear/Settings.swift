import Foundation

/// The language spoken around you: what the recognizer listens for.
enum HeardLanguage: String, CaseIterable, Identifiable, Codable {
    case enGB = "en-GB", enUS = "en-US", itIT = "it-IT", frFR = "fr-FR", esES = "es-ES", deDE = "de-DE", ruRU = "ru-RU"
    // Portuguese too (owner, 03/10: the same seven languages everywhere).
    case ptPT = "pt-PT", ptBR = "pt-BR"
    var id: String { rawValue }
    /// In the app's language, for the screens.
    var label: String {
        switch self {
        case .enGB: String(localized: "English (UK)")
        case .enUS: String(localized: "English (US)")
        case .itIT: String(localized: "Italian")
        case .frFR: String(localized: "French")
        case .esES: String(localized: "Spanish")
        case .deDE: String(localized: "German")
        case .ruRU: String(localized: "Russian")
        case .ptPT: String(localized: "Portuguese (Portugal)")
        case .ptBR: String(localized: "Portuguese (Brazil)")
        }
    }
    /// Always in English, for the instructions to the model.
    var english: String {
        switch self {
        case .enGB: "English (UK)"
        case .enUS: "English (US)"
        case .itIT: "Italian"
        case .frFR: "French"
        case .esES: "Spanish"
        case .deDE: "German"
        case .ruRU: "Russian"
        case .ptPT: "Portuguese (Portugal)"
        case .ptBR: "Portuguese (Brazil)"
        }
    }
}

/// The language explanations are written in: yours. The app speaks it too (owner, 03/10).
enum NativeLanguage: String, CaseIterable, Identifiable {
    case it, en, ru, es, fr, de, pt
    var id: String { rawValue }
    /// The Mac's language when it is one of ours, otherwise English.
    static var system: NativeLanguage {
        NativeLanguage(rawValue: String((Locale.preferredLanguages.first ?? "en").prefix(2))) ?? .en
    }
    /// Each language in its own words, so anyone finds theirs.
    var label: String {
        switch self {
        case .it: "Italiano"
        case .en: "English"
        case .ru: "Русский"
        case .es: "Español"
        case .fr: "Français"
        case .de: "Deutsch"
        case .pt: "Português"
        }
    }
    /// Always in English, for the instructions to the model.
    var english: String {
        switch self {
        case .it: "Italian"
        case .en: "English"
        case .ru: "Russian"
        case .es: "Spanish"
        case .fr: "French"
        case .de: "German"
        case .pt: "Portuguese"
        }
    }
}

/// Who turns the last seconds into text.
enum Transcription: String, CaseIterable, Identifiable {
    case mac, gemini
    var id: String { rawValue }
    var label: String {
        self == .mac ? String(localized: "On the Mac (private)") : String(localized: "Gemini listens to the audio (more accurate, the voice leaves the Mac)")
    }
}

/// What appears during the conversation.
enum HelpMode: String, CaseIterable, Identifiable {
    case silent, glance, full, pause
    var id: String { rawValue }
}

enum Provider: String, CaseIterable, Identifiable {
    case claude, gemini
    var id: String { rawValue }
    var label: String { self == .claude ? "Claude" : "Gemini" }
}

/// Keys shared by `@AppStorage` in the views and `AppSettings.current` in the model.
enum Key {
    static let server = "serverURL"
    static let code = "testerCode"
    static let heard = "heardLanguage"
    static let native = "nativeLanguage"
    static let level = "level"
    static let provider = "provider"
    static let seconds = "seconds"
    static let onDeviceOnly = "onDeviceOnly"
    static let transcription = "transcription"
    static let mode = "helpMode"
    static let sorry = "sorryDetection"
    static let doubleTap = "doubleTapOption"
    static let keyword = "voiceKeyword"
    static let webApp = "webAppURL"
    static let helpVideo = "helpVideo"
    static let helpCall = "helpCall"
    static let helpOther = "helpOther"
    static let calendar = "calendarOn"
    static let prepLead = "prepLeadMinutes"
    static let callsTextOnly = "callsTextOnly"
    static let myName = "myFirstName"
    static let askedMe = "showQuestionsToMe"
    static let opener = "suggestOpener"
    /// Gone (§ 19.26: voices never leave the devices); kept only to switch it off for old installs.
    static let syncAudio = "syncAudio"
    /// "Help me now": also the explanation (default), or only the subtitle and its translation.
    static let nowExplain = "nowExplain"
    /// Show the translation under the sentence even at B2/C1 (A2/B1 always see it).
    static let translationAlways = "translationAlways"
    /// The first-run setup is done.
    static let onboarded = "onboardedV2"
    static let dictionary = "myDictionary"
    static let useModel = "useYourModel"
    static let modelHints = "modelHints"
    /// Suggestions on or off, per kind of call (a title without numbers and dates).
    static let callHints = "callHintsByTitle"
    /// "Tell me before calls": all, hard, never (§ 19.15).
    static let callNotice = "callNotice"
    /// The clip of a tap also goes to the best recogniser on the server (§ 19.21). On by default.
    static let cloudTranscription = "cloudTranscription"
    /// Test (§ 19.25): in videos ElevenLabs also hears the sentence, kept only to compare. Off by default.
    static let compareCloud = "compareCloud"
    /// "Now" in a video pauses it (default); off: the video keeps playing under the explanation.
    static let pauseVideo = "pauseVideo"
    static let songs = "followSongs"
    static let airpods = "airpodsTap"
    /// Pause = tap (owner, 03/10): you pause a song or a video mid-line, Afterhear offers that line.
    static let pauseTap = "pauseIsTap"
}

struct AppSettings {
    var server: String
    var code: String
    var heard: HeardLanguage
    var native: NativeLanguage
    var level: String
    var provider: Provider
    var seconds: Double
    var onDeviceOnly: Bool
    var transcription: Transcription
    var mode: HelpMode
    var sorry: Bool
    var doubleTap: Bool

    static let defaultServer = "https://asaid-nine.vercel.app"
    static let defaultWebApp = "https://asaid-cx6u.vercel.app"
    static let levels = ["A2", "B1", "B2", "C1"]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.server: defaultServer,
            Key.code: "",
            Key.heard: HeardLanguage.enGB.rawValue,
            Key.native: NativeLanguage.system.rawValue,
            Key.level: "B2",
            Key.provider: Provider.gemini.rawValue,
            Key.nowExplain: true,
            Key.translationAlways: false,
            Key.seconds: 8.0,
            Key.onDeviceOnly: true,
            Key.transcription: Transcription.mac.rawValue,
            Key.mode: HelpMode.silent.rawValue,
            Key.compareCloud: false,
            Key.pauseVideo: true,
            Key.pauseTap: true,
            Key.sorry: true,
            Key.doubleTap: true,
            Key.webApp: defaultWebApp,
            Key.helpVideo: HelpMode.pause.rawValue,
            Key.helpCall: HelpMode.silent.rawValue,
            Key.helpOther: HelpMode.glance.rawValue,
            Key.calendar: false,
            Key.prepLead: 120,
        ])
    }

    static var current: AppSettings {
        let d = UserDefaults.standard
        return AppSettings(
            server: d.string(forKey: Key.server) ?? defaultServer,
            code: d.string(forKey: Key.code) ?? "",
            heard: HeardLanguage(rawValue: d.string(forKey: Key.heard) ?? "") ?? .enGB,
            native: NativeLanguage(rawValue: d.string(forKey: Key.native) ?? "") ?? .system,
            level: d.string(forKey: Key.level) ?? "B2",
            // The AI is ours: always Gemini, never chosen nor shown (owner, 02/10, § 19.27).
            provider: .gemini,
            seconds: d.double(forKey: Key.seconds),
            onDeviceOnly: d.bool(forKey: Key.onDeviceOnly),
            transcription: Transcription(rawValue: d.string(forKey: Key.transcription) ?? "") ?? .mac,
            mode: HelpMode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .glance,
            sorry: d.bool(forKey: Key.sorry),
            doubleTap: d.bool(forKey: Key.doubleTap)
        )
    }
}

extension AppSettings {
    /// What "help me now" does here (owner, 04/10: settings without doubles). The visible choices
    /// decide it: in a video, pause it while you read (or not); in a call or anywhere else, one line
    /// you read at a glance. With or without the explanation is "Show" in Settings (Key.nowExplain).
    static func nowMode(for context: AppContext) -> HelpMode {
        switch context {
        case .video: UserDefaults.standard.bool(forKey: Key.pauseVideo) ? .pause : .full
        case .call, .other: .glance
        }
    }
}
