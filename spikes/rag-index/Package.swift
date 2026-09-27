// swift-tools-version: 5.9
// Throwaway spike for ADR 0012 (project files RAG): the SQLite index layer.
// Standalone package; not part of the app build.
import PackageDescription

let package = Package(
    name: "RAGIndexSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "RAGIndex",
            path: "Sources/RAGIndex",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "ragbench",
            dependencies: ["RAGIndex"],
            path: "Sources/ragbench"
        ),
        .testTarget(
            name: "RAGIndexTests",
            dependencies: ["RAGIndex", "ragbench"],
            path: "Tests/RAGIndexTests"
        ),
    ]
)
