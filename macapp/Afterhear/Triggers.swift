import AppKit
import AVFoundation
import ApplicationServices

/// Two quick taps on an Option key: one finger, no looking. Left ⌥⌥ marks, right ⌥⌥ asks for
/// help now (owner, 02/10: no third tap, no waiting to see if one comes).
/// Reading keys pressed in other apps needs a macOS permission: "Input Monitoring"
/// (preferred, via an event tap) or "Accessibility" (via NSEvent monitors).
final class DoubleTapOption {
    /// Left ⌥⌥ marks the moment (nothing stops), right ⌥⌥ asks for help now.
    static let label = "left ⌥⌥"
    static let nowLabel = "right ⌥⌥"
    private static let rightOption: UInt16 = 61
    private static let leftOption: UInt16 = 58
    /// Diagnostics for the menu: the last modifier key seen, to know events arrive.
    private(set) var lastSeen: String?
    var onSeen: (() -> Void)?
    private var monitors: [Any] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var downAt: Date?
    private var lastTap: Date?
    private var lastKey: UInt16?
    private var taps = 0
    private let mark: () -> Void
    private let now: () -> Void
    /// Where key events come from right now: "input", "accessibility" or nil.
    private(set) var via: String?

    init(mark: @escaping () -> Void, now: @escaping () -> Void) {
        self.mark = mark
        self.now = now
    }

    static var canListen: Bool { CGPreflightListenEventAccess() }
    static var isTrusted: Bool { canListen || AXIsProcessTrusted() }

    static func askForPermission() {
        _ = CGRequestListenEventAccess()
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        let pane = canListen ? "Privacy_Accessibility" : "Privacy_ListenEvent"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard via == nil else { return }
        if Self.canListen, startTap() {
            via = "input"
        } else if AXIsProcessTrusted() {
            startMonitors()
            via = "accessibility"
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        via = nil
    }

    private func startTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let detector = Unmanaged<DoubleTapOption>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = detector.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let optionDown = event.flags.contains(.maskAlternate)
            let isKey = type == .keyDown
            DispatchQueue.main.async { detector.handle(isKey: isKey, keyCode: keyCode, optionDown: optionDown) }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func startMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handle(isKey: event.type == .keyDown, keyCode: event.keyCode, optionDown: event.modifierFlags.contains(.option))
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: {
            handler($0)
            return $0
        }) {
            monitors.append(local)
        }
    }

    private func handle(isKey: Bool, keyCode: UInt16, optionDown: Bool) {
        if !isKey {
            let name = keyCode == Self.rightOption ? "right ⌥" : keyCode == Self.leftOption ? "left ⌥" : "key \(keyCode)"
            lastSeen = "\(name) \(optionDown ? "down" : "up") at \(Date().formatted(date: .omitted, time: .standard))"
            onSeen?()
        }
        // Typing anything else (Option+letter, shortcuts) cancels the gesture.
        guard !isKey, keyCode == Self.rightOption || keyCode == Self.leftOption else {
            downAt = nil
            lastTap = nil
            taps = 0
            return
        }
        let time = Date()
        if optionDown {
            downAt = time
            return
        }
        guard let down = downAt, time.timeIntervalSince(down) < 0.5 else { return }
        downAt = nil
        // Both taps on the same Option key: left then right counts as nothing.
        if let last = lastTap, time.timeIntervalSince(last) < 0.8, lastKey == keyCode {
            taps += 1
        } else {
            taps = 1
        }
        lastTap = time
        lastKey = keyCode
        switch Self.gesture(taps: taps, right: keyCode == Self.rightOption) {
        case .now:
            taps = 0
            lastTap = nil
            now()
        case .mark:
            taps = 0
            lastTap = nil
            mark()
        case .none:
            break
        }
    }

    enum Gesture { case none, mark, now }

    /// One tap does nothing (Option is a normal key); two on the left mark, two on the right ask for help now.
    static func gesture(taps: Int, right: Bool) -> Gesture {
        taps == 2 ? (right ? .now : .mark) : .none
    }
}

/// Listens to your own microphone, transcribed on the Mac and kept in memory,
/// only to notice when you say "sorry?", "pardon?", "what do you mean?".
final class SorryDetector {
    private let engine = AVAudioEngine()
    /// Your own words, for the "tu" side of the conversation.
    let live = LiveTranscriber()
    private var timer: Timer?
    private var lastFired = Date.distantPast
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    private static let phrases: [HeardLanguage: String] = [
        .enGB: #"\b(sorry(\?|\s*$| what)|pardon|what do you mean|can you repeat|could you repeat|say (that|it) again|say again|come again|what was that|(didn't|did not) catch (that|it)|you what)"#,
        .enUS: #"\b(sorry(\?|\s*$| what)|pardon|what do you mean|can you repeat|could you repeat|say (that|it) again|say again|come again|what was that|(didn't|did not) catch (that|it))"#,
        .itIT: #"\b(scusa\?|scusi\?|come\?|cosa intendi|puoi ripetere|può ripetere)"#,
        .frFR: #"\b(pardon|comment\?|tu peux répéter|vous pouvez répéter)"#,
        .esES: #"\b(perdón\?|cómo\?|puedes repetir|puede repetir)"#,
        .deDE: #"\b(wie bitte|entschuldigung\?|kannst du das wiederholen|können sie das wiederholen)"#,
        .ruRU: #"(извините\?|что\?|повторите|можешь повторить)"#,
    ]

    var isRunning: Bool { engine.isRunning }

    static func askForMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
    }

    func start(language: HeardLanguage) throws {
        guard !engine.isRunning else { return }
        live.configure(language: language)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let live = self.live
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            live.append(channel, count: Int(buffer.frameLength), rate: format.sampleRate)
        }
        try engine.start()
        var pattern = Self.phrases[language] ?? Self.phrases[.enGB]!
        let keyword = UserDefaults.standard.string(forKey: Key.keyword)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if !keyword.isEmpty { pattern = "(" + pattern + "|" + NSRegularExpression.escapedPattern(for: keyword) + ")" }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.check(pattern)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        live.stop()
    }

    private func check(_ pattern: String) {
        guard Date().timeIntervalSince(lastFired) > 8 else { return }
        // Parakeet writes a sentence once it's over (~1 s later): look a little further back.
        let recent = live.text(last: 5).lowercased()
        guard recent.range(of: pattern, options: .regularExpression) != nil else { return }
        lastFired = Date()
        action()
    }
}
