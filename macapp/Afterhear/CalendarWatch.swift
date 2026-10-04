import AppKit
import CryptoKit
import EventKit
import SwiftUI
import UserNotifications

/// A call from your calendar: a meeting with guests or a video link.
struct Call: Identifiable, Equatable {
    /// Stable across refreshes: the calendar's own id plus the start time (repeating meetings share an id).
    let id: String
    let title: String
    let start: Date
    let end: Date
    /// People you track in Afterhear who are in this call (from the guest names and the title).
    let people: [String]
    let guests: Int
    /// You organised it: most likely you have to talk (§ 19.7).
    var organizer = false

    var who: String {
        if !people.isEmpty { return ListFormatter.localizedString(byJoining: people) }
        return title.isEmpty ? String(localized: "your call") : title
    }
}

/// Reads the calendars on this Mac (iCloud, Google, Exchange: whatever is in the Calendar app).
/// Before a call: a short prep with what slipped past you last time with those people.
/// During it: every moment is tagged with the call and the person. After it: the call lesson.
@MainActor
final class CalendarWatch: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = CalendarWatch()

    enum Access { case off, notAsked, granted, denied }

    @Published private(set) var access: Access = .off
    @Published private(set) var calls: [Call] = []

    private let events = EKEventStore()
    private var timer: Timer?
    private var observing = false
    private let defaults = UserDefaults.standard
    private var store: Store { AppModel.shared.store }
    /// The person Afterhear picked for the current call, so it can hand "Who are you talking with?" back after.
    private var autoPerson: (call: String, previous: String?)?

    var enabled: Bool {
        get { defaults.bool(forKey: Key.calendar) }
        set { defaults.set(newValue, forKey: Key.calendar); Task { await boot() } }
    }

    /// The call happening now (started, not ended, give or take a few minutes).
    var current: Call? {
        let now = Date()
        return calls.first { $0.start.addingTimeInterval(-120) <= now && now <= $0.end.addingTimeInterval(300) }
    }

    /// The next call that hasn't started yet, within a day.
    var next: Call? {
        calls.first { $0.start > Date() }
    }

    func boot() async {
        UNUserNotificationCenter.current().delegate = self
        guard enabled else {
            access = .off
            calls = []
            timer?.invalidate()
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            return
        }
        // Google Calendar connected directly (owner, 03/10) is enough on its own: the Calendar app's
        // permission is asked, but a "no" doesn't stop the prep.
        let google = GoogleCalendar.shared.connected
        if !isAuthorized {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = (try? await events.requestFullAccessToEvents()) ?? false
            } else {
                granted = (try? await events.requestAccess(to: .event)) ?? false
            }
            guard granted || google else { access = .denied; return }
            access = granted ? .granted : .denied
        } else {
            access = .granted
        }
        GoogleCalendar.shared.start()
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        CallNotice.registerCategory()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in CalendarWatch.shared.refresh() }
        }
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: events, queue: .main) { _ in
                Task { @MainActor in CalendarWatch.shared.refresh() }
            }
        }
    }

    private var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    // MARK: Reading the calendar

    func refresh() {
        let google = GoogleCalendar.shared.connected
        guard enabled, access == .granted || google else { return }
        let now = Date()
        let from = now.addingTimeInterval(-6 * 3600), to = now.addingTimeInterval(36 * 3600)
        var found: [Call] = []
        if access == .granted {
            let predicate = events.predicateForEvents(withStart: from, end: to, calendars: nil)
            found = events.events(matching: predicate)
                .filter { !$0.isAllDay && Self.isCall($0) }
                .map { call($0) }
        }
        // The same meeting from Google and from the Calendar app counts once.
        for event in GoogleCalendar.shared.events where event.isCall {
            let twin = found.contains { $0.title == event.title && abs($0.start.timeIntervalSince(event.start)) < 60 }
            if !twin { found.append(call(event)) }
        }
        calls = found.sorted { $0.start < $1.start }
        followCurrentCall()
        schedulePreps()
        sendLessons()
        Sync.shared.calendarChanged()
    }

    private static let callLinks = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "facetime.apple.com", "slack.com/huddle"]

    /// A meeting with other people, or anything with a video-call link.
    private static func isCall(_ event: EKEvent) -> Bool {
        let others = (event.attendees ?? []).filter { !$0.isCurrentUser }
        if !others.isEmpty { return true }
        let text = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
        return callLinks.contains { text.contains($0) }
    }

    private func call(_ event: EKEvent) -> Call {
        let title = event.title ?? ""
        let guests = (event.attendees ?? []).filter { !$0.isCurrentUser }
        let guestNames = guests.map { guest -> String in
            if let name = guest.name, !name.isEmpty, !name.contains("@") { return name }
            let email = guest.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return email.components(separatedBy: "@").first ?? email
        }
        let people = store.people.map(\.name).filter { person in
            guestNames.contains { Self.matches(person, $0) } || Self.mentions(title, person)
        }
        let raw = "\(event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? title)|\(Int(event.startDate.timeIntervalSince1970))"
        let id = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        var call = Call(id: String(id), title: title, start: event.startDate, end: event.endDate, people: people, guests: guests.count)
        call.organizer = event.organizer?.isCurrentUser ?? (guests.isEmpty)
        return call
    }

    private func call(_ event: GoogleCalendar.Event) -> Call {
        let people = store.people.map(\.name).filter { person in
            event.guests.contains { Self.matches(person, $0) } || Self.mentions(event.title, person)
        }
        let raw = "google:\(event.id)|\(Int(event.start.timeIntervalSince1970))"
        let id = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        var call = Call(id: String(id), title: event.title, start: event.start, end: event.end, people: people, guests: event.guests.count)
        call.organizer = event.organizerIsMe
        return call
    }

    /// "Sarah" matches the guest "Sarah Jones" or "sarah.jones".
    private static func matches(_ person: String, _ guest: String) -> Bool {
        let first = guest.lowercased().components(separatedBy: CharacterSet(charactersIn: " ._-")).first ?? ""
        return first == person.lowercased() || guest.caseInsensitiveCompare(person) == .orderedSame
    }

    /// "Catch-up with Sarah" mentions Sarah; "Sarahs" doesn't.
    private static func mentions(_ title: String, _ person: String) -> Bool {
        let words = title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        let name = person.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !name.isEmpty else { return false }
        return words.indices.contains { i in
            i + name.count <= words.count && Array(words[i..<(i + name.count)]) == name
        }
    }

    /// During a call with someone you track, their name goes on every moment; after, it's handed back.
    private func followCurrentCall() {
        let model = AppModel.shared
        if let call = current, let person = call.people.first {
            if autoPerson?.call != call.id {
                autoPerson = (call.id, autoPerson?.previous ?? model.talkingWith)
                model.talkingWith = person
            }
        } else if let auto = autoPerson {
            model.talkingWith = auto.previous
            autoPerson = nil
        }
    }

    // MARK: Before the call: the prep

    struct Lead: Identifiable {
        let label: String
        let minutes: Int
        var id: Int { minutes }
    }
    static let leads = [Lead(label: String(localized: "15 minutes before"), minutes: 15), Lead(label: String(localized: "1 hour before"), minutes: 60),
                        Lead(label: String(localized: "2 hours before"), minutes: 120), Lead(label: String(localized: "The evening before"), minutes: 0)]

    private var leadMinutes: Int {
        defaults.object(forKey: Key.prepLead) == nil ? 120 : defaults.integer(forKey: Key.prepLead)
    }

    /// When the prep notification goes out for this call.
    func prepTime(_ call: Call) -> Date {
        if leadMinutes == 0 {
            let dayBefore = Calendar.current.date(byAdding: .day, value: -1, to: call.start)!
            return Calendar.current.date(bySettingHour: 20, minute: 30, second: 0, of: dayBefore)!
        }
        return call.start.addingTimeInterval(-Double(leadMinutes) * 60)
    }

    /// What to go over before this call: what you missed with these people, still not known.
    func prep(for call: Call) -> [Moment] {
        let pool = call.people.isEmpty
            ? store.moments.filter { $0.context == "call" }
            : store.moments.filter { m in call.people.contains { $0 == m.with } }
        return Array(pool.filter { !$0.graduated && $0.review != .known }.prefix(8))
    }

    private func schedulePreps() {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        var keep: Set<String> = []
        defer {
            // Calls that moved or were cancelled lose their prep; the others are replaced in place.
            let kept = keep
            center.getPendingNotificationRequests { requests in
                let stale = requests.map(\.identifier).filter { ($0.hasPrefix("prep-") || $0.hasPrefix("notice-")) && !kept.contains($0) }
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
        }
        for call in calls where call.start > now {
            scheduleNotice(call, now: now, keep: &keep)
            // The notice 15 minutes before already carries the recap: a separate prep only when earlier.
            if leadMinutes == 15 && CallNotice.current != .never { continue }
            let moments = prep(for: call)
            guard !moments.isEmpty else { continue }
            let at = max(prepTime(call), now.addingTimeInterval(5))
            guard at < call.start else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(call.who) at \(call.start.formatted(date: .omitted, time: .shortened))")
            let pieces = moments.flatMap(\.pieces).map(\.text).prefix(3)
            content.body = pieces.isEmpty
                ? (moments.count == 1 ? String(localized: "1 thing slipped past you last time. Two minutes to go over it?")
                                      : String(localized: "\(moments.count) things slipped past you last time. Two minutes to go over them?"))
                : String(localized: "Last time: \(pieces.joined(separator: ", ")). Two minutes to go over them?")
            content.userInfo = ["kind": "prep", "call": call.id]
            keep.insert("prep-\(call.id)")
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
            center.add(UNNotificationRequest(identifier: "prep-\(call.id)", content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
    }

    /// The notice 15 minutes before (§ 19.15): last time with these people, and this call's mode,
    /// already chosen; the buttons change it with one tap, and it's remembered.
    private func scheduleNotice(_ call: Call, now: Date, keep: inout Set<String>) {
        let notice = CallNotice.current
        guard notice != .never, notice == .all || CallHistory.isHard(call) else { return }
        let at = call.start.addingTimeInterval(-CallNotice.minutes * 60)
        guard at > now else { return }
        let mode = CallModes.mode(for: call)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(call.who) at \(call.start.formatted(date: .omitted, time: .shortened)) · \(mode.label)")
        let recap = CallHistory.last(like: call, before: call.start).map(CallHistory.recap)
        content.body = (recap.map { $0 + " " } ?? "") + mode.detail + " " + String(localized: "Change it below.")
        content.categoryIdentifier = CallNotice.category
        content.userInfo = ["kind": "notice", "call": call.id]
        let id = "notice-\(call.id)"
        keep.insert(id)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content,
                                                                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }

    // MARK: After the call: the lesson

    /// The moments from this call: tagged during it, or tapped while it was on.
    func moments(of call: Call) -> [Moment] {
        store.moments.filter { m in
            m.call == call.id || (m.call == nil && m.date >= call.start.addingTimeInterval(-120) && m.date <= call.end.addingTimeInterval(300))
        }.sorted { $0.date < $1.date }
    }

    private var lessonsSent: Set<String> {
        get { Set(defaults.stringArray(forKey: "lessonsSent") ?? []) }
        set { defaults.set(Array(newValue.suffix(200)), forKey: "lessonsSent") }
    }

    private func sendLessons() {
        let now = Date()
        for call in calls where call.end.addingTimeInterval(120) <= now && call.end.addingTimeInterval(3 * 3600) > now {
            guard !lessonsSent.contains(call.id) else { continue }
            let moments = self.moments(of: call)
            guard !moments.isEmpty else { continue }
            lessonsSent.insert(call.id)
            let content = UNMutableNotificationContent()
            content.title = moments.count == 1 ? String(localized: "Your call with \(call.who): 1 moment") : String(localized: "Your call with \(call.who): \(moments.count) moments")
            let pieces = moments.flatMap(\.pieces).map(\.text).prefix(3)
            content.body = (pieces.isEmpty ? "" : pieces.joined(separator: " · ") + ". ") + String(localized: "Five minutes now, while it's fresh?")
            content.userInfo = ["kind": "lesson", "call": call.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lesson-\(call.id)", content: content, trigger: nil))
        }
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String, id = info["call"] as? String
        let since = info["since"] as? Double
        let event = info["event"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == "participants.copy" || (kind == "participants" && action == UNNotificationDefaultActionIdentifier) {
                ParticipantNotice.copy()
            } else if action == "calendar.addNotice", let event {
                await GoogleCalendar.shared.addNotice(to: event)
            } else if action == "participants.told" {
                CallGuard.shared.markTold()
            } else if action.hasPrefix("mode."), let mode = CallMode(rawValue: String(action.dropFirst(5))) {
                CallModes.set(mode, for: CalendarWatch.shared.calls.first { $0.id == id })
            } else if kind == "quiz" {
                ModelWatch.shared.openQuiz(since: Date(timeIntervalSince1970: (since ?? 0) - 1))
            } else if kind == "report", let id {
                CallCoach.shared.openReport(id)
            } else if let id, let call = CalendarWatch.shared.calls.first(where: { $0.id == id }) {
                if kind == "lesson" { CalendarWatch.shared.openLesson(call) } else { CalendarWatch.shared.openPrep(call) }
            }
        }
        completionHandler()
    }

    func openPrep(_ call: Call) {
        AppWindows.show(id: "prep", title: String(localized: "Before your call"), width: 460, height: 560) {
            PrepView(call: call).environmentObject(AppModel.shared.store)
        }
    }

    func openLesson(_ call: Call) {
        let ids = moments(of: call).map(\.id)
        AppWindows.show(id: "lesson", title: String(localized: "Your call with \(call.who)"), width: 520, height: 640) {
            ReviewView(only: ids, title: String(localized: "Your call with \(call.who)")).environmentObject(AppModel.shared.store)
        }
    }

    func practice(_ call: Call) {
        let ids = prep(for: call).map(\.id)
        AppWindows.show(id: "lesson", title: String(localized: "Before your call"), width: 520, height: 640) {
            ReviewView(only: ids, title: String(localized: "Before \(call.who)")).environmentObject(AppModel.shared.store)
        }
    }
}

/// Windows opened from outside SwiftUI scenes (a notification click).
@MainActor
enum AppWindows {
    private static var windows: [String: NSWindow] = [:]

    static func show<Content: View>(id: String, title: String, width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) {
        let window = windows[id] ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            // Every window in the panel's look: dark, warm, quiet (owner, 02/10).
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(Brand.onyx)
            w.titlebarAppearsTransparent = true
            w.center()
            windows[id] = w
            return w
        }()
        window.title = title
        window.contentView = NSHostingView(rootView: content())
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Before a call: who it's with, and what slipped past you last time with them.
struct PrepView: View {
    let call: Call
    @EnvironmentObject private var store: Store

    init(call: Call) {
        self.call = call
    }

    var body: some View {
        let moments = CalendarWatch.shared.prep(for: call)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(call.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Text(call.title.isEmpty ? call.who : call.title).font(.title2.weight(.semibold))
                if !call.people.isEmpty {
                    Text(call.people.map { name in
                        store.accent(of: name).map { "\(name) · \($0)" } ?? name
                    }.joined(separator: "   ")).foregroundStyle(.secondary)
                }
            }
            if moments.isEmpty {
                Text("Nothing slipped past you with \(call.who) yet. Tap whenever something does: it'll be here next time.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(call.people.isEmpty ? String(localized: "What slipped past you in recent calls") : String(localized: "What slipped past you last time"))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(moments) { moment in
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(moment.pieces.enumerated()), id: \.offset) { _, piece in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(piece.text).font(.system(size: 15, weight: .semibold))
                                        Text(piece.meaning).foregroundStyle(.secondary)
                                    }
                                }
                                if moment.pieces.isEmpty { Text(moment.transcript).lineLimit(2) }
                                Text(moment.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            YourselfCard(people: call.people)
            Divider()
            PrepCard(call: call)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if !moments.isEmpty {
                    Button("Practise them now") { CalendarWatch.shared.practice(call) }
                        .buttonStyle(.borderedProminent).tint(Brand.accent).foregroundStyle(Brand.onyx)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 480)
    }
}
