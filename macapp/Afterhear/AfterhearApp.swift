import SwiftUI
import AppKit

@main
struct AfterhearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        // Before anything reads the settings or the moments: what the app had under its old name.
        OldVersion.bringOver()
        // Then the language of every word on screen: yours (owner, 03/10).
        AppLanguage.apply()
        _model = StateObject(wrappedValue: AppModel.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(model.store)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Diary", id: "diary") {
            DiaryView()
                .background(Brand.onyx)
                .preferredColorScheme(.dark)
                .tint(Brand.accent)
                .environmentObject(model)
                .environmentObject(model.store)
        }
        .defaultSize(width: 620, height: 720)

        Window("Review", id: "review") {
            ReviewView()
                .background(Brand.onyx)
                .preferredColorScheme(.dark)
                .tint(Brand.accent)
                .environmentObject(model)
                .environmentObject(model.store)
        }
        .defaultSize(width: 520, height: 640)

        Window("Settings", id: "settings") {
            SettingsView()
                .background(Brand.onyx)
                .preferredColorScheme(.dark)
                .tint(Brand.accent)
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // afterhear://auth-callback: the browser hands the sign-in back to the app.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppModel.shared.boot()
            Onboarding.showIfNew()
            Sync.shared.boot()
            await CalendarWatch.shared.boot()
        }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == "afterhear" else { return }
        Task { @MainActor in Account.shared.handle(url) }
    }
}

/// Brand colours, same as the landing page.
enum Brand {
    /// Apricot (§ 19.11): warm, never mistaken for the Workout green.
    static let accent = Color(red: 0xf2 / 255, green: 0xc4 / 255, blue: 0xa0 / 255)
    static let onyx = Color(red: 0x0b / 255, green: 0x0c / 255, blue: 0x11 / 255)
    static let card = Color(red: 0x15 / 255, green: 0x16 / 255, blue: 0x1c / 255)
    static let paper = Color(red: 0xf7 / 255, green: 0xf7 / 255, blue: 0xf8 / 255)
}
