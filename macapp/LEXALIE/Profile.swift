import Foundation

/// The profile that learns (block INSIEME 5): what LEXALIE knows about how you listen, so the end
/// card and "Ask LEXALIE" pick what's hard for you and skip what isn't. Three answers at the start
/// (your field, who you have calls with, the accents you hear most), then what it learns from your
/// taps, the moments you remove from a card ("not important"), "I knew it" and the questions you ask,
/// by reason. Never an opinion about people: only what helps you understand. Readable and deletable
/// in Settings ("What LEXALIE knows about you"); it goes to your account so every device knows it.
@MainActor
final class Profile: ObservableObject {
    static let shared = Profile()

    struct Facts: Codable {
        var workField = ""
        var callsWith = ""
        var accents = ""
        /// Why you asked or tapped: "word", "name", "meant", "speed", "person", "accent", "numbers"…
        var reasons: [String: Int] = [:]
        /// Kinds of moment you removed from cards, by kind.
        var notImportant: [String: Int] = [:]
        /// The last sentences you removed, so the next cards pick fewer like them.
        var discarded: [String] = []
        /// Terms and expressions you said you knew.
        var knew: [String] = []
        var dirty = true
    }

    @Published private(set) var data = Facts()
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LEXALIE/profile.json")

    private init() {
        if let saved = try? Data(contentsOf: url), let d = try? JSONDecoder().decode(Facts.self, from: saved) { data = d }
    }

    /// Calls are deleted by themselves after this many days, when you chose it (Settings); nil keeps them.
    var callsDeleteDays: Int? {
        let days = UserDefaults.standard.integer(forKey: Key.callsDeleteDays)
        return days > 0 ? days : nil
    }

    var answered: Bool { !data.workField.isEmpty || !data.callsWith.isEmpty || !data.accents.isEmpty }

