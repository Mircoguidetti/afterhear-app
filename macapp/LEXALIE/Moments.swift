import AppKit
import Combine
import Foundation

struct Piece: Codable, Hashable {
    let text: String
    /// As the recogniser wrote it, when that was a mistake (e.g. "white thick" for "quite sick").
    let heardAs: String?
    /// One to four words, readable in a glance during the conversation.
    let gloss: String?
    let meaning: String
    let note: String
    let cause: String
    /// How advanced it is (CEFR, "B2", "C1"…): builds the map of what you know.
    let level: String?
    /// What it really means when the words say one thing and mean another ("quite good" = not great).
    var subtext: String? = nil
    /// Nothing was hard for your level, but you pressed: the likeliest one ("Maybe this one?").
    var guess: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case text, gloss, meaning, note, cause, level, subtext, guess
        case heardAs = "heard_as"
    }

    var causeLabel: String {
        switch cause {
        case "unknown_word": String(localized: "New word")
        case "known_not_recognized": String(localized: "Known word, not recognised")
        case "idiom": String(localized: "Idiom")
        case "connected_speech": String(localized: "Connected speech")
        case "speed_accent": String(localized: "Speed / accent")
        case "cultural": String(localized: "Cultural reference")
        case "subtext": String(localized: "What they really meant")
        case "numbers": String(localized: "Numbers, dates, prices")
        case "overlapping_voices": String(localized: "Voices at the same time")
        default: cause
        }
    }
}

/// "Maybe they meant…" (§ 19.28): the meaning beyond the words, with how sure and why.
struct Meant: Codable, Hashable {
    let text: String
    let alternative: String
    let evidence: String
    let confidence: Double
    let beyondWords: Bool

    enum CodingKeys: String, CodingKey {
        case text, alternative, evidence, confidence
        case beyondWords = "beyond_words"
    }

    /// Shown only when it's plain: a different meaning, very sure, and a clue beyond the words.
    static let threshold: Double = 90
    var shown: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty && confidence >= Self.threshold && beyondWords }
}

struct Explanation: Codable {
    /// Only when Gemini listened to the audio: what it heard.
    let transcript: String?
    let translation: String
    /// What the speaker really meant, when it differs from the words. Empty or missing otherwise.
    let intent: String?
    let pieces: [Piece]
    let provider: String?
    let model: String?
    let ms: Int?
    var meant: Meant? = nil
}

/// The evening diary: why this moment was missed. It's the question the whole
/// product hangs on — how often is it really an unknown word?
enum MomentLabel: String, CaseIterable, Identifiable, Codable {
    case unknownWord = "Parola che non conoscevo"
    case knownNotRecognized = "Parola nota, non riconosciuta"
    case idiom = "Modo di dire / slang"
    case connectedSpeech = "Parlato legato"
    case speedAccent = "Troppo veloce / accento"
    case cultural = "Riferimento culturale"
    case badAudio = "Audio incomprensibile"
    case transcriptWrong = "Trascrizione sbagliata"
    case notAMiss = "Falso allarme"
    // The raw values above are what's saved on disk: keep them. These are what you read.
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unknownWord: String(localized: "A word I didn't know")
        case .knownNotRecognized: String(localized: "Known word, not recognised")
        case .idiom: String(localized: "Idiom / slang")
        case .connectedSpeech: String(localized: "Connected speech")
        case .speedAccent: String(localized: "Too fast / accent")
        case .cultural: String(localized: "Cultural reference")
        case .badAudio: String(localized: "Audio unclear")
        case .transcriptWrong: String(localized: "Transcript wrong")
        case .notAMiss: String(localized: "False alarm")
        }
    }
    /// Stable name for the database.
    var key: String {
        switch self {
        case .unknownWord: "unknown_word"
        case .knownNotRecognized: "known_not_recognized"
        case .idiom: "idiom"
        case .connectedSpeech: "connected_speech"
        case .speedAccent: "speed_accent"
        case .cultural: "cultural"
        case .badAudio: "bad_audio"
        case .transcriptWrong: "transcript_wrong"
        case .notAMiss: "not_a_miss"
        }
    }
}

