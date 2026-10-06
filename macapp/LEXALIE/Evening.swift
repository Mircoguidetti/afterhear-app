import SwiftUI
import UserNotifications

/// One evening moment (block SERA, owner 06/10 night): at the hour you choose (21:00 unless you
/// change it), one notification, only on a day with moments; it opens tonight's window. On Sunday,
/// instead, the week's episode. Quiz, dictation and "five minutes now?" are all in here now.
@MainActor
enum Evening {
    static let hourKey = "eveningHour"
    private static let sentKey = "eveningSent"

    static var hour: Int {
        let h = UserDefaults.standard.integer(forKey: hourKey)
        return h == 0 ? 21 : h
    }

    /// Every half minute, from the listening timer.
    static func check(now: Date = Date()) async {
        let calendar = Calendar.current
        guard calendar.component(.hour, from: now) == hour else { return }
        let today = Store.dayKey(now)
        guard UserDefaults.standard.string(forKey: sentKey) != today else { return }
        let store = AppModel.shared.store
        let sunday = calendar.component(.weekday, from: now) == 1
        let content = UNMutableNotificationContent()
        if sunday {
            content.title = String(localized: "Your week, in four minutes")
            content.body = String(localized: "The things of the week, and what ties them together.")
            content.userInfo = ["kind": "sunday"]
        } else {
            let count = store.reviewQueue.count
            guard count > 0 else { return }
            content.title = count == 1 ? String(localized: "Tonight: 1 moment from today") : String(localized: "Tonight: \(count) moments from today")
            content.body = String(localized: "With the real voice. Five minutes.")
            content.userInfo = ["kind": "evening"]
        }
        UserDefaults.standard.set(today, forKey: sentKey)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "evening-\(today)", content: content, trigger: nil))
    }

    static func open() {
        AppWindows.show(id: "tonight", title: String(localized: "Tonight"), width: 520, height: 640) {
            ReviewView().environmentObject(AppModel.shared.store)
        }
    }
}

/// The refrain of the week, in tonight's window: what keeps coming back, explained if you ask.
struct RefrainLine: View {
    @State private var refrain: Nodes.Refrain?
    @State private var what: String?

    var body: some View {
        Group {
            if let refrain {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Comes back often · \(refrain.times) times this week").font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.line)
                    Text(refrain.node.text).font(.system(size: 16, weight: .semibold))
                    Text("Heard in: \(refrain.sources.prefix(3).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    if let what {
                        Text(what).font(.callout).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Button("What is it?") {
                            Task { what = await AppModel.shared.explainTerm(refrain.node.text) ?? String(localized: "Couldn't explain it now.") }
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Brand.paper.opacity(0.12)))
            }
        }
        .onAppear {
            guard refrain == nil, let r = Nodes.shared.refrain() else { return }
            refrain = r
            Nodes.shared.markShown(r.node.key)
        }
    }
}
