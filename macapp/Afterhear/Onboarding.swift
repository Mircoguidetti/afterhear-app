import SwiftUI

/// First launch (owner, 02/10: few steps, nothing to look for): your account first (owner, 03/10: the
/// explanations need it, and nobody looks for it in Settings), your languages, guessed from the Mac,
/// how well you understand, the two permissions, the one-time translation download, then "try it".
enum Onboarding {
    @MainActor static func showIfNew() {
        guard !UserDefaults.standard.bool(forKey: Key.onboarded) else {
            showSignInIfNeeded()
            return
        }
        guessLanguages()
        AppWindows.show(id: "welcome", title: String(localized: "Welcome to Afterhear"), width: 500, height: 500) {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: Key.onboarded)
                UserDefaults.standard.set(true, forKey: MacGuide.seenKey)
                AppModel.shared.languageChanged()
            }
        }
    }

    /// Already set up, but signed out and without a tester code (the rename, a new Mac): the explanations
    /// can't come, so the account step alone, once per launch, with "Not now".
    @MainActor static func showSignInIfNeeded() {
        guard !Account.shared.signedIn,
              (UserDefaults.standard.string(forKey: Key.code) ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return }
        AppWindows.show(id: "signin", title: String(localized: "Sign in to Afterhear"), width: 500, height: 500) {
            SignInStep(standalone: true)
                .padding(28)
                .frame(width: 500, height: 500)
                .background(Brand.onyx)
                .foregroundStyle(Brand.paper)
                .environment(\.colorScheme, .dark)
        }
    }

    /// Your language from the Mac's; the one to understand from where you live (a Spanish Mac in Italy:
    /// Italian), otherwise English.
    static func guessLanguages() {
        let d = UserDefaults.standard
        let mine = String((Locale.preferredLanguages.first ?? "en").prefix(2))
        if let native = NativeLanguage(rawValue: mine) { d.set(native.rawValue, forKey: Key.native) }
        let byRegion: [String: HeardLanguage] = ["IT": .itIT, "ES": .esES, "FR": .frFR, "DE": .deDE, "AT": .deDE,
                                                 "CH": .deDE, "RU": .ruRU, "GB": .enGB, "IE": .enGB, "US": .enUS,
                                                 "CA": .enUS, "AU": .enGB, "PT": .ptPT, "BR": .ptBR]
        let region = Locale.current.region?.identifier ?? ""
        if let local = byRegion[region], !local.rawValue.hasPrefix(mine) {
            d.set(local.rawValue, forKey: Key.heard)
        } else if !mine.hasPrefix("en") {
            d.set(HeardLanguage.enGB.rawValue, forKey: Key.heard)
        }
    }
}

