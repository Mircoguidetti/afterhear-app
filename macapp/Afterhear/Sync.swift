import AVFoundation
import Foundation

/// Keeps this Mac and the web app in step, through Supabase.
/// Up: moments (text only, never audio), people, known words, listening time.
/// Down: reviews done on the web ("I know it" / "Again"), so the Mac doesn't ask again.
@MainActor
final class Sync: ObservableObject {
    static let shared = Sync()

    @Published private(set) var lastSync: Date?
    @Published private(set) var status: String?
    @Published private(set) var running = false

    private let defaults = UserDefaults.standard
    private var pending: Task<Void, Never>?
    private var timer: Timer?
    private var store: Store { AppModel.shared.store }

    /// Moments changed on this Mac and not yet sent.
    private var dirty: Set<UUID> {
        get { Set((defaults.stringArray(forKey: "syncDirty") ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString), forKey: "syncDirty") }
    }
    private var removedPeople: Set<String> {
        get { Set(defaults.stringArray(forKey: "syncRemovedPeople") ?? []) }
        set { defaults.set(Array(newValue), forKey: "syncRemovedPeople") }
    }
    private var lastPull: String? {
        get { defaults.string(forKey: "syncLastPull") }
        set { defaults.set(newValue, forKey: "syncLastPull") }
    }

