import SwiftUI

struct SettingsView: View {
    @AppStorage(Key.code) private var code = ""
    @AppStorage(Key.server) private var server = AppSettings.defaultServer
    @AppStorage(Key.webApp) private var webApp = AppSettings.defaultWebApp
    @AppStorage(Key.heard) private var heard = HeardLanguage.enGB.rawValue
    @AppStorage(Key.native) private var native = NativeLanguage.system.rawValue
    @AppStorage(Key.showTranslation) private var showTranslation = true
    @AppStorage(Key.pauseVideo) private var pauseVideo = true
    @AppStorage(Key.sorry) private var sorry = true
    @AppStorage(Key.doubleTap) private var doubleTap = true
    @AppStorage(Key.keyword) private var keyword = ""
    @AppStorage(Key.callsTextOnly) private var callsTextOnly = false
    @AppStorage(Key.callReport) private var callReport = false
    @AppStorage(Key.myName) private var myName = ""
    @AppStorage(Key.dictionary) private var dictionary = ""
    @AppStorage(Key.useModel) private var useModel = false
    @AppStorage(Key.songs) private var songs = true
    @AppStorage(Key.airpods) private var airpods = false
    @AppStorage(Key.pauseTap) private var pauseTap = true
    @AppStorage("googleClientID") private var googleClientID = ""

    @State private var advanced = false
    /// Tester code, Google client ID, server and web app: ours, for tests (owner, 04/10). Hidden unless
    /// `defaults write app.lexalie.mac developer -bool YES`.
    @AppStorage("developer") private var developer = false

    /// The few things people actually choose, in view; everything else under Advanced (owner, 02/10:
    /// frictionless, not forty switches).
    var body: some View {
        Form {
            Section("Languages") {
                Picker("Your language", selection: $native) {
                    ForEach(NativeLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: native) { _ in AppLanguage.apply() }
                // The app speaks your language too; every word changes on the next start (owner, 03/10).
                if native != AppLanguage.shown {
                    HStack {
                        Text("LEXALIE will speak this language after a restart.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart now") { AppModel.shared.relaunch() }.controlSize(.small)
                    }
                }
                Picker("The language you want to understand", selection: $heard) {
                    ForEach(HeardLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: heard) { _ in AppModel.shared.languageChanged() }
                // No level to choose (owner, 06/10 night): LEXALIE learns it from your cards.
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("The sentence in your language too", isOn: $showTranslation)
                    Text("Under each sentence, what it says in your language.").font(.caption).foregroundStyle(.secondary)
                }
                TranslationRow(heard: HeardLanguage(rawValue: heard) ?? .enGB, native: NativeLanguage(rawValue: native) ?? .system)
            }
            Section("When you ask for help (\(DoubleTapOption.nowLabel))") {
                Toggle("Pause the video while I read", isOn: $pauseVideo)
            }
            // One evening moment (block SERA): at this hour, only on a day with moments; Sunday, the week.
            Section("Tonight") {
                Picker("Tonight's moment at", selection: Binding(get: { Evening.hour }, set: { UserDefaults.standard.set($0, forKey: Evening.hourKey) })) {
                    ForEach(17..<24, id: \.self) { Text(verbatim: "\($0):00").tag($0) }
                }
            }
            Section("Gestures") {
                Text("\(DoubleTapOption.label): mark it for tonight. \(DoubleTapOption.nowLabel): help me now.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Use \(DoubleTapOption.label) and \(DoubleTapOption.nowLabel)", isOn: $doubleTap)
                    .onChange(of: doubleTap) { _ in AppModel.shared.applyTriggers() }
                // Pause = tap (owner, 03/10): the AirPods' press and the space bar pause the song or the
                // video, and that pause asks for the line.
                Toggle("Pause to ask: pause a song or a video right after a line, and LEXALIE offers that line", isOn: $pauseTap)
                // In view, not under Advanced (owner, 03/10). It reaches LEXALIE only when nothing else plays.
                Toggle("Squeeze the AirPods: help me now (in calls, and when nothing else is playing)", isOn: $airpods)
                    .onChange(of: airpods) { _ in RemoteTap.shared.apply() }
                Button("Show me the gestures again") { MacGuide.show() }
            }
            // Before every call (owner, 03/10): in view, with Google Calendar.
            CalendarSection()
            Section("Privacy") {
                PrivateModelRow(heard: HeardLanguage(rawValue: heard) ?? .enGB)
                Toggle("In calls, keep text only (no audio clip)", isOn: $callsTextOnly)
                Text("Voices never leave your devices: everything is transcribed here. Only the text of the sentence you ask about goes to our model to explain it. In calls without people's names, numbers or your own names (the people you talk with, your words, your calendar); companies, products and places stay, so it can tell you who or what they are. A moment's audio stays on this Mac for \(Store.clipDays) days, then it's deleted.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("A report after each call", isOn: $callReport)
                Text("Only about understanding: what they asked you and what they asked you to do. When the call ends, the questions of the others and your answers, as text without names or numbers, go to our model to write it. Nothing about how you speak.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Block MEM: the names and terms LEXALIE noticed, only on this Mac, gone in 60 days or now.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Names and terms you heard")
                        Text("Only on this Mac, never the sentences around them: for what comes back often. They fade after 60 days.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Delete all") { Nodes.shared.deleteAll() }.controlSize(.small)
                }
                NeverCallsSection()
            }
            AccountSection(webApp: webApp)
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    advancedOptions
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Brand.onyx)
        .frame(width: 480)
        .padding(.vertical, 8)
    }

    /// Everything a few people will want, closed by default.
    @ViewBuilder private var advancedOptions: some View {
        Toggle("Your model: it follows calls, films and songs and picks what you probably missed, without a tap", isOn: $useModel)
        Toggle("Know which song is playing in Spotify or Music", isOn: $songs)
        VStack(alignment: .leading, spacing: 4) {
            Text("Your words: names and jargon to expect, one per line").font(.callout)
            TextEditor(text: $dictionary).frame(height: 60).font(.body)
        }
        TextField("Your first name (to notice when someone asks you)", text: $myName)
        Toggle("In calls, also listen to my voice (and mark when I say \"sorry?\")", isOn: $sorry)
            .onChange(of: sorry) { _ in AppModel.shared.applyTriggers() }
        // The microphone is on only in calls, with the toggle above (owner, 04/10: say where it works).
        TextField("…and my own word to mark, in calls (e.g. \"didn't get that\")", text: $keyword)
            .onSubmit { AppModel.shared.restartVoice() }
            .disabled(!sorry)
        if developer {
            SecureField("Tester code", text: $code)
            TextField("Google client ID, for Google Calendar (public, from Google Cloud)", text: $googleClientID)
            TextField("Server", text: $server)
            TextField("Web app", text: $webApp)
        }
    }
}

/// Sign in with the same account as the web app, so moments show up there too.
private struct AccountSection: View {
    let webApp: String
    @ObservedObject private var account = Account.shared
    @ObservedObject private var sync = Sync.shared
    @State private var email = ""
    @State private var password = ""
    @State private var usePassword = false

