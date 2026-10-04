import Foundation
import SwiftUI

/// Brand colours, same as the landing page and the Mac.
enum Brand {
    /// Apricot (§ 19.11): warm, never mistaken for the Workout green.
    static let accent = Color(red: 0xf2 / 255, green: 0xc4 / 255, blue: 0xa0 / 255)
    static let onyx = Color(red: 0x0b / 255, green: 0x0c / 255, blue: 0x11 / 255)
    static let card = Color(red: 0x15 / 255, green: 0x16 / 255, blue: 0x1c / 255)
}

/// Settings, shared by the views (`@AppStorage`) and the code.
enum K {
    static let server = "serverURL"
    static let webApp = "webAppURL"
    static let code = "testerCode"
    static let heard = "heardLanguage"
    static let native = "nativeLanguage"
    static let level = "level"
    static let keepEvening = "keepWholeEvening"
    static let phraseTaps = "phraseTaps"
    static let liveHelp = "liveHelp"
    static let focusLiveHelp = "focusLiveHelp"
    static let autoNight = "autoNight"
    static let stopOnLeave = "stopOnLeave"
    static let offerAtEvents = "offerAtEvents"
    static let airpods = "airpodsTap"
    static let maxHours = "maxHours"
    /// Where "now" (two taps) answers (§ 11.14): "auto" (where you tapped), "iphone", "watch", "voice".
    static let nowWhere = "nowWhere"

