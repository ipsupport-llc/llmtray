import Foundation
import LLMTrayCore

/// Chatterbox's files for spoken answers (adr/0016): the model with its
/// built-in voice, the speech tokenizer and the Russian stress pack, each
/// a folder in the models folder. Nothing downloads until the user asks;
/// each goes to `<folder>.partial` first, so a stopped download continues,
/// and is moved into place only when complete.
@MainActor
final class SpokenVoiceStore: ObservableObject {
    static let shared = SpokenVoiceStore()

    enum StoreError: LocalizedError {
        case busy
        case inUse
        case diskFull(needed: Int64, free: Int64)

        var errorDescription: String? {
            switch self {
            case .busy:
                return NSLocalizedString("The voice is being downloaded -- try again once it's done.", comment: "spoken answers")
            case .inUse:
                return NSLocalizedString("Stop reading the answer first.", comment: "spoken answers")
            case .diskFull(let needed, let free):
                return String(format: NSLocalizedString("Not enough disk space: the voice needs %1$@, %2$@ is free.", comment: "needed, free"),
                              ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
                              ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            }
        }
    }

    @Published private(set) var isBusy = false
    @Published private(set) var statusText = ""
    /// 0...1 while files download; nil otherwise.
    @Published private(set) var progress: Double?
    /// Bumped when files arrive or go (views re-read the disk).
    @Published private(set) var revision = 0
    /// Bytes of the folders this download already moved into place.
    private var finishedBytes: Int64 = 0

    private init() {}

    nonisolated static func path(_ file: SpokenVoiceFile) -> String { MediaModels.path(MediaModels.entry(file)) }

    nonisolated static func isInPlace(_ file: SpokenVoiceFile) -> Bool {
        guard MediaModels.isInstalled(MediaModels.entry(file)) else { return false }
        let dir = path(file)
        let fm = FileManager.default
        switch file {
        case .model:
            // What the loader reads; conds.safetensors is the built-in voice.
            return ["model.safetensors", "config.json", "tokenizer.json", "Cangjie5_TC.json", "conds.safetensors"]
                .allSatisfy { fm.fileExists(atPath: dir + "/" + $0) }
        case .tokenizer:
            return fm.fileExists(atPath: dir + "/model.safetensors")
        case .russianStress:
            return fm.fileExists(atPath: dir + "/" + SpokenVoiceFile.russianStressStamp)
        default:
            return true
        }
    }

    /// Everything Chatterbox needs is on disk.
    nonisolated static var isReady: Bool { SpokenVoiceFile.folders.allSatisfy(isInPlace) }

    /// Something is on disk (for Remove), complete or not.
    var hasAnything: Bool {
        _ = revision
        let fm = FileManager.default
        return SpokenVoiceFile.folders.contains {
            MediaModels.isInstalled(MediaModels.entry($0)) || fm.fileExists(atPath: Self.partialDir($0))
        }
    }

    var hasPartialDownload: Bool {
        _ = revision
        return SpokenVoiceFile.folders.contains { FileManager.default.fileExists(atPath: Self.partialDir($0)) }
    }

    nonisolated private static func size(_ path: String) async -> Int64 {
        (try? await ProcessRunner.offMain { DiskUsage.directorySize(path) }) ?? 0
    }

    static func partialDir(_ file: SpokenVoiceFile) -> String { MediaModels.downloadPath(MediaModels.entry(file)) + ".partial" }

    /// The audio runtime when it isn't installed yet, then each missing folder.
    func download() async throws {
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
        try MediaModels.checkModelsFolder()
        let missing = SpokenVoiceFile.folders.filter { !Self.isInPlace($0) }
        guard !missing.isEmpty else { return }
        finishedBytes = 0
        let fm = FileManager.default
        let total = missing.reduce(Int64(0)) { $0 + $1.downloadBytes }
        var have: Int64 = 0
        for file in missing where fm.fileExists(atPath: Self.partialDir(file)) {
            have += await Self.size(Self.partialDir(file))
        }
        if let free = DiskUsage.freeSpace(at: (Self.partialDir(missing[0]) as NSString).deletingLastPathComponent),
           free < max(0, total - have) + (1 << 30) {
            throw StoreError.diskFull(needed: max(0, total - have), free: free)
        }
        // What's on disk so far, once a second.
        // Folders done so far count with what the current one holds.
        let partials = missing.map(Self.partialDir)
        let watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                var bytes: Int64 = 0
                for dir in partials { bytes += await Self.size(dir) }
                guard !Task.isCancelled, let self, self.isBusy else { return }
                self.progress = min(0.99, Double(self.finishedBytes + bytes) / Double(max(1, total)))
            }
        }
        defer { watch.cancel() }
        for file in missing {
            let partial = Self.partialDir(file)
            try fm.createDirectory(atPath: partial, withIntermediateDirectories: true)
            statusText = String(format: NSLocalizedString("Downloading %@…", comment: ""), file.name)
            switch file {
            case .russianStress:
                try await AudioRuntime.shared.buildRussianStress(into: partial)
            default:
                try await AudioRuntime.shared.snapshotDownload(repo: file.repo, patterns: file.patterns, into: partial)
            }
            // huggingface_hub's own bookkeeping isn't part of the files.
            try? fm.removeItem(atPath: partial + "/.cache")
            let entry = MediaModels.entry(file)
            try MediaModels.clearIncompleteTarget(entry)
            try fm.moveItem(atPath: partial, toPath: MediaModels.downloadPath(entry))
            MediaModels.didDownload()
            finishedBytes += file.downloadBytes
        }
    }

    /// Every folder, and partial downloads, go to the Trash.
    func remove() async throws {
        guard !isBusy else { throw StoreError.busy }
        guard !SpokenAnswers.shared.isRunnerActive else { throw StoreError.inUse }
        isBusy = true
        defer { isBusy = false; revision += 1 }
        let fm = FileManager.default
        for file in SpokenVoiceFile.folders {
            if fm.fileExists(atPath: Self.partialDir(file)) {
                try fm.trashItem(at: URL(fileURLWithPath: Self.partialDir(file)), resultingItemURL: nil)
            }
            if MediaModels.isInstalled(MediaModels.entry(file)) {
                try ModelCatalog.shared.removeMedia(MediaModels.entry(file))
            }
        }
        if SpokenAnswers.shared.voiceKind == .chatterbox { SpokenAnswers.shared.voiceKind = .system }
    }
}
