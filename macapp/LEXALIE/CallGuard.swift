import AppKit
import SwiftUI
import UserNotifications

/// Telling the others in the call (docs/PIANO.md, block N). In Germany, in many US states and in
/// many companies listening to a call without the others knowing isn't allowed. In this version
/// nobody is told automatically: when a call starts, a notification only for you offers the
/// message, ready to copy. "Required" keeps LEXALIE deaf until you say you told them.
enum ParticipantNotice: String, CaseIterable, Identifiable {
    case off, remind, required
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .remind: String(localized: "Remind me when a call starts")
        case .required: String(localized: "Don't listen until I've told them")
        }
    }

    static var current: ParticipantNotice {
        ParticipantNotice(rawValue: UserDefaults.standard.string(forKey: Key.participantNotice) ?? "") ?? .remind
    }

    /// The message, in the language of the call (the language you hear), never the app's.
    static func message(for heard: HeardLanguage = AppSettings.current.heard) -> String {
        switch String(heard.rawValue.prefix(2)) {
        case "it": "Uso LEXALIE per seguire meglio la call: nessun bot entra nella call e non si conserva la registrazione. Trascrive sul mio Mac quello che si dice, solo per aiutarmi a capire, e posso cancellarlo quando voglio."
        case "es": "Uso LEXALIE para seguir mejor la llamada: ningún bot entra en la llamada y no se guarda la grabación. Transcribe en mi Mac lo que se dice, solo para ayudarme a entender, y puedo borrarlo cuando quiera."
        case "fr": "J’utilise LEXALIE pour mieux suivre l’appel : aucun bot ne rejoint l’appel et aucun enregistrement n’est gardé. Il transcrit sur mon Mac ce qui se dit, seulement pour m’aider à comprendre, et je peux l’effacer quand je veux."
        case "de": "Ich nutze LEXALIE, um dem Call besser zu folgen: Kein Bot tritt bei, und es wird keine Aufnahme behalten. Es schreibt auf meinem Mac mit, was gesagt wird, nur damit ich es verstehe, und ich kann es jederzeit löschen."
        case "ru": "Я пользуюсь LEXALIE, чтобы лучше следить за звонком: никакой бот не подключается, и запись не сохраняется. Он расшифровывает на моём Mac то, что говорится, только чтобы помочь мне понять, и я могу удалить это в любой момент."
        case "pt": "Uso o LEXALIE para acompanhar melhor a chamada: nenhum bot entra na chamada e não se guarda a gravação. Transcreve no meu Mac o que se diz, só para me ajudar a perceber, e posso apagar quando quiser."
        default: "I’m using LEXALIE to follow the call better: no bot joins the call and no recording is kept. It transcribes on my Mac what is said, only to help me understand, and I can delete it whenever I want."
        }
    }

    static let category = "participants"

    static func registerCategory() {
        let copy = UNNotificationAction(identifier: "participants.copy", title: String(localized: "Copy message"), options: [])
        let told = UNNotificationAction(identifier: "participants.told", title: String(localized: "I told them"), options: [])
        let made = UNNotificationCategory(identifier: Self.category, actions: [copy, told], intentIdentifiers: [])
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            UNUserNotificationCenter.current().setNotificationCategories(existing.filter { $0.identifier != made.identifier }.union([made]))
        }
    }

    static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message(), forType: .string)
    }
}

/// Calls LEXALIE never listens to (docs/PIANO.md, F4): a meeting, a person, or a call app.
enum NeverCalls {
    enum Kind: String { case meeting, person, app }

    struct Rule: Hashable, Identifiable {
        let kind: Kind
        let value: String
        var id: String { "\(kind.rawValue):\(value)" }

        var label: String {
            switch kind {
            case .meeting: String(localized: "Meeting: \(value)")
            case .person: String(localized: "With \(value)")
            case .app: String(localized: "App: \(NeverCalls.appName(value))")
            }
        }
    }

    static var rules: [Rule] {
        (UserDefaults.standard.stringArray(forKey: Key.neverCalls) ?? []).compactMap { raw in
            guard let colon = raw.firstIndex(of: ":"), let kind = Kind(rawValue: String(raw[..<colon])) else { return nil }
            return Rule(kind: kind, value: String(raw[raw.index(after: colon)...]))
        }
    }

