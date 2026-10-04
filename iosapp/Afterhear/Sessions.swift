import ActivityKit
import AudioToolbox
import AVFoundation
import CallKit
import CoreLocation
import EventKit
import Foundation
import MediaPlayer
import UIKit
import UserNotifications

/// A mark: "somewhere in the last minutes there was something" (§ 11.2–11.4).
struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    let at: Date
    /// "tap", "watch", "airpods", "siri", "lock_screen", "phrase", "earlier".
    let source: String
    /// How far back it may be, in minutes (a delayed tap can mean twenty minutes ago).
    let window: Double
}

/// One time out: "I'm out", from start to stop. Audio stays on this iPhone until the night.
struct OutSession: Codable, Identifiable {
    let id: UUID
    let start: Date
    var end: Date?
    var title: String
    var bookmarks: [Bookmark] = []
    /// One-minute audio pieces kept so far (file name → start).
    var chunks: [String: Date] = [:]
    /// Keep the whole evening, to find hard pieces without a tap (§ 11.8, § 13.5).
    var keepAll: Bool
    var processed = false
    /// When it should stop by itself: the end of the calendar event.
    var plannedEnd: Date?
}

/// Real life (docs/BRAIN.md § 11, § 13): silent by default, the lesson comes home.
@MainActor
final class Sessions: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Sessions()

    @Published private(set) var current: OutSession?
    @Published private(set) var all: [OutSession] = []
    @Published var message: String?
    /// The answer to two taps on the screen, shown under the button.
    @Published var nowLine: String?

    let recorder = Recorder()
    private var spotter: PhraseSpotter?
    private var timer: Timer?
    private var activity: Activity<ListeningAttributes>?
    private let location = CLLocationManager()
    private var startPlace: CLLocation?
    private let events = EKEventStore()
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("sessions.json")
    static var audioRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("out", isDirectory: true) }

    var listening: Bool { current != nil }

    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.audioRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([OutSession].self, from: data) {
            all = saved
            // Killed while listening: close it where it was.
            for i in all.indices where all[i].end == nil { all[i].end = all[i].chunks.values.max().map { $0.addingTimeInterval(60) } ?? all[i].start }
        }
        location.delegate = self
    }

    func boot() {
        K.register()
        recorder.onChunk = { [weak self] name, start in self?.chunkDone(name, start) }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended { Task { @MainActor in Sessions.shared.recorder.resume() } }
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Night.shared.pluggedIn() }
        }
        Task { await Memory.shared.sync() }
        offerAtEvents()
        PhoneCalls.shared.boot()
        WatchLink.shared.sendState()
    }

    // MARK: Start and stop

    /// `tv`: the phone on the couch listens to the TV (§ 14.3); the whole film is kept, so your
    /// model finds the lines you probably missed and the quiz comes after (§ 14.5).
    /// `apps`: the other apps' sound instead of the microphone (iOS 27, AppAudio).
    func start(title: String? = nil, tv: Bool = false, apps: Bool = false) async {
        guard current == nil else { return }
        if apps {
            await startApps(title: title)
            return
        }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else {
            message = "Afterhear needs the microphone: Settings → Afterhear → Microphone."
            return
        }
        let now = Date()
        let event = currentEvent()
        let id = UUID()
        var session = OutSession(id: id, start: now, title: tv ? "TV" : title ?? event?.title ?? "Out", keepAll: tv || K.bool(K.keepEvening))
        session.plannedEnd = event?.endDate
        do {
            try recorder.start(into: Self.audioRoot.appendingPathComponent(id.uuidString, isDirectory: true))
        } catch {
            message = "The microphone didn't start: \(error.localizedDescription)"
            return
        }
        current = session
        if K.bool(K.phraseTaps) {
            spotter = PhraseSpotter { Task { @MainActor in Sessions.shared.mark(source: "phrase") } }
            spotter?.start()
            let spotter = self.spotter
            recorder.onBuffer = { buffer in spotter?.append(buffer) }
        }
        if K.bool(K.airpods) { listenToAirPods(true) }
        if K.bool(K.stopOnLeave) {
            location.requestAlwaysAuthorization()
            location.allowsBackgroundLocationUpdates = true
            location.desiredAccuracy = kCLLocationAccuracyHundredMeters
            location.distanceFilter = 100
            startPlace = nil
            location.startUpdatingLocation()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in Sessions.shared.tick() } }
        startActivity(session)
        save()
        WatchLink.shared.sendState()
    }

    func stop(reason: String = "tap") {
        guard var session = current else { return }
        recorder.stop()
        recorder.stopFeed()
        #if IOS27_CAPTURE
        if #available(iOS 27.0, *) { AppAudioCapture.shared.stop() }
        #endif
        spotter?.stop()
        spotter = nil
        recorder.onBuffer = nil
        listenToAirPods(false)
        location.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
        session.end = Date()
        current = nil
        upsert(session)
        prune(session, final: true)
        endActivity()
        WatchLink.shared.sendState()
        if session.bookmarks.isEmpty && !session.keepAll {
            // Nothing marked and nothing to look for: the audio goes now.
            try? FileManager.default.removeItem(at: Self.audioRoot.appendingPathComponent(session.id.uuidString))
            if let i = all.firstIndex(where: { $0.id == session.id }) { all[i].processed = true; all[i].chunks = [:] }
            save()
            return
        }
        if reason != "tap" { message = "Stopped listening (\(reason))." }
        Night.shared.schedule()
    }

    // MARK: Marks

    /// One tap: a small vibration, nothing on screen. `minutesAgo` for "it was earlier".
    /// A tap can come long after the words (§ 19.3): the window reaches back to the start of
    /// this conversation, up to 30 minutes, and tonight your model finds the line in it.
    func mark(source: String, minutesAgo: Double = 0, window: Double = 3) {
        guard var session = current else {
            // In a phone call nobody can listen, not even Afterhear (§ 11.15): a bookmark with the time,
            // and after the call Apple's recording, shared to Afterhear, finds it.
            if PhoneCalls.shared.inCall {
                PhoneCalls.shared.bookmark(Bookmark(at: Date().addingTimeInterval(-minutesAgo * 60), source: "phone_" + source, window: max(3, minutesAgo + 2)))
                AudioServicesPlaySystemSound(1519)
                message = "Marked in the call. After it, share Apple's recording of the call to Afterhear."
                return
            }
            message = "Start listening first: Afterhear only keeps audio while you choose to."
            return
        }
        let at = Date().addingTimeInterval(-minutesAgo * 60)
        let conversation = minutesAgo > 0 ? 0 : min(30, at.timeIntervalSince(recorder.conversationStart) / 60)
        session.bookmarks.append(Bookmark(at: at, source: source, window: max(window, minutesAgo > 0 ? 5 : 3, conversation)))
        current = session
        upsert(session)
        // One light tick: never the long buzz, that one means "off" (§ 19.5).
        AudioServicesPlaySystemSound(1519)
        updateActivity()
        WatchLink.shared.sendState()
        if K.bool(K.liveHelp) || K.bool(K.focusLiveHelp) { Task { await liveHelp() } }
    }

    /// Two taps: "now" (§ 19.5). The mark is already there from the first tap; this explains
    /// the last seconds at once. From the Watch the answer goes back to the wrist; from the phone,
    /// a notification. Returns the one line to show.
    @discardableResult
    func now(source: String) async -> String? {
        guard current != nil else {
            message = "Start listening first: Afterhear only keeps audio while you choose to."
            return nil
        }
        let line = await liveHelp(notify: false)
        guard let line else { return nil }
        return await deliver(line, from: source)
    }

    /// Where the answer goes (§ 11.14): where you tapped, or where you chose. Returns what the
    /// Watch shows when the tap came from it.
    private func deliver(_ line: String, from source: String) async -> String {
        let place = K.string(K.nowWhere)
        let fromWatch = source == "watch"
        switch place {
        case "voice":
            Voice.say(line)
            return "🎧 In your ear"
        case "watch" where !fromWatch:
            WatchLink.shared.show(line)
            return line
        case "iphone" where fromWatch:
            await notify(line)
            return "On your iPhone"
        default:
            if !fromWatch { await notify(line) }
            return line
        }
    }

    private func notify(_ line: String) async {
        let content = UNMutableNotificationContent()
        let parts = line.components(separatedBy: " → ")
        content.title = parts.first ?? line
        content.body = parts.dropFirst().joined(separator: " → ")
        content.interruptionLevel = .timeSensitive
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// "Help me live" (§ 11.11), for who doesn't mind: the last seconds, explained in a notification.
    @discardableResult
    private func liveHelp(notify: Bool = true) async -> String? {
        let samples = recorder.last(25)
        guard samples.count > 16_000 else { return nil }
        // Real life: the sound never leaves the iPhone. Parakeet transcribes it here (§ 19.25).
        let found = await Private.shared.words(samples, start: Date())
        // iOS closes apps in the background that hold too much memory: the model goes right away.
        await Private.shared.release()
        guard let words = found else {
            return "The private model is still downloading (on Wi-Fi). Marked for tonight."
        }
        let heard = words.filter { $0.mine != true }.map(\.text).joined(separator: " ")
        guard !heard.isEmpty else { return "Didn't catch anything." }
        let text = String(heard.suffix(400))
        // No connection: a quick explanation from the model inside the iPhone.
        let explained: Api.Explanation?
        if let e = try? await Api.explain(text) { explained = e } else { explained = await OfflineExplainer.explain(text) }
        guard let e = explained, let p = e.pieces.first else { return "Nothing hard: it was just fast." }
        let body = [p.gloss, p.meaning].compactMap { $0 }.first ?? ""
        if notify {
            let content = UNMutableNotificationContent()
            content.title = p.text
            content.body = [p.gloss, p.meaning].compactMap { $0 }.joined(separator: " · ")
            content.interruptionLevel = .timeSensitive
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        return body.isEmpty ? p.text : "\(p.text) → \(body)"
    }

    /// Hold for two seconds: listening on or off (§ 19.5), with a feel you can't mistake:
    /// on = two short taps, off = one long buzz.
    func toggle(source: String) async {
        if current != nil {
            stop()
            Haptics.off()
        } else {
            await start()
            if current != nil { Haptics.on() }
        }
    }

    // MARK: Every 30 seconds

    private func tick() {
        guard let session = current else { return }
        let now = Date()
        let maxHours = max(0.5, UserDefaults.standard.double(forKey: K.maxHours))
        if now.timeIntervalSince(session.start) > maxHours * 3600 { stop(reason: "after \(Int(maxHours)) hours"); return }
        if now.timeIntervalSince(recorder.lastVoice) > 20 * 60 { stop(reason: "20 minutes of silence"); return }
        // At home the film is over when there's quiet: the quiz is ready sooner.
        if session.title == "TV", now.timeIntervalSince(recorder.lastVoice) > 5 * 60 { stop(reason: "the film seems over"); return }
        if let end = session.plannedEnd, now > end.addingTimeInterval(15 * 60) { stop(reason: "\(session.title) ended"); return }
        prune(session, final: false)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            guard Sessions.shared.current != nil else { return }
            if let start = Sessions.shared.startPlace {
                if last.distance(from: start) > 400 { Sessions.shared.stop(reason: "you left the place") }
            } else if last.horizontalAccuracy < 200 {
                Sessions.shared.startPlace = last
            }
        }
    }

    // MARK: Audio pieces

    private func chunkDone(_ name: String, _ start: Date) {
        guard let id = current?.id ?? all.first(where: { $0.end != nil && !$0.processed && Self.folder($0).appendingPathComponent(name).isFile })?.id,
              let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].chunks[name] = start
        if current?.id == id { current?.chunks[name] = start }
        save()
    }

    /// The 30-minute window (§ 11.6): older pieces go, unless near a mark or the whole evening is kept.
    private func prune(_ session: OutSession, final: Bool) {
        guard !session.keepAll else { return }
        let now = Date()
        var kept = session.chunks
        for (name, start) in session.chunks {
            let end = start.addingTimeInterval(60)
            let nearMark = session.bookmarks.contains { b in end >= b.at.addingTimeInterval(-b.window * 60 - 60) && start <= b.at.addingTimeInterval(30) }
            let inWindow = !final && now.timeIntervalSince(end) < 30 * 60
            if !nearMark && !inWindow {
                try? FileManager.default.removeItem(at: Self.folder(session).appendingPathComponent(name))
                kept[name] = nil
            }
        }
        guard kept.count != session.chunks.count, let i = all.firstIndex(where: { $0.id == session.id }) else { return }
        all[i].chunks = kept
        if current?.id == session.id { current?.chunks = kept }
        save()
    }

    static func folder(_ s: OutSession) -> URL { audioRoot.appendingPathComponent(s.id.uuidString, isDirectory: true) }

    func upsert(_ s: OutSession) {
        if let i = all.firstIndex(where: { $0.id == s.id }) { all[i] = s } else { all.insert(s, at: 0) }
        save()
    }

    func markProcessed(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].processed = true
        all[i].chunks = [:]
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(all.prefix(60))) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }

    // MARK: Live Activity: always visible while listening (§ 11.12)

    private func startActivity(_ s: OutSession) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = ListeningAttributes.ContentState(marks: 0, liveHelp: K.bool(K.liveHelp) || K.bool(K.focusLiveHelp))
        activity = try? Activity.request(attributes: ListeningAttributes(startedAt: s.start, title: s.title),
                                         content: .init(state: state, staleDate: nil))
    }

    private func updateActivity() {
        guard let activity, let s = current else { return }
        let state = ListeningAttributes.ContentState(marks: s.bookmarks.count, liveHelp: K.bool(K.liveHelp) || K.bool(K.focusLiveHelp))
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func endActivity() {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
    }

    // MARK: AirPods (§ 11.2), opt-in: a squeeze on the stem marks

    private func listenToAirPods(_ on: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        guard on else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.addTarget { _ in
                Task { @MainActor in Sessions.shared.mark(source: "airpods") }
                return .success
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Afterhear is listening"]
    }

    // MARK: Calendar (§ 11.7, § 13.8)

    private func currentEvent() -> EKEvent? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let now = Date()
        let predicate = events.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(60), calendars: nil)
        return events.events(matching: predicate).first { !$0.isAllDay && $0.startDate <= now.addingTimeInterval(15 * 60) && $0.endDate > now }
    }

    /// "Dinner with Sarah at 20:30: listen?" A notification at the start of your events
    /// (not calls, not all-day). Starting needs one tap: iOS never lets an app start the microphone by itself.
    func offerAtEvents() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: (0..<20).map { "offer-\($0)" })
        guard K.bool(K.offerAtEvents) else { return }
        Task {
            guard (try? await events.requestFullAccessToEvents()) == true else { return }
            let now = Date()
            let list = events.events(matching: events.predicateForEvents(withStart: now, end: now.addingTimeInterval(36 * 3600), calendars: nil))
                .filter { e in
                    let text = ((e.notes ?? "") + " " + (e.url?.absoluteString ?? "") + " " + (e.location ?? "")).lowercased()
                    return !e.isAllDay && !["teams.microsoft", "zoom.us", "meet.google", "webex"].contains { text.contains($0) }
                }
                .prefix(20)
            for (i, e) in list.enumerated() {
                let content = UNMutableNotificationContent()
                let time = e.startDate.formatted(date: .omitted, time: .shortened)
                content.title = "\(e.title ?? "Your event") at \(time)"
                content.body = "Start listening now? Afterhear stays silent; the lesson comes tonight."
                content.categoryIdentifier = "OFFER"
                content.userInfo = ["kind": "offer", "title": e.title ?? "Out"]
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: e.startDate)
                try? await center.add(UNNotificationRequest(identifier: "offer-\(i)", content: content,
                                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
            }
        }
    }
}

