import SwiftUI

struct SettingsView: View {
    @AppStorage(Key.code) private var code = ""
    @AppStorage(Key.server) private var server = AppSettings.defaultServer
    @AppStorage(Key.webApp) private var webApp = AppSettings.defaultWebApp
    @AppStorage(Key.heard) private var heard = HeardLanguage.enGB.rawValue
    @AppStorage(Key.native) private var native = NativeLanguage.it.rawValue
    @AppStorage(Key.level) private var level = "B2"
    @AppStorage(Key.pauseVideo) private var pauseVideo = true
    @AppStorage(Key.helpVideo) private var helpVideo = HelpMode.pause.rawValue
    @AppStorage(Key.helpCall) private var helpCall = HelpMode.silent.rawValue
    @AppStorage(Key.helpOther) private var helpOther = HelpMode.glance.rawValue
    @AppStorage(Key.sorry) private var sorry = true
    @AppStorage(Key.doubleTap) private var doubleTap = true
    @AppStorage(Key.keyword) private var keyword = ""
    @AppStorage(Key.callsTextOnly) private var callsTextOnly = false
    @AppStorage(Key.myName) private var myName = ""
    @AppStorage(Key.askedMe) private var askedMe = false
    @AppStorage(Key.opener) private var opener = false
    @AppStorage(Key.dictionary) private var dictionary = ""
    @AppStorage(Key.useModel) private var useModel = false
    @AppStorage(Key.songs) private var songs = false
    @AppStorage(Key.airpods) private var airpods = false

    @AppStorage(Key.nowExplain) private var nowExplain = true
    @AppStorage(Key.translationAlways) private var translationAlways = false
    @State private var advanced = false

    /// The few things people actually choose, in view; everything else under Advanced (owner, 02/10:
    /// frictionless, not forty switches).
    var body: some View {
        Form {
            Section("Languages") {
                Picker("Your language", selection: $native) {
                    ForEach(NativeLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("The language you want to understand", selection: $heard) {
                    ForEach(HeardLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: heard) { _ in AppModel.shared.languageChanged() }
                Picker("How well you understand it", selection: $level) {
                    Text("Getting there").tag("B1")
                    Text("Quite well").tag("B2")
                    Text("Very well").tag("C1")
                }
                TranslationRow(heard: HeardLanguage(rawValue: heard) ?? .enGB, native: NativeLanguage(rawValue: native) ?? .it)
            }
            Section("When you ask for help (\(DoubleTapOption.nowLabel))") {
                Picker("Show", selection: $nowExplain) {
                    Text("The sentence, its translation and the explanation").tag(true)
                    Text("Only the sentence and its translation").tag(false)
                }
                Toggle("Always show the translation", isOn: $translationAlways)
                Toggle("Pause the video while I read", isOn: $pauseVideo)
            }
            Section("Gestures") {
                Text("\(DoubleTapOption.label): mark it for tonight. \(DoubleTapOption.nowLabel): help me now.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Use \(DoubleTapOption.label) and \(DoubleTapOption.nowLabel)", isOn: $doubleTap)
                    .onChange(of: doubleTap) { _ in AppModel.shared.applyTriggers() }
                Button("Show me the gestures again") { MacGuide.show() }
            }
            Section("Privacy") {
                PrivateModelRow(heard: HeardLanguage(rawValue: heard) ?? .enGB)
                Toggle("In calls, keep text only (no audio clip)", isOn: $callsTextOnly)
                Text("Voices never leave your devices: everything is transcribed here. Only the text of the sentence you ask about, without names or numbers, goes to our model to explain it. A moment's audio stays on this Mac for \(Store.clipDays) days, then it's deleted.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        Picker("Help in a video", selection: $helpVideo) {
            ForEach(HelpMode.allCases) { Text($0.label).tag($0.rawValue) }
        }
        Picker("Help in a call", selection: $helpCall) {
            ForEach(HelpMode.allCases.filter { $0 != .pause }) { Text($0.label).tag($0.rawValue) }
        }
        Picker("Help anywhere else", selection: $helpOther) {
            ForEach(HelpMode.allCases.filter { $0 != .pause }) { Text($0.label).tag($0.rawValue) }
        }
        Toggle("Your model: it follows calls, films and songs and picks what you probably missed, without a tap", isOn: $useModel)
        Toggle("Know which song is playing in Spotify or Music", isOn: $songs)
        VStack(alignment: .leading, spacing: 4) {
            Text("Your words: names and jargon to expect, one per line").font(.callout)
            TextEditor(text: $dictionary).frame(height: 60).font(.body)
        }
        CalendarSection()
        TextField("Your first name (to notice when someone asks you)", text: $myName)
        Toggle("In calls, show a question asked to me, simply", isOn: $askedMe)
        Toggle("…and suggest how to start the answer", isOn: $opener).disabled(!askedMe)
        Toggle("In calls, also listen to my voice (and mark when I say \"sorry?\")", isOn: $sorry)
            .onChange(of: sorry) { _ in AppModel.shared.applyTriggers() }
        TextField("My keyword to mark (e.g. \"didn't get that\")", text: $keyword)
            .onSubmit { AppModel.shared.restartVoice() }
        Toggle("Squeeze the AirPods to mark (videos aren't paused then)", isOn: $airpods)
            .onChange(of: airpods) { _ in RemoteTap.shared.apply() }
        SecureField("Tester code", text: $code)
        TextField("Server", text: $server)
        TextField("Web app", text: $webApp)
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
                LabeledContent("Signed in as", value: session.email ?? "your account")
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
        if sync.running { return "Syncing…" }
        if let status = sync.status { return status }
        if let last = sync.lastSync { return "Up to date · \(last.formatted(date: .omitted, time: .shortened))" }
        return "Waiting"
    }
}

/// Your calendar: a prep before each call, the lesson right after.
private struct CalendarSection: View {
    @ObservedObject private var calendar = CalendarWatch.shared
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
                Text("The notice says how the last call with those people went, and how Afterhear helps in this one: Just mark, Suggestions or With me. Already chosen for you (you organise it or you're few: Just mark; many people and you're a guest: Suggestions), one tap to change, remembered for that meeting or those people.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if calendar.access == .denied {
                HStack {
                    Text("Afterhear can't read your calendar yet.").foregroundStyle(.orange)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            }
            Text("Reads the calendars in the Calendar app on this Mac (iCloud, Google, Outlook). Only meetings with other people or a video link count. Your account gets the call's title, time and the people you track in Afterhear, never the guest list or the notes.")
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
                Text(Parakeet.isDownloaded(heard) ? "Ready" : status.label)
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