    static func add(_ rule: Rule) {
        var all = UserDefaults.standard.stringArray(forKey: Key.neverCalls) ?? []
        guard !all.contains(rule.id), !rule.value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        all.append(rule.id)
        UserDefaults.standard.set(all, forKey: Key.neverCalls)
    }

    static func remove(_ rule: Rule) {
        let all = (UserDefaults.standard.stringArray(forKey: Key.neverCalls) ?? []).filter { $0 != rule.id }
        UserDefaults.standard.set(all, forKey: Key.neverCalls)
    }

    /// The call apps people can exclude, by the name ContextDetector.callApp() gives them.
    static let apps = ["com.microsoft.teams2", "us.zoom.xos", "meet", "com.apple.FaceTime", "com.cisco.webexmeetingsapp",
                       "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.hnc.Discord"]

    static func appName(_ id: String) -> String {
        switch id {
        case "com.microsoft.teams2", "com.microsoft.teams", "teams": "Microsoft Teams"
        case "us.zoom.xos", "zoom": "Zoom"
        case "meet": "Google Meet"
        case "com.apple.FaceTime": "FaceTime"
        case "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "webex": "Webex"
        case "net.whatsapp.WhatsApp": "WhatsApp"
        case "ru.keepcoder.Telegram": "Telegram"
        case "com.hnc.Discord": "Discord"
        default: id
        }
    }

    /// The rule that keeps LEXALIE out of this call, if any.
    static func match(call: Call?, app: String?) -> Rule? {
        rules.first { rule in
            switch rule.kind {
            case .meeting:
                return call.map { $0.title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(rule.value) == .orderedSame } ?? false
            case .person:
                return call?.people.contains { $0.caseInsensitiveCompare(rule.value) == .orderedSame } ?? false
            case .app:
                guard let app else { return false }
                return app == rule.value || (rule.value == "com.microsoft.teams2" && app == "com.microsoft.teams")
            }
        }
    }
}

/// Every few seconds during a call: should LEXALIE listen, and has the notice gone out.
@MainActor
final class CallGuard: ObservableObject {
    static let shared = CallGuard()

    enum Block: Equatable {
        /// A call you excluded (the rule's label).
        case excluded(String)
        /// "Don't listen until I've told them", and you haven't yet.
        case waitingForNotice
    }

    /// Why LEXALIE isn't listening right now; nil when it may.
    @Published private(set) var block: Block?
    /// The call going on, as LEXALIE sees it (a calendar call or a call app).
    @Published private(set) var callKey: String?

    private var lastSeen = Date.distantPast
    private var told: Set<String> = []
    private var notified: Set<String> = []

    func tick() {
        let now = Date()
        let calendarCall = CalendarWatch.shared.current
        let app = ContextDetector.callApp()
        let inCall = app != nil || (calendarCall != nil && ContextDetector.current() == .call)
        if inCall {
            lastSeen = now
            if callKey == nil {
                // A new call: the calendar's id when there is one, otherwise the app and the hour.
                callKey = calendarCall?.id ?? "\(app ?? "call")-\(Int(now.timeIntervalSince1970 / 3600))"
            }
        } else if callKey != nil, now.timeIntervalSince(lastSeen) > 90 {
            callKey = nil
        }
        guard let key = callKey else {
            setBlock(nil)
            return
        }
        if let rule = NeverCalls.match(call: calendarCall, app: app) {
            setBlock(.excluded(rule.label))
            return
        }
        let notice = ParticipantNotice.current
        if notice != .off, !notified.contains(key) {
            notified.insert(key)
            Task { await self.notify(required: notice == .required) }
        }
        setBlock(notice == .required && !told.contains(key) ? .waitingForNotice : nil)
    }

    /// You told the others: LEXALIE may listen to this call.
    func markTold() {
        guard let key = callKey else { return }
        told.insert(key)
        setBlock(nil)
    }

    private func setBlock(_ new: Block?) {
        guard new != block else { return }
        block = new
        AppModel.shared.guardChanged()
    }

