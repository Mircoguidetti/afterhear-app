import SwiftUI

/// What matters (block COSA, owner 07/10 evening): the taps of the last two weeks turned into the few
/// things worth knowing, in order, each with one line on why. Not a list of hundreds of moments: those
/// stay behind "All moments". Only what slipped past you, never "interesting things" (comprehension,
/// not notes); a thing goes away once you get it. Worked out on this Mac: no server, no cost.
@MainActor
enum WhatMatters {
    struct Item: Identifiable, Equatable {
        enum Kind { case expression, person, pattern }
        let id: String
        let kind: Kind
        /// The expression, the person, or the kind of thing ("Fast speech").
        let title: String
        /// Why it's here: "4 times · 3 in calls with Tom".
        let why: String
        /// The latest moment behind it: Replay, "Got it now".
        let moment: UUID?
        let score: Double
    }

    struct Summary: Equatable {
        /// One sentence on the period, worked out here ("These two weeks, …").
        let headline: String?
        let items: [Item]
    }

    static let days = 14

    /// The taps that count: yours (not your model's guesses, not a pause you didn't mean), not a false
    /// alarm, not bad audio, in the period.
    static func taps(_ moments: [Moment], now: Date = Date(), days: Int = days) -> [Moment] {
        let from = now.addingTimeInterval(-Double(days) * 86_400)
        return moments.filter { m in
            m.date >= from && !m.isModel && m.trigger != "hesitation" && m.label != .notAMiss && m.label != .badAudio
        }
    }

    static func summary(_ moments: [Moment], known: Set<String>, now: Date = Date()) -> Summary {
        let taps = taps(moments, now: now)
        guard !taps.isEmpty else { return Summary(headline: nil, items: []) }

        // Expressions: the same piece, wherever it came back.
        var groups: [String: [Moment]] = [:]
        for m in taps {
            guard let piece = m.pieces.first, !piece.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            groups[Memory.key(piece.text), default: []].append(m)
        }
        var items: [Item] = []
        for (key, ms) in groups {
            let latest = ms.max { $0.date < $1.date }!
            // Got it: "I know it", or the review said so the last time.
            if known.contains(key) || latest.review == .known || latest.graduated { continue }
            let inCalls = ms.filter { $0.context == "call" || $0.context == "in_person" || $0.call != nil }
            let age = now.timeIntervalSince(latest.date) / 86_400
            let recency = age <= 3 ? 1.0 : age <= 7 ? 0.5 : 0.0
            // Once only counts when it was with people (a call, the doctor), where it costs the most.
            guard ms.count >= 2 || !inCalls.isEmpty else { continue }
            let score = Double(ms.count) + 0.5 * Double(inCalls.count) + recency
            items.append(Item(id: "x:" + key, kind: .expression, title: latest.pieces[0].text,
                              why: why(ms, inCalls: inCalls, now: now), moment: latest.id, score: score))
        }
        items.sort { $0.score > $1.score }
        items = Array(items.prefix(5))

        // A person you lose more than the others (calls and in person only).
        let withPeople = taps.filter { $0.with != nil && ($0.context == "call" || $0.context == "in_person" || $0.call != nil) }
        let byPerson = Dictionary(grouping: withPeople) { $0.with! }
        if let top = byPerson.max(by: { $0.value.count < $1.value.count }), top.value.count >= 3,
           Double(top.value.count) >= 0.3 * Double(withPeople.count) {
            let name = top.key, ms = top.value
            let line = String(localized: "\(ms.count) of your \(withPeople.count) taps with people")
            items.insert(Item(id: "p:" + name, kind: .person, title: String(localized: "With \(name)"), why: line,
                              moment: ms.max { $0.date < $1.date }?.id, score: Double(ms.count)), at: min(1, items.count))
        }

        // The sound, not the words: sentences too fast or run together.
        let fast = taps.filter { ["speed_accent", "connected_speech", "overlapping_voices"].contains($0.pieces.first?.cause ?? "") || $0.label == .speedAccent }
        if fast.count >= 3, Double(fast.count) >= 0.4 * Double(taps.count) {
            items.append(Item(id: "s:fast", kind: .pattern, title: String(localized: "Fast speech"),
                              why: String(localized: "\(fast.count) of your \(taps.count) taps: the words were known, the speed wasn't"),
                              moment: fast.max { $0.date < $1.date }?.id, score: Double(fast.count)))
        }

        // Few taps so far: the latest ones still count, so the page is never empty after a first day.
        if items.count < 3 {
            let shown = Set(items.compactMap(\.moment))
            for m in taps.sorted(by: { $0.date > $1.date }) where items.count < 3 {
                guard let piece = m.pieces.first, !shown.contains(m.id), !known.contains(Memory.key(piece.text)),
                      !items.contains(where: { $0.id == "x:" + Memory.key(piece.text) }) else { continue }
                items.append(Item(id: "x:" + Memory.key(piece.text), kind: .expression, title: piece.text,
                                  why: why([m], inCalls: [], now: now), moment: m.id, score: 0))
            }
        }
        return Summary(headline: headline(taps), items: Array(items.prefix(7)))
    }

