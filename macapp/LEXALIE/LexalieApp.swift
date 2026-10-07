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

        Window("What matters", id: "matters") {
            Scenes.matters()
        }
        .defaultSize(width: 480, height: 600)

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

    static func matters() -> some View { styled(WhatMattersView()) }
    static func diary() -> some View { styled(DiaryView()) }
    static func review() -> some View { styled(ReviewView()) }
    static func settings() -> some View { styled(SettingsView()) }

    private static func styled<V: View>(_ view: V) -> some View {
        view
            .background(Brand.onyx)
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

/// Brand colours, black and white. The app follows the Mac's look (owner, 06/10 night): white when the
/// Mac is light, dark when it is dark. Every colour turns with it, so "paper" is always the ink that
/// reads on "onyx", the ground.
enum Brand {
    /// Buttons: black on white, light grey on dark (no apricot, owner 05/10).
    static let accent = dynamic(light: 0x18181A, dark: 0xE6E7EB)
    /// The one accent, only for the thing you missed: the landing's own (ice blue with its light on dark,
    /// the deeper blue of its white sections on light).
    static let line = dynamic(light: 0x2F86D0, dark: 0x9FD8FF)
    /// The ground of the card and the windows.
    static let onyx = dynamic(light: 0xFBFAF8, dark: 0x0B0C11)
    static let card = dynamic(light: 0xF4F2EE, dark: 0x15161C)
    /// The ink.
    static let paper = dynamic(light: 0x18181A, dark: 0xF7F7F8)
    /// The window ground for AppKit.
    static let windowGround = nsDynamic(light: 0xFBFAF8, dark: 0x0B0C11)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color { Color(nsColor: nsDynamic(light: light, dark: dark)) }

    private static func nsDynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}
