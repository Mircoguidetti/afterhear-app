import AVFoundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit

/// The last few seconds of sound, in memory only. Overwritten continuously;
/// nothing touches the disk unless the user asks for a moment.
final class SampleRing: @unchecked Sendable {
    private var samples: [Float] = []
    private var write = 0
    private var filled = 0
    private var rate: Double = 0
    private let lock = NSLock()
    private let seconds: Double

    init(seconds: Double) { self.seconds = seconds }

    func append(_ source: UnsafePointer<Float>, count: Int, rate newRate: Double) {
        lock.lock(); defer { lock.unlock() }
        if newRate != rate || samples.isEmpty {
            rate = newRate
            samples = [Float](repeating: 0, count: max(1, Int(seconds * newRate)))
            write = 0
            filled = 0
        }
        let capacity = samples.count
        for i in 0..<count {
            samples[write] = source[i]
            write += 1
            if write == capacity { write = 0 }
        }
        filled = min(capacity, filled + count)
    }

    func last(_ wanted: Double) -> (samples: [Float], rate: Double) {
        lock.lock(); defer { lock.unlock() }
        let capacity = samples.count
        guard capacity > 0, rate > 0 else { return ([], 0) }
        let n = min(filled, Int(wanted * rate))
        var out = [Float](repeating: 0, count: n)
        var index = (write - n + capacity) % capacity
        for i in 0..<n {
            out[i] = samples[index]
            index += 1
            if index == capacity { index = 0 }
        }
        return (out, rate)
    }

    func clear() {
        lock.lock(); filled = 0; lock.unlock()
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "Nessuno schermo da cui catturare l'audio." }
}

/// Captures the sound of the whole Mac (Teams, Meet, WhatsApp, FaceTime, a film…).
///
/// From macOS 14.2 with a Core Audio process tap: sound only, permission "System Audio Recording
/// Only". Nothing on screen is recorded, so Netflix and other protected video stay visible (with a
/// screen capture running they turn white: seen by the owner, 02/10). Older macOS: ScreenCaptureKit,
/// which needs a screen to capture even when only the sound is wanted.
final class SystemAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    /// 16 kHz, for the recognisers and the AI: what is said.
    let ring = SampleRing(seconds: LiveTranscriber.memorySeconds)
    /// Full quality (48 kHz), only to hear the real voice again (docs/BRAIN.md § 19.4).
    let hiRing = SampleRing(seconds: SystemAudio.hiSeconds)
    static let hiSeconds: Double = LiveTranscriber.memorySeconds + 5
    static let speechRate: Double = 16_000
    var onStop: ((Error) -> Void)?
    /// Every chunk of mono sound, on the audio queue (for live transcription).
    var onSamples: ((UnsafePointer<Float>, Int, Double) -> Void)?
    private var stream: SCStream?
    private var tap: AnyObject?
    private let queue = DispatchQueue(label: "app.afterhear.audio")

    var isRunning: Bool { stream != nil || tap != nil }

    func start() async throws {
        if #available(macOS 14.2, *) {
            do {
                let tap = try ProcessTap(queue: queue) { [weak self] samples, frames, channels, rate in
                    self?.consume(samples, frames: frames, channels: channels, rate: rate)
                }
                self.tap = tap
                return
            } catch {
                // A Mac that can't make a tap (rare): the screen-capture way below still works.
            }
        }
        try await startScreenCapture()
    }

    private func startScreenCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // We only want sound: keep the video part as small and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        let current = stream
        stream = nil
        try? await current?.stopCapture()
        if #available(macOS 14.2, *) { (tap as? ProcessTap)?.stop() }
        tap = nil
        ring.clear()
        hiRing.clear()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let first = list.first, let data = first.mData else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            consume(data.assumingMemoryBound(to: Float.self), frames: count / channels, channels: channels, rate: format.mSampleRate)
        }
    }

    /// One chunk of sound, from either source: mono, full quality kept, 16 kHz for the recognisers.
    private func consume(_ pointer: UnsafePointer<Float>, frames: Int, channels: Int, rate: Double) {
        guard frames > 0, rate > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames { mono[i] = pointer[i * channels] }
        mono.withUnsafeBufferPointer { hiRing.append($0.baseAddress!, count: frames, rate: rate) }
        // The recognisers want 16 kHz: average every few samples (a gentle low-pass, then keep one).
        let step = max(1, Int((rate / Self.speechRate).rounded()))
        var speech = mono
        var speechRate = rate
        if step > 1 {
            speech = stride(from: 0, to: frames - step + 1, by: step).map { start in
                var sum: Float = 0
                for k in 0..<step { sum += mono[start + k] }
                return sum / Float(step)
            }
            speechRate = rate / Double(step)
        }
        guard !speech.isEmpty else { return }
        speech.withUnsafeBufferPointer {
            ring.append($0.baseAddress!, count: speech.count, rate: speechRate)
            onSamples?($0.baseAddress!, speech.count, speechRate)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        ring.clear()
        hiRing.clear()
        onStop?(error)
    }
}

