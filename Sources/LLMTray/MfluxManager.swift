import AppKit
import Foundation

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
        case .gptq8bit: return "Z-Image Turbo — GPTQ 8-bit"
        case .gptq4bit: return "Z-Image Turbo — GPTQ 4-bit"
        case .gptqMixed: return "Z-Image Turbo — GPTQ mixed (recommended)"
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
        case .gptq8bit: return "Highest fidelity, largest download -- a correctness baseline you can trust."
        case .gptq4bit: return "Smallest and most aggressive -- can visibly drift a generation's composition on some prompts."
        case .gptqMixed: return "Attention at 8-bit, feed-forward at 4-bit -- best size/stability balance, validated against uniform 4-bit."
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
        case .fast: return "Fast (smaller canvas)"
        case .balanced: return "Balanced (default)"
        case .high: return "High quality (larger canvas)"
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
                return "No Python 3.10+ found. Install one from python.org or via Homebrew (https://brew.sh)."
            case .processFailed(let detail):
                return "Image generation failed: \(detail)"
            case .outputMissing:
                return "Image generation finished but produced no output file."
            }
        }
    }

    @Published private(set) var isBusy: Bool = false
    @Published private(set) var statusText: String = ""
    // Derived from mflux's own `--stepwise-image-output-dir` output files
    // (named "seed_<seed>_step<N>of<TOTAL>.png") during generate() -- gives
    // real step-accurate progress and a live-updating preview for free,
    // instead of parsing mflux's tqdm stdout text. nil when not generating.
    @Published private(set) var stepProgress: (step: Int, total: Int)?
    @Published private(set) var previewImage: NSImage?

    private var venvDir: String { RuntimePaths.externalRuntimeDir + "/mflux_venv" }
    private var venvPython: String { venvDir + "/bin/python3" }
    private var saveBinary: String { venvDir + "/bin/mflux-save" }

    private func generateBinary(for model: ImageGenModel) -> String {
        venvDir + "/bin/mflux-generate-z-image-turbo"
    }

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
            guard let python = await PythonLocator.findModern() else { throw MfluxError.noPython }
            statusText = "Setting up image generation (first time only)…"
            try await runProcess(python, ["-m", "venv", venvDir])
            try await runProcess(venvPython, ["-m", "pip", "install", "--quiet", "--upgrade", "pip"])
        }
        if !FileManager.default.fileExists(atPath: saveBinary) {
            statusText = "Installing mflux…"
            try await runProcess(venvPython, ["-m", "pip", "install", "--quiet", "mflux", "huggingface_hub"])
        }
        statusText = ""
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
        statusText = "Downloading \(model.displayName)…"
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

    /// Generates one image and returns its raw bytes. mflux's CLI only
    /// knows how to write a file (no stdout image option), so this writes
    /// to a unique path under the OS temp directory and deletes it
    /// immediately after reading the bytes back into memory -- nothing
    /// about the result is left on disk once this call returns.
    func generate(prompt: String, width: Int, height: Int, model: ImageGenModel) async throws -> Data {
        try await ensurePackageInstalled()

        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmtray-mflux-\(UUID().uuidString).png").path
        let stepDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmtray-mflux-steps-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: stepDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: outputPath)
            try? FileManager.default.removeItem(atPath: stepDir)
        }

        isBusy = true
        statusText = "Generating image…"
        let steps = Int(model.stepCount) ?? 9
        stepProgress = (step: 0, total: steps)
        previewImage = nil
        defer {
            isBusy = false
            statusText = ""
            stepProgress = nil
            previewImage = nil
        }

        let pollTask = Task { [weak self] in await self?.pollStepwiseProgress(in: stepDir) }
        defer { pollTask.cancel() }

        // width/height must be multiples of 16 for the model's patch size;
        // round rather than reject so an odd model-supplied value doesn't
        // hard-fail a tool call.
        let roundedWidth = max(256, (width / 16) * 16)
        let roundedHeight = max(256, (height / 16) * 16)
        let baseArgs = [
            "--prompt", prompt,
            "--width", String(roundedWidth),
            "--height", String(roundedHeight),
            "--steps", model.stepCount,
            "--output", outputPath,
            "--stepwise-image-output-dir", stepDir,
        ]

        let savedDir = savedModelDir(for: model)
        guard FileManager.default.fileExists(atPath: savedDir) else {
            // Shouldn't normally happen -- the Settings toggle only flips
            // on after downloadModel() succeeds -- but there's no
            // meaningful fallback for a published GPTQ checkpoint the way
            // there was for mflux's own stock --quantize path, so fail
            // clearly instead of silently doing something else.
            throw MfluxError.processFailed("\(model.displayName) isn't downloaded yet -- re-enable image generation in Settings.")
        }
        try await runProcess(generateBinary(for: model), baseArgs + ["--model", savedDir, "--base-model", model.mfluxModelName])

        guard let data = FileManager.default.contents(atPath: outputPath) else {
            throw MfluxError.outputMissing
        }
        return data
    }

    /// Watches --stepwise-image-output-dir for mflux's own
    /// "seed_<seed>_step<N>of<TOTAL>.png" files (one written per denoising
    /// step) and publishes the latest one as a live preview, plus exact
    /// step/total progress parsed straight from the filename -- no stdout
    /// parsing needed. Polling (vs. FSEvents) because steps land every ~2s;
    /// simplicity wins over the small latency. Cancelled via the caller's
    /// Task handle once generate()'s runProcess call returns.
    private static let stepFilePattern = try! NSRegularExpression(pattern: #"seed_\d+_step(\d+)of(\d+)\.png$"#)

    private func pollStepwiseProgress(in stepDir: String) async {
        var lastStep = -1
        while !Task.isCancelled {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: stepDir) {
                var best: (step: Int, total: Int, name: String)?
                for name in entries {
                    let range = NSRange(name.startIndex..., in: name)
                    guard let match = Self.stepFilePattern.firstMatch(in: name, range: range),
                          let stepRange = Range(match.range(at: 1), in: name),
                          let totalRange = Range(match.range(at: 2), in: name),
                          let step = Int(name[stepRange]), let total = Int(name[totalRange]) else { continue }
                    if best == nil || step > best!.step {
                        best = (step, total, name)
                    }
                }
                if let best, best.step != lastStep {
                    lastStep = best.step
                    stepProgress = (step: best.step, total: best.total)
                    if let image = NSImage(contentsOfFile: stepDir + "/" + best.name) {
                        previewImage = image
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func runProcess(_ executable: String, _ arguments: [String]) async throws {
        do {
            try await ProcessRunner.run(executable, arguments)
        } catch let failure as ProcessRunner.Failure {
            throw MfluxError.processFailed(failure.outputTail)
        }
    }
}
