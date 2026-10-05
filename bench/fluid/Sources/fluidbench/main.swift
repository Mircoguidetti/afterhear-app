import AVFoundation
import FluidAudio
import Foundation

// fluidbench <v2|ultra> <clips folder>: one JSON line with the texts, memory and times.

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

func peak() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_maxrss) // bytes on macOS
}

func read(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

func folderSize(_ url: URL) -> UInt64 {
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total: UInt64 = 0
    for case let file as URL in walker {
        total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
}

let args = CommandLine.arguments
let version: AsrModelVersion = args[1] == "v2" ? .v2 : .ultra
let clips = URL(fileURLWithPath: args[2])

_ = try await AsrModels.download(version: version, progressHandler: { _ in })
let before = footprint()
let start = Date()
let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: version), version: version)
let manager = AsrManager(config: .default)
try await manager.loadModels(models)
let load = Date().timeIntervalSince(start)
let loaded = footprint() - min(before, footprint())

func transcribe(_ samples: [Float]) async throws -> String {
    guard samples.count >= 8_000 else { return "" }
    var state = TdtDecoderState.make()
    return try await manager.transcribe(samples, decoderState: &state, language: nil).text
}

var tapTexts: [String: String] = [:], liveTexts: [String: String] = [:]
var tapTimes: [Double] = [], liveTimes: [Double] = []
var maxFootprint = footprint()
let files = try FileManager.default.contentsOfDirectory(atPath: clips.path).filter { $0.hasSuffix(".wav") }.sorted()
for name in files {
    let samples = try read(clips.appendingPathComponent(name))
    var t0 = Date()
    tapTexts[name] = try await transcribe(samples)
    tapTimes.append(Date().timeIntervalSince(t0))
    maxFootprint = max(maxFootprint, footprint())
    t0 = Date()
    var pieces: [String] = []
    var i = 0
    while i < samples.count {
        pieces.append(try await transcribe(Array(samples[i..<min(samples.count, i + 16_000 * 15)])))
        i += 16_000 * 15
    }
    liveTexts[name] = pieces.joined(separator: " ")
    liveTimes.append(Date().timeIntervalSince(t0))
    maxFootprint = max(maxFootprint, footprint())
    FileHandle.standardError.write("\(name) done\n".data(using: .utf8)!)
}

func median(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }
func mb(_ bytes: UInt64) -> Int { Int(bytes / 1_000_000) }
func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

let out: [String: Any] = [
    "model": "fluidaudio-\(args[1])",
    "disk_mb": mb(folderSize(AsrModels.defaultCacheDirectory(for: version))),
    "load_s": round1(load), "loaded_mb": mb(loaded),
    "peak_mb": mb(max(peak(), maxFootprint)), "footprint_mb": mb(maxFootprint),
    "tap_s": round1(median(tapTimes)), "live_s": round1(median(liveTimes)),
    "tap_texts": tapTexts, "live_texts": liveTexts,
]
print(String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
