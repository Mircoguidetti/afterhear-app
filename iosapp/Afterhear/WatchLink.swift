import Foundation
import WatchConnectivity

/// The Watch as the invisible tap (§ 11.2): a double tap on the wrist marks, a small
/// vibration confirms, and the Watch always shows when Afterhear is listening (§ 11.12).
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    @MainActor
    func sendState() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired else { return }
        let s = Sessions.shared.current
        try? WCSession.default.updateApplicationContext(["listening": s != nil, "marks": s?.bookmarks.count ?? 0, "title": s?.title ?? ""])
    }

    /// "Now" answered on the wrist even when the tap came from elsewhere (§ 11.14).
    func show(_ line: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired else { return }
        let message: [String: Any] = ["help": line]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { _ in WCSession.default.transferUserInfo(message) }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        var minutes = message["minutesAgo"] as? Double ?? 0
        // A mark queued while the phone was away keeps the time it was made.
        if let at = message["mark"] as? Double { minutes += max(0, Date().timeIntervalSince1970 - at) / 60 }
        Task { @MainActor in
            if message["start"] as? Bool == true { await Sessions.shared.start() }
            else if message["stop"] as? Bool == true { Sessions.shared.stop() }
            else if message["toggle"] as? Bool == true { await Sessions.shared.toggle(source: "watch") }
            else if message["now"] != nil { await Sessions.shared.now(source: "watch") }
            else { Sessions.shared.mark(source: "watch", minutesAgo: minutes) }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { handle(message) }

    /// Two taps on the wrist: the answer goes back to the Watch, one line (§ 19.5).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["now"] != nil else {
            handle(message)
            replyHandler([:])
            return
        }
        Task { @MainActor in
            let line = await Sessions.shared.now(source: "watch")
            replyHandler(["help": line ?? "Start listening first."])
        }
    }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { handle(userInfo) }

    /// The Watch recorded on its own (the table microphone): its audio and marks become a session.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let info = file.metadata ?? [:]
        guard info["watchRecording"] as? Bool == true else { return }
        // The file is only ours until this method returns: move it somewhere safe first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        guard (try? FileManager.default.moveItem(at: file.fileURL, to: kept)) != nil else { return }
        let start = (info["start"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let marks = (info["marks"] as? [Double] ?? []).map { Bookmark(at: Date(timeIntervalSince1970: $0), source: "watch_table", window: 3) }
        Task { @MainActor in
            await Sessions.shared.importAudio(kept, start: start, marks: marks, title: "Watch on the table", move: true)
        }
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in WatchLink.shared.sendState() }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