    func boot() {
        store.onChange = { change in Task { @MainActor in Sync.shared.changed(change) } }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in Sync.shared.schedule(after: 0) }
        }
        schedule(after: 2)
    }

    /// First sign-in on this Mac: send everything it already has.
    func signedIn() {
        dirty = Set(store.moments.map(\.id))
        lastPull = nil
        schedule(after: 0)
    }

    func changed(_ change: StoreChange) {
        switch change {
        case .moment(let id): dirty.insert(id)
        case .personRemoved(let name): removedPeople.insert(name)
        case .deletedAll:
            dirty = []
            Memory.shared.clear()
            Reports.shared.clear()
            Task { await deleteEverythingRemote() }
            return
        case .people, .known, .listening: break
        }
        schedule(after: 3)
    }

    func schedule(after seconds: Double) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    // MARK: The sync itself

    private func run() async {
        guard !running, let token = await Account.shared.accessToken() else { return }
        running = true
        defer { running = false }
        do {
            try await pushMoments(token)
            try await pushPeople(token)
            try await pushKnown(token)
            try await pushListening(token)
            try await pushCalls(token)
            try await pullReviews(token)
            try await Memory.shared.sync(token: token)
            lastSync = Date()
            status = nil
        } catch {
            status = String(localized: "Couldn't sync. Will try again soon.")
        }
    }

    /// Clips uploaded to storage (only with "Sync the real voice" on), by moment id.
    private var uploaded: Set<String> {
        get { Set(defaults.stringArray(forKey: "uploadedClips") ?? []) }
        set { defaults.set(Array(newValue), forKey: "uploadedClips") }
    }

    /// The real voice in your account, when you chose it (§ 5.9): m4a, 7 days, then deleted.
    private func syncClips(_ token: String) async {
        guard let uid = Account.shared.session?.userID else { return }
        let week = Date().addingTimeInterval(-Double(Store.clipDays) * 86_400)
        // Old ones go.
        for moment in store.moments where uploaded.contains(moment.id.uuidString.lowercased()) && moment.date < week {
            let id = moment.id.uuidString.lowercased()
            _ = try? await storage("DELETE", "clips/\(uid)/\(id).m4a", token: token)
            uploaded.remove(id)
            dirty.insert(moment.id)
        }
        guard defaults.bool(forKey: Key.syncAudio) else { return }
        for moment in store.moments where moment.date >= week && !uploaded.contains(moment.id.uuidString.lowercased()) {
            guard let wav = store.clipURL(moment), let m4a = await Self.compress(wav) else { continue }
            let id = moment.id.uuidString.lowercased()
            if (try? await storage("POST", "clips/\(uid)/\(id).m4a", token: token, body: try Data(contentsOf: m4a), type: "audio/mp4")) != nil {
                uploaded.insert(id)
                dirty.insert(moment.id)
            }
            try? FileManager.default.removeItem(at: m4a)
        }
    }

    private static func compress(_ wav: URL) async -> URL? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A) else { return nil }
        export.outputURL = out
        export.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        return export.status == .completed ? out : nil
    }

    @discardableResult
    private func storage(_ method: String, _ path: String, token: String, body: Data? = nil, type: String? = nil) async throws -> Data {
        guard let url = URL(string: Account.supabaseURL + "/storage/v1/object/" + path) else { throw AccountError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Account.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let type { request.setValue(type, forHTTPHeaderField: "content-type") }
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw AccountError.http(0) }
        return data
    }

    private func pushMoments(_ token: String) async throws {
        await syncClips(token)
        let ids = dirty
        let clips = uploaded
        let rows = store.moments.filter { ids.contains($0.id) }.map { MomentRow($0, hasClip: clips.contains($0.id.uuidString.lowercased())) }
        for start in stride(from: 0, to: rows.count, by: 50) {
            let batch = Array(rows[start..<min(start + 50, rows.count)])
            try await request("POST", "moments?on_conflict=id", token: token, body: try encoder.encode(batch),
                              prefer: "resolution=merge-duplicates,return=minimal")
        }
        dirty.subtract(ids)
    }

    private func pushPeople(_ token: String) async throws {
        let rows = store.people.map { ["name": $0.name, "accent": Person.english($0.accent)] }
        if !rows.isEmpty {
            try await request("POST", "people?on_conflict=user_id,name", token: token,
                              body: try JSONSerialization.data(withJSONObject: rows),
                              prefer: "resolution=merge-duplicates,return=minimal")
        }
        for name in removedPeople where !store.people.contains(where: { $0.name == name }) {
            try await request("DELETE", "people?name=eq.\(name.urlQuery)", token: token)
        }
        removedPeople = []
    }

    private func pushKnown(_ token: String) async throws {
        let words = Array(store.known)
        for start in stride(from: 0, to: words.count, by: 200) {
            let batch = words[start..<min(start + 200, words.count)].map { ["text": $0] }
            try await request("POST", "known_items?on_conflict=user_id,text", token: token,
                              body: try JSONSerialization.data(withJSONObject: batch),
                              prefer: "resolution=ignore-duplicates,return=minimal")
        }
    }

    private func pushListening(_ token: String) async throws {
        let hours = store.listeningHours
        let rows = store.listening.map { ["day": $0.key, "seconds": Int($0.value), "hours": (hours[$0.key] ?? [:]).mapValues { Int($0) }] as [String: Any] }
        guard !rows.isEmpty else { return }
        try await request("POST", "listening?on_conflict=user_id,day", token: token,
                          body: try JSONSerialization.data(withJSONObject: rows),
                          prefer: "resolution=merge-duplicates,return=minimal")
    }

    /// The calendar changed: send the calls soon (at most once a minute anyway, from the calendar timer).
    func calendarChanged() {
        let ids = CalendarWatch.shared.calls.map { "\($0.id)\($0.people)\($0.title)" }.joined()
        guard ids != lastCalls else { return }
        lastCalls = ids
        schedule(after: 3)
    }
    private var lastCalls = ""
    private var sentCalls = ""

    /// Calls coming up and just done: title, time and the people you track. Never the guest list.
    private func pushCalls(_ token: String) async throws {
        guard lastCalls != sentCalls else { return }
        let formatter = ISO8601DateFormatter()
        let rows: [[String: Any]] = CalendarWatch.shared.calls.map { call in
            ["id": call.id, "source": "mac", "title": String(call.title.prefix(200)),
             "starts_at": formatter.string(from: call.start), "ends_at": formatter.string(from: call.end),
             "people": call.people, "guests": min(call.guests, 500)]
        }
        if !rows.isEmpty {
            try await request("POST", "calendar_events?on_conflict=user_id,id", token: token,
                              body: try JSONSerialization.data(withJSONObject: rows),
                              prefer: "resolution=merge-duplicates,return=minimal")
        }
        sentCalls = lastCalls
    }

    /// A call report: short snippets, never the call (docs/BRAIN.md § 5.2).
    func saveCallReport(_ saved: SavedReport) {
        Task {
            guard let token = await Account.shared.accessToken() else { return }
            let f = ISO8601DateFormatter()
            var row: [String: Any] = [
                "call_id": saved.id, "title": String(saved.title.prefix(200)), "people": saved.people,
                "started_at": f.string(from: saved.start), "ended_at": f.string(from: saved.end),
                "score": saved.score, "turns": saved.turns,
            ]
            if let report = saved.report, let data = try? JSONEncoder().encode(report),
               let object = try? JSONSerialization.jsonObject(with: data) { row["report"] = object }
            _ = try? await request("POST", "call_reports?on_conflict=user_id,call_id", token: token,
                                   body: try JSONSerialization.data(withJSONObject: [row]),
                                   prefer: "resolution=merge-duplicates,return=minimal")
        }
    }

    /// Reviews done on the web: apply them here unless this Mac has newer changes waiting.
    private func pullReviews(_ token: String) async throws {
        var path = "moments?select=id,review,step,due_at,updated_at&order=updated_at.asc&limit=1000"
        if let lastPull { path += "&updated_at=gt.\(lastPull.urlQuery)" }
        let data = try await request("GET", path, token: token)
        struct Remote: Decodable {
            let id: String
            let review: String?
            let step: Int?
            let due_at: String?
            let updated_at: String
        }
        let rows = try JSONDecoder().decode([Remote].self, from: data)
        let waiting = dirty
        for row in rows {
            guard let id = UUID(uuidString: row.id), !waiting.contains(id) else { continue }
            store.applyRemoteReview(id: id, review: row.review.flatMap(Review.init(rawValue:)),
                                    step: row.step, due: row.due_at.flatMap(Sync.parseDate))
        }
        if let newest = rows.last?.updated_at { lastPull = newest }
    }

    /// "Delete everything" on the Mac also empties the account (the web app has its own button too).
    private func deleteEverythingRemote() async {
        guard let token = await Account.shared.accessToken() else { return }
        for table in ["call_reports?call_id=not.is.null", "signals?id=not.is.null", "items?key=not.is.null", "calendar_events?id=not.is.null", "moments?id=not.is.null", "people?name=not.is.null", "known_items?text=not.is.null", "listening?day=not.is.null"] {
            _ = try? await request("DELETE", table, token: token)
        }
        lastPull = nil
    }

    // MARK: HTTP

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    @discardableResult
    private func request(_ method: String, _ path: String, token: String, body: Data? = nil, prefer: String? = nil) async throws -> Data {
        guard let url = URL(string: Account.supabaseURL + "/rest/v1/" + path) else { throw AccountError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Account.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AccountError.http(status) }
        return data
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// One moment as the database stores it (see supabase/migrations/20260930090000_app_core.sql).
private struct MomentRow: Encodable {
    let id: String
    let occurred_at: Date
    let device = "mac"
    let context: String?
    let trigger: String?
    let person_name: String?
    let transcript: String
    let sent: String
    let translation: String
    let pieces: [Piece]
    let label: String?
    let review: String?
    let due_at: Date?
    let step: Int
    let delay_seconds: Double?
    let provider: String
    let latency_ms: Int
    let call_id: String?
    let call_title: String?
    let intent: String?
    let show: String?
    let has_clip: Bool

    init(_ m: Moment, hasClip: Bool = false) {
        id = m.id.uuidString.lowercased()
        occurred_at = m.date
        trigger = m.trigger
        context = m.context
        person_name = m.with
        transcript = String(m.transcript.prefix(4000))
        sent = String(m.sent.prefix(4000))
        translation = String(m.translation.prefix(4000))
        pieces = m.pieces
        label = m.label?.key
        review = m.review?.rawValue
        due_at = m.due
        step = min(m.step ?? 0, 20)
        delay_seconds = m.delay
        provider = String(m.provider.prefix(40))
        latency_ms = m.latencyMs
        call_id = m.call
        call_title = m.callTitle.map { String($0.prefix(200)) }
        intent = m.intent.map { String($0.prefix(600)) }
        show = m.show.map { String($0.prefix(200)) }
        has_clip = hasClip
    }

    enum CodingKeys: String, CodingKey {
        case id, occurred_at, device, context, trigger, person_name, transcript, sent, translation, pieces
        case label, review, due_at, step, delay_seconds, provider, latency_ms, call_id, call_title, intent, show, has_clip
    }

    /// Every key on every row, nulls included: PostgREST wants the same keys across a batch.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(occurred_at, forKey: .occurred_at)
        try c.encode(device, forKey: .device)
        try c.encode(context, forKey: .context)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(person_name, forKey: .person_name)
        try c.encode(transcript, forKey: .transcript)
        try c.encode(sent, forKey: .sent)
        try c.encode(translation, forKey: .translation)
        try c.encode(pieces, forKey: .pieces)
        try c.encode(label, forKey: .label)
        try c.encode(review, forKey: .review)
        try c.encode(due_at, forKey: .due_at)
        try c.encode(step, forKey: .step)
        try c.encode(delay_seconds, forKey: .delay_seconds)
        try c.encode(provider, forKey: .provider)
        try c.encode(latency_ms, forKey: .latency_ms)
        try c.encode(call_id, forKey: .call_id)
        try c.encode(call_title, forKey: .call_title)
        try c.encode(intent, forKey: .intent)
        try c.encode(show, forKey: .show)
        try c.encode(has_clip, forKey: .has_clip)
    }
}

private extension String {
    var urlQuery: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}
