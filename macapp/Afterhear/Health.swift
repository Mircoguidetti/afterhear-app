import AVFoundation
import AppKit
import SwiftUI

/// An app that doesn't break in silence (docs/PIANO.md, block E).
/// What failed goes to Supabase (public.app_errors): the step, the Mac, macOS, the version. Never
/// audio, never what was heard, never names. The owner never has to send the console.
enum ErrorLog {
    private static var lastSent: [String: Date] = [:]
    private static let lock = NSLock()

    static func record(_ step: String, _ error: Any? = nil) {
        let message = error.map { String(describing: $0) }.map { String($0.prefix(500)) }
        // The same failure at most once an hour from this Mac.
        lock.lock()
        let recent = lastSent[step].map { Date().timeIntervalSince($0) < 3600 } ?? false
        if !recent { lastSent[step] = Date() }
        lock.unlock()
        guard !recent else { return }
        Task { await send(step: step, message: message) }
    }

    static var machine: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        #if arch(x86_64)
        let arch = "intel"
        #else
        let arch = "arm"
        #endif
        return "\(String(cString: model)) \(arch)"
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private static func send(step: String, message: String?) async {
        guard let url = URL(string: Account.supabaseURL + "/rest/v1/app_errors") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(Account.publishableKey, forHTTPHeaderField: "apikey")
        let token = await Account.shared.accessToken()
        request.setValue("Bearer \(token ?? Account.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        var row: [String: Any] = [
            "app": "mac", "version": String(version.prefix(40)), "machine": String(machine.prefix(60)),
            "os": String(ProcessInfo.processInfo.operatingSystemVersionString.prefix(60)), "step": String(step.prefix(60)),
        ]
        if let message { row["message"] = message }
        request.httpBody = try? JSONSerialization.data(withJSONObject: row)
        _ = try? await URLSession.shared.data(for: request)
    }
}

/// Switches on the server (public.app_config), read when the app starts: change the engine or the
/// mode without a new version. The last values are kept for when there's no connection.
enum RemoteConfig {
    private static let prefix = "remote."

    static func value(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    static func refresh() async {
        guard let url = URL(string: Account.supabaseURL + "/rest/v1/app_config?select=key,value") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(Account.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Account.publishableKey)", forHTTPHeaderField: "Authorization")
        struct Row: Decodable { let key: String; let value: String }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return }
        for row in rows { UserDefaults.standard.set(row.value, forKey: prefix + row.key) }
        // "Best accuracy" from the server can be switched off for everyone at once.
        if value("cloud_transcription") == "off" { UserDefaults.standard.set(false, forKey: Key.cloudTranscription) }
    }
}

/// "Is everything ready?": the permissions, the sound, the model, the server. Shown once after the
/// first setup, again at launch only when something is missing, and from the menu at any time.
@MainActor
final class HealthCheck: ObservableObject {
    static let shared = HealthCheck()

    enum State: Equatable { case checking, ok, missing(String), waiting(String) }

    struct Item: Identifiable {
        let id: String
        let title: String
        var state: State = .checking
        /// The fix, when there is one you can do: a button.
        var fix: (label: String, action: @MainActor () -> Void)?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var running = false

    var allReady: Bool { !items.isEmpty && items.allSatisfy { $0.state == .ok } }
    var anyMissing: Bool { items.contains { if case .missing = $0.state { return true }; return false } }

    /// At launch: after the first setup always once, later only if something is wrong.
    func atLaunch() {
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard UserDefaults.standard.bool(forKey: Key.onboarded) else { return }
            await run()
            let first = !UserDefaults.standard.bool(forKey: "healthShown")
            if first || anyMissing {
                UserDefaults.standard.set(true, forKey: "healthShown")
                open()
            }
        }
    }

    func open() {
        AppWindows.show(id: "health", title: String(localized: "Is everything ready?"), width: 460, height: 460) { HealthView() }
    }

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let model = AppModel.shared
        let heard = AppSettings.current.heard
        items = [
            Item(id: "sound", title: String(localized: "Hearing the sound of this Mac")),
            Item(id: "gestures", title: String(localized: "The gestures (Accessibility)")),
            Item(id: "mic", title: String(localized: "Your microphone, only in calls")),
            Item(id: "model", title: String(localized: "The private model, on this Mac")),
            Item(id: "server", title: String(localized: "The explanations (account and server)")),
        ]

