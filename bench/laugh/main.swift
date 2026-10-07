// The laughter bench (bench/laugh.py): the app's own ToneMeter.laughter on every 10 seconds of a
// meeting, as CallCoach checks a call. Prints one JSON line per window: {"file", "start", "laugh"}.
import AVFoundation
import Foundation

func read(_ url: URL) throws -> ([Float], Double) {
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return ([], 0) }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { return ([], 0) }
    return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".wav") }.sorted()
for name in files {
    let (samples, rate) = try read(folder.appendingPathComponent(name))
    let step = Int(rate * 10)
    var start = 0
    while start + step <= samples.count {
        let laugh = ToneMeter.laughter(in: Array(samples[start..<(start + step)]), rate: rate)
        let out: [String: Any] = ["file": name, "start": Double(start) / rate, "laugh": laugh]
        print(String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
        start += step
    }
}
