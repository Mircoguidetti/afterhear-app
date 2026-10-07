import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import SwiftUI

/// Listening in person (owner, 07/10 evening): the doctor, a landlord, a counter, a meeting in a room.
/// The Mac's own microphone takes the place of the Mac's sound: taps work as usual (written on the screen,
/// names and numbers never leave the Mac), and at the end the card says what they told you to do.
///
/// Every time it starts, LEXALIE asks whether the person speaking knows it's listening: in many places
/// listening to someone needs their consent, and it's yours to ask. The sound stays on this Mac; the
/// conversation around a tap goes after 7 days, like everything else.
@MainActor
final class InPerson: ObservableObject {
    static let shared = InPerson()

    @Published private(set) var active = false { didSet { Self.isOn = active } }
    /// The same, readable from anywhere (the context, the microphone, the audio thread).
    nonisolated(unsafe) static var isOn = false
    private(set) var since = Date()
    private let engine = AVAudioEngine()
    private var timer: Timer?
    private var lines: [String] = []
    private var seen: Set<String> = []

    /// Asks first, every time; then listens with the Mac's microphone.
    func start() {
        guard !active, AppModel.shared.state == .listening else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Does the person speaking know LEXALIE is listening?")
        alert.informativeText = String(localized: "LEXALIE listens with this Mac's microphone so you can tap when you lose something. The sound stays on this Mac. In many places you need their consent: ask them first.")
        alert.addButton(withTitle: String(localized: "Yes, they know"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard await SorryDetector.askForMicrophone() else { return }
            await begin()
        }
    }

    private func begin() async {
        lines = []
        seen = []
        since = Date()
        ToldVoice.shared.reset()
        active = true
        // The Mac's sound steps aside while the room is heard (one source at a time for the tap).
        await AppModel.shared.pauseSystemAudio()
        do {
            try startMicrophone()
        } catch {
            ErrorLog.record("inperson.mic", error)
            await stop(showCard: false)
            return
        }
        AppModel.shared.applyMicrophone()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in InPerson.shared.observe() }
        }
    }

    func stop(showCard: Bool = true) async {
        guard active else { return }
        observe()
        timer?.invalidate()
        timer = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        active = false
        await AppModel.shared.resumeSystemAudio()
        if showCard { await EndCards.afterInPerson(lines: lines, since: since) }
    }

    /// What was said in the room, a minute at a time: kept for the end, the requests with their voice.
    private func observe() {
        guard active else { return }
        let start = Date().addingTimeInterval(-60)
        for turn in AppModel.shared.recentTurns(seconds: 60) {
            let text = turn.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, turn.end < 57, seen.insert(text.lowercased()).inserted else { continue }
            if lines.count < 400 { lines.append(String(text.prefix(1200))) }
            if Told.looksLikeRequest(text) { ToldVoice.shared.keep(turn, clipStart: start) }
        }
    }

    // MARK: The microphone

    /// The Mac's own microphone when there is one: AirPods' microphone would turn everything into
    /// phone-call sound, and it hears you better than the person in front of you.
    private func startMicrophone() throws {
        let input = engine.inputNode
        if let unit = input.audioUnit, var device = Self.builtInMicrophone() {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw LexalieError.server("microphone") }
        Self.listen(input, format: format)
        try engine.start()
    }

    /// The tap runs on the audio thread: built outside the main actor.
    nonisolated private static func listen(_ input: AVAudioInputNode, format: AVAudioFormat) {
        let channels = Int(format.channelCount), rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            // Deinterleaved: the first channel is enough for a voice.
            AppModel.feedRoom(data, frames: Int(buffer.frameLength), channels: buffer.format.isInterleaved ? channels : 1, rate: rate)
        }
    }

    static func builtInMicrophone() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        for device in devices {
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                              mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0 { return device }
        }
        return nil
    }
}

/// The menu's row: start, or the red dot while the room is heard and the way to stop.
struct InPersonRow: View {
    @ObservedObject private var inPerson = InPerson.shared

    var body: some View {
        if inPerson.active {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Listening in person").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Stop") { Task { await InPerson.shared.stop() } }.controlSize(.small)
            }
        } else {
            Button("Listen in person…") { InPerson.shared.start() }.controlSize(.small)
                .help(String(localized: "The doctor, a landlord, a meeting in a room: this Mac's microphone, after you ask them."))
        }
    }
}
