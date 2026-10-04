import Foundation

/// The app's words follow "Your language" (owner, 03/10: the app speaks the same seven languages as
/// the landing). The translations are in <language>.lproj, written by macapp/l10n/make.py.
enum AppLanguage {
    /// At launch, before any word is drawn: macOS then picks that language's translations.
    static func apply() {
        let native = UserDefaults.standard.string(forKey: Key.native) ?? NativeLanguage.system.rawValue
        UserDefaults.standard.set([native], forKey: "AppleLanguages")
    }

    /// The language the words on screen are in (the one at launch).
    static var shown: String { String((Bundle.main.preferredLocalizations.first ?? "en").prefix(2)) }
}
