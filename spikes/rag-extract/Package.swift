// swift-tools-version:5.9
// Throwaway spike for ADR 0012 extraction tier 1 -- not part of the app.
import PackageDescription

let package = Package(
    name: "rag-extract",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ExtractKit"),
        // The stand-in for `LLMTray --extract <path>`: JSON lines on stdout.
        .executableTarget(name: "extract", dependencies: ["ExtractKit"]),
        // The parent: spawns `extract` with time / memory / output limits.
        .executableTarget(name: "supervise"),
        // Builds the sample and hostile files into a directory.
        .executableTarget(name: "makesamples", dependencies: ["ExtractKit"]),
        // Measurement helpers (rlimit behaviour, main-thread checks, sockets).
        .executableTarget(name: "probe", dependencies: ["ExtractKit"]),
    ]
)