    private func notify(required: Bool) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        ParticipantNotice.registerCategory()
        let content = UNMutableNotificationContent()
        content.title = required ? String(localized: "Call started: LEXALIE waits until you've told them")
                                 : String(localized: "Call started: do you want to tell the others?")
        content.body = ParticipantNotice.message()
        content.categoryIdentifier = ParticipantNotice.category
        content.userInfo = ["kind": "participants"]
        try? await center.add(UNNotificationRequest(identifier: "participants-\(callKey ?? "call")", content: content, trigger: nil))
    }
}

/// In the menu, during a call: the message to copy, "I told them", and "Never in this call".
struct CallGuardRow: View {
    @ObservedObject private var guardian = CallGuard.shared
    @State private var copied = false

    var body: some View {
        if guardian.callKey != nil {
            VStack(alignment: .leading, spacing: 6) {
                switch guardian.block {
                case .excluded(let label)?:
                    Label(String(localized: "Not listening in this call (\(label))"), systemImage: "ear.trianglebadge.exclamationmark")
                        .font(.caption)
                case .waitingForNotice?:
                    Text("Not listening yet: tell the others first.").font(.caption).foregroundStyle(.orange)
                    buttons(told: true)
                case nil:
                    if ParticipantNotice.current != .off { buttons(told: false) }
                }
                if !excluded {
                    Button("Never listen in calls like this one") { neverHere() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private var excluded: Bool {
        if case .excluded? = guardian.block { return true }
        return false
    }

    @ViewBuilder private func buttons(told: Bool) -> some View {
        HStack {
            Button(copied ? String(localized: "Copied") : String(localized: "Copy the message for the others")) {
                ParticipantNotice.copy()
                copied = true
            }
            if told { Button("I told them") { CallGuard.shared.markTold() } }
        }
        .controlSize(.small)
    }

    private func neverHere() {
        if let call = CalendarWatch.shared.current, !call.title.trimmingCharacters(in: .whitespaces).isEmpty {
            NeverCalls.add(.init(kind: .meeting, value: call.title.trimmingCharacters(in: .whitespaces)))
        } else if let app = ContextDetector.callApp() {
            NeverCalls.add(.init(kind: .app, value: app))
        }
        CallGuard.shared.tick()
    }
}

/// Settings → Privacy: calls LEXALIE never listens to, and telling the others.
struct NeverCallsSection: View {
    @AppStorage(Key.participantNotice) private var notice = ParticipantNotice.remind.rawValue
    @State private var rules = NeverCalls.rules
    // Not from the environment: this section must never take the Settings window down (05/10).
    @ObservedObject private var store = AppModel.shared.store
    @ObservedObject private var calendar = CalendarWatch.shared

    var body: some View {
        Picker("Tell the others in the call", selection: $notice) {
            ForEach(ParticipantNotice.allCases) { Text($0.label).tag($0.rawValue) }
        }
        Text("When a call starts, a notification only for you with this message, ready to copy into the chat: “\(ParticipantNotice.message())”")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Never listen in these calls")
                Spacer()
                Menu("Add") {
                    Menu("A call app") {
                        ForEach(NeverCalls.apps, id: \.self) { app in
                            Button(NeverCalls.appName(app)) { add(.init(kind: .app, value: app)) }
                        }
                    }
                    Menu("A meeting from your calendar") {
                        ForEach(uniqueTitles, id: \.self) { title in
                            Button(title) { add(.init(kind: .meeting, value: title)) }
                        }
                    }
                    .disabled(uniqueTitles.isEmpty)
                    Menu("A person") {
                        ForEach(store.people) { person in
                            Button(person.name) { add(.init(kind: .person, value: person.name)) }
                        }
                    }
                    .disabled(store.people.isEmpty)
                }
                .fixedSize()
            }
            ForEach(rules) { rule in
                HStack {
                    Text(rule.label).font(.callout)
                    Spacer()
                    Button("Remove") { NeverCalls.remove(rule); rules = NeverCalls.rules }
                        .controlSize(.small)
                }
            }
            Text("In these calls LEXALIE doesn't listen at all: nothing is heard, nothing is kept.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var uniqueTitles: [String] {
        var seen = Set<String>()
        return calendar.calls.map { $0.title.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func add(_ rule: NeverCalls.Rule) {
        NeverCalls.add(rule)
        rules = NeverCalls.rules
        CallGuard.shared.tick()
    }
}
