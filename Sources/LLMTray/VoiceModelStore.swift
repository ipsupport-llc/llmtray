import Foundation
import LLMTrayCore

/// Voice Lab's on/off switch and its model on disk (adr/0016): off by
/// default; the model is downloaded only when the user asks, into
/// voice_models/<name>, with the audio runtime it needs. The download goes
/// to a fixed `<name>.partial` folder, so one interrupted (a quit, no
/// network) continues where it stopped the next time, and is moved into
/// place only when complete.
@MainActor
final class VoiceModelStore: ObservableObject {
    static let shared = VoiceModelStore()

    enum StoreError: LocalizedError {
        case busy
        case diskFull(needed: Int64, free: Int64)
        case inUse

        var errorDescription: String? {
            switch self {
            case .busy:
                return NSLocalizedString("The voice model is being downloaded -- try again once it's done.", comment: "")
            case .diskFull(let needed, let free):
                return String(format: NSLocalizedString("Not enough disk space: the voice model needs %1$@, %2$@ is free.", comment: "needed, free"),
                              ByteCountFormatter.string(fromByteCount: needed, countStyle: .file), ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            case .inUse:
                return NSLocalizedString("Stop Voice Lab first.", comment: "")
            }
        }
    }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard[Pref.voiceLabEnabled] = isEnabled
            if !isEnabled { VoiceLabSession.shared.stop() }   // off means off
        }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = ""
    /// 0...1 while the model's files download; nil otherwise.
    @Published private(set) var progress: Double?
    /// Bumped when a model is downloaded or removed (views re-read the disk).
    @Published private(set) var revision = 0

    private init() {
        isEnabled = UserDefaults.standard[Pref.voiceLabEnabled]
    }

    static var modelsDir: String { RuntimePaths.externalRuntimeDir + "/voice_models" }
    static func modelDir(_ model: VoiceLabModel) -> String { modelsDir + "/" + model.folderName }
    static func partialDir(_ model: VoiceLabModel) -> String { modelDir(model) + ".partial" }

    /// The files are in place (config and weights index).
    func isDownloaded(_ model: VoiceLabModel) -> Bool {
        let dir = Self.modelDir(model)
        return FileManager.default.fileExists(atPath: dir + "/config.json")
            && FileManager.default.fileExists(atPath: dir + "/model.safetensors.index.json")
    }

    /// A download that stopped part way, to continue.
    func hasPartialDownload(_ model: VoiceLabModel) -> Bool {
        FileManager.default.fileExists(atPath: Self.partialDir(model))
    }

    /// The audio runtime (when it isn't installed yet) and the model.
    func download(_ model: VoiceLabModel) async throws {
        guard !isBusy else { throw StoreError.busy }
        isBusy = true
        defer {
            isBusy = false
            statusText = ""
            progress = nil
            revision += 1
        }
        try await AudioRuntime.shared.ensureInstalled { [weak self] text in
            if !text.isEmpty { self?.statusText = text }
        }
        guard !isDownloaded(model) else { return }
        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.modelsDir, withIntermediateDirectories: true)
        let partial = Self.partialDir(model)
        let have = fm.fileExists(atPath: partial) ? await Self.size(partial) : 0
        let needed = max(0, model.downloadBytes - have)
        if let free = DiskUsage.freeSpace(at: Self.modelsDir), free < needed + (1 << 30) {
            throw StoreError.diskFull(needed: needed, free: free)
        }
        statusText = String(format: NSLocalizedString("Downloading %@…", comment: ""), model.displayName)
        progress = model.downloadFraction(bytesOnDisk: have)
        // What's on disk so far, once a second (snapshot_download reports
        // nothing we could read).
        let watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let bytes = await Self.size(partial)
                guard !Task.isCancelled, let self, self.isBusy else { return }
                self.progress = model.downloadFraction(bytesOnDisk: bytes)
            }
        }
        defer { watch.cancel() }
        try await AudioRuntime.shared.snapshotDownload(repo: model.repo, into: partial)
        // huggingface_hub's own bookkeeping isn't part of the model.
        try? fm.removeItem(atPath: partial + "/.cache")
        try fm.moveItem(atPath: partial, toPath: Self.modelDir(model))
    }

    /// The model's files, and a partial download, go.
    func remove(_ model: VoiceLabModel) async throws {
        guard !isBusy else { throw StoreError.busy }
        guard !VoiceLabSession.shared.isActive else { throw StoreError.inUse }
        isBusy = true
        defer { isBusy = false; revision += 1 }
        for dir in [Self.modelDir(model), Self.partialDir(model)] {
            try await ProcessRunner.offMain {
                if FileManager.default.fileExists(atPath: dir) { try FileManager.default.removeItem(atPath: dir) }
            }
        }
    }

    nonisolated private static func size(_ path: String) async -> Int64 {
        (try? await ProcessRunner.offMain { DiskUsage.directorySize(path) }) ?? 0
    }
}
