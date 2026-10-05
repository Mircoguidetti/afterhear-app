import AVFoundation
import Foundation
import Speech

// applewords <clips folder>: one JSON line per clip with its timed words and the seconds it took.
// Errors go to stderr, so the bench can say why Apple's recogniser didn't run on this Mac.

func log(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }

let clips = URL(fileURLWithPath: CommandLine.arguments[1])
guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-GB")) else {
    log("no supported English locale")
    exit(2)
}
log("locale \(locale.identifier)")
let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
do {
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
        log("downloading the English model")
        try await request.downloadAndInstall()
    }
} catch {
    log("model install failed: \(error)")
    exit(3)
}

let files = try FileManager.default.contentsOfDirectory(atPath: clips.path).filter { $0.hasSuffix(".wav") }.sorted()
for name in files {
    let t0 = Date()
    var words: [[String]] = []
    do {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () -> [[String]] in
            var out: [[String]] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    out.append([String(range.start.seconds), String(range.end.seconds), text])
                }
            }
            return out
        }
        let file = try AVAudioFile(forReading: clips.appendingPathComponent(name))
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        words = try await collect.value
    } catch {
        log("\(name): \(error)")
    }
    let out: [String: Any] = ["file": name, "seconds": Date().timeIntervalSince(t0), "words": words]
    print(String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
}
