import Foundation
import UserNotifications

/// How LEXALIE helps in one call (docs/BRAIN.md § 19.15), chosen in the notice 15 minutes before.
/// - Just mark: nothing shows up, everything is in the report.
/// - Suggestions: now and then a hard word, from your model.
/// - With me: every live help (suggestions, "they asked you", how to start the answer).
enum CallMode: String, CaseIterable, Identifiable {
    case mark, suggestions, withMe
    var id: String { rawValue }

    var label: String {
        switch self {
        case .mark: String(localized: "Just mark")
        case .suggestions: String(localized: "Suggestions")
        case .withMe: String(localized: "With me")
        }
    }

    var detail: String {
        switch self {
        case .mark: String(localized: "Nothing on screen. It's all in the report after.")
        case .suggestions: String(localized: "Now and then a hard word.")
        case .withMe: String(localized: "Every help: hard words, the question they asked you, how to start.")
        }
    }

    /// Your model's hints show up in the call.
    var hints: Bool { self != .mark }
}

/// The mode of each call, remembered for the recurring meeting or the people in it.
@MainActor
enum CallModes {
    private static let key = "callModes"

    /// The same people, or the same meeting without numbers and dates ("Weekly sync").
    static func key(for call: Call?) -> String {
        if let people = call?.people, !people.isEmpty { return "people:" + people.sorted().joined(separator: ",").lowercased() }
        let letters = (call?.title ?? "").lowercased().filter { $0.isLetter || $0 == " " }
        let title = letters.split(separator: " ").joined(separator: " ")
        return "title:" + (title.isEmpty ? "untitled" : title)
    }

    /// Your choice last time, otherwise: you organise it or you're few (you talk) → Just mark;
    /// many people and you're a guest (you mostly listen) → Suggestions.
    static func mode(for call: Call?) -> CallMode {
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if let raw = saved[key(for: call)], let mode = CallMode(rawValue: raw) { return mode }
        // Choices made before the three modes (Suggestions on or off).
        let old = UserDefaults.standard.dictionary(forKey: Key.callHints) as? [String: Bool] ?? [:]
        let oldKey = String(key(for: Call(id: "", title: call?.title ?? "", start: .now, end: .now, people: [], guests: 0)).dropFirst(6))
        if let on = old[oldKey] { return on ? .suggestions : .mark }
        guard let call else { return .mark }
        return !call.organizer && call.guests >= 4 ? .suggestions : .mark
    }

    static func set(_ mode: CallMode, for call: Call?) {
        var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        saved[key(for: call)] = mode.rawValue
        UserDefaults.standard.set(saved, forKey: key)
        if call?.id == CalendarWatch.shared.current?.id || call == nil { ModelWatch.shared.modeChanged(mode) }
    }
}

/// "Tell me before calls: all / only the hard ones / never" (§ 19.15).
enum CallNotice: String, CaseIterable, Identifiable {
    case all, hard, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: String(localized: "All calls")
        case .hard: String(localized: "Only the hard ones")
        case .never: String(localized: "Never")
        }
    }
    static var current: CallNotice { CallNotice(rawValue: UserDefaults.standard.string(forKey: Key.callNotice) ?? "") ?? .all }

    static let category = "precall"
    static let minutes: Double = 15

    /// The notice's buttons: change the mode with one tap.
    static func registerCategory() {
        let actions = CallMode.allCases.map { UNNotificationAction(identifier: "mode." + $0.rawValue, title: $0.label) }
        let category = UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: [])
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            UNUserNotificationCenter.current().setNotificationCategories(existing.filter { $0.identifier != category.identifier }.union([category]))
        }
    }
}

/// What happened in the last call with the same people, for the notice before and the summary after.
@MainActor
enum CallHistory {
    /// The last report of a call with these people (or this recurring meeting), before `before`.
    static func last(like call: Call, before: Date) -> SavedReport? {
        let key = CallModes.key(for: call)
        return Reports.shared.all.first { r in
            r.start < before.addingTimeInterval(-60) && r.id != call.id
                && CallModes.key(for: Call(id: r.id, title: r.title, start: r.start, end: r.end, people: r.people, guests: 0)) == key
        }
    }

    /// One line about the last time: what slipped, where you hesitated, what they asked you.
    static func recap(_ r: SavedReport) -> String {
        var parts: [String] = []
        let taps = r.taps ?? AppModel.shared.store.moments.filter { $0.date >= r.start && $0.date <= r.end.addingTimeInterval(60) }.count
        if taps > 0 { parts.append(taps == 1 ? String(localized: "1 thing slipped past you") : String(localized: "\(taps) things slipped past you")) }
        if let n = r.report?.hesitations.filter(\.language).count, n > 0 { parts.append(n == 1 ? String(localized: "you hesitated once") : String(localized: "you hesitated \(n) times")) }
        if let first = r.report?.requests.first { parts.append(String(localized: "they asked you to \(String(first.request.prefix(60)))")) }
        let pieces = AppModel.shared.store.moments.filter { $0.date >= r.start && $0.date <= r.end.addingTimeInterval(60) }
            .flatMap(\.pieces).map(\.text).prefix(2)
        if !pieces.isEmpty { parts.append(pieces.joined(separator: ", ")) }
        return parts.isEmpty ? String(localized: "Last time went smoothly.") : String(localized: "Last time: ") + parts.joined(separator: " · ") + "."
    }

    /// A call worth a notice when you chose "only the hard ones": it went badly last time,
    /// or many people, or people you've missed things with.
    static func isHard(_ call: Call) -> Bool {
        if let r = last(like: call, before: call.start), r.score < 85 { return true }
        if call.guests >= 5 { return true }
        return !CalendarWatch.shared.prep(for: call).isEmpty
    }

    /// "What you improved" compared with the last call with the same people (§ 19.16):
    /// fewer taps, a higher score, expressions you missed then and got by yourself this time.
    static func improvements(now: SavedReport, taps: Int, previous: SavedReport?) -> [String] {
        guard let previous else { return [] }
        var out: [String] = []
        let before = previous.taps ?? AppModel.shared.store.moments.filter { $0.date >= previous.start && $0.date <= previous.end.addingTimeInterval(60) }.count
        if before > taps { out.append(taps == 1 ? String(localized: "1 tap instead of \(before)") : String(localized: "\(taps) taps instead of \(before)")) }
        if now.score > previous.score { out.append(String(localized: "\(now.score)% followed, up from \(previous.score)%")) }
        let then = Set(AppModel.shared.store.moments.filter { $0.date >= previous.start && $0.date <= previous.end.addingTimeInterval(60) }
            .flatMap(\.pieces).map { Memory.key($0.text) })
        let gotIt = Memory.shared.smooth(from: now.start, to: now.end.addingTimeInterval(120)).filter { then.contains(Memory.key($0)) }
        for text in gotIt.prefix(2) { out.append(String(localized: "“\(text)”: you got it by yourself")) }
        return out
    }
}
