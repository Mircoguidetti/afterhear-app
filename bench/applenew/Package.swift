// swift-tools-version:6.0
// The tap bench (bench/tap.py): Apple's new recogniser (SpeechAnalyzer, macOS 26) on the same
// clips, to see whether it could replace Parakeet. Runs only on macOS 26.
import PackageDescription

let package = Package(
    name: "applewords",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "applewords", swiftSettings: [.swiftLanguageMode(.v5)])]
)
