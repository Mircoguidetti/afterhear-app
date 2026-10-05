import AVFoundation
import FluidAudio
import Foundation

// fluidwords <v2|ultra> <clips folder>: one JSON line per clip with its timed words and the
// seconds it took, the same calls as Parakeet.swift (transcribe, then buildWordTimings).

func read(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

let args = CommandLine.arguments
let version: AsrModelVersion = args[1] == "v2" ? .v2 : .ultra
let clips = URL(fileURLWithPath: args[2])
_ = try await AsrModels.download(version: version, progressHandler: { _ in })
let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: version), version: version)
let manager = AsrManager(config: .default)
try await manager.loadModels(models)

let files = try FileManager.default.contentsOfDirectory(atPath: clips.path).filter { $0.hasSuffix(".wav") }.sorted()
for name in files {
    let samples = try read(clips.appendingPathComponent(name))
    let t0 = Date()
    var words: [[String]] = []
    if samples.count >= 8_000 {
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        words = buildWordTimings(from: result.tokenTimings ?? []).map { [String($0.startTime), String($0.endTime), $0.word] }
    }
    let out: [String: Any] = ["file": name, "seconds": Date().timeIntervalSince(t0), "words": words]
    print(String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
}
