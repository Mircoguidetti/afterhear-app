import AVFoundation
import Foundation
import Speech

// Apple's recognisers on the bench's clips, on a Mac (docs/BRAIN.md § 19.21): the new one
// (SpeechAnalyzer, macOS 26) and the old one (SFSpeechRecognizer, on-device), the same two the
// app uses. One JSON line per clip and engine; bench/run.py apple turns them into the table.
//
// macOS kills a program that asks for speech recognition from Terminal (zsh: abort), so
// bench/apple.sh wraps it in a small app with bench/Info.plist and opens that:  sh apple.sh

struct Clip: Decodable { let name: String; let file: String }

struct Line: Encodable {
    let name: String
    let engine: String
    var text = ""
    var seconds = 0.0
    var error: String?
}

enum Failure: Error, CustomStringConvertible {
    case unsupported(String), timeout
    var description: String {
        switch self {
        case .unsupported(let why): return why
        case .timeout: return "timed out"
        }
    }
}

final class Once: @unchecked Sendable {
    let lock = NSLock()
    var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// The first of `work` or the clock. A work that never finishes (a permission nobody answers)
/// is left behind instead of waited for: a task group would wait for it forever.
func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        Task {
            do { let v = try await work(); if once.claim() { c.resume(returning: v) } }
            catch { if once.claim() { c.resume(throwing: error) } }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if once.claim() { c.resume(throwing: Failure.timeout) }
        }
    }
}

let locale = Locale(identifier: "en-GB")

/// Progress on stderr, so the job log shows where it is; stdout stays clean JSON.
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

@available(macOS 26.0, *)
func newEngine(_ url: URL) async throws -> String {
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
        throw Failure.unsupported("en-GB not supported by SpeechTranscriber")
    }
    let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    // Reserve the language and fetch its model if needed. On an ad-hoc signed app macOS can refuse
    // both ("not subscribed to transcription.en", 02/10) while the model is already on the Mac:
    // then go on, and the analyzer says whether it can listen.
    _ = try? await AssetInventory.reserve(locale: supported)
    if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try? await request.downloadAndInstall()
    }
    // It takes sound only in its own format ("Audio format is not supported" for the clips as
    // they are, 02/10): read the whole clip, convert it, hand it over in one piece.
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        throw Failure.unsupported("no audio format for SpeechAnalyzer")
    }
    let file = try AVAudioFile(forReading: url)
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw Failure.unsupported("can't read \(url.lastPathComponent)")
    }
    try file.read(into: input)
    guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
          let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 1024) else {
        throw Failure.unsupported("can't convert to \(format)")
    }
    var given = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if given { status.pointee = .endOfStream; return nil }
        given = true
        status.pointee = .haveData
        return input
    }
    if let error { throw error }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let collect = Task { () -> String in
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters) + " "
        }
        return text
    }
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    continuation.yield(AnalyzerInput(buffer: output))
    continuation.finish()
    if let last = try await analyzer.analyzeSequence(stream) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collect.value
}

/// On long audio the on-device recogniser starts over after a pause, and its final result can
/// hold only the last stretch (or nothing, if the clip ends in silence: "0 words in 116 s" on a
/// real Mac, 02/10). So every result is kept, word by word at its time, and put back together.
func oldEngine(_ url: URL) async throws -> String {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition else {
        throw Failure.unsupported("no on-device SFSpeechRecognizer for en-US")
    }
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    request.addsPunctuation = true
    request.shouldReportPartialResults = true
    return try await withCheckedThrowingContinuation { continuation in
        var done = false
        var words: [Int: String] = [:]   // tenths of a second → word
        var finalCount = 0
        func text() -> String { words.keys.sorted().map { words[$0]! }.joined(separator: " ") }
        recognizer.recognitionTask(with: request) { result, error in
            guard !done else { return }
            if let result {
                for seg in result.bestTranscription.segments { words[Int(seg.timestamp * 10)] = seg.substring }
                if result.isFinal {
                    done = true
                    finalCount = result.bestTranscription.segments.count
                    log("  final result alone: \(finalCount) words, all results: \(words.count)")
                    continuation.resume(returning: text())
                    return
                }
            }
            if let error, !done {
                done = true
                // "No speech detected" at the end isn't a failure when words came before it.
                if words.isEmpty { continuation.resume(throwing: error) } else { continuation.resume(returning: text()) }
            }
        }
    }
}

@main
struct Bench {
    static func main() async {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "bench/out/clips")
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("clips.json")),
              let clips = try? JSONDecoder().decode([Clip].self, from: data) else {
            print("no clips.json in \(folder.path)")
            exit(1)
        }
        // The old recogniser asks for permission; on a build machine nobody can answer: at most 15 s, then it's reported, not hidden.
        let status = (try? await withTimeout(15) {
            await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }) ?? .notDetermined
        log("speech permission: \(status.rawValue), clips: \(clips.count)")
        let encoder = JSONEncoder()
        for clip in clips {
            let url = folder.appendingPathComponent(clip.file)
            var engines: [(String, @Sendable () async throws -> String)] = []
            if #available(macOS 26.0, *) {
                engines.append(("apple new (SpeechAnalyzer)", { try await newEngine(url) }))
            } else {
                print(String(data: try! encoder.encode(Line(name: clip.name, engine: "apple new (SpeechAnalyzer)", error: "needs macOS 26")), encoding: .utf8)!)
            }
            // A file named skip-old in the folder: only the new recogniser (the old one already measured).
            let skipOld = FileManager.default.fileExists(atPath: folder.appendingPathComponent("skip-old").path)
            if skipOld {
            } else if status == .authorized {
                engines.append(("apple old (SFSpeechRecognizer)", { try await oldEngine(url) }))
            } else {
                print(String(data: try! encoder.encode(Line(name: clip.name, engine: "apple old (SFSpeechRecognizer)", error: "speech permission \(status.rawValue) on this machine")), encoding: .utf8)!)
            }
            for (name, run) in engines {
                log("\(clip.name) · \(name)…")
                var line = Line(name: clip.name, engine: name)
                let start = Date()
                do {
                    line.text = try await withTimeout(240, run)
                } catch {
                    line.error = String(describing: error).prefix(200).description
                }
                line.seconds = Date().timeIntervalSince(start)
                log("  \(line.error ?? "\(line.text.split(separator: " ").count) words") in \(Int(line.seconds)) s")
                print(String(data: try! encoder.encode(line), encoding: .utf8)!)
                fflush(stdout)
            }
        }
    }
}
