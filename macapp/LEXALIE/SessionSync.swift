import Foundation

/// The sessions, their cards, your questions and your profile in your account (block INSIEME 6), so
/// every device signed in with it sees the same. Signed in once, it stays signed in (Account); without
/// the network everything waits here and goes when it's back. Row level security on the server lets
/// each person read and write only their own rows (afterhear: supabase/tests/together.sql).
@MainActor
final class SessionSync {
    static let shared = SessionSync()

    private let defaults = UserDefaults.standard
    private var pending: Task<Void, Never>?
    private var timer: Timer?
    private var running = false
    private var lastLive = Date.distantPast

    /// Snippets already in storage ("<session>/<moment>.m4a").
    private var uploaded: Set<String> {
        get { Set(defaults.stringArray(forKey: "snippetsUploaded") ?? []) }
        set { defaults.set(Array(newValue), forKey: "snippetsUploaded") }
    }
    /// Sessions forgotten here, still to remove from the account.
    private var toForget: Set<String> {
        get { Set(defaults.stringArray(forKey: "sessionsToForget") ?? []) }
        set { defaults.set(Array(newValue), forKey: "sessionsToForget") }
    }
    private var forgetEverything: Bool {
        get { defaults.bool(forKey: "forgetEverythingPending") }
        set { defaults.set(newValue, forKey: "forgetEverythingPending") }
    }

