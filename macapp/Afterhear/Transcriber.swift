import Foundation

enum AfterhearError: LocalizedError {
    case paused
    case silence
    case noWords
    case recognizerUnavailable(String)
    case noOnDevice(String)
    case server(String)
    case missingCode

    var errorDescription: String? {
        switch self {
        case .paused: "Afterhear is paused."
        case .silence: "No sound from the Mac in the last few seconds."
        case .noWords: "Didn't catch anything in the last few seconds."
        case .recognizerUnavailable(let lang): "Speech recognition for \(lang) isn't available right now."
        case .noOnDevice(let lang): "The private model for \(lang) isn't on this Mac yet: it downloads on Wi-Fi (Settings)."
        case .server(let code): Self.serverMessage(code)
        case .missingCode: "The tester code is missing: add it in Settings."
        }
    }

    private static func serverMessage(_ code: String) -> String {
        switch code {
        case "bad_code": "Wrong tester code (Settings)."
        case "server_not_configured": "The server has no tester codes yet (Vercel → ASAID_TESTER_CODES)."
        case "provider_key": "The server has no valid AI key (Vercel → GEMINI_API_KEY or ANTHROPIC_API_KEY)."
        case "rate_limited": "Too many requests to the AI: try again shortly."
        default: "The server didn't answer (\(code))."
        }
    }
}
