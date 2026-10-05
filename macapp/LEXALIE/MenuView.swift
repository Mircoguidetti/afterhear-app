import SwiftUI

/// The window under the menu bar icon.
struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @ObservedObject private var account = Account.shared
    @ObservedObject private var sync = Sync.shared
    @ObservedObject private var calendar = CalendarWatch.shared
    @Environment(\.openWindow) private var openWindow
    @State private var newName = ""
    @State private var newAccent = Person.accents[0]
    @State private var addingPerson = false
    @State private var songLine: String?

    @ObservedObject private var watch = ModelWatch.shared

    /// In a call: Just mark, Suggestions or With me, for this call and the ones like it (§ 19.15).
    @ViewBuilder private var callSuggestions: some View {
        if watch.kind == .call {
            VStack(alignment: .leading, spacing: 4) {
                Picker("This call", selection: Binding(get: { watch.callMode }, set: { watch.setCallMode($0) })) {
                    ForEach(CallMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(watch.callMode.detail).font(.caption).foregroundStyle(.secondary)
            }
        } else if watch.kind == .video {
            // "Use your model", where it matters (§ 19.8): watching together, a light sign at most every 90 s.
            Toggle(isOn: Binding(get: { watch.enabled },
                                 set: { watch.setWatching($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watch with me")
                    Text("Your model listens in silence, never interrupts: a quiz at the end.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    /// Clean on purpose (owner, 02/10: frictionless): how it's going, the one button, today, four
    /// doors. Everything else lives in Settings or behind "More".
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            status
            if model.state == .listening {
                Button {
                    Task { await model.captureMoment(now: true) }
                } label: {
                    HStack {
                        Text("What did I miss?")
                        Spacer()
                        Text(DoubleTapOption.nowLabel).foregroundStyle(.secondary).font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Text("\(DoubleTapOption.label): mark for tonight · \(DoubleTapOption.nowLabel): help me now")
                    .font(.caption).foregroundStyle(.secondary)
                if model.needsAccessibility {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The gestures need the \"Accessibility\" permission: turn on LEXALIE, then reopen it.")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Open Settings") { DoubleTapOption.openSettings() }
                            Button("Reopen") { model.relaunch() }
                        }
                        .controlSize(.small)
                    }
                }
                // The private model, until it's ready (then the line goes away).
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let heard = AppSettings.current.heard
                    if !Parakeet.isDownloaded(heard) {
                        Text("Private model: \(Parakeet.status.label)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if watch.kind == .call { callSuggestions }
                CallGuardRow()
                nextCall
            }

            if !todayMoments.isEmpty {
                Divider()
                Text("Today").font(.caption).foregroundStyle(.secondary)
                ForEach(todayMoments.prefix(3)) { moment in
                    HStack(alignment: .firstTextBaseline) {
                        Text(moment.pieces.map(\.text).joined(separator: " · ").ifEmpty(moment.transcript))
                            .font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(moment.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if model.waiting > 0 {
                Text(model.lowBattery ? String(localized: "Battery low: \(model.waiting) saved, explained when you charge")
                                      : String(localized: "\(model.waiting) saved, explained as soon as possible"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Review (\(store.reviewQueue.count))") { open("review") }
                    .disabled(store.reviewQueue.isEmpty)
                Button("Progress") {
                    AppWindows.show(id: "progress", title: String(localized: "Your progress"), width: 480, height: 520) { ProgressStoryView() }
                }
                Button("Settings") { open("settings") }
                Menu("More") {
                    Button("Diary") { open("diary") }
                    Button("Your week") { Podcast.shared.open() }
                    Button("Is everything ready?") { HealthCheck.shared.open() }
                    if quizCount > 0 { Button("Quiz (\(quizCount))") { ModelWatch.shared.openAllQuiz() } }
                    Divider()
                    Button(model.state == .paused ? String(localized: "Resume listening") : String(localized: "Pause listening")) {
                        Task { await model.togglePause() }
                    }
                    .disabled(model.state == .starting)
                    Button("Quit LEXALIE") { NSApp.terminate(nil) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .controlSize(.small)
            HStack {
                Text(Self.version)
                Spacer()
                Text(syncLine)
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var syncLine: String {
        guard account.signedIn else { return String(localized: "Not signed in") }
        if let status = sync.status { return status }
        if let last = sync.lastSync { return String(localized: "Synced \(last.formatted(date: .omitted, time: .shortened))") }
        return String(localized: "Syncing…")
    }

    static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "LEXALIE \(short) · build \(build)"
    }()

    /// Who you're talking with: every moment of this conversation gets the label.
    @ViewBuilder private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who are you talking with?").font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("", selection: Binding(get: { model.talkingWith ?? "" }, set: { model.talkingWith = $0.isEmpty ? nil : $0 })) {
                    Text("Not set").tag("")
                    ForEach(store.people) { person in
                        Text(verbatim: "\(person.name) · \(Person.label(person.accent))").tag(person.name)
                    }
                }
                .labelsHidden()
                Button {
                    addingPerson.toggle()
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .help("Add a person or a group")
            }
            if addingPerson {
                HStack {
                    TextField("Name (e.g. Sarah, Marketing team)", text: $newName)
                    Picker("", selection: $newAccent) {
                        ForEach(Person.accents, id: \.self) { Text(Person.label($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                Button("Save") {
                    store.upsertPerson(Person(name: newName, accent: newAccent))
                    model.talkingWith = newName.trimmingCharacters(in: .whitespaces)
                    newName = ""
                    addingPerson = false
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                .controlSize(.small)
            }
        }
    }

    private var quizCount: Int { store.moments.filter(\.waitsForQuiz).count }

    /// The song playing, and "What's this song?" for music from a speaker (§ 17.1).
    @ViewBuilder private var songRow: some View {
        if NowPlaying.following {
            HStack {
                Label(songLine ?? NowPlaying.current()?.label ?? String(localized: "No song playing"), systemImage: "music.note")
                    .font(.caption).lineLimit(1)
                Spacer()
                Button("What's this song?") {
                    songLine = String(localized: "Listening…")
                    Task { songLine = await NowPlaying.identify()?.label ?? String(localized: "Not recognised") }
                }
                .controlSize(.small)
            }
        }
    }

    /// Today's taps against time listened: the number that should go down.
    private var stats: some View {
        let minutes = Int(store.listeningToday / 60)
        let rate = String(format: "%.1f", Double(store.tapsToday) / max(store.listeningToday / 3600, 0.01))
        let perHour = store.listeningToday > 600 ? String(localized: " · \(rate) per hour") : ""
        return Text("Today: \(store.tapsToday) moments in \(minutes) min of listening\(perHour)")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// The next call from your calendar and its prep; or an invitation to connect the calendar.
    @ViewBuilder private var nextCall: some View {
        switch calendar.access {
        case .off, .notAsked:
            Button {
                calendar.enabled = true
            } label: {
                Label("Prep before your calls: connect your calendar", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.link).font(.caption)
        case .denied:
            Text("LEXALIE can't read your calendar: allow it in System Settings → Privacy → Calendars.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .granted:
            if let call = calendar.current {
                Label("In a call with \(call.who): moments go to its lesson", systemImage: "phone.fill")
                    .font(.caption).foregroundStyle(Brand.accent)
            } else if let call = calendar.next {
                HStack {
                    Label("\(call.who) · \(call.start.formatted(date: .omitted, time: .shortened))", systemImage: "calendar")
                        .font(.caption).lineLimit(1)
                    Spacer()
                    Button("Prep") { calendar.openPrep(call) }.controlSize(.small)
                }
            }
        }
    }

    private var todayMoments: [Moment] {
        store.moments.filter { Calendar.current.isDateInToday($0.date) }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .starting:
            Label("Starting…", systemImage: "hourglass")
        case .listening:
            VStack(alignment: .leading, spacing: 4) {
                Label("Listening", systemImage: "waveform").foregroundStyle(Brand.accent)
                Text("Only the last few minutes stay in memory. Nothing is saved until you tap.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paused:
            Label("Paused: not listening", systemImage: "pause.circle")
        case .needsPermission(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Permission needed", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open System Settings") { model.openScreenRecordingSettings() }
                    Button("Reopen LEXALIE") { model.relaunch() }
                }
                .controlSize(.small)
            }
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
