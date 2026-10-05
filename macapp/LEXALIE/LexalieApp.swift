import SwiftUI
import AppKit

@main
struct LexalieApp: App {
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
            Scenes.menu()
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Diary", id: "diary") {
            Scenes.diary()
        }
        .defaultSize(width: 620, height: 720)

        Window("Review", id: "review") {
            Scenes.review()
        }
        .defaultSize(width: 520, height: 640)

        Window("Settings", id: "settings") {
            Scenes.settings()
        }
        .windowResizability(.contentSize)
    }
}

/// What each window shows, with everything it needs: the same for the app and for the self-test
/// (SelfTest.swift), so a window missing something fails on GitHub, not on your Mac (05/10).
@MainActor
enum Scenes {
    private static var model: AppModel { AppModel.shared }

    static func menu() -> some View {
        MenuView().environmentObject(model).environmentObject(model.store)
    }

    static func diary() -> some View { styled(DiaryView()) }
    static func review() -> some View { styled(ReviewView()) }
    static func settings() -> some View { styled(SettingsView()) }

    private static func styled<V: View>(_ view: V) -> some View {
        view
            .background(Brand.onyx)
            .preferredColorScheme(.dark)
            .tint(Brand.accent)
            .environmentObject(model)
            .environmentObject(model.store)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // lexalie://auth-callback: the browser hands the sign-in back to the app.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The self-test on GitHub's Macs: no listening, no setup, every window opened once.
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in await SelfTest.run() }
            return
        }
        Task { @MainActor in
            AppModel.shared.boot()
            Onboarding.showIfNew()
            Sync.shared.boot()
            await CalendarWatch.shared.boot()
        }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), ["lexalie", "afterhear"].contains(url.scheme ?? "") else { return }
        Task { @MainActor in Account.shared.handle(url) }
    }
}

/// Brand colours, same as the landing page.
enum Brand {
    /// A white that leans to grey: black and white, no apricot (owner, 05/10). The app is always dark.
    static let accent = Color(red: 0xe6 / 255, green: 0xe7 / 255, blue: 0xeb / 255)
    static let onyx = Color(red: 0x0b / 255, green: 0x0c / 255, blue: 0x11 / 255)
    static let card = Color(red: 0x15 / 255, green: 0x16 / 255, blue: 0x1c / 255)
    static let paper = Color(red: 0xf7 / 255, green: 0xf7 / 255, blue: 0xf8 / 255)
}