/// The Core Audio process tap (macOS 14.2): every app's sound but ours, mixed to mono, read
/// through a private aggregate device clocked by the speakers or headphones in use. When those
/// change (AirPods connect), it rebuilds itself on the new ones.
@available(macOS 14.2, *)
final class ProcessTap {
    enum Failure: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self { case .coreAudio(let step, let status): "System audio: \(step) failed (\(status))." }
        }
    }

    typealias Handler = (UnsafePointer<Float>, Int, Int, Double) -> Void
    private let queue: DispatchQueue
    private let handler: Handler
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listener: AudioObjectPropertyListenerBlock?
    private static var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init(queue: DispatchQueue, handler: @escaping Handler) throws {
        self.queue = queue
        self.handler = handler
        try buildAny()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.teardown()
            try? self.buildAny()
        }
        self.listener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, queue, listener)
    }

    func stop() {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, queue, listener)
        }
        listener = nil
        teardown()
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw Failure.coreAudio(step, status) }
    }

    /// The tap alone first: nothing else in the device, so no microphone is ever opened (with
    /// AirPods in, the speakers-and-tap device read the AirPods' microphone, the room around you,
    /// instead of the film: owner, 02/10). If macOS refuses a device without speakers, add them
    /// as its clock, and still read only the tap's own stream.
    private func buildAny() throws {
        do { try build(withOutput: false) } catch { try build(withOutput: true) }
    }

    private func build(withOutput: Bool) throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ourProcess().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Afterhear"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "tap")
        tapID = tap

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &format), "format")
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            teardown()
            throw Failure.coreAudio("float format", -1)
        }
        let rate = format.mSampleRate

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Afterhear listening",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        if withOutput {
            let output: String
            do { output = try Self.outputUID() } catch { teardown(); throw error }
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "aggregate device")
        } catch {
            teardown()
            throw error
        }
        deviceID = device

        let handler = self.handler
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
            // The tap's stream comes after any device's own inputs (a headset microphone): read the last.
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = list.last, let data = buffer.mData else { return }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            handler(data.assumingMemoryBound(to: Float.self), frames, channels, rate)
        }
        do {
            try check(status, "reader")
            procID = proc
            try check(AudioDeviceStart(device, proc), "start")
        } catch {
            teardown()
            throw error
        }
    }

    private func teardown() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Our own audio object, to leave our sounds (the voice reading a sentence back) out.
    private static func ourProcess() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// The speakers or headphones in use, which give the aggregate device its clock.
    private static func outputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = outputAddress
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw Failure.coreAudio("output device", status) }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else { throw Failure.coreAudio("output device id", status) }
        return value as String
    }
}

enum Clip {
    /// Root mean square: tells silence apart from speech.
    static func loudness(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// A clip too quiet or too distorted to understand: not your ears, the line (docs/BRAIN.md § 2.5).
    static func isBadAudio(_ samples: [Float]) -> Bool {
        guard samples.count > 1000 else { return false }
        let rms = loudness(samples)
        let clipped = samples.reduce(0) { $0 + (abs($1) > 0.98 ? 1 : 0) }
        return rms < 0.006 || Double(clipped) / Double(samples.count) > 0.01
    }

    /// A kept clip back as mono samples, for the recogniser on this Mac.
    static func read(_ url: URL) -> (samples: [Float], rate: Double)? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }

    /// The real voice, as heard: full quality, compressed (AAC), small enough to keep for days.
    static func writeVoice(_ samples: [Float], rate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0], !samples.isEmpty else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.initialize(from: $0.baseAddress!, count: samples.count) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func write(_ samples: [Float], rate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.initialize(from: source.baseAddress!, count: samples.count)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
