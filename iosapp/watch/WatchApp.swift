import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct UhsideWatchApp: App {
    @StateObject private var link = PhoneLink.shared

    var body: some Scene {
        WindowGroup {
            MarkView().environmentObject(link)
        }
    }
}

/// The three gestures on the wrist (docs/BRAIN.md § 19.5):
/// one tap marks, two taps explain it now, hold for two seconds turns listening on or off.
/// The system double tap (finger and thumb) is a mark too. The wave shows when LEXALIE listens.
struct MarkView: View {
    @EnvironmentObject private var link: PhoneLink
    @ObservedObject private var table = WatchRecorder.shared
    @AppStorage("watchGesturesSeen") private var seen = false
    @State private var lastTap = Date.distantPast
    @State private var holding = false

    var body: some View {
        if !seen {
            WatchGuide { seen = true }
        } else {
            main
        }
    }

    private var main: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    if table.recording {
                        Image(systemName: "applewatch.radiowaves.left.and.right").foregroundStyle(Brand.accent)
                        Text("On the Watch · \(table.marks.count) marked").font(.footnote)
                    } else if link.listening {
                        Image(systemName: "waveform").foregroundStyle(Brand.accent)
                        Text("Listening · \(link.marks) marked").font(.footnote)
                    } else {
                        Text("Not listening").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let help = link.help {
                    Text(help).font(.headline).multilineTextAlignment(.center)
                        .padding(8).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                        .onTapGesture { link.help = nil }
                } else if link.asking {
                    ProgressView()
                }
                surface
                if active {
                    HStack {
                        Button("5 min ago") { markAt(5) }
                        Button("20 min") { markAt(20) }
                    }
                    .font(.footnote)
                } else {
                    // The iPhone stays in the bag: the Watch is the microphone on the table.
                    Button("Record on the Watch") { table.begin() }.font(.footnote)
                }
                Text(active ? "Tap: mark · Two taps: now · Hold: off" : "Hold to start listening")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("How it works") { seen = false }.font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    /// The one big target: tap, tap-tap, or hold.
    @ViewBuilder private var surface: some View {
        Text(active ? "Didn't get that" : "Hold to listen")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(RoundedRectangle(cornerRadius: 14).fill(active ? Brand.accent : Color.white.opacity(0.12)))
            .foregroundStyle(active ? Color.black : Color.white)
            .scaleEffect(holding ? 0.94 : 1)
            .animation(.easeOut(duration: 0.2), value: holding)
            .overlay(alignment: .bottom) {
                // The knot ties itself where you tapped, with the tick.
                KnotTie(color: Color.black.opacity(0.75), trigger: link.tied).frame(width: 44).padding(.bottom, 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { tapped() }
            .onLongPressGesture(minimumDuration: 2, pressing: { holding = $0 }) {
                holding = false
                // Recording here, or no iPhone nearby: the Watch records by itself.
                if table.recording || (!link.listening && !WCSession.default.isReachable) {
                    table.toggle()
                } else {
                    link.toggle()
                }
            }
        // The system double tap (finger and thumb): once is a mark, twice in a row is "now".
        if #available(watchOS 11.0, *), active {
            Button("Mark") { tapped() }
                .font(.footnote)
                .handGestureShortcut(.primaryAction)
        }
    }

    /// The first tap marks at once; a second one within half a second asks for "now".
    private func tapped() {
        guard active else { return }
        let now = Date()
        if now.timeIntervalSince(lastTap) < 0.5 {
            lastTap = .distantPast
            // Recording on the Watch: "now" needs the iPhone; without it, it stays a mark.
            if !table.recording || WCSession.default.isReachable { link.askNow() }
        } else {
            lastTap = now
            markAt(0)
        }
    }

    private var active: Bool { link.listening || table.recording }

    private func markAt(_ minutes: Double) {
        if table.recording {
            table.mark(minutesAgo: minutes)
            link.tied += 1
        } else {
            link.mark(minutesAgo: minutes)
        }
    }
}

/// First launch on the wrist (§ 19.10): the three gestures, one screen each, with Skip.
struct WatchGuide: View {
    let done: () -> Void
    @State private var page = 0
    private let pages: [(String, String, String)] = [
        ("hand.tap", "One tap", "Something slipped past you? Tap. A light tick: it's marked. Tonight LEXALIE finds it."),
        ("hand.tap.fill", "Two taps", "Need it now? Tap twice: one line on your wrist."),
        ("waveform", "Hold", "Hold for two seconds to start or stop listening. Two short taps: on. One long buzz: off."),
    ]

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: pages[page].0).font(.title2).foregroundStyle(Brand.accent)
            Text(pages[page].1).font(.headline)
            Text(pages[page].2).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("Skip") { done() }.font(.footnote)
                Button(page == pages.count - 1 ? "Got it" : "Next") {
                    if page == pages.count - 1 { done() } else { page += 1 }
                }
                .font(.footnote.weight(.semibold))
                .tint(Brand.accent)
            }
        }
        .padding(.horizontal, 4)
    }
}

