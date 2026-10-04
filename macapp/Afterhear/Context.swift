import AppKit
import ApplicationServices
import CoreGraphics

/// Where you are when you tap: it decides how much Afterhear shows you right away.
enum AppContext: String, CaseIterable, Identifiable, Codable {
    case video, call, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .video: "Watching a video"
        case .call: "In a call"
        case .other: "Anything else"
        }
    }
}

/// Reads the app in front and its window title (through Accessibility). Nothing is saved:
/// only "video", "call" or "other".
enum ContextDetector {
    private static let videoApps: Set<String> = [
        "com.apple.TV", "org.videolan.vlc", "com.colliderli.iina", "com.apple.QuickTimePlayerX",
        "com.netflix.Netflix", "com.amazon.aiv.AIVApp", "com.disney.disneyplus",
    ]
    private static let callApps: Set<String> = [
        "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos", "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "com.hnc.Discord",
    ]
    private static let videoTitles = ["YouTube", "Netflix", "Prime Video", "Disney+", "Vimeo", "Twitch", "Apple TV", "RaiPlay", "BBC iPlayer"]
    private static let callTitles = ["Meet -", "Google Meet", "Microsoft Teams", "Zoom Meeting", "Zoom Workplace", "Whereby", "Webex"]

    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Is the Mac playing sound right now? Set by AppModel from the sound it already hears.
    static var soundPlaying: () -> Bool = { false }

    static func current() -> AppContext {
        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier ?? ""
        let windows = visibleWindows()
        // Window titles come with Screen Recording, which Afterhear no longer asks for (Netflix turned
        // white): the title of the window in front is read through Accessibility instead (§ 19.24).
        var frontTitles = windows.filter { $0.pid == front?.processIdentifier }.map(\.title)
        if let title = frontTitle(front) { frontTitles.append(title) }

        // What you're looking at wins: a video in front is a video, even with Teams open behind.
        if videoApps.contains(frontID) || frontTitles.contains(where: matches(videoTitles)) { return .video }
        if callApps.contains(frontID) || frontTitles.contains(where: matches(callTitles)) { return .call }
        // A call running in another window still counts as a call.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if windows.contains(where: { matches(callTitles)($0.title) }) { return .call }
        if !callApps.isDisjoint(with: running) && windows.contains(where: { w in
            NSRunningApplication(processIdentifier: w.pid).map { callApps.contains($0.bundleIdentifier ?? "") } ?? false
        }) {
            return .call
        }
        // A browser in front playing sound, and no call anywhere: most likely a video (a site we
        // don't know by name, or no title to read).
        if browsers.contains(frontID), soundPlaying() { return .video }
        return .other
    }

    /// The title of the window in front, through Accessibility (no Screen Recording needed).
    static func frontTitle(_ app: NSRunningApplication?) -> String? {
        guard let app, AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let text = title as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func matches(_ needles: [String]) -> (String) -> Bool {
        { title in needles.contains { title.localizedCaseInsensitiveContains($0) } }
    }

    private static func visibleWindows() -> [(pid: pid_t, title: String)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty else { return nil }
            return (pid, title)
        }
    }
}

/// The play/pause key on the keyboard, pressed for you: pauses YouTube, Netflix, the TV app…
/// macOS only lets an app press keys once it has the Accessibility permission.
enum MediaKey {
    static var allowed: Bool { AXIsProcessTrusted() }

    static func askForPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// System Settings → Privacy & Security → Accessibility.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns false when the permission is missing (and asks for it).
    @discardableResult
    static func playPause() -> Bool {
        guard allowed else {
            askForPermission()
            return false
        }
        press(down: true)
        press(down: false)
        return true
    }

    private static func press(down: Bool) {
        let playKey = 16 // NX_KEYTYPE_PLAY
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = (playKey << 16) | ((down ? 0xa : 0xb) << 8)
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       subtype: 8, data1: data1, data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}

extension ContextDetector {
    /// The series or video in front (§ 5.15): the window title without the app's name.
    static func show() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let seen = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 })?[kCGWindowName as String] as? String
        guard let title = (seen?.isEmpty == false ? seen : nil) ?? frontTitle(front) else { return nil }
        var t = title
        for suffix in [" - Google Chrome", " — Google Chrome", " - Safari", " — Safari", " - Arc", " — Mozilla Firefox", " - Microsoft Edge", " - YouTube", " – YouTube", " | Netflix", " - Netflix", " | Prime Video", " – Prime Video", " | Disney+", " - BBC iPlayer", " | BBC iPlayer"] {
            if let r = t.range(of: suffix, options: [.caseInsensitive, .backwards]) { t = String(t[..<r.lowerBound]) }
        }
        t = t.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.count >= 2 && !["netflix", "youtube", "prime video"].contains(t.lowercased()) ? String(t.prefix(200)) : nil
    }
}

/// Live captions from Teams, Meet or Zoom, read through Accessibility (§ 2.3, experimental):
/// often more accurate than our own recogniser, and they know who spoke.
enum CaptionReader {
    struct Line { let speaker: String?; let text: String }

    static func recent() -> [Line] {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium and Electron apps (Chrome, Edge, Teams) only expose web content when asked.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var queue: [AXUIElement] = [root], visited = 0
        while !queue.isEmpty, visited < 4000 {
            let element = queue.removeFirst()
            visited += 1
            let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute, kAXRoleDescriptionAttribute]
                .compactMap { string(element, $0) }.joined(separator: " ").lowercased()
            if label.contains("caption") || label.contains("subtitle") || label.contains("transcript") {
                let texts = collect(element)
                if texts.count >= 1 { return lines(texts) }
            }
            queue += children(element)
        }
        return []
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func collect(_ e: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        var out: [String] = []
        if string(e, kAXRoleAttribute) == kAXStaticTextRole, let v = string(e, kAXValueAttribute) ?? string(e, kAXTitleAttribute),
           !v.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(v.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for c in children(e) { out += collect(c, depth: depth + 1) }
        return out
    }

    /// Captions usually alternate a short name and what they said.
    private static func lines(_ texts: [String]) -> [Line] {
        var out: [Line] = [], speaker: String?
        for t in texts.suffix(40) {
            if t.split(separator: " ").count <= 3 && t.first?.isUppercase == true && !t.hasSuffix(".") && !t.hasSuffix("?") {
                speaker = t
            } else {
                out.append(Line(speaker: speaker, text: t))
            }
        }
        return Array(out.suffix(12))
    }
}
