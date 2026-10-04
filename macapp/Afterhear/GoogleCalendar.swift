import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UserNotifications

/// Google Calendar, connected directly (owner, 03/10: many people use Google Calendar only in the
/// browser, never added to the Calendar app on the Mac). It reads the calls of the next day and a
/// half, every few minutes, and writes only one thing, when you say yes: the line telling the
/// others that you use Afterhear, in the description of a call you organise (PIANO.md, N2). Google's sign-in for apps (PKCE, no secret in the app); the refresh
/// token stays in this Mac's Keychain. Like the Calendar app: only the call's title, time and the
/// people you track reach your account, never the guest list or the notes.
@MainActor
final class GoogleCalendar: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleCalendar()

    /// An "iOS" OAuth client of Afterhear's Google Cloud project (public, not a secret): docs/OWNER-TODO.md.
    static let clientID = "999371817319-0s9d3e49r0glln3ar6anasdnhnldnpit.apps.googleusercontent.com" // also overridable in Settings → Advanced
    private static let scope = "https://www.googleapis.com/auth/calendar.events"

    struct Event: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        /// The other guests' names (or the part of their email before the @).
        let guests: [String]
        let organizerIsMe: Bool
        /// A video link (Meet, Zoom, Teams…) or other guests: a call.
        let isCall: Bool
        /// The description already says Afterhear is in the call.
        var hasNotice = false
    }

    @Published private(set) var connected = GoogleKeychain.load() != nil
    @Published private(set) var events: [Event] = []
    @Published var message: String?

    private var accessToken: (token: String, until: Date)?
    /// The window Google's sign-in sheet hangs from: set on the main thread before it opens.
    nonisolated(unsafe) private var anchorWindow: NSWindow?
    private var session: ASWebAuthenticationSession?
    private var timer: Timer?

    var configuredClientID: String {
        let custom = UserDefaults.standard.string(forKey: "googleClientID")?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? Self.clientID : custom
    }

    /// "com.googleusercontent.apps.123-abc": Google's redirect for an app's client.
    private var scheme: String {
        let id = configuredClientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps." + id
    }

    var available: Bool { !configuredClientID.isEmpty }

    func start() {
        guard connected else { return }
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await GoogleCalendar.shared.refresh() }
        }
    }

    // MARK: Connecting

    func connect() {
        guard available else {
            message = String(localized: "Google Calendar isn't set up in this build yet.")
            return
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let redirect = scheme + ":/oauth2redirect"
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: configuredClientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = parts.url else { return }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
            Task { @MainActor in
                let shared = GoogleCalendar.shared
                shared.session = nil
                guard error == nil, let callback,
                      let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                    if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { return }
                    shared.message = String(localized: "Google didn't connect. Try again.")
                    return
                }
                await shared.exchange(code: code, verifier: verifier, redirect: redirect)
            }
        }
        anchorWindow = NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    func disconnect() {
        GoogleKeychain.delete()
        accessToken = nil
        events = []
        connected = false
        timer?.invalidate()
        CalendarWatch.shared.refresh()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchorWindow!
    }

    private func exchange(code: String, verifier: String, redirect: String) async {
        do {
            let data = try await tokenRequest([
                "client_id": configuredClientID, "code": code, "code_verifier": verifier,
                "grant_type": "authorization_code", "redirect_uri": redirect,
            ])
            struct Token: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double? }
            let token = try JSONDecoder().decode(Token.self, from: data)
            guard let refresh = token.refresh_token else { message = String(localized: "Google didn't give lasting access. Try again."); return }
            GoogleKeychain.save(refresh)
            accessToken = (token.access_token, Date().addingTimeInterval((token.expires_in ?? 3600) - 60))
            connected = true
            message = nil
            start()
            // The calendar prep turns on with it: that's why you connected it.
            if !CalendarWatch.shared.enabled { CalendarWatch.shared.enabled = true }
        } catch {
            message = String(localized: "Google didn't connect. Try again.")
        }
    }

    // MARK: Reading

    private func token() async -> String? {
        if let accessToken, accessToken.until > Date() { return accessToken.token }
        guard let refresh = GoogleKeychain.load() else { return nil }
        do {
            let data = try await tokenRequest(["client_id": configuredClientID, "refresh_token": refresh, "grant_type": "refresh_token"])
            struct Token: Decodable { let access_token: String; let expires_in: Double? }
            let token = try JSONDecoder().decode(Token.self, from: data)
            accessToken = (token.access_token, Date().addingTimeInterval((token.expires_in ?? 3600) - 60))
            return token.access_token
        } catch GoogleError.http(let status) where status == 400 || status == 401 {
            // Access was removed in the Google account: say so once and stop.
            disconnect()
            message = String(localized: "Google Calendar was disconnected. Connect it again to keep the prep before calls.")
            return nil
        } catch {
            return nil
        }
    }

    func refresh() async {
        guard connected, let token = await token() else { return }
        let iso = ISO8601DateFormatter()
        let now = Date()
        var parts = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        parts.queryItems = [
            URLQueryItem(name: "timeMin", value: iso.string(from: now.addingTimeInterval(-6 * 3600))),
            URLQueryItem(name: "timeMax", value: iso.string(from: now.addingTimeInterval(36 * 3600))),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "60"),
        ]
        guard let url = parts.url else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(EventList.self, from: data) else { return }
        let fresh = list.items.compactMap(Self.event)
        if fresh != events {
            events = fresh
            CalendarWatch.shared.refresh()
        }
        await proposeNotice(fresh)
    }

    // MARK: Writing the line (N2)

    /// Calls you organise that we already offered the line for: offered once, yes or no.
    private var offered: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "noticeOffered") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: "noticeOffered") }
    }

    /// A call you organise, not started yet, without the line: a notification only for you offers it.
    private func proposeNotice(_ events: [Event]) async {
        guard ParticipantNotice.current != .off else { return }
        let now = Date()
        for event in events where event.organizerIsMe && event.isCall && !event.hasNotice && event.start > now && !offered.contains(event.id) {
            offered.insert(event.id)
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let add = UNNotificationAction(identifier: "calendar.addNotice", title: String(localized: "Add it"), options: [])
            let category = UNNotificationCategory(identifier: "calendarNotice", actions: [add], intentIdentifiers: [])
            let existing = await center.notificationCategories()
            center.setNotificationCategories(existing.filter { $0.identifier != category.identifier }.union([category]))
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Tell the guests of “\(event.title)” in the invitation?")
            content.body = ParticipantNotice.message()
            content.categoryIdentifier = category.identifier
            content.userInfo = ["kind": "calendarNotice", "event": event.id]
            try? await center.add(UNNotificationRequest(identifier: "calendarNotice-\(event.id)", content: content, trigger: nil))
        }
    }

    /// Adds the line at the end of the event's description, leaving the rest as it is.
    func addNotice(to eventID: String) async {
        guard let token = await token(),
              let id = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(id)") else { return }
        var get = URLRequest(url: url, timeoutInterval: 15)
        get.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct Item: Decodable { let description: String? }
        guard let (data, response) = try? await URLSession.shared.data(for: get),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let item = try? JSONDecoder().decode(Item.self, from: data) else { return }
        let old = item.description ?? ""
        guard !old.contains("Afterhear") else { return }
        let line = ParticipantNotice.message()
        var patch = URLRequest(url: url, timeoutInterval: 15)
        patch.httpMethod = "PATCH"
        patch.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        patch.setValue("application/json", forHTTPHeaderField: "content-type")
        patch.httpBody = try? JSONSerialization.data(withJSONObject: ["description": old.isEmpty ? line : old + "\n\n" + line])
        let status = ((try? await URLSession.shared.data(for: patch))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 {
            // Connected before Afterhear could write: Google needs a yes again.
            message = String(localized: "To add the line, connect Google Calendar again and allow editing events.")
        } else if status == 200 {
            await refresh()
        }
    }

    private struct EventList: Decodable {
        struct Item: Decodable {
            struct When: Decodable { let dateTime: String? }
            struct Person: Decodable {
                let email: String?
                let displayName: String?
                /// Google's "self": this guest is you.
                let isSelf: Bool?
                enum CodingKeys: String, CodingKey { case email, displayName, isSelf = "self" }
            }
            struct Conference: Decodable {
                struct Entry: Decodable { let uri: String? }
                let entryPoints: [Entry]?
            }
            let id: String
            let status: String?
            let summary: String?
            let location: String?
            let description: String?
            let hangoutLink: String?
            let start: When
            let end: When
            let attendees: [Person]?
            let organizer: Person?
            let conferenceData: Conference?
        }
        let items: [Item]
    }

    private static let callLinks = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "facetime.apple.com", "slack.com/huddle"]

    private static func event(_ item: EventList.Item) -> Event? {
        // All-day events have only a date: not a call.
        guard item.status != "cancelled", let s = item.start.dateTime, let e = item.end.dateTime,
              let start = parse(s), let end = parse(e) else { return nil }
        let others = (item.attendees ?? []).filter { $0.isSelf != true }
        let guests = others.map { person -> String in
            if let name = person.displayName, !name.isEmpty, !name.contains("@") { return name }
            let email = person.email ?? ""
            return email.components(separatedBy: "@").first ?? email
        }
        let links = ([item.hangoutLink, item.location, item.description].compactMap { $0 }
                     + (item.conferenceData?.entryPoints ?? []).compactMap(\.uri)).joined(separator: " ").lowercased()
        let isCall = !others.isEmpty || callLinks.contains { links.contains($0) }
        return Event(id: item.id, title: item.summary ?? "", start: start, end: end, guests: guests,
                     organizerIsMe: item.organizer?.isSelf ?? others.isEmpty, isCall: isCall,
                     hasNotice: item.description?.contains("Afterhear") ?? false)
    }

    private static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private func tokenRequest(_ form: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var parts = URLComponents()
        parts.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw GoogleError.http(status) }
        return data
    }
}

enum GoogleError: Error {
    case http(Int)
}

/// The Google refresh token in the macOS Keychain, readable only by this app.
enum GoogleKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.afterhear.mac.google-calendar",
        kSecAttrAccount as String: "refresh",
    ]

    static func save(_ token: String) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