    func boot() {
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in SessionSync.shared.schedule(after: 0) }
        }
        Task {
            if let token = await Account.shared.accessToken() { _ = try? await rpc("purge_expired", token: token) }
            schedule(after: 5)
        }
    }

    /// First sign-in on this Mac: everything it already has goes up.
    func signedIn() {
        for s in Sessions.shared.sessions { Sessions.shared.update(s) }
        uploaded = []
        Profile.shared.changed()
        schedule(after: 0)
    }

    func schedule(after seconds: Double = 4) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    /// Before a question to "Ask LEXALIE": the session going on right now reaches the account too.
    func flushLive() async {
        guard let token = await Account.shared.accessToken(), let live = Sessions.shared.current else { return }
        try? await push(live, token: token, card: false)
        lastLive = Date()
    }

    func run() async {
        guard !running, let token = await Account.shared.accessToken() else { return }
        running = true
        defer { running = false }
        do {
            if forgetEverything {
                try await removeEverything(token)
                forgetEverything = false
            }
            for id in toForget {
                try await remove(id, token: token)
                toForget.remove(id)
            }
            for s in Sessions.shared.sessions where s.dirty {
                try await push(s, token: token, card: true)
                Sessions.shared.markSynced(s.id)
            }
            if let live = Sessions.shared.current, Date().timeIntervalSince(lastLive) > 110 {
                try await push(live, token: token, card: false)
                lastLive = Date()
            }
            try await Profile.shared.push(token: token)
            try await Questions.shared.push(token: token)
        } catch {
            ErrorLog.record("sessions.sync", error)
        }
    }

    // MARK: Up

    private func push(_ s: Sessions.Session, token: String, card: Bool) async throws {
        let id = s.id.uuidString.lowercased()
        var row: [String: Any] = [
            "id": id, "kind": s.kind, "title": s.title, "people": s.people, "language": s.language,
            "device": "mac", "started_at": Self.iso(s.start),
        ]
        row["ended_at"] = s.end.map { Self.iso($0) as Any } ?? NSNull()
        row["delete_after"] = s.deleteAfter.map { Self.iso($0) as Any } ?? NSNull()
        try await rest("POST", "sessions?on_conflict=id", token: token, body: [row])
        let lines = s.lines.map { ["session_id": id, "idx": $0.i, "speaker": "", "mine": false,
                                   "start_s": $0.start, "end_s": $0.end, "text": $0.text] as [String: Any] }
        for from in stride(from: 0, to: lines.count, by: 300) {
            try await rest("POST", "turns?on_conflict=session_id,idx", token: token, body: Array(lines[from..<min(from + 300, lines.count)]))
        }
        guard card, !s.card.isEmpty || !s.asked.isEmpty, let uid = Account.shared.session?.userID else { return }
        var rows: [[String: Any]] = []
        for m in s.card {
            let line = s.lines.first { $0.i == m.line }
            var path: Any = NSNull()
            let key = "\(id)/\(m.id.uuidString.lowercased()).m4a"
            if let url = Sessions.shared.clipURL(s, m) {
                if !uploaded.contains(key), let data = try? Data(contentsOf: url) {
                    try await storage("POST", "snippets/\(uid)/\(key)", token: token, body: data, type: "audio/mp4")
                    uploaded.insert(key)
                }
                path = "\(uid)/\(key)"
            }
            let card: [String: Any] = [
                "sentence": m.sentence, "why": m.why, "meaning": m.meaning, "numbers": m.numbers, "negation": m.negation,
                "terms": m.terms.map { ["term": $0.term, "meaning": $0.meaning, "public": $0.isPublic] as [String: Any] },
                "glossary": m.glossary ?? "", "unsure": m.unsure,
            ]
            rows.append(["id": m.id.uuidString.lowercased(), "session_id": id, "start_s": line?.start ?? 0, "end_s": line?.end ?? 0,
                         "source": m.source, "quote": line?.text ?? m.sentence, "card": card, "clip": path,
                         "discarded": m.discarded, "knew": m.knew] as [String: Any])
        }
        for a in s.asked {
            let line = s.lines.first { $0.i == a.line }
            rows.append(["id": a.id.uuidString.lowercased(), "session_id": id, "start_s": line?.start ?? 0, "end_s": line?.end ?? 0,
                         "source": a.open ? "open" : "asked", "quote": a.sentence, "card": ["meaning": a.meaning] as [String: Any],
                         "clip": NSNull(), "discarded": false, "knew": false] as [String: Any])
        }
        try await rest("POST", "session_moments?on_conflict=id", token: token, body: rows)
    }

    // MARK: Forgetting

    func forget(_ id: UUID) {
        toForget.insert(id.uuidString.lowercased())
        schedule(after: 0)
    }

    func forgetAll(_ ids: [UUID]) {
        forgetEverything = true
        toForget = []
        schedule(after: 0)
    }

    private func remove(_ id: String, token: String) async throws {
        try await rest("DELETE", "sessions?id=eq.\(id)", token: token, body: nil)
        try await removeSnippets(prefix: id, token: token)
    }

    private func removeEverything(_ token: String) async throws {
        let data = try await rest("GET", "sessions?select=id", token: token, body: nil)
        let ids = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] ?? []
        for row in ids { if let id = row["id"] { try await removeSnippets(prefix: id, token: token) } }
        try await rpc("forget_everything", token: token)
        uploaded = []
    }

    /// The snippets of one session, listed then deleted (storage needs the names).
    private func removeSnippets(prefix session: String, token: String) async throws {
        guard let uid = Account.shared.session?.userID else { return }
        let listed = try await storageJSON("POST", "list/snippets", token: token, body: ["prefix": "\(uid)/\(session)/", "limit": 1000])
        let names = (listed as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.map { "\(uid)/\(session)/\($0)" }
        if !names.isEmpty { _ = try await storageJSON("DELETE", "snippets", token: token, body: ["prefixes": names]) }
        uploaded = uploaded.filter { !$0.hasPrefix(session + "/") }
    }

    // MARK: HTTP

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    @discardableResult
    func rest(_ method: String, _ path: String, token: String, body: Any?) async throws -> Data {
        guard let url = URL(string: Account.supabaseURL + "/rest/v1/" + path) else { throw AccountError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(Account.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if method == "POST", path.contains("on_conflict") { request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AccountError.http(status) }
        return data
    }

    @discardableResult
    private func rpc(_ name: String, token: String) async throws -> Data {
        try await rest("POST", "rpc/\(name)", token: token, body: [String: Any]())
    }

    private func storage(_ method: String, _ path: String, token: String, body: Data, type: String) async throws {
        guard let url = URL(string: Account.supabaseURL + "/storage/v1/object/" + path) else { throw AccountError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Account.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(type, forHTTPHeaderField: "content-type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.httpBody = body
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw AccountError.http(0) }
    }

    private func storageJSON(_ method: String, _ path: String, token: String, body: [String: Any]) async throws -> Any? {
        guard let url = URL(string: Account.supabaseURL + "/storage/v1/object/" + path) else { throw AccountError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Account.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw AccountError.http(0) }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

