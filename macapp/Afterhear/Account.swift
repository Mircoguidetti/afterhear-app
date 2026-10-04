import AppKit
import CryptoKit
import Foundation
import Security

/// Your Afterhear account on this Mac: the same one as the web app.
/// Google and the email link go through the browser, land on our "signed in" page and come back on afterhear://auth-callback
/// (PKCE: the one-time code is useless without the secret that never leaves this Mac).
/// The session lives in the Keychain.
@MainActor
final class Account: ObservableObject {
    static let shared = Account()

    static let supabaseURL = "https://yybnjnixekolomyghioo.supabase.co"
    static let publishableKey = "sb_publishable_cJUXbz2kHWKg4sjxxTi3Sw_MYJdgSnk"
    static let callback = "afterhear://auth-callback"
    /// Where the browser lands after Google or the email link: a page that says "you're signed in"
    /// and hands the code on to afterhear://auth-callback, so the tab doesn't sit on Google's spinner.
    static let signedInPage = "https://asaid-nine.vercel.app/signed-in.html"

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

    var signedIn: Bool { session != nil }

    private var verifier: String? {
        get { UserDefaults.standard.string(forKey: "pkceVerifier") }
        set { UserDefaults.standard.set(newValue, forKey: "pkceVerifier") }
    }

    private init() {
        session = Keychain.load()
    }

    // MARK: Signing in

    func signInWithGoogle() {
        let challenge = newChallenge()
        var parts = URLComponents(string: Self.supabaseURL + "/auth/v1/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: Self.signedInPage),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        message = String(localized: "Finish signing in in your browser.")
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }

    func sendMagicLink(email: String) async {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { message = String(localized: "Enter a valid email."); return }
        let challenge = newChallenge()
        working = true
        defer { working = false }
        do {
            var parts = URLComponents(string: Self.supabaseURL + "/auth/v1/otp")!
            parts.queryItems = [URLQueryItem(name: "redirect_to", value: Self.signedInPage)]
            _ = try await post(parts.url!, body: [
                "email": email, "create_user": true,
                "code_challenge": challenge, "code_challenge_method": "s256",
            ])
            message = String(localized: "We sent a link to \(email). Open it on this Mac.")
        } catch {
            message = String(localized: "We couldn't send the link. Try again in a minute.")
        }
    }

    func signIn(email: String, password: String) async {
        working = true
        defer { working = false }
        do {
            let data = try await post(URL(string: Self.supabaseURL + "/auth/v1/token?grant_type=password")!,
                                      body: ["email": email.trimmingCharacters(in: .whitespaces), "password": password])
            try store(data)
            message = nil
        } catch {
            message = String(localized: "Wrong email or password.")
        }
    }

    /// afterhear://auth-callback?code=… from Google or the email link.
    func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fragment = URLComponents(string: "x:?" + (url.fragment ?? ""))?.queryItems ?? []
        let value = { (name: String) in (items + fragment).first { $0.name == name }?.value }
        if let error = value("error_description") {
            message = error.replacingOccurrences(of: "+", with: " ")
            return
        }
        guard let code = value("code"), let verifier else {
            message = String(localized: "That link didn't work. Try signing in again.")
            return
        }
        Task {
            working = true
            defer { working = false }
            do {
                let data = try await post(URL(string: Self.supabaseURL + "/auth/v1/token?grant_type=pkce")!,
                                          body: ["auth_code": code, "code_verifier": verifier])
                try store(data)
                self.verifier = nil
                message = nil
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                message = String(localized: "That link has expired or was already used. Try again.")
            }
        }
    }

    func signOut() {
        if let token = session?.accessToken {
            var request = URLRequest(url: URL(string: Self.supabaseURL + "/auth/v1/logout")!)
            request.httpMethod = "POST"
            request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            Task { _ = try? await URLSession.shared.data(for: request) }
        }
        session = nil
        Keychain.delete()
    }

    // MARK: Tokens

    /// A valid access token, refreshed when it's about to expire. Nil when signed out.
    func accessToken() async -> String? {
        guard let session else { return nil }
        if session.expiresAt - 60 > Date().timeIntervalSince1970 { return session.accessToken }
        do {
            let data = try await post(URL(string: Self.supabaseURL + "/auth/v1/token?grant_type=refresh_token")!,
                                      body: ["refresh_token": session.refreshToken])
            try store(data)
            return self.session?.accessToken
        } catch AccountError.http(let status) where status == 400 || status == 401 {
            // The session was revoked (signed out elsewhere, account deleted).
            signOut()
            message = String(localized: "You were signed out. Sign in again to keep syncing.")
            return nil
        } catch {
            return nil
        }
    }

    // MARK: Helpers

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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AccountError.http(status) }
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
        let expires = token.expires_at ?? Date().timeIntervalSince1970 + (token.expires_in ?? 3600)
        let session = Session(accessToken: token.access_token, refreshToken: token.refresh_token,
                              expiresAt: expires, userID: token.user.id, email: token.user.email)
        let firstTime = self.session?.userID != session.userID
        self.session = session
        Keychain.save(session)
        if firstTime { Sync.shared.signedIn() }
    }
}

enum AccountError: Error {
    case http(Int)
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The session in the macOS Keychain, readable only by this app.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.afterhear.mac.session",
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
