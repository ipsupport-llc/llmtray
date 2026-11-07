import Foundation
import LLMTrayCore

/// The models a voice conversation listens with (adr/0031): Silero VAD,
/// Smart Turn, and the picked recognizer's weights, each a folder in the
/// models folder. Nothing downloads until the user asks; each goes to
/// `<folder>.partial` first and is moved into place when complete.
@MainActor
final class VoiceInputStore: ObservableObject {
    static let shared = VoiceInputStore()

    @Published var recognizer: VoiceRecognizer {
        didSet { UserDefaults.standard[Pref.voiceRecognizer] = recognizer.rawValue }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = ""
    @Published private(set) var progress: Double?
    @Published private(set) var revision = 0
    private var finishedBytes: Int64 = 0

    private init() {
        recognizer = VoiceRecognizer(rawValue: UserDefaults.standard[Pref.voiceRecognizer]) ?? .parakeet
    }

    nonisolated static func path(_ file: VoiceInputFile) -> String { MediaModels.path(MediaModels.entry(file)) }

    nonisolated static func isInPlace(_ file: VoiceInputFile) -> Bool {
        MediaModels.isInstalled(MediaModels.entry(file))
            && FileManager.default.fileExists(atPath: path(file) + "/" + file.marker)
    }

    /// Everything the picked recognizer needs is on disk.
    var isReady: Bool {
        _ = revision
        return VoiceInputFile.needed(for: recognizer).allSatisfy(Self.isInPlace)
    }

    func missingBytes(for recognizer: VoiceRecognizer) -> Int64 {
        VoiceInputFile.needed(for: recognizer).filter { !Self.isInPlace($0) }.reduce(0) { $0 + $1.downloadBytes }
    }

    static func partialDir(_ file: VoiceInputFile) -> String { MediaModels.downloadPath(MediaModels.entry(file)) + ".partial" }

    nonisolated private static func size(_ path: String) async -> Int64 {
        (try? await ProcessRunner.offMain { DiskUsage.directorySize(path) }) ?? 0
    }

    /// The audio runtime when it isn't installed yet, then each missing folder.
    func download() async throws {
        guard !isBusy else { throw SpokenVoiceStore.StoreError.busy }
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
        let missing = VoiceInputFile.needed(for: recognizer).filter { !Self.isInPlace($0) }
        guard !missing.isEmpty else { return }
        let fm = FileManager.default
        let total = missing.reduce(Int64(0)) { $0 + $1.downloadBytes }
        if let free = DiskUsage.freeSpace(at: (Self.partialDir(missing[0]) as NSString).deletingLastPathComponent),
           free < total + (1 << 30) {
            throw SpokenVoiceStore.StoreError.diskFull(needed: total, free: free)
        }
        finishedBytes = 0
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
            try await AudioRuntime.shared.snapshotDownload(repo: file.repo, patterns: file.patterns, into: partial)
            if let extra = file.extraRepo {
                try await AudioRuntime.shared.snapshotDownload(repo: extra, patterns: file.extraPatterns, into: partial)
            }
            try? fm.removeItem(atPath: partial + "/.cache")
            let entry = MediaModels.entry(file)
            try MediaModels.clearIncompleteTarget(entry)
            try fm.moveItem(atPath: partial, toPath: MediaModels.downloadPath(entry))
            MediaModels.didDownload()
            finishedBytes += file.downloadBytes
        }
    }

    /// The recognizer weights not in use go to the Trash (turn-taking stays).
    func remove(_ recognizer: VoiceRecognizer) async throws {
        guard !isBusy else { throw SpokenVoiceStore.StoreError.busy }
        guard !VoiceConversation.shared.isActive else { throw SpokenVoiceStore.StoreError.inUse }
        isBusy = true
        defer { isBusy = false; revision += 1 }
        let file: VoiceInputFile?
        switch recognizer {
        case .parakeet: file = .parakeet
        case .whisper: file = .whisper
        case .apple: file = nil
        }
        if let file, MediaModels.isInstalled(MediaModels.entry(file)) {
            try ModelCatalog.shared.removeMedia(MediaModels.entry(file))
        }
    }
}
