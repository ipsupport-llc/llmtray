import Foundation
import LLMTrayCore

/// The project-files embedder (adr/0012): its weights and the managed
/// runner that uses them. Nothing is downloaded or started until the
/// feature is turned on in Settings (PR 3.5); this is the API that uses.
///
/// **Where it runs: the mlx-lm server's venv** (`mlx_server_venv`), not a
/// venv of its own like mflux's or music's. The runner needs only `mlx`,
/// `tokenizers` and `numpy` -- all already there for the chat server --
/// while a dedicated venv would download another ~200 MB of the same
/// wheels. The coupling is guarded, not assumed: every load re-embeds the
/// entry's reference vectors and refuses the model below `min_cosine` (so
/// an mlx or tokenizers bump by the fork pin that changed the vectors
/// fails loudly instead of silently mixing old and new vectors), and the
/// weights and tokenizer are pinned by sha256.
@MainActor
final class EmbedderManager: ObservableObject {
    enum EmbedderError: LocalizedError {
        case noRuntime
        case noRegistry(String)
        case busy
        case processFailed(String)
        case checksum([String])

        var errorDescription: String? {
            switch self {
            case .noRuntime:
                return NSLocalizedString("The model runtime isn't installed yet -- start a model once, then try again.", comment: "")
            case .noRegistry(let detail):
                return String(format: NSLocalizedString("The embedder list is missing or invalid: %@", comment: ""), detail)
            case .busy:
                return NSLocalizedString("The embedder is being downloaded -- try again once it's done.", comment: "")
            case .processFailed(let detail):
                return String(format: NSLocalizedString("Downloading the embedder failed: %@", comment: ""), detail)
            case .checksum(let files):
                return String(format: NSLocalizedString("The downloaded embedder files don't match their checksums: %@", comment: ""),
                              files.joined(separator: ", "))
            }
        }
    }

    @Published private(set) var isBusy = false
    @Published private(set) var statusText = ""
    /// One runner per entry, whoever asks: `remove` stops the only one.
    private let runners = EmbedRunnerPool()

    init() {
        Self.sweepPartials()
    }