    /// "4 times · 3 in calls with Tom", "Twice · in The Office", "Yesterday, in a video".
    static func why(_ ms: [Moment], inCalls: [Moment], now: Date) -> String {
        let latest = ms.max { $0.date < $1.date }!
        let people = Array(Set(inCalls.compactMap(\.with))).sorted()
        let shows = Array(Set(ms.compactMap(\.show))).sorted()
        var parts: [String] = []
        if ms.count >= 2 { parts.append(String(localized: "\(ms.count) times")) }
        if !inCalls.isEmpty {
            if let who = people.first {
                parts.append(inCalls.count == ms.count ? String(localized: "with \(who)") : String(localized: "\(inCalls.count) with \(who)"))
            } else {
                parts.append(String(localized: "\(inCalls.count) in calls"))
            }
        } else if let show = shows.first {
            parts.append(String(localized: "in \(show)"))
        }
        if ms.count == 1 {
            parts.insert(latest.date.formatted(.relative(presentation: .named)), at: 0)
        }
        return parts.joined(separator: " · ")
    }

    /// One sentence on the two weeks, from what kind of thing slipped past most and where.
    static func headline(_ taps: [Moment]) -> String? {
        let causes = taps.compactMap { $0.pieces.first?.cause }
        guard taps.count >= 3, let top = Dictionary(grouping: causes, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key else { return nil }
        let what: String
        switch top {
        case "idiom": what = String(localized: "sayings")
        case "unknown_word": what = String(localized: "words you didn't know")
        case "cultural": what = String(localized: "names and references")
        case "subtext": what = String(localized: "what people really meant")
        case "speed_accent", "connected_speech", "overlapping_voices": what = String(localized: "sentences too fast to catch")
        case "numbers": what = String(localized: "numbers and dates")
        case "known_not_recognized": what = String(localized: "words you know, said differently")
        default: return nil
        }
        let withPeople = taps.filter { $0.context == "call" || $0.context == "in_person" || $0.call != nil }.count
        let inVideos = taps.filter { $0.context == "video" || $0.context == "song" }.count
        if withPeople * 2 > taps.count { return String(localized: "These two weeks, what slipped past you most: \(what), mostly with people.") }
        if inVideos * 2 > taps.count { return String(localized: "These two weeks, what slipped past you most: \(what), mostly in videos.") }
        return String(localized: "These two weeks, what slipped past you most: \(what).")
    }
}

/// The first thing you see (owner, 07/10 evening): what matters, then "All moments".
struct WhatMattersView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var gotIt: Set<String> = []

    var body: some View {
        let summary = WhatMatters.summary(store.moments, known: store.known)
        VStack(alignment: .leading, spacing: 16) {
            Text("What matters").font(.system(size: 24, weight: .semibold))
            if let headline = summary.headline {
                Text(headline).font(.system(size: 14)).foregroundStyle(Brand.paper.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            }
            if summary.items.isEmpty {
                Text("Nothing yet. Tap when something slips past you: what keeps coming back shows up here.")
                    .font(.system(size: 14)).foregroundStyle(Brand.paper.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(summary.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().overlay(Brand.paper.opacity(0.1)).padding(.vertical, 12) }
                            row(item)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("All moments") { openWindow(id: "diary") }
                Spacer()
                Text("Last two weeks").font(.caption).foregroundStyle(Brand.paper.opacity(0.5))
            }
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 520)
        .foregroundStyle(Brand.paper)
    }

    @ViewBuilder private func row(_ item: WhatMatters.Item) -> some View {
        let moment = item.moment.flatMap { id in store.moments.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title)
                .font(item.kind == .expression ? .system(size: 18, design: .serif) : .system(size: 16, weight: .semibold))
            Text(item.why).font(.system(size: 12.5)).foregroundStyle(Brand.paper.opacity(0.6))
            if item.kind == .expression, let piece = moment?.pieces.first {
                Text(piece.meaning).font(.system(size: 13)).foregroundStyle(Brand.paper.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                if let moment, moment.clipFile != nil { Button("Replay") { AppModel.shared.play(moment, slow: false) } }
                if item.kind == .expression, let moment, let piece = moment.pieces.first {
                    Button(gotIt.contains(item.id) ? String(localized: "Noted: it goes away") : String(localized: "I get it now")) {
                        guard !gotIt.contains(item.id) else { return }
                        gotIt.insert(item.id)
                        AppModel.shared.knew(piece, in: moment)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Brand.paper.opacity(0.6))
        }
    }
}
