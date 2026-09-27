// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LLMTray",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Pure, UI-free logic (settings model, profile resolution, server
        // launch arguments) -- its own target so it can be unit-tested
        // without launching the app.
        .target(
            name: "LLMTrayCore",
            path: "Sources/LLMTrayCore"
        ),
        .executableTarget(
            name: "LLMTray",
            dependencies: [
                "LLMTrayCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/LLMTray"
        ),
        .testTarget(
            name: "LLMTrayCoreTests",
            dependencies: ["LLMTrayCore"],
            path: "Tests/LLMTrayCoreTests",
            // Only what can't be generated at test time: the RTF that loops
            // Apple's importer (ExtractorIntegrationTests).
            resources: [.copy("Fixtures")]
        )
    ]
)
