// swift-tools-version: 5.9
import PackageDescription

// The Mac App Store build (adr/0018): LLMTRAY_APP_STORE=1 compiles with
// APP_STORE and without Sparkle -- the App Store updates it, and an unused
// updater framework is itself a review risk. Without it: the standalone
// (Developer ID) build, unchanged.
let appStore = Context.environment["LLMTRAY_APP_STORE"] == "1"
let flavor: [SwiftSetting] = appStore ? [.define("APP_STORE")] : []

let package = Package(
    name: "LLMTray",
    platforms: [.macOS(.v14)],
    dependencies: appStore ? [] : [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Pure, UI-free logic (settings model, profile resolution, server
        // launch arguments) -- its own target so it can be unit-tested
        // without launching the app.
        .target(
            name: "LLMTrayCore",
            path: "Sources/LLMTrayCore",
            // The CBLAS interface without the macOS 13.3 deprecation
            // (DenseVectors' cblas_sgemv): same symbols, current headers.
            swiftSettings: [.unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])] + flavor,
            // The system SQLite (ProjectIndex, adr/0012): FTS5 built in, no
            // extensions to load.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "LLMTray",
            dependencies: ["LLMTrayCore"] + (appStore ? [] : [.product(name: "Sparkle", package: "Sparkle")]),
            path: "Sources/LLMTray",
            swiftSettings: flavor
        ),
    ] + (appStore ? [] : [
        // `llmtray`, the command-line tool (adr/0019): the standalone build
        // only -- the App Store build neither bundles it nor serves its
        // socket. LLMTrayCore only: no AppKit, no UI; it talks to the running
        // app over the control socket and to the OpenAI endpoint. Built as
        // `LLMTrayCLI` and renamed in the bundle (build_app.sh): an
        // `llmtray` binary would overwrite `LLMTray` in .build/release on a
        // case-insensitive volume.
        .executableTarget(
            name: "LLMTrayCLI",
            dependencies: ["LLMTrayCore"],
            path: "Sources/LLMTrayCLI"
        ),
    ]) + [
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