    func setAnswers(work: String, calls: String, accents: String) {
        data.workField = String(work.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        data.callsWith = String(calls.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        data.accents = String(accents.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        changed()
    }

    func asked(_ reason: String) { count(reason) }
    func tapped(_ why: String) { count(why) }

    func discarded(_ sentence: String, why: String) {
        data.notImportant[why, default: 0] += 1
        data.discarded = Array((data.discarded + [String(sentence.prefix(300))]).suffix(20))
        changed()
    }

    func knew(_ text: String) {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !t.isEmpty, !data.knew.contains(t) else { return }
        data.knew = Array((data.knew + [t]).suffix(80))
        changed()
    }

    private func count(_ reason: String) {
        guard !reason.isEmpty else { return }
        data.reasons[reason, default: 0] += 1
        changed()
    }

    /// For Gemini, with every call that picks or explains for you (no names: only what you told us).
    var summary: String {
        var parts: [String] = []
        if !data.workField.isEmpty { parts.append("Works in: \(data.workField).") }
        if !data.callsWith.isEmpty { parts.append("Has calls with: \(data.callsWith).") }
        if !data.accents.isEmpty { parts.append("Accents heard most: \(data.accents).") }
        let hard = data.reasons.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) (\($0.value))" }
        if !hard.isEmpty { parts.append("Most often misses or asks about: \(hard.joined(separator: ", ")).") }
        let skip = data.notImportant.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        if !skip.isEmpty { parts.append("Removed as not important for them, several times: \(skip.joined(separator: ", ")).") }
        if !data.knew.isEmpty { parts.append("Already knows: \(data.knew.suffix(30).joined(separator: ", ")).") }
        return String(parts.joined(separator: " ").prefix(1500))
    }

    /// "What LEXALIE knows about you", in your language, one line each.
    var readable: [String] {
        var out: [String] = []
        if !data.workField.isEmpty { out.append(String(localized: "You work in: \(data.workField)")) }
        if !data.callsWith.isEmpty { out.append(String(localized: "Your calls are with: \(data.callsWith)")) }
        if !data.accents.isEmpty { out.append(String(localized: "Accents you hear most: \(data.accents)")) }
        for (reason, n) in data.reasons.sorted(by: { $0.value > $1.value }).prefix(4) {
            out.append(String(localized: "You often miss: \(Self.label(reason)) (\(n))"))
        }
        for (why, n) in data.notImportant.sorted(by: { $0.value > $1.value }).prefix(3) where n >= 2 {
            out.append(String(localized: "Less important for you: \(Self.label(why))"))
        }
        if !data.knew.isEmpty { out.append(String(localized: "You already know: \(data.knew.suffix(8).joined(separator: ", "))")) }
        return out
    }

    static func label(_ reason: String) -> String {
        switch reason {
        case "word": String(localized: "words you don't know")
        case "acronym": String(localized: "acronyms")
        case "name": String(localized: "who or what someone is")
        case "meant": String(localized: "what people really mean")
        case "numbers": String(localized: "numbers said fast")
        case "negation": String(localized: "negations")
        case "joke": String(localized: "jokes")
        case "speed", "accent": String(localized: "fast speech and accents")
        case "person": String(localized: "people hard to follow")
        case "asked": String(localized: "questions put to you")
        default: String(localized: "other things")
        }
    }

    /// Settings → "Forget it": here and on the account.
    func forget() {
        data = Facts()
        changed()
    }

    func changed() {
        data.dirty = true
        if let saved = try? JSONEncoder().encode(data) { try? saved.write(to: url, options: .atomic) }
        SessionSync.shared.schedule()
    }

    func push(token: String) async throws {
        guard data.dirty, let uid = Account.shared.session?.userID else { return }
        let learned: [String: Any] = ["reasons": data.reasons, "not_important": data.notImportant, "discarded": data.discarded, "knew": data.knew]
        let row: [String: Any] = [
            "work_field": data.workField.isEmpty ? NSNull() as Any : data.workField as Any,
            "calls_with": data.callsWith.isEmpty ? NSNull() as Any : data.callsWith as Any,
            "accents": data.accents.isEmpty ? NSNull() as Any : data.accents as Any,
            "learned": learned,
            "calls_delete_days": callsDeleteDays.map { $0 as Any } ?? NSNull(),
        ]
        try await SessionSync.shared.rest("PATCH", "profiles?id=eq.\(uid)", token: token, body: row)
        data.dirty = false
        if let saved = try? JSONEncoder().encode(data) { try? saved.write(to: url, options: .atomic) }
    }
}

/// The questions you asked LEXALIE and its answers (table questions): every device sees them, and
/// their reasons teach the profile. Kept on this Mac until they reach the account.
@MainActor
final class Questions {
    static let shared = Questions()

    struct Asked: Codable {
        var id = UUID()
        var at = Date()
        var question: String
        var answer: String
        var reason: String
        var sessions: [String]
    }

    private var waiting: [Asked] {
        get { (UserDefaults.standard.data(forKey: "questionsWaiting").flatMap { try? JSONDecoder().decode([Asked].self, from: $0) }) ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.suffix(200))), forKey: "questionsWaiting") }
    }

    func add(_ q: Asked) {
        waiting.append(q)
        Profile.shared.asked(q.reason)
        SessionSync.shared.schedule()
    }

    func push(token: String) async throws {
        let all = waiting
        guard !all.isEmpty else { return }
        let rows: [[String: Any]] = all.map {
            ["id": $0.id.uuidString.lowercased(), "asked_at": SessionSync.iso($0.at), "device": "mac", "question": String($0.question.prefix(1000)),
             "answer": ["answer": $0.answer], "reason": $0.reason, "session_ids": $0.sessions] as [String: Any]
        }
        try await SessionSync.shared.rest("POST", "questions?on_conflict=id", token: token, body: rows)
        let sent = Set(all.map(\.id))
        waiting = waiting.filter { !sent.contains($0.id) }
    }
}