        switch model.state {
        case .listening, .paused: set("sound", .ok)
        case .starting: set("sound", .waiting(String(localized: "Starting…")))
        case .needsPermission:
            set("sound", .missing(String(localized: "Turn on Afterhear in “Screen & System Audio Recording”, then reopen it.")),
                fix: (String(localized: "Open Settings"), { AppModel.shared.openScreenRecordingSettings() }))
        }

        if MediaKey.allowed { set("gestures", .ok) } else {
            set("gestures", .missing(String(localized: "Turn on Afterhear in “Accessibility”, then reopen it.")),
                fix: (String(localized: "Open Settings"), { DoubleTapOption.openSettings() }))
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: set("mic", .ok)
        case .notDetermined: set("mic", .waiting(String(localized: "Afterhear asks the first time you're in a call.")))
        default:
            set("mic", .missing(String(localized: "Without it, Afterhear doesn't hear your “sorry?” in calls.")),
                fix: (String(localized: "Open Settings"), {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                }))
        }

        if !Parakeet.isDownloaded(heard) {
            switch Parakeet.status {
            case .downloading(let percent): set("model", .waiting(String(localized: "Downloading \(percent)%…")))
            case .failed(let why):
                ErrorLog.record("model.download", why)
                set("model", .missing(String(localized: "The download stopped: \(why)")),
                    fix: (String(localized: "Try again"), { Task { await Parakeet.shared.prepare(heard, anyNetwork: true) } }))
            default:
                set("model", .waiting(String(localized: "Not downloaded yet")))
                Task { await Parakeet.shared.prepare(heard) }
            }
        } else if await Parakeet.shared.words([Float](repeating: 0, count: 16_000), language: heard) != nil {
            set("model", .ok)
        } else {
            ErrorLog.record("model.load", Parakeet.onProcessor ? "processor" : "neural engine")
            set("model", .missing(String(localized: "The model is here but didn't start. Reopen Afterhear.")),
                fix: (String(localized: "Reopen"), { AppModel.shared.relaunch() }))
        }

        let signedIn = Account.shared.signedIn || !AppSettings.current.code.trimmingCharacters(in: .whitespaces).isEmpty
        if !signedIn {
            set("server", .missing(String(localized: "Sign in, so the explanations can come.")),
                fix: (String(localized: "Sign in"), { Onboarding.showSignInIfNeeded() }))
        } else if await serverAnswers() {
            set("server", .ok)
        } else {
            ErrorLog.record("server.unreachable", AppSettings.current.server)
            set("server", .missing(String(localized: "The server doesn't answer. Check the connection: the moments are kept and explained later.")))
        }
    }

    private func set(_ id: String, _ state: State, fix: (String, @MainActor () -> Void)? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = state
        items[i].fix = fix.map { (label: $0.0, action: $0.1) }
    }

    private func serverAnswers() async -> Bool {
        guard let base = URL(string: AppSettings.current.server.trimmingCharacters(in: .whitespaces)) else { return false }
        var request = URLRequest(url: base, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return status < 500
    }
}

struct HealthView: View {
    @ObservedObject private var check = HealthCheck.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(check.allReady ? String(localized: "Everything is ready.") : String(localized: "Is everything ready?"))
                .font(.title2.weight(.semibold))
            ForEach(check.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    icon(item.state)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                        switch item.state {
                        case .missing(let why), .waiting(let why):
                            Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        default: EmptyView()
                        }
                        if let fix = item.fix, item.state != .ok {
                            Button(fix.label) { fix.action() }.controlSize(.small)
                        }
                    }
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Check again") { Task { await check.run() } }.disabled(check.running)
            }
        }
        .padding(24)
        .frame(width: 460, height: 460, alignment: .topLeading)
        .task { if check.items.isEmpty { await check.run() } }
    }

    @ViewBuilder private func icon(_ state: HealthCheck.State) -> some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        }
    }
}
