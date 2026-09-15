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
        // Dev case: walk up from the executable looking for Package.swift
        // to identify the repo root, rather than assuming a fixed depth --
        // SwiftPM's `.build/<config>` is a symlink to a toolchain-triple-
        // specific directory (e.g. `.build/arm64-apple-macosx/debug/`) on
        // newer toolchains, and resolving that symlink adds an extra path
        // component that a fixed "go up 3" silently landed one level too
        // high with (producing `.build/runtime` instead of `<repo>/runtime`).
        if let exePath = Bundle.main.executablePath {
            var dir = URL(fileURLWithPath: exePath).deletingLastPathComponent()
            while dir.pathComponents.count > 1 {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                    return dir.appendingPathComponent("runtime").path
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        return FileManager.default.currentDirectoryPath + "/runtime"
    }
}
