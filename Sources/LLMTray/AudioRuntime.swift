import Foundation
import LLMTrayCore

/// The one audio runtime (adr/0016): a venv with mlx-audio from our fork,
/// shared by the music generator (ACE-Step, adr/0010) and Voice Lab
/// (VoiceChat). It's still called music_venv on disk: the name predates
/// voice, and renaming it would reinstall every existing setup.
///
/// One install at a time, whoever asks: a second caller waits for the
/// running install and then finds it done (or tries again after a failure).
@MainActor
final class AudioRuntime: ObservableObject {
    static let shared = AudioRuntime()

    enum RuntimeError: LocalizedError {
        case noPython
        case installFailed(String)
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPython:
                return NSLocalizedString("No Python 3.10+ found. Install one from python.org or via Homebrew (https://brew.sh).", comment: "")
            case .installFailed(let detail):
                return String(format: NSLocalizedString("Installing mlx-audio failed: %@", comment: ""), detail)
            case .downloadFailed(let detail):
                return String(format: NSLocalizedString("The download failed: %@", comment: ""), detail)
            }
        }
    }

    /// Pinned: runtime/llmtray_music_runner.py drives mlx-audio's ACE-Step
    /// internals, which upstream only has on its unmerged `pc/add-ace`
    /// branch. Our fork's `llmtray` branch carries them on current upstream
    /// main (where the voice models are), so music and voice share one
    /// runtime; advanced deliberately -- the runner patches internals. A
    /// tarball of the commit needs no git on the Mac. b99f797 (fork PR #2):
    /// VoiceChat loads mlx-community's (mlx-vlm v2) checkpoints offline,
    /// tokenizer from the model folder. 2dce524 (fork PR #3): VoiceChat
    /// speedups -- bf16 perception with a compiled conformer, the TTS
    /// mixture head computing only the sampled mixture, compiled TTS codes
    /// and codec step (185 -> ~88 ms per 80 ms frame on a base M5 with
    /// the GPTQ-3 model). ab0b648 (fork PR #4): optional TTS/codec pause
    /// while the model is quiet (the runner's --tts-idle-frames).
    static let bundledCommit = "ab0b648b2ce6ad261e8bb3203e08b34680eec471"

    /// The commit in use: one picked by hand in Settings > Updates, while
    /// it was picked over this build's own pin (a newer app's pin wins).
    static var mlxAudioCommit: String {
        guard let data = FileManager.default.contents(atPath: overridePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let ref = obj["pinned_ref"], obj["bundled_ref"] == bundledCommit
        else { return bundledCommit }
        return ref
    }

    private static var overridePath: String { RuntimePaths.externalRuntimeDir + "/audio_runtime_pin.json" }

    static func setOverride(_ commit: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["pinned_ref": commit, "bundled_ref": bundledCommit], options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: overridePath), options: .atomic)
    }

    /// mlx-audio with what both runners import. The voice models' part is
    /// mlx-audio's `sts` extras (pyproject.toml), listed here rather than
    /// as `mlx-audio[sts]`: `mlx-lm` is pinned below already, and the
    /// extras' `webrtcvad` (with `setuptools<81` for it) is left out -- it
    /// ships no wheels, so pip would need a C compiler (the Command Line
    /// Tools) on the user's Mac, and only mlx-audio's HTTP server uses it.
    /// Changing this list changes the install stamp: the next use installs.
    static var requirements: [String] {
        [
            "mlx-audio @ https://github.com/ipsupport-llc/mlx-audio/archive/\(mlxAudioCommit).tar.gz",
            "mlx==0.32.2", "mlx-lm==0.31.1", "transformers==5.17.0", "pyyaml", "huggingface_hub",
            // sts extras (VoiceChat's tokenizers)
            "sentencepiece>=0.2.0",
        ]
    }

    static var venvDir: String { RuntimePaths.externalRuntimeDir + "/music_venv" }
    #if APP_STORE
    static var venvPython: String { BundledRuntime.python }
    #else
    static var venvPython: String { venvDir + "/bin/python3" }
    #endif
    /// Written after a complete install: the pins it was made with.
    private static var installStamp: String { venvDir + "/llmtray-requirements.txt" }

    @Published private(set) var isInstalling = false
    @Published private(set) var statusText = ""
    private var install: Task<Void, Error>?

    /// A venv was set up (its requirements may be older: `ensureInstalled`
    /// brings them up to date before a run).
    var hasVenv: Bool { FileManager.default.isExecutableFile(atPath: Self.venvPython) }

    #if APP_STORE
    /// The bundled runtime is installed with the app.
    var isInstalled: Bool { hasVenv }
    #endif

    /// The stamp's first line: the install method. Stamps written before
    /// mlx-audio was force-reinstalled don't match, so those venvs (still
    /// on an older fork commit, pip having kept it) install once more.
    private static let stampHeader = "# llmtray audio runtime v2: mlx-audio force-reinstalled and checked"
    private static var wantedStamp: String { ([stampHeader] + requirements).joined(separator: "\n") }

    /// The venv is there with exactly these requirements.
    #if !APP_STORE
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.venvPython)
            && Self.installedRequirements() == Self.wantedStamp
    }
    #endif

    /// Before a run: `ensureInstalled`, but a working venv that can't be
    /// brought up to date (offline, GitHub down) is kept -- the error comes
    /// back for a log line instead of stopping the run. No venv at all
    /// still throws.
    func ensureInstalledOrKeep(status: ((String) -> Void)? = nil) async throws -> Error? {
        do {
            try await ensureInstalled(status: status)
            return nil
        } catch {
            guard hasVenv else { throw error }
            return error
        }
    }

    private static func installedRequirements() -> String? {
        (try? String(contentsOfFile: installStamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates the venv and installs the requirements when they aren't
    /// (both first time only). `status` gets what's happening, for the
    /// caller's own UI.
    func ensureInstalled(status: ((String) -> Void)? = nil) async throws {
        #if APP_STORE
        // Inside the bundle, installed with it: nothing to install.
        #else
        while let running = install {
            // Another caller's install: its progress here too.
            let watch = $statusText.sink { status?($0) }
            _ = try? await running.value
            watch.cancel()
            // Another caller may have started the next one meanwhile.
            if install == running { install = nil }
        }
        guard !isInstalled else { return }
        let task = Task { @MainActor in
            try await self.performInstall(status: status)
        }
        install = task
        defer { if install == task { install = nil } }
        try await task.value
        #endif
    }

    private func performInstall(status: ((String) -> Void)?) async throws {
        isInstalling = true
        defer { isInstalling = false; statusText = ""; status?("") }
        func report(_ text: String) { statusText = text; status?(text) }
        try FileManager.default.createDirectory(atPath: RuntimePaths.externalRuntimeDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.venvPython) {
            guard let python = await PythonLocator.findModern(preferring: [MLXRuntimeInstaller.externalFrameworkPython()].compactMap { $0 })
            else { throw RuntimeError.noPython }
            report(NSLocalizedString("Setting up the audio runtime (first time only)…", comment: ""))
            try await run(python, ["-m", "venv", Self.venvDir])
            try await run(Self.venvPython, ["-m", "pip", "install", "--quiet", "--upgrade", "pip"])
        }
        let wanted = Self.wantedStamp
        if Self.installedRequirements() != wanted {
            let installing = NSLocalizedString("Installing mlx-audio…", comment: "")
            report(installing)
            do {
                // Minutes on a first run: which package it's on, not a bare "Installing…".
                try await PipProgress.install(Self.venvPython, Self.requirements) { detail in report(installing + " " + detail) }
            } catch let error as ProcessRunner.Failure {
                throw RuntimeError.installFailed(error.outputTail)
            }
            // Every fork commit has the same version number, so pip counts a
            // new tarball URL as already satisfied and keeps the old code:
            // replace the package itself, then check which commit it is.
            try await run(Self.venvPython, ["-m", "pip", "install", "--quiet", "--force-reinstall", "--no-deps", Self.requirements[0]])
            try await run(Self.venvPython, [
                "-c",
                """
                import sys
                from importlib.metadata import distribution
                url = distribution("mlx-audio").read_text("direct_url.json") or ""
                sys.exit(0 if "\(Self.mlxAudioCommit)" in url else "installed mlx-audio isn't \(Self.mlxAudioCommit): " + url)
                """,
            ])
            try wanted.write(toFile: Self.installStamp, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Updates (Settings > Updates, by hand)

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(current: String, latest: String)
        case updating
        case failed(String)
    }

    @Published private(set) var updateState: UpdateState = .idle
    /// The fork branch the app's pins come from.
    private static let trackedBranch = "llmtray"

    /// Compares the commit in use with the fork branch's tip (GitHub API;
    /// offline, it just fails -- nothing changes).
    func checkForUpdate() {
        updateState = .checking
        Task {
            do {
                let url = URL(string: "https://api.github.com/repos/ipsupport-llc/mlx-audio/commits/\(Self.trackedBranch)")!
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let latest = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["sha"] as? String else {
                    updateState = .failed("unexpected GitHub API response")
                    return
                }
                let current = Self.mlxAudioCommit
                if !isInstalled {
                    // Not installed (or out of step): installing is the update.
                    updateState = .updateAvailable(current: current, latest: latest == current ? current : latest)
                } else if latest != current, try await GitHubCommits.isNewer(latest, than: current, in: "ipsupport-llc/mlx-audio") {
                    updateState = .updateAvailable(current: current, latest: latest)
                } else {
                    // The same commit, or a branch tip behind the one in use.
                    updateState = .upToDate
                }
            } catch {
                updateState = .failed(error.localizedDescription)
            }
        }
    }

    /// Installs `commit` (the branch tip) and keeps it over this build's pin.
    func applyUpdate(to commit: String) {
        updateState = .updating
        Task {
            let previous = Self.mlxAudioCommit
            do {
                try Self.setOverride(commit)
                try await ensureInstalled { _ in }
                updateState = .upToDate
            } catch {
                try? Self.setOverride(previous)
                updateState = .failed(String(format: NSLocalizedString("Update failed: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    /// Installs the commit in use again from scratch (a venv that got out
    /// of step): the stamp goes, so the full install with its check runs.
    func reinstall() {
        updateState = .updating
        Task {
            try? FileManager.default.removeItem(atPath: Self.installStamp)
            do {
                try await ensureInstalled { _ in }
                updateState = .upToDate
            } catch {
                updateState = .failed(String(format: NSLocalizedString("Reinstall failed: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    /// `snapshot_download` of `repo` into `dir` with the venv's
    /// huggingface_hub (`patterns`: allow_patterns). Resumable: files already
    /// complete in `dir` are kept, partial ones continue.
    func snapshotDownload(repo: String, patterns: [String]? = nil, into dir: String) async throws {
        let allow = patterns.map { "allow_patterns=[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "], " } ?? ""
        try await run(Self.venvPython, failure: RuntimeError.downloadFailed, [
            "-c",
            """
            from huggingface_hub import snapshot_download
            snapshot_download("\(repo)", \(allow)local_dir="\(dir)")
            """,
        ])
    }

    private func run(_ executable: String, failure: (String) -> RuntimeError = RuntimeError.installFailed,
                     _ arguments: [String]) async throws {
        do {
            try await ProcessRunner.run(executable, arguments)
        } catch let error as ProcessRunner.Failure {
            throw failure(error.outputTail)
        }
    }
}
