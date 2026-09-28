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
    /// the GPTQ-3 model).
    static let mlxAudioCommit = "2dce52460b2ff95793bb18ba93404c7bf531d141"

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
    static var venvPython: String { venvDir + "/bin/python3" }
    /// Written after a complete install: the pins it was made with.
    private static var installStamp: String { venvDir + "/llmtray-requirements.txt" }

    @Published private(set) var isInstalling = false
    @Published private(set) var statusText = ""
    private var install: Task<Void, Error>?

    /// A venv was set up (its requirements may be older: `ensureInstalled`
    /// brings them up to date before a run).
    var hasVenv: Bool { FileManager.default.isExecutableFile(atPath: Self.venvPython) }

    /// The venv is there with exactly these requirements.
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.venvPython)
            && Self.installedRequirements() == Self.requirements.joined(separator: "\n")
    }

    private static func installedRequirements() -> String? {
        (try? String(contentsOfFile: installStamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates the venv and installs the requirements when they aren't
    /// (both first time only). `status` gets what's happening, for the
    /// caller's own UI.
    func ensureInstalled(status: ((String) -> Void)? = nil) async throws {
        while let running = install {
            status?(statusText)
            _ = try? await running.value
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
        let wanted = Self.requirements.joined(separator: "\n")
        if Self.installedRequirements() != wanted {
            report(NSLocalizedString("Installing mlx-audio…", comment: ""))
            try await run(Self.venvPython, ["-m", "pip", "install", "--quiet"] + Self.requirements)
            try wanted.write(toFile: Self.installStamp, atomically: true, encoding: .utf8)
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
