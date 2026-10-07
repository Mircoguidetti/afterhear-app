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
    @AppStorage(Key.tapLater) private var tapLater = false

    /// What LEXALIE is hearing now, in a word (block M).
    private var hearing: String {
        switch watch.kind {
        case .call: String(localized: "Listening to a call")
        case .video: String(localized: "Listening to a video")
        case .song: String(localized: "Listening to music")
        case nil: String(localized: "Listening")
        }
    }

    /// Watching a video: your model, in silence, with you (§ 19.8).
    @ViewBuilder private var callSuggestions: some View {
        if watch.kind == .video {
            // "Use your model", where it matters (§ 19.8): watching together, a light sign at most every 90 s.
            Toggle(isOn: Binding(get: { watch.enabled },
                                 set: { watch.setWatching($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watch with me")
                    Text("Your model listens in silence, never interrupts: at the end, what a local got.")
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
                    Task { await model.captureMoment(trigger: "menu", now: true) }
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
                // The one switch (block M): what every tap does, until you change it.
                VStack(alignment: .leading, spacing: 4) {
                    Text("When I tap").font(.caption).foregroundStyle(.secondary)
                    Picker("When I tap", selection: $tapLater) {
                        Text("Explain now").tag(false)
                        Text("At the end").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: tapLater) { _ in model.objectWillChange.send() }
                    // "Tell me later" (block COSA 6): nothing interrupts you, the end card explains them all.
                    if tapLater {
                        Text("Nothing interrupts you: explained together when the video, the call or the conversation ends.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Not now, without quitting: back by itself in an hour or at the end of the call (block M).
                Button("Pause for an hour") { Task { await model.togglePause() } }
                    .controlSize(.small)
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
                if watch.kind == .video { callSuggestions }
                if watch.kind == .call {
                    // Telling the others (block N), here and not in a notification at the start of the call.
                    Button("Copy the message for the others in the call") { ParticipantNotice.copy() }.controlSize(.small)
                }
                CallGuardRow()
                InPersonRow()
                nextCall
            }

            // What matters first (block COSA): the few things worth knowing, not the list of taps.
            let matters = WhatMatters.summary(store.moments, known: store.known).items
            if !matters.isEmpty {
                Divider()
                Button { open("matters") } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("What matters").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(matters.prefix(3)) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(item.why).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if model.waiting > 0 {
                Text(model.lowBattery ? String(localized: "Battery low: \(model.waiting) saved, explained when you charge")
                                      : String(localized: "\(model.waiting) saved, explained as soon as possible"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                // One evening moment (block SERA): today's moments with the real voice, "I know it / again".
                Button("Tonight (\(store.reviewQueue.count))") { open("review") }
                    .disabled(store.reviewQueue.isEmpty)
                Button("Progress") {
                    AppWindows.show(id: "progress", title: String(localized: "Your progress"), width: 480, height: 520) { ProgressStoryView() }
                }
                Button("Settings") { open("settings") }
                Menu("More") {
                    Button("What matters") { open("matters") }
                    Button("All moments") { open("diary") }
                    Button("Your week") { Podcast.shared.open() }
                    Button("Is everything ready?") { HealthCheck.shared.open() }
                    Divider()
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

    @ViewBuilder private var status: some View {
        switch model.state {
        case .starting:
            Label("Starting…", systemImage: "hourglass")
        case .listening:
            VStack(alignment: .leading, spacing: 4) {
                Label(hearing, systemImage: tapLater ? "waveform.circle" : "waveform.circle.fill").foregroundStyle(Brand.paper)
                Text("Only the last few minutes stay in memory. Nothing is saved until you tap.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paused:
            VStack(alignment: .leading, spacing: 6) {
                Label("Paused: not listening", systemImage: "waveform.slash")
                Text("It starts again by itself in an hour, or when this call ends.").font(.caption).foregroundStyle(.secondary)
                Button("Listen again") { Task { await model.togglePause() } }.controlSize(.small)
            }
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
