import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Your LEXALIE account on the iPhone: the same one as the web app and the Mac.
/// Google goes through a secure browser sheet; the email link comes back on lexalie://auth-callback
/// (PKCE: the one-time code is useless without the secret that never leaves this phone).
@MainActor
final class Account: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = Account()

    static let supabaseURL = "https://yybnjnixekolomyghioo.supabase.co"
    static let publishableKey = "sb_publishable_cJUXbz2kHWKg4sjxxTi3Sw_MYJdgSnk"
    static let callback = "lexalie://auth-callback"

    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double
        var userID: String
        var email: String?
    }

    @Published private(set) var session: Session?
    @Published var message: String?
    @Published private(set) var working = false
    private var web: ASWebAuthenticationSession?

    var signedIn: Bool { session != nil }

    private var verifier: String? {
        get { UserDefaults.standard.string(forKey: "pkceVerifier") }
        set { UserDefaults.standard.set(newValue, forKey: "pkceVerifier") }
    }

    private override init() {
        super.init()
        session = Keychain.load()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    func signInWithGoogle() {
        let challenge = newChallenge()
        var parts = URLComponents(string: Self.supabaseURL + "/auth/v1/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: Self.callback),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        guard let url = parts.url else { return }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "lexalie") { url, _ in
            Task { @MainActor in if let url { Account.shared.handle(url) } }
        }
        session.presentationContextProvider = self
        web = session
        session.start()
    }

    func sendMagicLink(email: String) async {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { message = "Enter a valid email."; return }
        let challenge = newChallenge()
        working = true
        defer { working = false }
        do {
            var parts = URLComponents(string: Self.supabaseURL + "/auth/v1/otp")!
            parts.queryItems = [URLQueryItem(name: "redirect_to", value: Self.callback)]
            _ = try await post(parts.url!, body: ["email": email, "create_user": true, "code_challenge": challenge, "code_challenge_method": "s256"])
            message = "We sent a link to \(email). Open it on this iPhone."
        } catch {
            message = "We couldn't send the link. Try again in a minute."
        }
    }

    func signIn(email: String, password: String) async {
        working = true
        defer { working = false }
        do {
            try store(try await post(URL(string: Self.supabaseURL + "/auth/v1/token?grant_type=password")!,
                                     body: ["email": email.trimmingCharacters(in: .whitespaces), "password": password]))
            message = nil
        } catch {
            message = "Wrong email or password."
        }
    }

    /// lexalie://auth-callback?code=… from Google or the email link.
    func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fragment = URLComponents(string: "x:?" + (url.fragment ?? ""))?.queryItems ?? []
        let value = { (name: String) in (items + fragment).first { $0.name == name }?.value }
        if let error = value("error_description") {
            message = error.replacingOccurrences(of: "+", with: " ")
            return
        }
        guard let code = value("code"), let verifier else {
            message = "That link didn't work. Try signing in again."
            return
        }
        Task {
            working = true
            defer { working = false }
            do {
                try store(try await post(URL(string: Self.supabaseURL + "/auth/v1/token?grant_type=pkce")!,
                                         body: ["auth_code": code, "code_verifier": verifier]))
                self.verifier = nil
                message = nil
            } catch {
                message = "That link has expired or was already used. Try again."
            }
        }
    }

    func signOut() {
        session = nil
        Keychain.delete()
    }

    /// A valid access token, refreshed when it's about to expire. Nil when signed out.
    func accessToken() async -> String? {
        guard let session else { return nil }
        if session.expiresAt - 60 > Date().timeIntervalSince1970 { return session.accessToken }
        do {
            try store(try await post(URL(string: Self.supabaseURL + "/auth/v1/token?grant_type=refresh_token")!,
                                     body: ["refresh_token": session.refreshToken]))
            return self.session?.accessToken
        } catch {
            return nil
        }
    }

    private func newChallenge() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URL
        self.verifier = verifier
        return Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    private func post(_ url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw LexalieError.server("auth") }
        return data
    }

    private func store(_ data: Data) throws {
        struct Token: Decodable {
            struct User: Decodable { let id: String; let email: String? }
            let access_token: String
            let refresh_token: String
            let expires_in: Double?
            let expires_at: Double?
            let user: User
        }
        let token = try JSONDecoder().decode(Token.self, from: data)
        let session = Session(accessToken: token.access_token, refreshToken: token.refresh_token,
                              expiresAt: token.expires_at ?? Date().timeIntervalSince1970 + (token.expires_in ?? 3600),
                              userID: token.user.id, email: token.user.email)
        self.session = session
        Keychain.save(session)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The session in the iPhone Keychain, readable only by this app.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.lexalie.ios.session",
        kSecAttrAccount as String: "supabase",
    ]

    static func save(_ session: Account.Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> Account.Session? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Account.Session.self, from: data)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
