import Foundation

/// Installs and upgrades the mlx-lm runtime (a Python venv with LLMTray's
/// pinned mlx-lm fork) that mlx_lm.server runs from. Split out of
/// ServerManager, which only runs the server.
@MainActor
final class MLXRuntimeInstaller {
    /// Setup progress goes into the same log as the server's own output.
    private let log: @MainActor @Sendable (String) -> Void

    init(log: @escaping @MainActor @Sendable (String) -> Void) {
        self.log = log
    }

    /// Lives outside the app bundle (see RuntimePaths.externalRuntimeDir) so
    /// it survives Sparkle replacing Contents/ wholesale on every
    /// auto-update. Talking to the binary directly (instead of shelling out
    /// through run_server.sh every launch) skips a `pip install mlx-lm`
    /// network round-trip and a re-check of both idempotent patch scripts on
    /// every single "Start Server" click -- work that only ever needs doing
    /// once, not once per app launch (or, prior to this, once per update).
    static var venvDir: String { RuntimePaths.externalRuntimeDir + "/mlx_server_venv" }
    static var venvPython: String { venvDir + "/bin/python3" }
    // Only ever used as an existence check (pip creates it as its last
    // install step, so its presence is a reliable "setup finished" signal)
    // -- never executed directly, see ServerManager.launchServerProcess.
    private static var venvServerBinary: String { venvDir + "/bin/mlx_lm.server" }
    static var versionMarkerPath: String { venvDir + "/.llmtray_pinned_version" }

    /// Only present in the "Full" build variant (scripts/build_full_app.sh),
    /// which vendors a working venv straight into the bundle so first launch
    /// never needs the network. Reused as the *source* for the one-time
    /// external copy above rather than a copy this app ever runs from
    /// directly -- Contents/ is exactly what the next Sparkle update wipes.
    private static var bundledVenvDir: String { RuntimePaths.runtimeDir + "/.mlx_server_venv" }
    private static var bundledVenvServerBinary: String { bundledVenvDir + "/bin/mlx_lm.server" }

