import Foundation

/// Locates the `runtime/` directory (run_server.sh, the mlx-lm patch
/// scripts, and the version pin) that ships alongside this repo.
enum RuntimePaths {
    static var runtimeDir: String {
        if let override = ProcessInfo.processInfo.environment["LLMTRAY_RUNTIME_DIR"] {
            return override
        }
        // Packaged .app case: a CI-built bundle would ship the runtime
        // scripts under Contents/Resources/runtime.
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("runtime")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled.path
            }
        }
        // Dev case: `swift build` puts the executable at
        // <repo>/.build/<config>/LLMTray -- three path components below
        // repo root (the binary itself, <config>, and .build).
        if let exePath = Bundle.main.executablePath {
            let repoRoot = URL(fileURLWithPath: exePath).resolvingSymlinksInPath()
                .deletingLastPathComponent() // LLMTray (binary)
                .deletingLastPathComponent() // <config>
                .deletingLastPathComponent() // .build
            return repoRoot.appendingPathComponent("runtime").path
        }
        return FileManager.default.currentDirectoryPath + "/runtime"
    }
}
