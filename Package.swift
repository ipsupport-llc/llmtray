// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LLMTray",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LLMTray",
            path: "Sources/LLMTray"
        )
    ]
)