extension URL {
    var isFile: Bool { FileManager.default.fileExists(atPath: path) }
}

/// The feel of on and off (§ 19.5): never mistaken for each other.
enum Haptics {
    @MainActor static func on() {
        let tap = UIImpactFeedbackGenerator(style: .rigid)
        tap.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { tap.impactOccurred() }
    }

    @MainActor static func off() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}

/// The answer in your ear (§ 11.14): a short line, read in the language you hear, quietly.
@MainActor
enum Voice {
    private static let synth = AVSpeechSynthesizer()

    static func say(_ line: String) {
        let utterance = AVSpeechUtterance(string: line.replacingOccurrences(of: "→", with: ","))
        utterance.voice = AVSpeechSynthesisVoice(language: K.string(K.heard).isEmpty ? "en-GB" : K.string(K.heard))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.volume = 0.8
        synth.speak(utterance)
    }
}

// MARK: - Other ears (docs/BRAIN.md § 11.15, § 19.18)

extension Sessions {
    /// Listening to the other apps (iOS 27): the same session, marks and night, without the microphone.
    func startApps(title: String?) async {
        #if IOS27_CAPTURE
        guard #available(iOS 27.0, *) else { return }
        let id = UUID()
        let session = OutSession(id: id, start: Date(), title: title ?? "On this iPhone", keepAll: K.bool(K.keepEvening))
        do {
            try recorder.startFeed(into: Self.audioRoot.appendingPathComponent(id.uuidString, isDirectory: true))
        } catch {
            message = "Couldn't start: \(error.localizedDescription)"
            return
        }
        let recorder = self.recorder
        AppAudioCapture.shared.start(onBuffer: { recorder.feed($0) }, onEnd: {
            Task { @MainActor in if Sessions.shared.current?.id == id { Sessions.shared.stop(reason: "the app stopped sharing its sound") } }
        })
        current = session
        upsert(session)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in Sessions.shared.tick() } }
        startActivity(session)
        WatchLink.shared.sendState()
        #else
        message = "Listening to other apps needs iOS 27."
        #endif
    }

    /// A recording made elsewhere becomes a session like one of ours: the Watch on the table,
    /// or Apple's recording of a phone call. The night transcribes it around the marks.
    func importAudio(_ source: URL, start: Date?, marks: [Bookmark], title: String, move: Bool) async {
        let asset = AVURLAsset(url: source)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard seconds > 1 else {
            message = "That file has no audio Afterhear can read."
            return
        }
        let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let begin = start ?? modified.addingTimeInterval(-seconds)
        var session = OutSession(id: UUID(), start: begin, title: title, keepAll: marks.isEmpty)
        session.end = begin.addingTimeInterval(seconds)
        session.bookmarks = marks
        let folder = Self.folder(session)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let name = "\(Int(begin.timeIntervalSince1970)).\(source.pathExtension.isEmpty ? "m4a" : source.pathExtension)"
        let target = folder.appendingPathComponent(name)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            if move { try FileManager.default.moveItem(at: source, to: target) } else { try FileManager.default.copyItem(at: source, to: target) }
        } catch {
            message = "Couldn't keep the recording: \(error.localizedDescription)"
            return
        }
        session.chunks = [name: begin]
        upsert(session)
        message = marks.isEmpty
            ? "\(title): kept. Tonight your model looks for what you probably missed."
            : "\(title): \(marks.count) \(marks.count == 1 ? "mark" : "marks"). Tonight Afterhear finds them."
        Night.shared.schedule()
    }

    /// Apple's call recording (Notes → share → Afterhear), or any audio file opened in Afterhear.
    /// It's matched to the phone call it belongs to, with the marks made during it.
    func importShared(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let call = PhoneCalls.shared.match(length: seconds, near: modified)
        let start = call?.start
        let window = call.map { ($0.start, $0.end) } ?? (modified.addingTimeInterval(-seconds - 60), modified.addingTimeInterval(60))
        let marks = PhoneCalls.shared.takeMarks(from: window.0.addingTimeInterval(-60), to: window.1.addingTimeInterval(60))
        await importAudio(url, start: start, marks: marks, title: call == nil ? "Recording" : "Phone call", move: false)
    }
}

