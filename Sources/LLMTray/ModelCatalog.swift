import Combine
import Foundation
import LLMTrayCore

/// The installed models and their aliases -- one shared, observable copy
/// for the popover, Settings, auto-start and the proxy's request routing,
/// which each used to scan the models folder and read aliases on their own
/// (the popover kept a stale alias after a rename in Settings, and the
/// proxy rescanned the disk on every request).
///
/// Rescans when the models folder setting changes and after a Hugging Face
/// download (.modelsDidChange); `rescan()` for everything else.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    @Published private(set) var models: [LocalModel] = []
    /// model id (its path) -> the `model` name API clients use for it.
    @Published private(set) var aliases: [String: String] = [:]
    /// On-disk size of each model folder (bytes), computed in the
    /// background after every rescan -- filled in as it arrives.
    @Published private(set) var sizes: [String: Int64] = [:]
    /// Free space on the models folder's volume (what macOS would make
    /// available for an important download, incl. purgeable space).
    @Published private(set) var freeBytes: Int64?
    var totalBytes: Int64 { sizes.values.reduce(0, +) }
    private(set) var root: String = ModelDiscovery.currentModelsRoot()
    private var observers: [AnyCancellable] = []
    private var usageTask: Task<Void, Never>?
    private var lastMissRescan = Date.distantPast

    private init() {
        rescan()
        observers = [
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, ModelDiscovery.currentModelsRoot() != self.root else { return }
                    self.rescan()
                },
            NotificationCenter.default.publisher(for: .modelsDidChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.rescan() },
        ]
    }

    /// Publishes only what actually changed, so a rescan that finds the
    /// same models doesn't re-render every view observing the catalog.
    func rescan() {
        root = ModelDiscovery.currentModelsRoot()
        let scanned = ModelDiscovery.scanModels(root: root)
        let scannedAliases = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, ModelAliasStore.alias(for: $0.id)) })
        if scanned != models { models = scanned }
        if scannedAliases != aliases { aliases = scannedAliases }
        refreshUsage()
    }

    /// Recomputes model sizes and free space off the main thread.
    func refreshUsage() {
        usageTask?.cancel()
        let paths = models.map(\.path)
        let root = root
        usageTask = Task.detached(priority: .utility) { [weak self] in
            let free = DiskUsage.freeSpace(at: root)
            var sizes: [String: Int64] = [:]
            for path in paths {
                if Task.isCancelled { return }
                sizes[path] = DiskUsage.directorySize(path)
            }
            await MainActor.run { [weak self, sizes] in
                guard let self, !Task.isCancelled else { return }
                if self.freeBytes != free { self.freeBytes = free }
                if self.sizes != sizes { self.sizes = sizes }
            }
        }
    }

    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func format(_ bytes: Int64) -> String { byteFormatter.string(fromByteCount: bytes) }

    func model(id: String?) -> LocalModel? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    func alias(for modelID: String) -> String {
        aliases[modelID] ?? ModelAliasStore.alias(for: modelID)
    }

    func setAlias(_ alias: String, for modelID: String) {
        ModelAliasStore.setAlias(alias, for: modelID)
        aliases[modelID] = ModelAliasStore.alias(for: modelID)
    }

    /// Another installed model already answers to this alias -- then only
    /// one of them is reachable by name.
    func isAliasTaken(_ alias: String, excluding modelID: String) -> Bool {
        models.contains { $0.id != modelID && self.alias(for: $0.id) == alias }
    }

    /// The model a request's `model` field names: an alias first (the
    /// explicit mapping), then the model's own folder or display name, so
    /// the real name works without an alias. The cached list is re-read
    /// when a hit's folder is gone (moved/deleted in Finder -- loading it
    /// would unload the working model for nothing) and on a miss (copied
    /// in by hand), the latter at most every few seconds: a client that
    /// always sends some other name ("gpt-4o") mustn't rescan per request.
    func resolve(modelName: String) -> String? {
        guard !modelName.isEmpty else { return nil }
        if let path = lookup(modelName) {
            if FileManager.default.fileExists(atPath: path + "/config.json") { return path }
            rescan()
            return lookup(modelName)
        }
        guard Date().timeIntervalSince(lastMissRescan) > 5 else { return nil }
        lastMissRescan = Date()
        rescan()
        return lookup(modelName)
    }

    private func lookup(_ name: String) -> String? {
        if let byAlias = models.first(where: { alias(for: $0.id) == name }) {
            return byAlias.path
        }
        return models.first {
            $0.displayName == name || ($0.path as NSString).lastPathComponent == name
        }?.path
    }
}
