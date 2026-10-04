import SwiftUI

/// First launch (owner, 02/10: few steps, nothing to look for): your languages, guessed from the Mac,
/// how well you understand, the two permissions, the one-time translation download, then "try it".
enum Onboarding {
    @MainActor static func showIfNew() {
        guard !UserDefaults.standard.bool(forKey: Key.onboarded) else { return }
        guessLanguages()
        AppWindows.show(id: "welcome", title: "Welcome to Afterhear", width: 500, height: 500) {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: Key.onboarded)
                UserDefaults.standard.set(true, forKey: MacGuide.seenKey)
                AppModel.shared.languageChanged()
            }
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
                                                 "CA": .enUS, "AU": .enGB]
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
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var heardLanguage: HeardLanguage { HeardLanguage(rawValue: heard) ?? .enGB }
    private var nativeLanguage: NativeLanguage { NativeLanguage(rawValue: native) ?? .it }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                KnotMark(color: Brand.accent, lineWidth: 1.8).frame(width: 26, height: 25)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(i == step ? Brand.accent : Color.white.opacity(0.2)).frame(width: 6, height: 6)
                    }
                }
            }
            Group {
                switch step {
                case 0: languages
                case 1: permissions
                case 2: translations
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Spacer()
                Button(step == 3 ? "Start" : "Continue") {
                    if step == 3 { done(); NSApp.keyWindow?.close() } else { step += 1 }
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
            title("Subtitles only when you need them.", "Two languages and you're set. We guessed them from your Mac.")
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
            title("Two permissions.", "Voices never leave your devices: everything is transcribed here.")
            row("speaker.wave.2", "Your Mac's sound", "To hear the sentence you missed, in a film or a call. macOS asks once.",
                ok: AppModel.shared.state == .listening, action: ("Open Settings", { AppModel.shared.openScreenRecordingSettings() }))
            row("hand.tap", "The gestures", "\(DoubleTapOption.label) and \(DoubleTapOption.nowLabel), and pausing the video for you.",
                ok: trusted, action: ("Allow", { MediaKey.askForPermission() }))
        }
    }

    private var translations: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Instant translations.", "The translation under each sentence, at once and offline. A one-time download from Apple.")
            switch translation {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.accent)
            case .needsDownload:
                Button(downloading ? "Downloading…" : "Download") { downloading = true }
                    .disabled(downloading).controlSize(.large)
            case .unsupported, .unavailable:
                Text("On this Mac the translation comes with the explanation, a second later.")
                    .foregroundStyle(Brand.paper.opacity(0.65))
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Try it.", "Play any video. When a sentence slips past you:")
            gesture(DoubleTapOption.nowLabel, "Help me now: the sentence, its translation, then what it means.")
            gesture(DoubleTapOption.label, "Mark it: nothing stops, it's waiting for you tonight.")
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