    /// Also Full-build-only: the self-contained Python.framework
    /// build_full_app.sh vendored to create that venv in the first place.
    /// Copied out alongside the venv so that if the external venv is ever
    /// deleted (e.g. via the "Uninstall Runtime Data" menu item) and needs
    /// recreating on a machine with no system Python 3.10+, there's still a
    /// working interpreter to recreate it with -- without that, a Full
    /// install would silently degrade into needing a system Python anyway,
    /// defeating the point of "Full" in the first place.
    private static var bundledFrameworkDir: String? {
        guard let frameworksPath = Bundle.main.privateFrameworksPath else { return nil }
        let path = frameworksPath + "/Python.framework"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
    private static var externalFrameworkDir: String { RuntimePaths.externalRuntimeDir + "/Python.framework" }

    /// Whether the installed mlx-lm has the given model architecture
    /// (models/<type>.py) -- e.g. the Gemma 4 MTP drafter's.
    static func supportsModelType(_ modelType: String) -> Bool {
        let lib = venvDir + "/lib"
        guard let pythons = try? FileManager.default.contentsOfDirectory(atPath: lib) else { return false }
        return pythons.contains { py in
            FileManager.default.fileExists(atPath: "\(lib)/\(py)/site-packages/mlx_lm/models/\(modelType).py")
        }
    }

    /// Version directory name (e.g. "3.14") isn't known ahead of time, so
    /// this just looks at whatever's actually there instead of hardcoding it.
    private static func externalFrameworkPython() -> String? {
        let versionsDir = externalFrameworkDir + "/Versions"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) else { return nil }
        for version in versions where version != "Current" {
            let candidate = "\(versionsDir)/\(version)/bin/python\(version)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Makes the venv match the pinned mlx-lm commit: first run (from the
    /// Full build's vendored copy, or a fresh venv + pip install), or an
    /// upgrade after a new pin. Always our fork, never PyPI -- see
    /// adr/0001-mlx-runtime.md.
    func ensureReady() async throws {
        let runtimeDir = RuntimePaths.runtimeDir
        guard let pinData = FileManager.default.contents(atPath: runtimeDir + "/mlx_lm_runtime.json"),
              let pinObj = try? JSONSerialization.jsonObject(with: pinData) as? [String: Any],
              let pinnedRepo = pinObj["repo"] as? String,
              let pinnedRef = pinObj["pinned_ref"] as? String else {
            throw NSError(
                domain: "MLXRuntimeInstaller", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not read mlx_lm_runtime.json"]
            )
        }
        let pinnedRuntimeGitURL = "git+https://github.com/\(pinnedRepo).git@\(pinnedRef)"
        let targetVersion = pinnedRef

        // The marker is only ever written after a fully successful install
        // (see the two write sites below), so its presence -- not just the
        // venv directory's -- is what distinguishes "ready" or "just needs
        // a version bump" from "leftover half-built venv from a prior
        // crashed attempt."
        let installedVersion = try? String(contentsOfFile: Self.versionMarkerPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if FileManager.default.fileExists(atPath: Self.venvServerBinary), installedVersion == targetVersion {
            return
        }

        try FileManager.default.createDirectory(
            atPath: RuntimePaths.externalRuntimeDir, withIntermediateDirectories: true
        )

        // Full build, first launch: a working venv (for this exact pinned
        // commit, since both were produced by the same build_full_app.sh
        // run) is already sitting in the bundle -- copying it out is a fast
        // local operation with no network, unlike everything below.
        if !FileManager.default.fileExists(atPath: Self.venvDir),
           FileManager.default.fileExists(atPath: Self.bundledVenvServerBinary) {
            log("--- first run: copying vendored runtime out of the app bundle ---\n")
            // Hundreds of MB: copied off the main actor, the UI stays live.
            let (venvSource, venvTarget) = (Self.bundledVenvDir, Self.venvDir)
            try await ProcessRunner.offMain { try FileManager.default.copyItem(atPath: venvSource, toPath: venvTarget) }
            if let bundledFramework = Self.bundledFrameworkDir {
                let frameworkTarget = Self.externalFrameworkDir
                if !FileManager.default.fileExists(atPath: frameworkTarget) {
                    try? await ProcessRunner.offMain { try FileManager.default.copyItem(atPath: bundledFramework, toPath: frameworkTarget) }
                }
                // The copied venv's own bin/python3.X is a symlink pointing
                // at the *bundled* framework by absolute path (that's how
                // `python -m venv` created it in build_full_app.sh) -- valid
                // only as long as that original .app sticks around. Left
                // alone, it dangles the instant the next Sparkle update
                // replaces Contents/, which is exactly the update this
                // whole external-copy was supposed to survive. Repoint it at
                // the framework copy that now lives right alongside it.
                Self.relinkVendoredInterpreter(newFrameworkDir: Self.externalFrameworkDir)
            }
            try pinnedRef.write(toFile: Self.versionMarkerPath, atomically: true, encoding: .utf8)
            log("--- runtime ready ---\n")
            return
        }

        log("--- first run: setting up mlx-lm runtime (this can take a minute) ---\n")

        if FileManager.default.fileExists(atPath: Self.venvDir), installedVersion == nil {
            // No marker means the previous attempt at this exact venv never
            // finished (e.g. it was created with an incompatible Python and
            // the mlx-lm install inside it failed) -- venv creation is
            // cheap, so start clean rather than trying to patch up a
            // half-working one. A venv WITH a marker just needs the pip
            // install/patch steps below re-run against the new version, not
            // a full recreation.
            try? FileManager.default.removeItem(atPath: Self.venvDir)
        }

        if !FileManager.default.fileExists(atPath: Self.venvDir) {
            let vendored = Self.externalFrameworkPython().map { [$0] } ?? []
            guard let python = await PythonLocator.findModern(preferring: vendored) else {
                throw NSError(
                    domain: "MLXRuntimeInstaller", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "No Python 3.10+ found. Install one from python.org or via Homebrew (https://brew.sh), then try Start Server again."]
                )
            }
            try await ProcessRunner.run(python, ["-m", "venv", Self.venvDir], log: log)
            // -m pip, not the pip console-script directly -- same
            // shebang-can't-survive-relocation-or-spaces reasoning as
            // ServerManager.launchServerProcess.
            try await ProcessRunner.run(Self.venvPython, ["-m", "pip", "install", "--quiet", "--upgrade", "pip"], log: log)
        }
        // --force-reinstall: pip won't otherwise treat a git URL as newer
        // than an already-satisfied "mlx-lm" (e.g. picking up a bumped pin).
        try await ProcessRunner.run(Self.venvPython, ["-m", "pip", "install", "--quiet", "--force-reinstall", pinnedRuntimeGitURL], log: log)
        try targetVersion.write(toFile: Self.versionMarkerPath, atomically: true, encoding: .utf8)
        log("--- runtime ready ---\n")
    }

    /// Re-points the copied venv's interpreter symlinks (and pyvenv.cfg) at
    /// the copied framework, matched by the "Python.framework/" suffix of
    /// the old target -- it was created on the build machine. Without it the
    /// venv breaks once the next update removes the original app.
    /// adr/0001-mlx-runtime.md.
    private static func relinkVendoredInterpreter(newFrameworkDir: String) {
        if let binEntries = try? FileManager.default.contentsOfDirectory(atPath: Self.venvDir + "/bin") {
            for entry in binEntries {
                let path = Self.venvDir + "/bin/" + entry
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                      !FileManager.default.fileExists(atPath: target),
                      let range = target.range(of: "Python.framework/") else { continue }
                let newTarget = newFrameworkDir + "/" + target[range.upperBound...]
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: newTarget)
            }
        }
        // pyvenv.cfg's home/executable/command fields aren't what actually
        // gets executed (bin/python3.X above is), but leaving them pointing
        // at a now-deleted path would confuse any tooling that does read it.
        // Same suffix-based approach: a regex matching "<anything non-space>
        // ending in Python.framework/" rather than a known literal prefix.
        let cfgPath = Self.venvDir + "/pyvenv.cfg"
        if let cfg = try? String(contentsOfFile: cfgPath, encoding: .utf8),
           let regex = try? NSRegularExpression(pattern: #"\S*Python\.framework/"#) {
            let fullRange = NSRange(cfg.startIndex..., in: cfg)
            let replacement = NSRegularExpression.escapedTemplate(for: newFrameworkDir + "/")
            let fixed = regex.stringByReplacingMatches(in: cfg, range: fullRange, withTemplate: replacement)
            try? fixed.write(toFile: cfgPath, atomically: true, encoding: .utf8)
        }
    }
}
