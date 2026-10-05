import Foundation

/// Who may use the AI: your account (owner, 03/10: the account replaces the tester code; the server
/// checks the account against the testers' list) or, still, a tester code from Settings → Advanced.
enum ServerAccess {
    static func authorize(_ request: inout URLRequest, settings: AppSettings) async throws {
        let code = settings.code.trimmingCharacters(in: .whitespaces)
        let token = await Account.shared.accessToken()
        guard !code.isEmpty || token != nil else { throw LexalieError.signIn }
        if !code.isEmpty { request.setValue(code, forHTTPHeaderField: "x-lexalie-code") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }
}

/// Talks to LEXALIE's server (api/explain.ts on Vercel), which holds the AI keys.
enum ExplainClient {
    private struct Body: Encodable {
        let text: String
        let audio: String?
        let heard: String
        let native: String
        let level: String
        let known: [String]
        let struggling: [String]
        let watch: [String]
        let profile: String
        let source: String
        let overlap: Bool
        let provider: String
        let focus: String
        let tone: String
        let before: [String]
        let after: [String]
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    static func explain(_ text: String, audio: Data? = nil, settings: AppSettings, known: [String],
                        struggling: [String] = [], watch: [String] = [], profile: String = "",
                        source: String = "", overlap: Bool = false, focus: String = "", tone: String = "",
                        before: [String] = [], after: [String] = []) async throws -> Explanation {
        guard let base = URL(string: settings.server.trimmingCharacters(in: .whitespaces)) else {
            throw LexalieError.server("url")
        }
        var request = URLRequest(url: base.appendingPathComponent("api/explain"))
        request.httpMethod = "POST"
        // Offline is found at the tap (Reachability); this only caps a slow server.
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        try await ServerAccess.authorize(&request, settings: settings)
        request.httpBody = try JSONEncoder().encode(Body(
            text: text,
            audio: audio?.base64EncodedString(),
            heard: settings.heard.rawValue,
            native: settings.native.rawValue,
            level: settings.level,
            known: Array(known.prefix(500)),
            struggling: Array(struggling.prefix(200)),
            watch: Array(watch.prefix(200)),
            profile: String(profile.prefix(600)),
            source: String(source.prefix(200)),
            overlap: overlap,
            provider: "gemini",
            focus: String(focus.prefix(120)),
            tone: String(tone.prefix(400)),
            before: before.suffix(3).map { String(Redactor.redact($0).prefix(300)) },
            after: after.prefix(2).map { String(Redactor.redact($0).prefix(300)) }
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(status)"
            throw LexalieError.server(code)
        }
        return try JSONDecoder().decode(Explanation.self, from: data)
    }
}