    /// Leftovers of downloads a quit or crash interrupted
    /// (`<id>.partial-<uuid>`, gigabytes each): nothing else writes there, and
    /// no download runs before this manager exists. (mflux and music name
    /// their temp folders the same way in their own directories and code;
    /// they aren't touched here.)
    static func sweepPartials() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: modelsDir)) ?? [] where name.contains(".partial-") {
            try? fm.removeItem(atPath: modelsDir + "/" + name)
        }
    }

    static var registryURL: URL { URL(fileURLWithPath: RuntimePaths.runtimeDir + "/embedders.json") }
    static var modelsDir: String { RuntimePaths.externalRuntimeDir + "/embed_models" }
    static func modelDir(_ entry: EmbedderEntry) -> String { modelsDir + "/" + entry.id }

    func registry() throws -> EmbedderRegistry {
        do {
            return try EmbedderRegistry.load(from: Self.registryURL)
        } catch {
            throw EmbedderError.noRegistry(String(describing: error))
        }
    }

    /// The registry's default entry (bge-m3).
    func defaultEntry() throws -> EmbedderEntry {
        let r = try registry()
        guard let e = r.entry(r.defaultID) else { throw EmbedderError.noRegistry(r.defaultID) }
        return e
    }

    /// Where the runner's modules are, when shipped.
    private var runnerScript: String { RuntimePaths.runtimeDir + "/llmtray_embed_runner.py" }

    /// The stamp only (cheap); `verify` hashes the files.
    func isDownloaded(_ entry: EmbedderEntry) -> Bool {
        EmbedderInstall.isStamped(entry, at: URL(fileURLWithPath: Self.modelDir(entry)))
    }

    /// Hashes the installed files; a damaged one takes the stamp away, so
    /// the entry isn't ready and `download` repairs it. Call it when the
    /// runner fails to load the model. Returns the damaged files.
    @discardableResult
    func verify(_ entry: EmbedderEntry) async throws -> [String] {
        try await EmbedderInstall.verify(entry, at: URL(fileURLWithPath: Self.modelDir(entry)))
    }

    /// Weights in place and verified, the runtime there to run them.
    func isReady(_ entry: EmbedderEntry) -> Bool {
        isDownloaded(entry)
            && FileManager.default.isExecutableFile(atPath: MLXRuntimeInstaller.venvPython)
            && FileManager.default.fileExists(atPath: runnerScript)
    }

    /// Installs the entry's pinned files, or repairs them: every file already
    /// there is hashed (the stamp alone isn't trusted -- a damaged file under
    /// a good stamp is fetched again); missing or mismatching files are
    /// downloaded into a temporary folder, the good ones linked over, the
    /// whole set checked against its sha256 and only then moved into place.
    func download(_ entry: EmbedderEntry) async throws {
        guard !isBusy else { throw EmbedderError.busy }
        guard FileManager.default.isExecutableFile(atPath: MLXRuntimeInstaller.venvPython) else { throw EmbedderError.noRuntime }
        isBusy = true
        defer { isBusy = false; statusText = "" }
        statusText = NSLocalizedString("Checking the download…", comment: "")
        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.modelsDir, withIntermediateDirectories: true)
        do {
            try await EmbedderInstall.install(entry, at: URL(fileURLWithPath: Self.modelDir(entry))) { files, temp in
                statusText = String(format: NSLocalizedString("Downloading %@…", comment: ""), entry.displayName)
                // A runner using the folder being replaced exits first.
                await runners.stop(entry.id)
                // Values go in as arguments, not into the code.
                do {
                    try await ProcessRunner.run(MLXRuntimeInstaller.venvPython, [
                        "-c",
                        """
                        import sys
                        from huggingface_hub import snapshot_download
                        snapshot_download(sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3], allow_patterns=sys.argv[4:])
                        """,
                        entry.source.repo, entry.source.revision, temp.path,
                    ] + files)
                } catch let failure as ProcessRunner.Failure {
                    throw EmbedderError.processFailed(failure.outputTail)
                }
                try? fm.removeItem(at: temp.appendingPathComponent(".cache"))   // huggingface_hub's own bookkeeping
                statusText = NSLocalizedString("Checking the download…", comment: "")
            }
        } catch let mismatch as EmbedderInstall.ChecksumMismatch {
            throw EmbedderError.checksum(mismatch.files)
        }
    }

    /// Removes the weights (the feature turned off in Settings), after the
    /// entry's runner -- the one `makeRunner` shares -- has exited.
    func remove(_ entry: EmbedderEntry) async throws {
        guard !isBusy else { throw EmbedderError.busy }
        isBusy = true
        defer { isBusy = false }
        await runners.stop(entry.id)
        let target = Self.modelDir(entry)
        if FileManager.default.fileExists(atPath: target) { try FileManager.default.removeItem(atPath: target) }
    }

    /// The entry's runner (not started: the first request starts it), shared
    /// by every caller while one lives. Offline, bytecode-free, with the
    /// parent's pid for its watchdog; the orphan marker is EmbedRunner's own.
    func makeRunner(_ entry: EmbedderEntry) -> EmbedRunner {
        runners.runner(for: entry.id) {
            EmbedRunner(configuration: EmbedRunner.Configuration(
                executable: MLXRuntimeInstaller.venvPython,
                arguments: [
                    runnerScript,
                    "--registry", Self.registryURL.path,
                    "--entry", entry.id,
                    "--model-dir", Self.modelDir(entry),
                    "--parent", String(getpid()),
                ],
                environment: [
                    "PYTHONDONTWRITEBYTECODE": "1",
                    "HF_HUB_OFFLINE": "1",
                    "TOKENIZERS_PARALLELISM": "false",
                ]))
        }
    }
}