    static func register() {
        UserDefaults.standard.register(defaults: [
            server: "https://asaid-nine.vercel.app",
            webApp: "https://asaid-cx6u.vercel.app",
            code: "", heard: "en-GB", native: "it", level: "B2",
            keepEvening: false, phraseTaps: false, liveHelp: false, autoNight: true,
            stopOnLeave: false, offerAtEvents: true, airpods: false, maxHours: 4.0, nowWhere: "auto",
        ])
    }

    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

/// One piece of a moment: the same JSON as the Mac and the web app.
struct Piece: Codable, Hashable {
    var text: String
    var heard_as: String? = nil
    var gloss: String? = nil
    var meaning: String
    var note: String? = nil
    var cause: String? = nil
    var level: String? = nil
    var subtext: String? = nil
    /// Nothing was hard for your level, but you pressed: the likeliest one ("Maybe this one?").
    var guess: Bool? = nil
}

enum AfterhearError: LocalizedError {
    case missingCode, server(String), signedOut
    var errorDescription: String? {
        switch self {
        case .missingCode: "Add your tester code in Settings."
        case .server(let s): "The server said: \(s)"
        case .signedOut: "Sign in to send your evening to your account."
        }
    }
}

/// The brain on the server (api/*.ts): explanations and your model's picks.
enum Api {
    static func post<T: Decodable>(_ path: String, _ body: [String: Any], timeout: TimeInterval = 30) async throws -> T {
        let code = K.string(K.code).trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { throw AfterhearError.missingCode }
        guard let base = URL(string: K.string(K.server)) else { throw AfterhearError.server("url") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(code, forHTTPHeaderField: "x-afterhear-code")
        var full = body
        full["heard"] = full["heard"] ?? K.string(K.heard)
        full["native"] = K.string(K.native)
        full["level"] = K.string(K.level)
        request.httpBody = try JSONSerialization.data(withJSONObject: full)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AfterhearError.server("HTTP \(status)") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct Explanation: Decodable {
        let translation: String
        let intent: String?
        let pieces: [Piece]
    }

    struct Spotted: Decodable {
        struct Found: Decodable {
            let text: String
            let line: String
            let gloss: String
            let meaning: String
            let cause: String
            let level: String
            let likelihood: Double
        }
        let pieces: [Found]
    }

    struct Heard: Decodable { let text: String; let provider: String }

    /// The best recogniser on the server (ElevenLabs, § 19.21) for a short clip; nil when offline.
    @MainActor static func transcribe(_ url: URL) async -> String? {
        guard let data = try? Data(contentsOf: url), data.count < 2_900_000 else { return nil }
        let heard: Heard? = try? await post("api/transcribe", ["audio": data.base64EncodedString(), "mime": "audio/mp4",
                                                              "language": K.string(K.heard)], timeout: 8)
        let text = heard?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    @MainActor static func explain(_ text: String) async throws -> Explanation {
        try await post("api/explain", ["text": Redactor.redact(text), "known": Memory.shared.knownWell, "watch": Memory.shared.watch,
                                       "source": "in person"], timeout: 20) // the server always answers with Gemini (§ 19.27)
    }

    @MainActor static func spot(_ text: String) async throws -> Spotted {
        try await post("api/spot", ["text": String(Redactor.redact(text).prefix(4000)), "source": "a conversation in person",
                                    "known": Memory.shared.knownWell, "watch": Memory.shared.watch, "weak": Memory.shared.weakCauses], timeout: 40)
    }

    /// Supabase REST as the signed-in user (row level security decides whose rows these are).
    @discardableResult
    static func rest(_ method: String, _ path: String, token: String, body: Data? = nil, prefer: String? = nil) async throws -> Data {
        guard let url = URL(string: Account.supabaseURL + "/rest/v1/" + path) else { throw AfterhearError.server("url") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Account.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AfterhearError.server("HTTP \(status)") }
        return data
    }
}

/// A moment as the database stores it (supabase/migrations/20260930090000_app_core.sql).
struct MomentRow: Encodable {
    let id: String
    let occurred_at: Date
    let device = "iphone"
    let context = "life"
    let trigger: String
    let person_name: String?
    let transcript: String
    let sent: String
    let translation: String
    let pieces: [Piece]
    let label: String?
    let review: String?
    let step: Int
    let provider: String
    let latency_ms = 0
    let intent: String?
    let show: String?

    enum CodingKeys: String, CodingKey {
        case id, occurred_at, device, context, trigger, person_name, transcript, sent, translation, pieces, label, review, step, provider, latency_ms, intent, show
    }

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
        try c.encode(step, forKey: .step)
        try c.encode(provider, forKey: .provider)
        try c.encode(latency_ms, forKey: .latency_ms)
        try c.encode(intent, forKey: .intent)
        try c.encode(show, forKey: .show)
    }

    /// Sends moments to your account; they show up on the web and the Mac tonight.
    @MainActor
    static func upload(_ rows: [MomentRow]) async throws {
        guard !rows.isEmpty else { return }
        guard let token = await Account.shared.accessToken() else { throw AfterhearError.signedOut }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await Api.rest("POST", "moments?on_conflict=id", token: token, body: try encoder.encode(rows),
                           prefer: "resolution=merge-duplicates,return=minimal")
    }
}

/// The memory loop from the phone (docs/BRAIN.md § 12): signals up, what you know down.
/// Same server brain as the Mac (web/src/lib/memory.ts via /api/memory).
@MainActor
final class Memory {
    static let shared = Memory()

    struct Item: Codable {
        let key: String
        let text: String
        let cause: String?
        let state: String
        let understanding: Double
        let lapses: Int
        let reps: Int
    }

    private(set) var items: [Item] = []
    private var queue: [[String: String]] = (UserDefaults.standard.array(forKey: "memoryQueue") as? [[String: String]]) ?? []

    /// Same rule as the server: "Crack on!" and "crack on" are one expression.
    static func key(_ text: String) -> String {
        let punctuation = CharacterSet(charactersIn: "“”\"«»()[]{}.,!?;:…")
        let spaced = text.lowercased().precomposedStringWithCompatibilityMapping.unicodeScalars
            .map { punctuation.contains($0) ? " " : String($0) }.joined()
        return String(spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
    }

    var knownWell: [String] { Array(items.filter { $0.reps > 0 && ($0.state == "promoted" || $0.understanding >= 0.9) }.map(\.text).prefix(500)) }
    var watch: [String] { Array(items.filter { $0.reps > 0 && $0.understanding < 0.75 }.map(\.text).prefix(200)) }

    /// How hard a sentence is for you (Ranking): learning = 1, known well = 0.15, unknown to us = 0.4.
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
    var weakCauses: [String] {
        var n: [String: Int] = [:]
        for i in items where i.state != "promoted" { if let c = i.cause, c != "speaking" { n[c, default: 0] += 1 + i.lapses } }
        return n.sorted { $0.value > $1.value }.prefix(3).map(\.key)
    }

    func record(_ kind: String, pieces: [Piece], momentID: String? = nil) {
        let at = ISO8601DateFormatter().string(from: Date())
        for p in pieces where !p.text.isEmpty {
            var s: [String: String] = ["kind": kind, "text": String(p.text.prefix(200)), "meaning": p.meaning, "at": at, "context": "life", "device": "iphone"]
            if let g = p.gloss { s["gloss"] = g }
            if let c = p.cause { s["cause"] = c }
            if let l = p.level { s["level"] = l }
            if let momentID { s["moment_id"] = momentID }
            queue.append(s)
        }
        UserDefaults.standard.set(Array(queue.suffix(1000)), forKey: "memoryQueue")
        Task { await sync() }
    }

    /// The second encounter (§ 12.3): an expression you learned came back and you didn't mark it.
    func encounters(in lines: [String], except marked: Set<String>) {
        let hay = " " + lines.map(Memory.key).joined(separator: " ") + " "
        let at = ISO8601DateFormatter().string(from: Date())
        for item in items where item.reps > 0 && item.key.count >= 5 && !marked.contains(item.key) && hay.contains(" " + item.key + " ") {
            queue.append(["kind": "encounter_smooth", "text": item.text, "at": at, "context": "life", "device": "iphone"])
        }
        UserDefaults.standard.set(Array(queue.suffix(1000)), forKey: "memoryQueue")
    }

    func sync() async {
        guard let token = await Account.shared.accessToken(),
              let url = URL(string: K.string(K.webApp))?.appendingPathComponent("api/memory") else { return }
        if !queue.isEmpty {
            let outgoing = Array(queue.prefix(200))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["signals": outgoing])
            if let (_, response) = try? await URLSession.shared.data(for: request), ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 {
                queue.removeFirst(min(outgoing.count, queue.count))
                UserDefaults.standard.set(queue, forKey: "memoryQueue")
            }
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct Reply: Decodable { let items: [Item] }
        if let (data, _) = try? await URLSession.shared.data(for: request), let reply = try? JSONDecoder().decode(Reply.self, from: data) {
            items = reply.items
        }
    }
}
