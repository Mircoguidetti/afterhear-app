import Foundation

/// The memory loop on the Mac (docs/BRAIN.md § 12). The brain itself lives on the server
/// (web/src/lib/memory.ts, one for every device): the Mac sends it signals and gets back,
/// for every expression, how well you understand it right now.
///
/// The Mac uses that to:
/// - stay quiet about what you clearly know now (the help that fades);
/// - watch for what you knew once and may have forgotten;
/// - notice the second encounter: an expression you missed comes back in a call or a video,
///   and this time you don't tap. That's a clean understanding, and your memory of it grows.
///
/// Only signals leave the Mac: which expression, what happened, when. Never the conversation.
@MainActor
final class Memory: ObservableObject {
    static let shared = Memory()

    struct Item: Codable {
        let key: String
        let text: String
        let cause: String?
        let level: String?
        let state: String
        let understanding: Double
        let lapses: Int
        let reps: Int
        let gloss: String?
        let meaning: String?
        var due_at: String? = nil
        var avoid: String? = nil
        var challenge: Bool? = nil
    }

    struct Signal: Codable {
        let kind: String
        let text: String
        var gloss: String?
        var meaning: String?
        var cause: String?
        var level: String?
        let at: String
        var context: String?
        var person: String?
        var device = "mac"
        var moment_id: String?
        var avoid: String?
    }

    @Published private(set) var items: [String: Item] = [:]
    /// The account says: in calls keep text only, no audio clip.
    @Published private(set) var callsTextOnly = false
    /// Your name on the account, to notice when someone asks you something (stays on this Mac).
    private(set) var displayName: String? = UserDefaults.standard.string(forKey: "accountDisplayName")
    /// Your words from the web app (§ 7.4), merged with the ones typed on this Mac.
    private(set) var accountDictionary: [String] = UserDefaults.standard.stringArray(forKey: "accountDictionary") ?? []