/// Phone calls on this iPhone: only when they start and end (CallKit), never their audio,
/// which Apple gives to no app. Marks made during a call wait here for the recording.
@MainActor
final class PhoneCalls: NSObject, CXCallObserverDelegate {
    static let shared = PhoneCalls()

    struct Span: Codable { let start: Date; var end: Date }

    private let observer = CXCallObserver()
    private var started: [UUID: Date] = [:]
    private(set) var inCall = false

    private var spans: [Span] {
        get { (UserDefaults.standard.data(forKey: "phoneCalls")).flatMap { try? JSONDecoder().decode([Span].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.suffix(30))), forKey: "phoneCalls") }
    }

    private var marks: [Bookmark] {
        get { (UserDefaults.standard.data(forKey: "phoneMarks")).flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.suffix(100))), forKey: "phoneMarks") }
    }

    func boot() {
        observer.setDelegate(self, queue: nil)
        inCall = observer.calls.contains { !$0.hasEnded }
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let id = call.uuid, connected = call.hasConnected, ended = call.hasEnded
        Task { @MainActor in PhoneCalls.shared.changed(id: id, connected: connected, ended: ended) }
    }

    private func changed(id: UUID, connected: Bool, ended: Bool) {
        if connected, !ended, started[id] == nil { started[id] = Date() }
        if ended, let start = started.removeValue(forKey: id) { spans = spans + [Span(start: start, end: Date())] }
        inCall = observer.calls.contains { !$0.hasEnded }
    }

    func bookmark(_ b: Bookmark) { marks = marks + [b] }

    /// The call this recording belongs to: about as long, and ended shortly before the file was saved.
    func match(length: Double, near: Date) -> Span? {
        spans.filter { abs($0.end.timeIntervalSince($0.start) - length) < 120 && abs(near.timeIntervalSince($0.end)) < 6 * 3600 }
            .min { abs(near.timeIntervalSince($0.end)) < abs(near.timeIntervalSince($1.end)) }
    }

    func takeMarks(from: Date, to: Date) -> [Bookmark] {
        let taken = marks.filter { $0.at >= from && $0.at <= to }
        marks = marks.filter { !($0.at >= from && $0.at <= to) }
        return taken
    }
}