    var body: some View {
        Section("Account") {
            if let session = account.session {
                LabeledContent("Signed in as", value: session.email ?? String(localized: "your account"))
                LabeledContent("Sync", value: syncText)
                HStack {
                    Button("Sync now") { sync.schedule(after: 0) }.disabled(sync.running)
                    Button("Open the web app") {
                        if let url = URL(string: webApp) { NSWorkspace.shared.open(url) }
                    }
                    Spacer()
                    Button("Sign out") { account.signOut() }
                }
            } else {
                Text("Sign in to see your moments, review and progress in the web app too. Only text is synced, never audio.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Continue with Google") { account.signInWithGoogle() }
                TextField("Email", text: $email)
                if usePassword {
                    SecureField("Password", text: $password)
                    HStack {
                        Button("Sign in") { Task { await account.signIn(email: email, password: password) } }
                            .disabled(email.isEmpty || password.isEmpty || account.working)
                        Button("Use an email link instead") { usePassword = false }.buttonStyle(.link)
                    }
                } else {
                    HStack {
                        Button("Email me a link") { Task { await account.sendMagicLink(email: email) } }
                            .disabled(email.isEmpty || account.working)
                        Button("Use a password instead") { usePassword = true }.buttonStyle(.link)
                    }
                }
            }
            if let message = account.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var syncText: String {
        if sync.running { return String(localized: "Syncing…") }
        if let status = sync.status { return status }
        if let last = sync.lastSync { return String(localized: "Up to date · \(last.formatted(date: .omitted, time: .shortened))") }
        return String(localized: "Waiting")
    }
}

/// Your calendar: a prep before each call, the lesson right after.
private struct CalendarSection: View {
    @ObservedObject private var calendar = CalendarWatch.shared
    @ObservedObject private var google = GoogleCalendar.shared
    @AppStorage(Key.calendar) private var on = false
    @AppStorage(Key.prepLead) private var lead = 120
    @AppStorage(Key.callNotice) private var notice = CallNotice.all.rawValue

    var body: some View {
        Section("Calendar") {
            Toggle("Prep me before calls, and teach me right after", isOn: Binding(get: { on }, set: { calendar.enabled = $0 }))
            if on {
                Picker("Prep", selection: $lead) {
                    ForEach(CalendarWatch.leads) { Text($0.label).tag($0.minutes) }
                }
                .onChange(of: lead) { _ in calendar.refresh() }
                Picker("Tell me 15 minutes before calls", selection: $notice) {
                    ForEach(CallNotice.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: notice) { _ in calendar.refresh() }
                Text("The notice says how the last call with those people went, and how LEXALIE helps in this one: Just mark, Suggestions or With me. Already chosen for you (you organise it or you're few: Just mark; many people and you're a guest: Suggestions), one tap to change, remembered for that meeting or those people.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // Google Calendar directly, for people who never added it to the Calendar app (owner, 03/10).
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Calendar")
                    Text(google.connected ? String(localized: "Connected") : String(localized: "Connect it if it isn't in the Calendar app on this Mac"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if google.connected {
                    Button("Disconnect") { google.disconnect() }.controlSize(.small)
                } else {
                    Button("Connect") { google.connect() }.controlSize(.small).disabled(!google.available)
                }
            }
            if let message = google.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if calendar.access == .denied, !google.connected {
                HStack {
                    Text("LEXALIE can't read your calendar yet.").foregroundStyle(.orange)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            }
            Text("Reads the calendars in the Calendar app on this Mac (iCloud, Google, Outlook), or Google Calendar directly. Only meetings with other people or a video link count. Your account gets the call's title, time and the people you track in LEXALIE, never the guest list or the notes.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The private recogniser: downloaded once (~0.5 GB, on Wi-Fi), then everything stays on the device.
private struct PrivateModelRow: View {
    let heard: HeardLanguage
    @State private var status = Parakeet.status
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Private transcription · stays on your device")
                Text(Parakeet.isDownloaded(heard) ? String(localized: "Ready") : status.label)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !Parakeet.isDownloaded(heard), !status.isDownloading {
                Button("Download now") { Task { await Parakeet.shared.prepare(heard, anyNetwork: true) } }
                    .controlSize(.small)
            }
        }
        .onReceive(timer) { _ in status = Parakeet.status }
    }
}