    /// Your words (work, city, people): the recogniser expects them, the AI never explains them.
    var dictionary: [String] {
        let typed = (defaults.string(forKey: Key.dictionary) ?? "").split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        return (typed + accountDictionary).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Where you are now ("video", "song", "call"): songs weigh differently in your model (§ 17.8).
    var context: String?

    private let defaults = UserDefaults.standard
    private let itemsURL: URL
    private var queue: [Signal] {
        get { (defaults.data(forKey: "memoryQueue")).flatMap { try? JSONDecoder().decode([Signal].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(Array(newValue.suffix(2000))), forKey: "memoryQueue") }
    }
    /// Expressions heard again, waiting to see whether you tap. No tap in time = a clean encounter.
    private var pending: [String: Date] = [:]
    private var lastTap = Date.distantPast
    private var countedOn: [String: String] = [:]
    private static let quietSeconds: TimeInterval = 45

    private init() {
        itemsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LEXALIE/items.json")
        if let data = try? Data(contentsOf: itemsURL), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = Dictionary(saved.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Same rule as the server: "Crack on!" and "crack on" are one expression.
    static func key(_ text: String) -> String {
        let punctuation = CharacterSet(charactersIn: "“”\"«»()[]{}.,!?;:…")
        let spaced = text.lowercased().precomposedStringWithCompatibilityMapping.unicodeScalars
            .map { punctuation.contains($0) ? " " : String($0) }.joined()
        return String(spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
    }

    // MARK: Signals

    func record(_ kind: String, pieces: [Piece], moment: Moment?) {
        let at = ISO8601DateFormatter().string(from: Date())
        let new = pieces.filter { !$0.text.isEmpty }.map { p in
            Signal(kind: kind, text: String(p.text.prefix(200)), gloss: p.gloss, meaning: p.meaning, cause: p.cause, level: p.level,
                   at: at, context: moment?.context, person: moment?.with, moment_id: moment?.id.uuidString.lowercased())
        }
        guard !new.isEmpty else { return }
        queue += new
        Sync.shared.schedule(after: 5)
    }

    func record(_ kind: String, item: Item, moment: Moment? = nil) {
        queue += [Signal(kind: kind, text: item.text, gloss: item.gloss, meaning: item.meaning, cause: item.cause, level: item.level,
                         at: ISO8601DateFormatter().string(from: Date()), context: moment?.context ?? context, person: moment?.with,
                         moment_id: moment?.id.uuidString.lowercased())]
        Sync.shared.schedule(after: 5)
    }

    /// Your own speaking, from the call report: the better way to say it, and what to avoid.
    func recordSpeaking(text: String, avoid: String?, meaning: String) {
        queue += [Signal(kind: "tap", text: String(text.prefix(200)), meaning: String(meaning.prefix(1000)), cause: "speaking",
                         at: ISO8601DateFormatter().string(from: Date()), context: "call", avoid: avoid.map { String($0.prefix(200)) })]
        Sync.shared.schedule(after: 5)
    }

    /// What you said lately: did you use the better phrase, or slip back to the old one? (§ 4.4, § 12.7)
    func scanMine(_ recent: String) {
        let hay = " " + Self.key(recent) + " "
        guard hay.count > 3 else { return }
        let day = Store.dayKey()
        for item in items.values where (item.cause == "speaking" || item.challenge == true) && countedOn["me:" + item.key] != day {
            if item.key.count >= 3, hay.contains(" " + item.key + " ") {
                countedOn["me:" + item.key] = day
                record("used", item: item)
            } else if let avoid = item.avoid.map(Self.key), avoid.count >= 3, hay.contains(" " + avoid + " ") {
                countedOn["me:" + item.key] = day
                record("avoid_used", item: item)
            }
        }
    }

    /// A tap: whatever was waiting to count as understood wasn't.
    func tapped() {
        lastTap = Date()
        pending.removeAll()
    }

    // MARK: What the model says

    /// Clearly yours now: the AI doesn't explain these any more (the help fades, § 8.5).
    var knownWell: [String] {
        items.values.filter { $0.reps > 0 && ($0.state == "promoted" || $0.understanding >= 0.9) }.map(\.text)
    }

    /// Known once, maybe forgotten: the AI prefers them when they show up (§ 12.5).
    var watch: [String] {
        items.values.filter { $0.reps > 0 && $0.understanding < 0.75 }
            .sorted { ($0.lapses, -$0.understanding) > ($1.lapses, -$1.understanding) }
            .prefix(200).map(\.text)
    }

    /// How hard a sentence is for you (for Ranking): an expression you're learning = 1,
    /// one you know well = 0.15, nothing we know about = 0.4.
    var hardness: (String) -> Double {
        let learning = watch.map(Self.key).filter { $0.count >= 4 }
        let mastered = knownWell.map(Self.key).filter { $0.count >= 4 }
        return { text in
            let k = " " + Self.key(text) + " "
            if learning.contains(where: { k.contains(" " + $0 + " ") }) { return 1 }
            if mastered.contains(where: { k.contains(" " + $0 + " ") }) { return 0.15 }
            return 0.4
        }
    }

    /// What trips you up most, for your model's guesses (§ 18.2).
    var weakCauses: [String] {
        var n: [String: Int] = [:]
        for i in items.values where i.state != "promoted" { if let c = i.cause, c != "speaking" { n[c, default: 0] += 1 + i.lapses } }
        return n.sorted { $0.value > $1.value }.prefix(3).map(\.key)
    }

    /// Expressions you learned before that appear in these words (for "Not in the list?").
    func knownBefore(in text: String) -> [Item] {
        let hay = " " + Self.key(text) + " "
        return items.values.filter { $0.reps > 0 && $0.key.count >= 4 && hay.contains(" " + $0.key + " ") }
            .sorted { $0.understanding < $1.understanding }
    }

    // MARK: The second encounter

    struct SmoothEncounter: Codable { let at: Date; let text: String }

    /// Expressions you once missed and then understood without a tap, with when (for "you got it by yourself").
    private var smoothLog: [SmoothEncounter] {
        get { (defaults.data(forKey: "smoothLog")).flatMap { try? JSONDecoder().decode([SmoothEncounter].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "smoothLog") }
    }

    func smooth(from: Date, to: Date) -> [String] {
        var seen = Set<String>()
        return smoothLog.filter { $0.at >= from && $0.at <= to }.map(\.text).filter { seen.insert(Self.key($0)).inserted }
    }

    func smoothCount(from: Date, to: Date) -> Int { smooth(from: from, to: to).count }

    /// Called every few seconds with what the others said recently.
    func scan(_ recent: String) {
        let now = Date()
        let day = Store.dayKey(now)
        // Heard a while ago, no tap since: understood.
        for (key, heard) in pending where now.timeIntervalSince(heard) >= Self.quietSeconds {
            pending[key] = nil
            guard heard > lastTap, countedOn[key] != day, let item = items[key] else { continue }
            countedOn[key] = day
            record("encounter_smooth", item: item)
            var log = smoothLog
            log.append(SmoothEncounter(at: heard, text: item.text))
            smoothLog = Array(log.suffix(300))
        }
        let hay = " " + Self.key(recent) + " "
        guard hay.count > 2 else { return }
        for item in items.values where item.reps > 0 && item.key.count >= 5 && pending[item.key] == nil && countedOn[item.key] != day {
            if hay.contains(" " + item.key + " ") { pending[item.key] = now }
        }
    }

    // MARK: Sync

    func sync(token: String) async throws {
        guard let base = URL(string: (defaults.string(forKey: Key.webApp) ?? AppSettings.defaultWebApp).trimmingCharacters(in: .whitespaces)) else { return }
        let url = base.appendingPathComponent("api/memory")
        let outgoing = queue
        if !outgoing.isEmpty {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(["signals": Array(outgoing.prefix(200))])
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw AccountError.http(0) }
            queue = Array(queue.dropFirst(min(200, outgoing.count)))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw AccountError.http(0) }
        struct Reply: Decodable {
            struct Settings: Decodable { let calls_text_only: Bool; let display_name: String?; let dictionary: [String]? }
            let items: [Item]
            let settings: Settings?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        items = Dictionary(reply.items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        callsTextOnly = reply.settings?.calls_text_only ?? false
        displayName = reply.settings?.display_name
        defaults.set(displayName, forKey: "accountDisplayName")
        accountDictionary = reply.settings?.dictionary ?? []
        defaults.set(accountDictionary, forKey: "accountDictionary")
        AppModel.shared.store.applyMemory(items)
        if let data = try? JSONEncoder().encode(reply.items) { try? data.write(to: itemsURL, options: .atomic) }
    }

    func clear() {
        queue = []
        items = [:]
        pending = [:]
        try? FileManager.default.removeItem(at: itemsURL)
    }
}
