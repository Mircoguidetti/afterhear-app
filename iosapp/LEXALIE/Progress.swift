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
              let url = URL(string: K.string(K.webApp))?.appendingPathComponent("api/story") else { return nil }
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

    var body: some View {
        NavigationStack {
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
                        Text("Sign in (Settings → Account) to see your progress, the same on every device.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Progress")
            .refreshable { story = await Story.load() }
            .task {
                story = await Story.load()
                loading = false
            }
        }
    }
}
