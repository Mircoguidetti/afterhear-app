// swift-tools-version:5.10
// The compressed model test (bench/compressed.py): Parakeet through FluidAudio on the Neural
// Engine, the same version and the same calls as the Mac app (macapp/LEXALIE/Parakeet.swift).
import PackageDescription

let package = Package(
    name: "fluidbench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.5")],
    targets: [
        .executableTarget(name: "fluidbench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        // The tap bench (bench/tap.py): timed words of each clip, as Parakeet.swift gets them.
        .executableTarget(name: "fluidwords", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
