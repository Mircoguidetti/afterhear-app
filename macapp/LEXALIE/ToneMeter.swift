import AVFoundation
import Foundation
import SoundAnalysis

/// How a sentence was said, measured on the device (docs/BRAIN.md § 19.28). It measures, it doesn't
/// judge: every tag is a fact about the sound ("rises at the end", "'capito' 2.6× longer than this
/// speaker's usual", "laughter right after"), compared with how the same clip sounds elsewhere.
/// Only these words go to the model, never the audio: voices stay on the device.
enum ToneMeter {
    struct Span { let start: Double; let end: Double; let words: [(text: String, start: Double, end: Double)] }

    /// `samples` is the 16 kHz clip, `turn` the sentence on the clip's clock, `next` when the next
    /// line starts (for the pause after), `voice` the full-quality sound for laughter.
    static func tags(samples: [Float], rate: Double, turn: Span, clipWords: [(text: String, start: Double, end: Double)],
                     next: Double?, voice: [Float], voiceRate: Double, voiceStart: Double) -> String {
        guard rate > 0, turn.end > turn.start, !samples.isEmpty else { return "" }
        var tags: [String] = []
        let pitch = contour(samples, rate: rate, from: turn.start, to: turn.end)
        // The speaker's usual: the half minute around the sentence (cheap, and close in time).
        let baseline = contour(samples, rate: rate, from: max(0, turn.start - 30), to: min(Double(samples.count) / rate, turn.end + 5))
        if pitch.count >= 6, baseline.count >= 12 {
            let third = max(1, pitch.count / 3)
            let first = median(Array(pitch.prefix(third))), last = median(Array(pitch.suffix(third)))
            if last > first * 1.12 { tags.append("rises at the end") }
            if last < first * 0.85 { tags.append("falls at the end") }
            let range = spread(pitch), usual = spread(baseline)
            if usual > 0, range > usual * 1.6 { tags.append("wide, exaggerated pitch") }
            if usual > 0, range < usual * 0.55 { tags.append("flat, level voice") }
            if median(pitch) > median(baseline) * 1.2 { tags.append("higher than this speaker's usual") }
        }
        // Stretched words: seconds per letter against the clip's usual.
        let usualPerLetter = median(clipWords.compactMap { w -> Double? in
            let letters = w.text.filter(\.isLetter).count
            return letters >= 2 ? (w.end - w.start) / Double(letters) : nil
        })
        if usualPerLetter > 0 {
            for w in turn.words {
                let letters = w.text.filter(\.isLetter).count
                guard letters >= 3 else { continue }
                let ratio = (w.end - w.start) / Double(letters) / usualPerLetter
                if ratio >= 2.2 { tags.append("'\(w.text.trimmingCharacters(in: .punctuationCharacters))' stretched (\(String(format: "%.1f", ratio))× its usual length)") }
            }
        }
        // Loudness and pace against the whole clip.
        let loud = rms(samples, rate: rate, from: turn.start, to: turn.end), usualLoud = rms(samples, rate: rate, from: 0, to: Double(samples.count) / rate)
        if usualLoud > 0, loud > usualLoud * 1.6 { tags.append("louder than usual") }
        if usualLoud > 0, loud < usualLoud * 0.55 { tags.append("quieter than usual") }
        let pace = Double(turn.words.count) / (turn.end - turn.start)
        let clipSpan = (clipWords.last?.end ?? 0) - (clipWords.first?.start ?? 0)
        let usualPace = clipSpan > 0 ? Double(clipWords.count) / clipSpan : 0
        if usualPace > 0, turn.words.count >= 3 {
            if pace < usualPace * 0.7 { tags.append("slower than usual") }
            if pace > usualPace * 1.35 { tags.append("faster than usual") }
        }
        if let next, next - turn.end >= 1.2 { tags.append(String(format: "a pause of %.1f s after", next - turn.end)) }
        if laughs(voice, rate: voiceRate, from: turn.end - voiceStart, seconds: 3) { tags.append("laughter right after") }
        return tags.joined(separator: "; ")
    }

    // MARK: - Pitch: autocorrelation on voiced 40 ms frames, 70–400 Hz.

    private static func contour(_ s: [Float], rate: Double, from: Double, to: Double) -> [Double] {
        let frame = Int(rate * 0.04), hop = Int(rate * 0.02)
        let lo = Int(rate / 400), hi = Int(rate / 70)
        var i = max(0, Int(from * rate))
        let end = min(s.count, Int(to * rate))
        var out: [Double] = []
        while i + frame + hi < end {
            var energy: Float = 0
            for k in 0..<frame { energy += s[i + k] * s[i + k] }
            if energy / Float(frame) > 1e-4 {
                var best = 0, bestScore: Float = 0
                var lag = lo
                while lag <= hi {
                    var sum: Float = 0
                    var k = 0
                    while k < frame { sum += s[i + k] * s[i + k + lag]; k += 4 }
                    if sum > bestScore { bestScore = sum; best = lag }
                    lag += 1
                }
                if best > 0, bestScore > energy * 0.3 { out.append(rate / Double(best)) }
            }
            i += hop
        }
        return out
    }

    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }

    /// Between the 10th and 90th percentile, as a share of the median.
    private static func spread(_ v: [Double]) -> Double {
        guard v.count >= 5 else { return 0 }
        let s = v.sorted()
        let m = s[s.count / 2]
        return m > 0 ? (s[s.count * 9 / 10] - s[s.count / 10]) / m : 0
    }

    private static func rms(_ s: [Float], rate: Double, from: Double, to: Double) -> Double {
        let a = max(0, Int(from * rate)), b = min(s.count, Int(to * rate))
        guard b > a else { return 0 }
        var sum: Double = 0
        for k in a..<b { sum += Double(s[k] * s[k]) }
        return (sum / Double(b - a)).squareRoot()
    }

    // MARK: - Laughter: Apple's built-in sound classifier, on the device.

    /// How sure a laugh must be (bench/laugh.py on AMI's hand-marked laughs picks it).
    static var laughThreshold = 0.5

    /// Laughter anywhere in these seconds (the end card's "why they laughed", in calls).
    static func laughter(in voice: [Float], rate: Double) -> Bool {
        laughterConfidence(in: voice, rate: rate) >= laughThreshold
    }

    /// The surest laugh in these seconds, 0 to 1.
    static func laughterConfidence(in voice: [Float], rate: Double) -> Double {
        guard rate > 0 else { return 0 }
        return laughs(voice, rate: rate, from: 0, seconds: Double(voice.count) / rate)
    }

    private static func laughs(_ voice: [Float], rate: Double, from: Double, seconds: Double) -> Double {
        guard rate > 0, from >= 0 else { return 0 }
        let a = Int(from * rate), b = min(voice.count, a + Int(seconds * rate))
        guard b - a > Int(rate * 0.5),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(b - a)),
              let channel = buffer.floatChannelData?[0],
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return 0 }
        buffer.frameLength = AVAudioFrameCount(b - a)
        voice.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + a, count: b - a) }
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = LaughObserver()
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return 0 }
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
        return observer.best
    }
}

private final class LaughObserver: NSObject, SNResultsObserving {
    private(set) var best = 0.0

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        for c in result.classifications {
            let id = c.identifier.lowercased()
            if id.contains("laugh") || id.contains("giggl") || id.contains("chuckl") || id.contains("snicker") { best = max(best, c.confidence) }
        }
    }
}
