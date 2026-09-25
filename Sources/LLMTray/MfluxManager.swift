import AppKit
import Foundation
import LLMTrayCore

/// Which GPTQ-corrected Z-Image-Turbo checkpoint mflux drives. Unlike
/// mflux's own stock `--quantize N` (naive round-to-nearest, quantized
/// on-device from the full-precision checkpoint every time), these are
/// pre-quantized with Hessian-corrected GPTQ (see
/// github.com/rromenskyi/quant-ternary/tree/main/zimage-quant) and
/// published ready-to-use on HF -- downloadModel() pulls the finished
/// MLX checkpoint directly, no on-device quantization pass needed at all.
enum ImageGenModel: String, CaseIterable, Identifiable, Codable {
    case gptq8bit
    case gptq4bit
    case gptqMixed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gptq8bit: return NSLocalizedString("Z-Image Turbo — GPTQ 8-bit", comment: "")
        case .gptq4bit: return NSLocalizedString("Z-Image Turbo — GPTQ 4-bit", comment: "")
        case .gptqMixed: return NSLocalizedString("Z-Image Turbo — GPTQ mixed (recommended)", comment: "")
        }
    }

    /// Exact sizes -- these are fixed published checkpoints, not an
    /// on-device quantization pass, so unlike the old mflux-native path
    /// these numbers are measured facts, not estimates.
    var approximateDownloadDescription: String {
        switch self {
        case .gptq8bit: return "~10GB"
        case .gptq4bit: return "~5.5GB"
        case .gptqMixed: return "~6.3GB"
        }
    }

    var summary: String {
        switch self {
        case .gptq8bit: return NSLocalizedString("Highest fidelity, largest download -- a correctness baseline you can trust.", comment: "")
        case .gptq4bit: return NSLocalizedString("Smallest and most aggressive -- can visibly drift a generation's composition on some prompts.", comment: "")
        case .gptqMixed: return NSLocalizedString("Attention at 8-bit, feed-forward at 4-bit -- best size/stability balance, validated against uniform 4-bit.", comment: "")
        }
    }

    /// HF repo this checkpoint is published under -- already in mflux's
    /// native MLX format (mflux is a line-by-line diffusers port), so
    /// downloadModel() just fetches it as-is.
    var hfRepo: String {
        switch self {
        case .gptq8bit: return "roman220220/z-image-turbo-gptq-mlx-8bit"
        case .gptq4bit: return "roman220220/z-image-turbo-gptq-mlx-4bit"
        case .gptqMixed: return "roman220220/z-image-turbo-gptq-mlx-mixed"
        }
    }

    /// All three are the same Z-Image-Turbo architecture -- only the
    /// weights' bit-width allocation differs.
    var mfluxModelName: String { "z-image-turbo" }
    var stepCount: String { "9" }
}

/// Scales whatever width/height the model's own tool call requested (see
/// ChatClient.executeToolCalls) -- Z-Image-Turbo defaults to 1024x1024,
/// so .balanced is a 1x no-op and .fast/.high bias the canvas down/up from
/// there while preserving the model's own requested aspect ratio.
enum ImageQuality: String, CaseIterable, Identifiable, Codable {
    case fast
    case balanced
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: return NSLocalizedString("Fast (smaller canvas)", comment: "")
        case .balanced: return NSLocalizedString("Balanced (default)", comment: "")
        case .high: return NSLocalizedString("High quality (larger canvas)", comment: "")
        }
    }

    var scale: Double {
        switch self {
        case .fast: return 0.5
        case .balanced: return 1.0
        case .high: return 1.5
        }
    }
}

