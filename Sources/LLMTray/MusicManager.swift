import Foundation
import LLMTrayCore

/// Bootstraps and drives ACE-Step 1.5 (MIT; text and lyrics to music with
/// vocals, 48 kHz stereo) through mlx-audio, for the `generate_music` chat
/// tool. Its own venv, like mflux's: mlx-audio pulls in its own
/// transformers/librosa stack.
///
/// Measured in quant-ternary/acestep-quant (docs/FINDINGS.md): with the
/// runner's planner (the official ACE-Step prompt layout), 4-bit DiT + LM
/// 1.7B sings about as intelligibly as the official pipeline, ~3x faster --
/// ~22 s for 30 s of music on an M5.
@MainActor
final class MusicManager: ObservableObject {
    enum MusicError: LocalizedError {
        case noPython
        case processFailed(String)
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .noPython:
                return NSLocalizedString("No Python 3.10+ found. Install one from python.org or via Homebrew (https://brew.sh).", comment: "")
            case .processFailed(let detail):
                return String(format: NSLocalizedString("Music generation failed: %@", comment: ""), detail)
            case .outputMissing:
                return NSLocalizedString("Music generation finished but produced no audio.", comment: "")
            }
        }
    }

    @Published private(set) var isBusy = false
    @Published private(set) var statusText = ""
    /// 0...100 during generate(); nil otherwise.
    @Published private(set) var progress: Int?

    /// Pinned: runtime/llmtray_music_runner.py drives mlx-audio's ACE-Step
    /// internals, which only exist on its `pc/add-ace` branch (not in a PyPI
    /// release). A tarball of that commit needs no git on the Mac.
    static let mlxAudioCommit = "1e8264a487dd74d4ea327a8250c071558a7cd8f4"
    static var requirements: [String] {
        [
            "mlx-audio @ https://github.com/Blaizzy/mlx-audio/archive/\(mlxAudioCommit).tar.gz",
            "mlx==0.32.2", "mlx-lm==0.31.1", "transformers==5.17.0", "pyyaml", "huggingface_hub",
        ]
    }

    /// The 4-bit DiT, text encoder and VAE (mlx-community's conversion).
    static let ditRepo = "mlx-community/ACE-Step1.5-MLX-4bit"
    /// The 5 Hz LM planner, 1.7B: a folder of the official repo.
    static let lmRepo = "ACE-Step/Ace-Step1.5"
    static let lmFolder = "acestep-5Hz-lm-1.7B"
    static let approximateDownloadDescription = "~9GB"

    static var venvDir: String { RuntimePaths.externalRuntimeDir + "/music_venv" }
    private var venvDir: String { Self.venvDir }
    private var venvPython: String { venvDir + "/bin/python3" }
    /// Written after a complete install: the pins it was made with.
    private var installStamp: String { venvDir + "/llmtray-requirements.txt" }
    private static var modelsDir: String { RuntimePaths.externalRuntimeDir + "/music_models" }
    private var modelsDir: String { Self.modelsDir }
    private var ditDir: String { Self.modelsDir + "/ace-step-1.5-4bit" }
    private var lmDir: String { Self.modelsDir + "/ace-step-1.5-lm-1.7B" }
    /// Where the checkpoints are, with their repos (About › Licenses).
    static var modelPaths: [(String, String)] {
        [(modelsDir + "/ace-step-1.5-4bit", ditRepo), (modelsDir + "/ace-step-1.5-lm-1.7B", lmRepo)]
    }

    var isReady: Bool {
        FileManager.default.fileExists(atPath: ditDir) && FileManager.default.fileExists(atPath: lmDir)
            && installedRequirements() == Self.requirements.joined(separator: "\n")
    }

    private func installedRequirements() -> String? {
        (try? String(contentsOfFile: installStamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensurePackagesInstalled() async throws {
        try FileManager.default.createDirectory(atPath: RuntimePaths.externalRuntimeDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: venvPython) {
            guard let python = await PythonLocator.findModern(preferring: [MLXRuntimeInstaller.externalFrameworkPython()].compactMap { $0 })
            else { throw MusicError.noPython }
            statusText = NSLocalizedString("Setting up music generation (first time only)…", comment: "")
            try await runProcess(python, ["-m", "venv", venvDir])
            try await runProcess(venvPython, ["-m", "pip", "install", "--quiet", "--upgrade", "pip"])
        }
        let wanted = Self.requirements.joined(separator: "\n")
        if installedRequirements() != wanted {
            statusText = NSLocalizedString("Installing mlx-audio…", comment: "")
            try await runProcess(venvPython, ["-m", "pip", "install", "--quiet"] + Self.requirements)
            try wanted.write(toFile: installStamp, atomically: true, encoding: .utf8)
        }
        statusText = ""
    }

    /// Settings-initiated, before the tool is turned on: the packages and
    /// both checkpoints, each downloaded to a temporary folder and moved
    /// into place only when complete.
    func download() async throws {
        guard !isBusy else {
            throw MusicError.processFailed(NSLocalizedString("The music generator is busy -- try again once it's done.", comment: ""))
        }
        isBusy = true
        defer { isBusy = false; statusText = "" }
        try await ensurePackagesInstalled()
        try FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: ditDir) {
            statusText = String(format: NSLocalizedString("Downloading %@…", comment: ""), "ACE-Step 1.5")
            try await fetch(repo: Self.ditRepo, patterns: nil, into: ditDir)
        }
        if !FileManager.default.fileExists(atPath: lmDir) {
            statusText = String(format: NSLocalizedString("Downloading %@…", comment: ""), "ACE-Step 1.5 LM")
            let temp = lmDir + ".partial-\(UUID().uuidString)"
            do {
                try await fetch(repo: Self.lmRepo, patterns: [Self.lmFolder + "/*"], into: temp, move: false)
                try FileManager.default.moveItem(atPath: temp + "/" + Self.lmFolder, toPath: lmDir)
                try? FileManager.default.removeItem(atPath: temp)
            } catch {
                try? FileManager.default.removeItem(atPath: temp)
                throw error
            }
        }
    }

    /// snapshot_download into `dir` (through a temporary folder when `move`).
    private func fetch(repo: String, patterns: [String]?, into dir: String, move: Bool = true) async throws {
        let target = move ? dir + ".partial-\(UUID().uuidString)" : dir
        let allow = patterns.map { "allow_patterns=[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "], " } ?? ""
        do {
            try await runProcess(venvPython, [
                "-c",
                """
                from huggingface_hub import snapshot_download
                snapshot_download("\(repo)", \(allow)local_dir="\(target)")
                """,
            ])
            if move { try FileManager.default.moveItem(atPath: target, toPath: dir) }
        } catch {
            if move { try? FileManager.default.removeItem(atPath: target) }
            throw error
        }
    }

    /// One piece of music, as 16-bit stereo WAV bytes -- in memory only: the
    /// runner reads the request from stdin and writes the audio to stdout,
    /// so nothing touches the disk (a temporary chat must leave no trace).
    func generate(caption: String, lyrics: String, duration: Int, language: String) async throws -> Data {
        guard isReady else {
            throw MusicError.processFailed(NSLocalizedString("Music generation isn't set up -- turn it on again in Settings.", comment: ""))
        }
        // Claimed before any suspension: two tabs can't both run it.
        guard !isBusy else {
            throw MusicError.processFailed(NSLocalizedString("The music generator is busy with another chat -- try again once it's done.", comment: ""))
        }
        isBusy = true
        statusText = NSLocalizedString("Generating music…", comment: "")
        progress = 0
        defer {
            isBusy = false
            statusText = ""
            progress = nil
        }
        let request = try JSONSerialization.data(withJSONObject: [
            "caption": caption, "lyrics": lyrics, "duration": duration, "language": language,
        ])
        let result = AudioResult()
        try await ProcessRunner.runStreaming(venvPython, [
            RuntimePaths.runtimeDir + "/llmtray_music_runner.py",
            "--dit", ditDir,
            "--lm", lmDir,
        ], stdin: request, environment: [
            "PYTHONDONTWRITEBYTECODE": "1",
            "HF_HUB_OFFLINE": "1",
            "TOKENIZERS_PARALLELISM": "false",
            OrphanScan.musicRunnerMarker: "1",
        ], onLine: { [weak self] line in
            guard let message = MusicRunnerMessage(line: line) else { return }
            switch message {
            case .audio(let data):
                result.set(data)
            case .step(let step, let total):
                Task { @MainActor [weak self] in
                    guard let self, self.isBusy, total > 0 else { return }
                    self.progress = min(100, step * 100 / total)
                }
            case .stage(let text):
                Task { @MainActor [weak self] in
                    guard let self, self.isBusy else { return }
                    self.statusText = Self.localizedStage(text)
                }
            }
        })
        guard let data = result.get() else { throw MusicError.outputMissing }
        return data
    }

    /// The runner's stage names, for the UI.
    private static func localizedStage(_ stage: String) -> String {
        switch stage {
        case "Writing the song": return NSLocalizedString("Writing the song…", comment: "music generation stage")
        case "Composing": return NSLocalizedString("Composing…", comment: "music generation stage")
        case "Mixing": return NSLocalizedString("Mixing…", comment: "music generation stage")
        default: return stage
        }
    }

    private func runProcess(_ executable: String, _ arguments: [String]) async throws {
        do {
            try await ProcessRunner.run(executable, arguments)
        } catch let failure as ProcessRunner.Failure {
            throw MusicError.processFailed(failure.outputTail)
        }
    }
}

/// The audio, set from the reader thread, read after the run.
private final class AudioResult: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}
