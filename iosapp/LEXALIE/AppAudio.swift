import AVFoundation
import Foundation

/// The other apps' sound on the iPhone (docs/BRAIN.md § 19.18): from iOS 27 an app can capture
/// what other apps play (ScreenCaptureKit, with your consent each time). YouTube, a podcast,
/// WhatsApp or FaceTime on speaker: LEXALIE hears them as clearly as on the Mac, without the room.
/// Phone calls stay out: Apple gives their audio to no app (§ 11.15).
///
/// Built only with the iOS 27 SDK: add IOS27_CAPTURE to "Active Compilation Conditions".
/// Still to try on a device: capture with the screen locked, and apps that protect their sound (DRM).
enum AppAudio {
    #if IOS27_CAPTURE
    static var isAvailable: Bool { if #available(iOS 27.0, *) { return true } else { return false } }
    #else
    static let isAvailable = false
    #endif
}

#if IOS27_CAPTURE
import ScreenCaptureKit

@available(iOS 27.0, *)
final class AppAudioCapture: NSObject, SCStreamOutput, SCContentSharingPickerObserver {
    static let shared = AppAudioCapture()

    private var stream: SCStream?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onEnd: (() -> Void)?

    /// Asks which app to listen to (the system picker), then sends its sound to `onBuffer`.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onEnd: @escaping () -> Void) {
        self.onBuffer = onBuffer
        self.onEnd = onEnd
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        SCContentSharingPicker.shared.isActive = false
        SCContentSharingPicker.shared.remove(self)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        // Video is required by the API: the smallest frame, as rarely as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        try? s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "app.lexalie.appaudio"))
        s.startCapture { _ in }
        self.stream = s
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        onEnd?()
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        onEnd?()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = Self.pcm(sampleBuffer) else { return }
        onBuffer?(buffer)
    }

    private static func pcm(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
#endif
