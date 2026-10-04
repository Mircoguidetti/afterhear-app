import Foundation
import Network
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// The sentence's translation at once, on the device (Apple's translator): the subtitle under the
/// subtitle, before our model's explanation arrives (owner, 02/10). Nil when it can't (macOS older
/// than 26, the language pair not downloaded): the translation then comes with the explanation.
enum Translator {
    enum Status: Equatable { case ready, needsDownload, unsupported, unavailable }

    static func source(_ heard: HeardLanguage) -> Locale.Language { Locale.Language(identifier: heard.rawValue) }
    static func target(_ native: NativeLanguage) -> Locale.Language { Locale.Language(identifier: native.rawValue) }

    static func same(_ heard: HeardLanguage, _ native: NativeLanguage) -> Bool {
        heard.rawValue.prefix(2) == native.rawValue.prefix(2)
    }

    static func translate(_ text: String, from heard: HeardLanguage, to native: NativeLanguage) async -> String? {
        guard !same(heard, native), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            guard await status(heard, native) == .ready else { return nil }
            let session = TranslationSession(installedSource: source(heard), target: target(native))
            return try? await session.translate(text).targetText
        }
        #endif
        return nil
    }

    static func status(_ heard: HeardLanguage, _ native: NativeLanguage) async -> Status {
        guard !same(heard, native) else { return .unsupported }
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            switch await LanguageAvailability().status(from: source(heard), to: target(native)) {
            case .installed: return .ready
            case .supported: return .needsDownload
            case .unsupported: return .unsupported
            @unknown default: return .unavailable
            }
        }
        #endif
        return .unavailable
    }
}

/// Asks macOS to download a language pair: the system shows its own "Download" sheet, once.
/// Put it on a view with `.modifier(TranslationDownload(…))` and flip `run` to true.
struct TranslationDownload: ViewModifier {
    let heard: HeardLanguage
    let native: NativeLanguage
    @Binding var run: Bool
    var done: () -> Void = {}

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            content.translationTask(run ? TranslationSession.Configuration(source: Translator.source(heard), target: Translator.target(native)) : nil) { session in
                try? await session.prepareTranslation()
                await MainActor.run {
                    run = false
                    done()
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// In Settings: are translations instant, or does the pair need its one-time download?
struct TranslationRow: View {
    let heard: HeardLanguage
    let native: NativeLanguage
    @State private var status: Translator.Status = .unavailable
    @State private var run = false

    var body: some View {
        Group {
            switch status {
            case .ready:
                LabeledContent("Instant translations", value: String(localized: "Ready"))
            case .needsDownload:
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instant translations")
                        Text("A one-time download from Apple, then it works offline too.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Download") { run = true }.controlSize(.small)
                }
            case .unsupported, .unavailable:
                EmptyView()
            }
        }
        .modifier(TranslationDownload(heard: heard, native: native, run: $run) { refresh() })
        .task(id: "\(heard.rawValue)-\(native.rawValue)") { await check() }
    }

    private func refresh() { Task { await check() } }
    private func check() async { status = await Translator.status(heard, native) }
}

/// Is there a network? Checked at the tap, so nobody waits for an explanation that can't come.
final class Reachability: @unchecked Sendable {
    static let shared = Reachability()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return online
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.online = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "app.afterhear.reachability"))
    }
}