struct OnboardingView: View {
    let done: () -> Void
    @State private var step = 0
    @AppStorage(Key.native) private var native = NativeLanguage.it.rawValue
    @AppStorage(Key.heard) private var heard = HeardLanguage.enGB.rawValue
    @AppStorage(Key.level) private var level = "B2"
    @State private var trusted = AXIsProcessTrusted()
    @State private var translation: Translator.Status = .unavailable
    @State private var downloading = false
    @ObservedObject private var account = Account.shared
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var heardLanguage: HeardLanguage { HeardLanguage(rawValue: heard) ?? .enGB }
    private var nativeLanguage: NativeLanguage { NativeLanguage(rawValue: native) ?? .it }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                KnotMark(color: Brand.accent, lineWidth: 1.8).frame(width: 26, height: 25)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { i in
                        Circle().fill(i == step ? Brand.accent : Color.white.opacity(0.2)).frame(width: 6, height: 6)
                    }
                }
            }
            Group {
                switch step {
                case 0: SignInStep(standalone: false)
                case 1: languages
                case 2: permissions
                case 3: translations
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Spacer()
                Button(step == 4 ? String(localized: "Start") : step == 0 && !account.signedIn ? String(localized: "Not now") : String(localized: "Continue")) {
                    if step == 4 { done(); NSApp.keyWindow?.close() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent).tint(Brand.accent).foregroundStyle(Brand.onyx)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 500, height: 500)
        .background(Brand.onyx)
        .foregroundStyle(Brand.paper)
        .environment(\.colorScheme, .dark)
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
        .task(id: "\(heard)-\(native)") { translation = await Translator.status(heardLanguage, nativeLanguage) }
        .modifier(TranslationDownload(heard: heardLanguage, native: nativeLanguage, run: $downloading) {
            Task { translation = await Translator.status(heardLanguage, nativeLanguage) }
        })
    }

    private func title(_ text: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 24, weight: .semibold))
            Text(sub).font(.system(size: 14)).foregroundStyle(Brand.paper.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 18) {
            title(String(localized: "Subtitles only when you need them."), String(localized: "Two languages and you're set. We guessed them from your Mac."))
            Picker("You speak", selection: $native) {
                ForEach(NativeLanguage.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("You want to understand", selection: $heard) {
                ForEach(HeardLanguage.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("How well, today", selection: $level) {
                Text("Getting there").tag("B1")
                Text("Quite well").tag("B2")
                Text("Very well").tag("C1")
            }
            .pickerStyle(.segmented)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            title(String(localized: "Two permissions."), String(localized: "Voices never leave your devices: everything is transcribed here."))
            row("speaker.wave.2", String(localized: "Your Mac's sound"), String(localized: "To hear the sentence you missed, in a film or a call. macOS asks once."),
                ok: AppModel.shared.state == .listening, action: (String(localized: "Open Settings"), { AppModel.shared.openScreenRecordingSettings() }))
            row("hand.tap", String(localized: "The gestures"), String(localized: "\(DoubleTapOption.label) and \(DoubleTapOption.nowLabel), and pausing the video for you."),
                ok: trusted, action: (String(localized: "Allow"), { MediaKey.askForPermission() }))
        }
    }

    private var translations: some View {
        VStack(alignment: .leading, spacing: 18) {
            title(String(localized: "Instant translations."), String(localized: "The translation under each sentence, at once and offline. A one-time download from Apple."))
            switch translation {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.accent)
            case .needsDownload:
                Button(downloading ? String(localized: "Downloading…") : String(localized: "Download")) { downloading = true }
                    .disabled(downloading).controlSize(.large)
            case .unsupported, .unavailable:
                Text("On this Mac the translation comes with the explanation, a second later.")
                    .foregroundStyle(Brand.paper.opacity(0.65))
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 18) {
            title(String(localized: "Try it."), String(localized: "Play any video. When a sentence slips past you:"))
            gesture(DoubleTapOption.nowLabel, String(localized: "Help me now: the sentence, its translation, then what it means."))
            gesture(DoubleTapOption.label, String(localized: "Mark it: nothing stops, it's waiting for you tonight."))
        }
    }

    private func gesture(_ keys: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(keys).font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.accent).frame(width: 90, alignment: .leading)
            Text(text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ icon: String, _ name: String, _ why: String, ok: Bool, action: (String, () -> Void)) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Brand.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 15, weight: .semibold))
                Text(why).font(.system(size: 13)).foregroundStyle(Brand.paper.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent)
            } else {
                Button(action.0, action: action.1).controlSize(.small)
            }
        }
    }
}

/// The account step: Google in one click, or an email link. No password to invent (owner, 03/10).
struct SignInStep: View {
    /// Shown alone (signed out after setup): it closes itself once you're in.
    let standalone: Bool
    @ObservedObject private var account = Account.shared
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if standalone {
                KnotMark(color: Brand.accent, lineWidth: 1.8).frame(width: 26, height: 25)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(account.signedIn ? String(localized: "You're in.") : String(localized: "Sign in to start.")).font(.system(size: 24, weight: .semibold))
                Text(account.signedIn
                     ? String(localized: "Your moments follow you on the web and on your iPhone.")
                     : String(localized: "Your account brings the explanations, and keeps your moments on every device. Only text is synced, never a voice."))
                    .font(.system(size: 14)).foregroundStyle(Brand.paper.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let session = account.session {
                Label(session.email ?? String(localized: "Signed in"), systemImage: "checkmark.circle.fill").foregroundStyle(Brand.accent)
            } else {
                Button { account.signInWithGoogle() } label: {
                    Text("Continue with Google").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                HStack {
                    TextField("Or your email", text: $email).textFieldStyle(.roundedBorder)
                    Button("Email me a link") { Task { await account.sendMagicLink(email: email) } }
                        .disabled(!email.contains("@") || account.working)
                }
            }
            if let message = account.message {
                Text(message).font(.system(size: 13)).foregroundStyle(Brand.paper.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if standalone {
                HStack {
                    Spacer()
                    Button(account.signedIn ? String(localized: "Done") : String(localized: "Not now")) { NSApp.keyWindow?.close() }
                        .buttonStyle(.borderedProminent).tint(Brand.accent).foregroundStyle(Brand.onyx)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
