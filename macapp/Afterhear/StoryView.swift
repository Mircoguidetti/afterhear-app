import SwiftUI

/// Your progress in words (docs/BRAIN.md § 19.17): the same line of the day and story of the
/// week as the web app and the Mac, from the server (web /api/story). The numbers come from
/// your signals; the words are written from them, never the other way round.
struct Story: Decodable {
    struct Day: Decodable { let line: String }
    struct Week: Decodable { let title: String; let paragraphs: [String]; let train: String? }
    let day: Day
    let week: Week

    static func load() async -> Story? {
        guard let token = await Account.shared.accessToken(),
              let url = URL(string: (UserDefaults.standard.string(forKey: Key.webApp) ?? AppSettings.defaultWebApp).trimmingCharacters(in: .whitespaces))?.appendingPathComponent("api/story") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Story.self, from: data)
    }
}

struct ProgressStoryView: View {
    @State private var story: Story?
    @State private var loading = true
    @ObservedObject private var account = Account.shared
    @ObservedObject private var store = AppModel.shared.store

    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let story {
                        Text("TODAY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(.init(story.day.line)).font(.title3)
                        Divider()
                        Text("THIS WEEK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(story.week.title).font(.title2.weight(.semibold))
                        ForEach(story.week.paragraphs, id: \.self) { Text(.init($0)) }
                        if let train = story.week.train { Text(.init(train)).fontWeight(.semibold).foregroundStyle(Brand.accent) }
                        Text("The numbers come from your taps and listening; the words are written from them.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        // Never an empty window (owner, 03/10): what this Mac knows, account or not.
                        LocalProgress(store: store)
                        Divider()
                        if account.signedIn {
                            Text("The written story of your week couldn't load right now. It comes back with the connection.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Sign in to read the story of your week, the same on every device.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Sign in with Google") { account.signInWithGoogle() }
                        }
                    }
                    Divider()
                    EarProfileView(profile: EarProfile(moments: store.moments))
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: account.signedIn) {
                loading = true
                story = await Story.load()
                loading = false
            }
        }
    }
}

/// Your progress from the moments on this Mac: today, this week against the last, the expressions
/// you met most and the ones you now know.
private struct LocalProgress: View {
    @ObservedObject var store: Store

    private var taps: [Moment] { store.moments.filter { !$0.isModel } }

    private func count(daysAgo from: Int, to: Int) -> Int {
        let now = Date()
        return taps.filter {
            let days = now.timeIntervalSince($0.date) / 86_400
            return days >= Double(from) && days < Double(to)
        }.count
    }

    private var topExpressions: [String] {
        var seen: [String: Int] = [:]
        var order: [String] = []
        for moment in taps.reversed() {
            for piece in moment.pieces {
                let key = piece.text.lowercased()
                if seen[key] == nil { order.append(piece.text) }
                seen[key, default: 0] += 1
            }
        }
        return order.sorted { (seen[$0.lowercased()] ?? 0) > (seen[$1.lowercased()] ?? 0) }.prefix(5).map { $0 }
    }

    var body: some View {
        let today = store.tapsToday
        let week = count(daysAgo: 0, to: 7), lastWeek = count(daysAgo: 7, to: 14)
        let hours = store.listening.values.reduce(0, +) / 3600
        VStack(alignment: .leading, spacing: 12) {
            Text("TODAY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(today == 0 ? String(localized: "No moments yet today.") : today == 1 ? String(localized: "1 moment today.") : String(localized: "\(today) moments today."))
                .font(.title3)
            Divider()
            Text("THIS WEEK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(week == 1 ? "1 moment" : "\(week) moments").font(.title2.weight(.semibold))
            if lastWeek > 0 {
                Text(week < lastWeek ? String(localized: "Fewer than last week (\(lastWeek)): you need it less.")
                     : week == lastWeek ? String(localized: "The same as last week.") : String(localized: "More than last week (\(lastWeek)): you listened more."))
                    .foregroundStyle(.secondary)
            }
            if hours >= 0.1 {
                Text(String(localized: "\(String(format: "%.1f", hours)) hours of listening in all.")).foregroundStyle(.secondary)
            }
            if !topExpressions.isEmpty {
                Text("What comes back most").font(.headline).padding(.top, 4)
                ForEach(topExpressions, id: \.self) { Text($0).foregroundStyle(Brand.accent) }
            }
            if !store.known.isEmpty {
                Text(store.known.count == 1 ? String(localized: "1 expression you now know.") : String(localized: "\(store.known.count) expressions you now know."))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