/// Bootstraps and drives `mflux` (github.com/filipstrand/mflux), an
/// MLX-native local image-generation runtime, for the `generate_image`
/// tool exposed to chat models (see ChatClient.swift). Lives in its own
/// venv, separate from mlx_server_venv -- mflux pulls in its own
/// tokenizer/model-loading stack that has no reason to share a venv (and
/// thus a dependency-resolution outcome) with the chat server.
@MainActor
final class MfluxManager: ObservableObject {
    enum MfluxError: LocalizedError {
        case noPython
        case processFailed(String)
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .noPython:
                return NSLocalizedString("No Python 3.10+ found. Install one from python.org or via Homebrew (https://brew.sh).", comment: "")
            case .processFailed(let detail):
                return String(format: NSLocalizedString("Image generation failed: %@", comment: ""), detail)
            case .outputMissing:
                return NSLocalizedString("Image generation finished but produced no output file.", comment: "")
            }
        }
    }

    @Published private(set) var isBusy: Bool = false
    @Published private(set) var statusText: String = ""
    // Streamed by the runner during generate() (a decoded preview per
    // denoising step, in memory). nil when not generating.
    @Published private(set) var stepProgress: (step: Int, total: Int)?
    @Published private(set) var previewImage: NSImage?

    /// Pinned: runtime/llmtray_mflux_runner.py drives mflux's internals
    /// (in-memory model, step callbacks), which move between releases -- a
    /// new mflux must not silently break image generation for new installs.
    /// (Never vendor this venv into a DMG: opencv-python in it bundles GPL
    /// codecs; the user's own pip installs it.)
    static let mfluxVersion = "0.20.0"
    static var mfluxRequirement: String { "mflux==\(mfluxVersion)" }

    private var venvDir: String { RuntimePaths.externalRuntimeDir + "/mflux_venv" }
    private var venvPython: String { venvDir + "/bin/python3" }
    private var saveBinary: String { venvDir + "/bin/mflux-save" }

    /// Where a model's published HF checkpoint is downloaded to -- already
    /// GPTQ-quantized and in mflux's native MLX format, so this is used
    /// as-is with no further on-device processing.
    private func savedModelDir(for model: ImageGenModel) -> String {
        RuntimePaths.externalRuntimeDir + "/mflux_models/\(model.rawValue)"
    }

    /// Installs the mflux *package* -- not the model weights, which mflux
    /// downloads itself, lazily, the first time a given model is actually
    /// loaded. Idempotent and cheap once the venv exists.
    private func ensurePackageInstalled() async throws {
        try FileManager.default.createDirectory(
            atPath: RuntimePaths.externalRuntimeDir, withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: venvDir) {
            // The Full build's own Python first: a clean Mac has no other.
            guard let python = await PythonLocator.findModern(preferring: [MLXRuntimeInstaller.externalFrameworkPython()].compactMap { $0 })
            else { throw MfluxError.noPython }
            statusText = NSLocalizedString("Setting up image generation (first time only)…", comment: "")
            try await runProcess(python, ["-m", "venv", venvDir])
            try await runProcess(venvPython, ["-m", "pip", "install", "--quiet", "--upgrade", "pip"])
        }
        // Also when an install from before the pin has another version.
        if !FileManager.default.fileExists(atPath: saveBinary) || installedMfluxVersion() != Self.mfluxVersion {
            statusText = NSLocalizedString("Installing mflux…", comment: "")
            try await runProcess(venvPython, ["-m", "pip", "install", "--quiet", Self.mfluxRequirement, "huggingface_hub"])
        }
        statusText = ""
    }

    /// The mflux version in the venv, from its dist-info folder's name
    /// (mflux-0.20.0.dist-info) -- no Python started for it.
    private func installedMfluxVersion() -> String? {
        guard let site = PythonPackageLicenses.sitePackages(venv: URL(fileURLWithPath: venvDir)),
              let items = try? FileManager.default.contentsOfDirectory(atPath: site.path) else { return nil }
        return items.first { $0.hasPrefix("mflux-") && $0.hasSuffix(".dist-info") }
            .map { String($0.dropFirst("mflux-".count).dropLast(".dist-info".count)) }
    }

    /// Explicit, user-initiated warm-up: installs mflux if needed, then
    /// downloads the given model's published GPTQ checkpoint from HF ONCE,
    /// caching it under externalRuntimeDir/mflux_models -- every later
    /// generate() call loads straight from that copy. Unlike the old
    /// mflux-native `--quantize` path, there is no on-device quantization
    /// step at all here: these repos are already GPTQ-corrected and saved
    /// in mflux's native MLX format (see MfluxManager's ImageGenModel
    /// docstring), so downloading IS the full preparation step. Called
    /// from a confirmation flow in Settings (see ContentView) before
    /// flipping the feature on, not automatically.
    func downloadModel(_ model: ImageGenModel) async throws {
        try await ensurePackageInstalled()
        if FileManager.default.fileExists(atPath: savedModelDir(for: model)) { return }

        isBusy = true
        statusText = String(format: NSLocalizedString("Downloading %@…", comment: ""), model.displayName)
        defer {
            isBusy = false
            statusText = ""
        }

        try FileManager.default.createDirectory(
            atPath: RuntimePaths.externalRuntimeDir + "/mflux_models", withIntermediateDirectories: true
        )
        // Write to a temp path and rename into place atomically -- a
        // crash/quit partway through the download must not leave a
        // half-written directory that a later fileExists() check above
        // would wrongly treat as "already done."
        let tempDir = savedModelDir(for: model) + ".partial-\(UUID().uuidString)"
        do {
            try await runProcess(venvPython, [
                "-c",
                """
                from huggingface_hub import snapshot_download
                snapshot_download("\(model.hfRepo)", local_dir="\(tempDir)")
                """,
            ])
            try FileManager.default.moveItem(atPath: tempDir, toPath: savedModelDir(for: model))
        } catch {
            try? FileManager.default.removeItem(atPath: tempDir)
            throw error
        }
    }

    /// Generates one image and returns its PNG bytes -- entirely in memory:
    /// runtime/llmtray_mflux_runner.py drives mflux's Python API and streams
    /// progress, step previews and the result over stdout, so nothing (not
    /// even a temporary file) touches the disk. Matters for temporary chats,
    /// which must leave no trace.
    func generate(prompt: String, width: Int, height: Int, model: ImageGenModel) async throws -> Data {
        // Set up by the download in Settings; never installed mid-chat (a
        // temporary chat must not cause files to be written).
        guard FileManager.default.fileExists(atPath: venvPython) else {
            throw MfluxError.processFailed(NSLocalizedString("Image generation isn't set up -- turn it on again in Settings.", comment: ""))
        }
        // Installed before the pin, or by an older app: its internals may
        // not match the runner's.
        guard installedMfluxVersion() == Self.mfluxVersion else {
            throw MfluxError.processFailed(NSLocalizedString("Image generation needs an update -- turn it off and on again in Settings.", comment: ""))
        }

        let savedDir = savedModelDir(for: model)
        guard FileManager.default.fileExists(atPath: savedDir) else {
            // The Settings toggle only turns on after downloadModel() has
            // succeeded; fail clearly rather than silently do something else.
            throw MfluxError.processFailed(String(format: NSLocalizedString("%@ isn't downloaded yet -- re-enable image generation in Settings.", comment: ""), model.displayName))
        }

        isBusy = true
        statusText = NSLocalizedString("Generating image…", comment: "")
        stepProgress = (step: 0, total: Int(model.stepCount) ?? 9)
        previewImage = nil
        defer {
            isBusy = false
            statusText = ""
            stepProgress = nil
            previewImage = nil
        }

        // width/height must be multiples of 16 for the model's patch size;
        // round rather than reject an odd model-supplied value.
        let roundedWidth = min(max(256, (width / 16) * 16), 2048)
        let roundedHeight = min(max(256, (height / 16) * 16), 2048)
        let result = ImageResult()
        try await ProcessRunner.runStreaming(venvPython, [
            RuntimePaths.runtimeDir + "/llmtray_mflux_runner.py",
            "--width", String(roundedWidth),
            "--height", String(roundedHeight),
            "--steps", model.stepCount,
            "--model", savedDir,
            "--base-model", model.mfluxModelName,
        ], stdin: Data(prompt.utf8), environment: [
            "PYTHONDONTWRITEBYTECODE": "1",
            // The model is local: no Hub lookups (nor their cache writes,
            // from a temporary chat).
            "HF_HUB_OFFLINE": "1",
            // Ours: a runner left behind by a crash is stopped at the
            // next launch (OrphanScan).
            OrphanScan.imageRunnerMarker: "1",
        ], onLine: { [weak self] line in
            guard let message = MfluxRunnerMessage(line: line) else { return }
            switch message {
            case .image(let data):
                result.set(data)
            case .step(let step, let total):
                Task { @MainActor [weak self] in
                    guard let self, self.isBusy else { return }   // a late line after the run
                    self.stepProgress = (step: step, total: total)
                }
            case .preview(let data):
                Task { @MainActor [weak self] in
                    guard let self, self.isBusy, let image = NSImage(data: data) else { return }
                    self.previewImage = image
                }
            }
        })
        guard let data = result.get() else { throw MfluxError.outputMissing }
        return data
    }

    private func runProcess(_ executable: String, _ arguments: [String]) async throws {
        do {
            try await ProcessRunner.run(executable, arguments)
        } catch let failure as ProcessRunner.Failure {
            throw MfluxError.processFailed(failure.outputTail)
        }
    }
}

/// The final image, set from the reader thread, read after the run.
private final class ImageResult: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}