/// What changed in the store, for sync.
enum StoreChange {
    case moment(UUID)
    case people
    case personRemoved(String)
    case known
    case listening
    case deletedAll
    /// One moment deleted by you (F3): its text, its clip, its row in the account.
    case momentRemoved(UUID)
}

enum Review: String, Codable {
    case known, again
}

struct Moment: Codable, Identifiable {
    var id = UUID()
    var date: Date
    /// What was said, kept only on this Mac.
    var transcript: String
    /// What left the Mac: the same text without names and numbers.
    var sent: String
    var translation: String
    var pieces: [Piece]
    /// File name only; the clip lives in Application Support and is deleted after a week.
    var clipFile: String?
    var provider: String
    var latencyMs: Int
    /// Time spent recognising speech on the Mac, and waiting for the server.
    var transcribeMs: Int? = nil
    var serverMs: Int? = nil
    /// "Now": how long it waited for the sentence to end before transcribing (owner, 03/10).
    var waitMs: Int? = nil
    /// "apple-new" / "apple-old" (the Mac's recogniser, live), "mac-clip", "cloud:<provider>" or "gemini-audio".
    var transcribedBy: String? = nil
    var label: MomentLabel?
    var review: Review?
    /// Who you were talking with (a label you wrote: "Sarah", "Team marketing").
    var with: String? = nil
    /// "tap" (shortcut, double ⌥) or "sorry" (you said "sorry?").
    var trigger: String? = nil
    /// "video" or "call" when LEXALIE recognised where you were.
    var context: String? = nil
    /// What they really meant, beyond the words (tone, politeness, irony).
    var intent: String? = nil
    /// The series or video it came from ("Peaky Blinders").
    var show: String? = nil
    /// The calendar call it happened in (id and title), for the lesson after the call.
    var call: String? = nil
    var callTitle: String? = nil
    /// The last minutes of conversation around the tap (only on this Mac), and
    /// which turn is the missed one (guessed, then confirmed or changed by you).
    var turns: [Turn]? = nil
    var chosen: Int? = nil
    /// The second most likely sentence, offered as "Or maybe" (owner, 02/10).
    var alternative: Int? = nil
    /// Seconds between the end of the missed turn and the tap, once you confirmed it.
    var delay: Double? = nil
    /// Seconds from the clip start to the tap.
    var tapAt: Double? = nil
    /// Explained offline by the model inside this Mac: Gemini rewrites it once you're back online.
    var offline: Bool? = nil
    /// The sentence's translation from the translator on this Mac, at once (the explanation's own comes later).
    var quickTranslation: String? = nil
    /// "Maybe they meant…" for this sentence, and how it was said (measured here).
    var meant: Meant? = nil
    var tone: String? = nil
    /// Spaced repetition: when it comes back in the review, and how many times it was known.
    var due: Date? = nil
    var step: Int? = nil
    /// Your ear (block I), only on this Mac: what was measured at the tap, the evening's test,
    /// and the guests of a group call for "Who said it?".
    var signals: Signals? = nil
    var diagnosis: Diagnosis? = nil
    var callGuests: [String]? = nil
    /// The other sentences a tap offers, one touch away, best first (Conversation.offer, owner 05/10).
    var others: [Int]? = nil

    /// Picked by your model, not by you (§ 18): not a tap, and a quiz before it's a lesson.
    var isModel: Bool { trigger == "model" }
    var waitsForQuiz: Bool { isModel && review == nil }

    /// Known enough times in a row: it no longer comes back.
    var graduated: Bool { (step ?? 0) >= Store.intervals.count }
}

/// Someone you talk with. Only a name you choose and the accent you pick:
/// no voiceprints, nothing about them leaves this Mac.
struct Person: Codable, Identifiable, Hashable {
    var name: String
    var accent: String
    var id: String { name }

    static let accents = ["British", "Scottish", "Irish", "American", "Australian", "Indian", "Other / not sure"]