enum Brand {
    /// Apricot (§ 19.11): warm, never mistaken for the Workout green.
    static let accent = Color(red: 0xf2 / 255, green: 0xc4 / 255, blue: 0xa0 / 255)
}

final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneLink()
    @Published var listening = false
    @Published var marks = 0

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// One line from two taps, shown on the wrist for a few seconds.
    /// Changes on every mark: the knot ties itself on screen (§ 19.12).
    @Published var tied = 0
    @Published var help: String?
    @Published var asking = false
    /// The latest end-of-session card, one line per moment (block INSIEME).
    @Published var cardTitle = ""
    @Published var cardLines: [String] = []

    /// "Ask LEXALIE", dictated here: the iPhone looks in everything you listened to together.
    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let session = WCSession.default
        guard session.isReachable else {
            help = "Your iPhone isn't reachable."
            return
        }
        asking = true
        session.sendMessage(["ask": q], replyHandler: { reply in
            DispatchQueue.main.async {
                self.asking = false
                self.help = reply["help"] as? String
                WKInterfaceDevice.current().play(.notification)
            }
        }, errorHandler: { _ in
            DispatchQueue.main.async { self.asking = false; self.help = "Couldn't ask now." }
        })
    }

    /// The latest card, fresh from the iPhone.
    func loadCard() {
        let session = WCSession.default
        guard session.isReachable else { return }
        session.sendMessage(["card": true], replyHandler: { reply in
            DispatchQueue.main.async {
                self.cardTitle = reply["cardTitle"] as? String ?? self.cardTitle
                self.cardLines = reply["cardLines"] as? [String] ?? self.cardLines
            }
        }, errorHandler: nil)
    }

    func mark(minutesAgo: Double) {
        WKInterfaceDevice.current().play(.click)
        tied += 1
        send(["mark": Date().timeIntervalSince1970, "minutesAgo": minutesAgo])
        marks += 1
    }

    /// Two taps: the iPhone explains the last seconds and answers here.
    func askNow() {
        let session = WCSession.default
        guard session.isReachable else {
            help = "Your iPhone isn't reachable: it's marked, tonight you'll see it."
            return
        }
        WKInterfaceDevice.current().play(.directionUp)
        asking = true
        session.sendMessage(["now": Date().timeIntervalSince1970], replyHandler: { reply in
            DispatchQueue.main.async {
                self.asking = false
                self.help = reply["help"] as? String
                WKInterfaceDevice.current().play(.notification)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.help = nil }
            }
        }, errorHandler: { _ in
            DispatchQueue.main.async { self.asking = false }
        })
    }

    /// Hold: on or off. On = two short taps; off = one long buzz (§ 19.5).
    func toggle() {
        let wasListening = listening
        send(["toggle": true])
        if wasListening {
            WKInterfaceDevice.current().play(.stop)
        } else {
            WKInterfaceDevice.current().play(.click)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { WKInterfaceDevice.current().play(.click) }
        }
    }

    func send(_ message: [String: Any]) {
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            // Delivered as soon as the iPhone can take it: the mark keeps its time.
            session.transferUserInfo(message)
        }
    }

    private func apply(_ context: [String: Any]) {
        DispatchQueue.main.async {
            self.listening = context["listening"] as? Bool ?? false
            self.marks = context["marks"] as? Int ?? 0
            if let title = context["cardTitle"] as? String { self.cardTitle = title }
            if let lines = context["cardLines"] as? [String] { self.cardLines = lines }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        apply(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    /// "Now" from the iPhone or the AirPods, shown here because you chose the wrist (§ 11.14).
    private func showHelp(_ message: [String: Any]) {
        guard let line = message["help"] as? String else { return }
        DispatchQueue.main.async {
            self.help = line
            WKInterfaceDevice.current().play(.notification)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if self.help == line { self.help = nil } }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { showHelp(message) }

    /// The Watch's own recording reached the iPhone: it can go from here.
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil { try? FileManager.default.removeItem(at: fileTransfer.file.fileURL) }
    }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { showHelp(userInfo) }
}
