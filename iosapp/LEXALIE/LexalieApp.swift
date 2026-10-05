import SwiftUI
import UserNotifications

@main
struct LexalieApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var sessions = Sessions.shared
    @StateObject private var night = Night.shared
    @StateObject private var account = Account.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessions)
                .environmentObject(night)
                .environmentObject(account)
                .onOpenURL { url in
                    // A recording shared to LEXALIE (Apple's call recording from Notes, Voice Memos, Files).
                    if url.isFileURL { Task { await Sessions.shared.importShared(url) } } else { Account.shared.handle(url) }
                }
                .preferredColorScheme(.dark)
                .tint(Brand.accent)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        K.register()
        Night.register()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "OFFER", actions: [UNNotificationAction(identifier: "START", title: "Start listening", options: [.foreground])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "TRANSCRIBE", actions: [UNNotificationAction(identifier: "NOW", title: "Transcribe now", options: [.foreground])],
                                   intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        WatchLink.shared.activate()
        Task { @MainActor in Sessions.shared.boot() }
        // The private recogniser (§ 19.25): downloads by itself the first time, only on Wi-Fi.
        Task { await Private.shared.prepare() }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String
        let title = info["title"] as? String
        Task { @MainActor in
            switch kind {
            case "offer": await Sessions.shared.start(title: title)
            case "transcribe": await Night.shared.run(auto: false)
            default: break
            }
        }
        completionHandler()
    }
}