    /// People saved before the app was in English keep their Italian accent names: show them in English.
    static func english(_ accent: String) -> String {
        let old = ["Britannico", "Scozzese", "Irlandese", "Americano", "Australiano", "Indiano", "Altro / non so"]
        if let i = old.firstIndex(of: accent) { return accents[i] }
        return accent
    }

    /// The accent in the app's language; it's saved and sent in English.
    static func label(_ accent: String) -> String {
        switch english(accent) {
        case "British": String(localized: "British")
        case "Scottish": String(localized: "Scottish")
        case "Irish": String(localized: "Irish")
        case "American": String(localized: "American")
        case "Australian": String(localized: "Australian")
        case "Indian": String(localized: "Indian")
        case "Other / not sure": String(localized: "Other / not sure")
        default: accent
        }
    }
}

/// Moments, the "I know it" list and the clips, all on this Mac.
final class Store: ObservableObject {
    @Published private(set) var moments: [Moment] = []
    @Published private(set) var known: Set<String> = []
    /// Seconds of listening per day ("2026-09-29": 3600), to count taps per hour.
    @Published private(set) var listening: [String: Double] = [:]
    /// The same, per hour of the day ("2026-09-29": ["9": 1800]), to see when you listen best.
    private(set) var listeningHours: [String: [String: Double]] = UserDefaults.standard.dictionary(forKey: "listeningHours") as? [String: [String: Double]] ?? [:]
    @Published private(set) var people: [Person] = []
    /// Called after every local change, so sync can send it.
    var onChange: ((StoreChange) -> Void)?

    /// Days until a moment comes back after each "La so".
    static let intervals: [Double] = [3, 7, 21]

