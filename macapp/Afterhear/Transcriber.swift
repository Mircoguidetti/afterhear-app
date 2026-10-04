import Foundation

enum AfterhearError: LocalizedError {
    case paused
    case silence
    case noWords
    case recognizerUnavailable(String)
    case noOnDevice(String)
    case server(String)
    case missingCode
    /// Neither an account nor a tester code: nothing can reach the AI.
    case signIn

    var errorDescription: String? {
        switch self {
        case .paused: String(localized: "Afterhear is paused.")
        case .silence: String(localized: "Nobody has spoken in the last few minutes: nothing to go back to.")
        case .noWords: String(localized: "Didn't catch anything in the last few seconds.")
        case .recognizerUnavailable(let lang): String(localized: "Speech recognition for \(lang) isn't available right now.")
        case .noOnDevice(let lang): String(localized: "The private model for \(lang) isn't on this Mac yet: it downloads on Wi-Fi (Settings).")
        case .server(let code): Self.serverMessage(code)
        case .missingCode: String(localized: "The tester code is missing: add it in Settings.")
        case .signIn: String(localized: "Sign in to get explanations: Settings → Account.")
        }
    }

    private static func serverMessage(_ code: String) -> String {
        switch code {
        case "bad_code": String(localized: "Sign in again to get explanations (Settings → Account).")
        case "bad_token", "sign_in": String(localized: "Your sign-in expired: sign in again (Settings → Account).")
        case "not_tester": String(localized: "Your account isn't on the testers' list yet.")
        case "server_not_configured": String(localized: "The server has no tester codes yet (Vercel → ASAID_TESTER_CODES).")
        case "provider_key": String(localized: "The server has no valid AI key (Vercel → GEMINI_API_KEY or ANTHROPIC_API_KEY).")
        case "rate_limited": String(localized: "Too many requests to the AI: try again shortly.")
        default: String(localized: "The server didn't answer (\(code)).")
        }
    }
}