    static let clipDays = 7
    private let folder: URL
    private var momentsURL: URL { folder.appendingPathComponent("moments.json") }
    private var knownURL: URL { folder.appendingPathComponent("known.json") }
    private var listeningURL: URL { folder.appendingPathComponent("listening.json") }
    private var peopleURL: URL { folder.appendingPathComponent("people.json") }
    var clipsFolder: URL { folder.appendingPathComponent("clips", isDirectory: true) }

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LEXALIE", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipsFolder, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: momentsURL), let saved = try? decoder.decode([Moment].self, from: data) {
            moments = saved
        }
        if let data = try? Data(contentsOf: knownURL), let saved = try? JSONDecoder().decode([String].self, from: data) {
            known = Set(saved)
        }
        if let data = try? Data(contentsOf: listeningURL), let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            listening = saved
        }
        if let data = try? Data(contentsOf: peopleURL), let saved = try? JSONDecoder().decode([Person].self, from: data) {
            people = saved.map { Person(name: $0.name, accent: Person.english($0.accent)) }
        }
        purgeOldClips()
    }

    static func dayKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func addListening(seconds: Double) {
        listening[Self.dayKey(), default: 0] += seconds
        let hour = String(Calendar.current.component(.hour, from: Date()))
        listeningHours[Self.dayKey(), default: [:]][hour, default: 0] += seconds
        // Only the last two months matter.
        if listeningHours.count > 62 { listeningHours = listeningHours.filter { $0.key >= Self.dayKey(Date().addingTimeInterval(-62 * 86_400)) } }
        UserDefaults.standard.set(listeningHours, forKey: "listeningHours")
        if let data = try? JSONEncoder().encode(listening) { try? data.write(to: listeningURL, options: .atomic) }
        onChange?(.listening)
    }

    func upsertPerson(_ person: Person) {
        let name = person.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        people.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        people.insert(Person(name: name, accent: person.accent), at: 0)
        if let data = try? JSONEncoder().encode(people) { try? data.write(to: peopleURL, options: .atomic) }
        onChange?(.people)
    }

    func removePerson(_ name: String) {
        people.removeAll { $0.name == name }
        if let data = try? JSONEncoder().encode(people) { try? data.write(to: peopleURL, options: .atomic) }
        onChange?(.personRemoved(name))
    }

    func accent(of name: String?) -> String? {
        people.first { $0.name == name }?.accent
    }

    /// Taps per person and per accent: with whom (and which accent) it's hardest.
    func byPerson() -> [(name: String, accent: String?, taps: Int)] {
        let names = Set(moments.compactMap(\.with))
        return names.map { name in (name, accent(of: name), moments.filter { $0.with == name && !$0.isModel }.count) }
            .sorted { $0.taps > $1.taps }
    }

    var tapsToday: Int { moments.filter { Calendar.current.isDateInToday($0.date) && !$0.isModel }.count }
    var listeningToday: Double { listening[Self.dayKey()] ?? 0 }

    /// Moments to review now: new ones and the ones whose day has come.
    var reviewQueue: [Moment] {
        let now = Date()
        return moments.filter { !$0.graduated && !$0.waitsForQuiz && ($0.due ?? $0.date) <= now }.sorted { $0.date < $1.date }
    }

    /// Taps per hour of listening over the last `days` days, oldest first.
    func weeklyRates(weeks: Int = 4) -> [(label: String, taps: Int, hours: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<weeks).reversed().map { back in
            let start = calendar.date(byAdding: .day, value: -7 * (back + 1) + 1, to: today)!
            let end = calendar.date(byAdding: .day, value: 7, to: start)!
            let taps = moments.filter { $0.date >= start && $0.date < end && !$0.isModel }.count
            var seconds = 0.0
            var day = start
            while day < end {
                seconds += listening[Self.dayKey(day)] ?? 0
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
            return (back == 0 ? String(localized: "This week") : String(localized: "\(back) wk ago"), taps, seconds / 3600)
        }
    }

    func newClipURL(_ ext: String = "wav") -> URL {
        clipsFolder.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    func clipURL(_ moment: Moment) -> URL? {
        guard let name = moment.clipFile else { return nil }
        let url = clipsFolder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func add(_ moment: Moment) {
        moments.insert(moment, at: 0)
        save()
        onChange?(.moment(moment.id))
    }

    /// "Delete this moment" (F3): gone from this Mac, with its clip, and from your account.
    func delete(_ id: UUID) {
        guard let i = moments.firstIndex(where: { $0.id == id }) else { return }
        if let clip = clipURL(moments[i]) { try? FileManager.default.removeItem(at: clip) }
        moments.remove(at: i)
        save()
        onChange?(.momentRemoved(id))
    }

    func update(_ moment: Moment) {
        guard let i = moments.firstIndex(where: { $0.id == moment.id }) else { return }
        moments[i] = moment
        save()
        onChange?(.moment(moment.id))
    }

    /// Your usual delay between missing something and tapping, from the moments you confirmed.
    /// Pieces you keep missing ("Again"): the server flags them when they come back.
    var struggling: [String] {
        Array(Set(moments.filter { $0.review == .again }.flatMap { $0.pieces.map { $0.text.lowercased() } })).sorted()
    }

    /// How you listen, in one or two sentences for the AI: what trips you up and at what level.
    var listeningProfile: String {
        let limit = Date().addingTimeInterval(-60 * 86_400)
        let pieces = moments.filter { $0.date >= limit && !$0.isModel }.flatMap(\.pieces)
        guard pieces.count >= 3 else { return "" }
        var causes: [String: Int] = [:]
        for p in pieces { causes[p.causeLabel.lowercased(), default: 0] += 1 }
        let top = causes.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key) \($0.value * 100 / pieces.count)%" }.joined(separator: ", ")
        let levels = pieces.compactMap(\.level).sorted()
        var text = "Most of what they miss: \(top)."
        if !levels.isEmpty { text += " The pieces they miss are usually around \(levels[levels.count / 2])." }
        text += " They already know \(known.count) expressions."
        let ear = EarProfile(moments: moments).forModel
        if !ear.isEmpty { text += " " + ear }
        return text
    }

    /// Your usual delay in one situation ("call", "video", "song", or nil for anything else): a call
    /// after a long answer and a quick tap on YouTube are different habits (owner, 05/10).
    func usualDelay(for context: String?) -> Double? {
        let delays = moments.filter { $0.context == context }.compactMap(\.delay).prefix(15).sorted()
        return delays.isEmpty ? nil : delays[delays.count / 2]
    }

    var usualDelay: Double? {
        let delays = moments.compactMap(\.delay).prefix(15).sorted()
        return delays.isEmpty ? nil : delays[delays.count / 2]
    }

    func setDiagnosis(_ diagnosis: Diagnosis, for id: UUID) {
        guard let i = moments.firstIndex(where: { $0.id == id }) else { return }
        moments[i].diagnosis = diagnosis
        save()
    }

    /// "Who said it?": the name, and the accent you gave that person if you did.
    func setWith(_ name: String, for id: UUID) {
        guard let i = moments.firstIndex(where: { $0.id == id }) else { return }
        moments[i].with = name
        if moments[i].signals != nil { moments[i].signals?.accent = accent(of: name) }
        save()
        onChange?(.moment(id))
    }

    func setLabel(_ label: MomentLabel?, for id: UUID) {
        guard let i = moments.firstIndex(where: { $0.id == id }) else { return }
        moments[i].label = label
        save()
        onChange?(.moment(id))
    }

    /// A false alarm (you paused because you were thinking): labelled, and it never comes back.
    func dismiss(_ id: UUID) {
        guard let i = moments.firstIndex(where: { $0.id == id }) else { return }
        moments[i].label = .notAMiss
        moments[i].review = .known
        moments[i].step = Self.intervals.count
        save()
        onChange?(.moment(id))
    }

    func setReview(_ review: Review, for id: UUID) {
        guard let i = moments.firstIndex(where: { $0.id == id }) else { return }
        moments[i].review = review
        if review == .known {
            let step = (moments[i].step ?? 0) + 1
            moments[i].step = step
            let days = step <= Self.intervals.count ? Self.intervals[step - 1] : 0
            moments[i].due = Date().addingTimeInterval(days * 86_400)
        } else {
            moments[i].step = 0
            moments[i].due = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        }
        for piece in moments[i].pieces {
            let key = piece.text.lowercased()
            if review == .known { known.insert(key) } else { known.remove(key) }
        }
        save()
        onChange?(.moment(id))
        onChange?(.known)
    }

    /// A review done in the web app. Doesn't count as a local change.
    func applyRemoteReview(id: UUID, review: Review?, step: Int?, due: Date?) {
        guard let i = moments.firstIndex(where: { $0.id == id }) else { return }
        guard moments[i].review != review || moments[i].step != step || moments[i].due != due else { return }
        moments[i].review = review
        moments[i].step = step
        moments[i].due = due
        if let review {
            for piece in moments[i].pieces {
                let key = piece.text.lowercased()
                if review == .known { known.insert(key) } else { known.remove(key) }
            }
        }
        save()
    }

    /// The forgetting curve decides when a moment comes back: when its weakest piece is due
    /// (docs/BRAIN.md § 5.7). A moment whose pieces are all yours now stops coming back.
    @MainActor func applyMemory(_ items: [String: Memory.Item]) {
        for moment in moments where moment.review != nil && !moment.graduated {
            let mine = moment.pieces.compactMap { items[Memory.key($0.text)] }
            guard !mine.isEmpty, mine.count == moment.pieces.count else { continue }
            let dues = mine.compactMap { $0.due_at.flatMap(Sync.parseDate) }
            guard let due = dues.min() else { continue }
            var updated = moment
            if mine.allSatisfy({ $0.state == "promoted" }) { updated.step = Store.intervals.count }
            if abs((moment.due ?? .distantPast).timeIntervalSince(due)) > 3600 || updated.step != moment.step {
                updated.due = due
                update(updated)
            }
        }
    }

    func deleteAll() {
        moments = []
        known = []
        listening = [:]
        people = []
        try? FileManager.default.removeItem(at: listeningURL)
        try? FileManager.default.removeItem(at: peopleURL)
        try? FileManager.default.removeItem(at: clipsFolder)
        try? FileManager.default.createDirectory(at: clipsFolder, withIntermediateDirectories: true)
        save()
        onChange?(.deletedAll)
    }

    /// Privacy rule: clips stay on the Mac for a week at most.
    func purgeOldClips() {
        let limit = Date().addingTimeInterval(-Double(Self.clipDays) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: clipsFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < limit { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Percentages per cause, to paste into the plan.
    func report() -> String {
        let labelled = moments.filter { $0.label != nil }
        var lines = ["LEXALIE · diary (\(moments.count) moments, \(labelled.count) labelled)"]
        let hours = listening.values.reduce(0, +) / 3600
        if hours > 0 { lines.append(String(format: "Listening: %.1f h · %.1f taps/hour", hours, Double(moments.count) / hours)) }
        let sorry = moments.filter { $0.trigger == "sorry" }.count
        if sorry > 0 { lines.append("Marked by \"sorry?\": \(sorry)") }
        let people = byPerson()
        if !people.isEmpty {
            lines.append("By person:")
            for p in people { lines.append("  \(p.name)\(p.accent.map { " (\($0))" } ?? ""): \(p.taps)") }
            var accents: [String: Int] = [:]
            for p in people { accents[p.accent ?? "not set", default: 0] += p.taps }
            lines.append("By accent: " + accents.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        }
        if !moments.isEmpty {
            func median(_ values: [Int]) -> Int? {
                let sorted = values.sorted()
                return sorted.isEmpty ? nil : sorted[sorted.count / 2]
            }
            // Only what you asked for and waited on: marks are worked out later, the model's picks aren't taps.
            let asked = moments.filter { !$0.isModel && $0.latencyMs > 0 }
            lines.append("This Mac: \(Parakeet.onProcessor ? "Intel (Parakeet on the processor)" : "Apple chip (Parakeet on the Neural Engine)")")
            if let total = median(asked.map(\.latencyMs)) { lines.append("Median, tap to explanation: \(total) ms") }
            // Per source, and for voices where the time goes. Songs have nothing to transcribe (owner, 03/10:
            // their 0 ms pulled the transcription median down to 0).
            let modes = Set(asked.compactMap(\.transcribedBy)).sorted()
            for mode in modes {
                let group = asked.filter { $0.transcribedBy == mode }
                guard let total = median(group.map(\.latencyMs)) else { continue }
                var parts: [String] = []
                if mode != "lyrics" {
                    if let wait = median(group.compactMap(\.waitMs)) { parts.append("waiting for the end of the sentence \(wait)") }
                    if let mac = median(group.compactMap(\.transcribeMs).filter { $0 > 0 }) { parts.append("transcription \(mac)") }
                }
                if let server = median(group.compactMap(\.serverMs)) { parts.append("AI \(server)") }
                lines.append("  \(mode): \(group.count) moments, median \(total) ms" + (parts.isEmpty ? "" : " (" + parts.joined(separator: " · ") + ")"))
            }
            // The last ones, one by one: from one paste it's clear where the time goes.
            let formatter = DateFormatter()
            formatter.dateFormat = "dd/MM HH:mm"
            let recent = asked.sorted { $0.date > $1.date }.prefix(8)
            if !recent.isEmpty { lines.append("Last moments:") }
            for m in recent {
                var times = ["\(m.latencyMs) ms"]
                if let wait = m.waitMs { times.append("wait \(wait)") }
                if let mac = m.transcribeMs, mac > 0 { times.append("transcription \(mac)") }
                if let server = m.serverMs { times.append("AI \(server)") }
                let source = [m.transcribedBy, m.context, m.trigger].compactMap { $0 }.joined(separator: ", ")
                let label = m.label.map { " · \($0.title)" } ?? ""
                lines.append("  \(formatter.string(from: m.date)) [\(source)] \(times.joined(separator: " · "))\(label): \"\(String(m.sent.prefix(90)))\"")
            }
        }
        for label in MomentLabel.allCases {
            let n = labelled.filter { $0.label == label }.count
            guard n > 0 else { continue }
            lines.append("\(label.title): \(n) (\(n * 100 / labelled.count)%)")
        }
        return lines.joined(separator: "\n")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(moments) { try? data.write(to: momentsURL, options: .atomic) }
        if let data = try? JSONEncoder().encode(Array(known).sorted()) { try? data.write(to: knownURL, options: .atomic) }
    }
}
