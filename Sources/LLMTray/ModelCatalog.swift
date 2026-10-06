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
    /// Each model's weights (its .safetensors) and this Mac's GPU limit,
    /// for the "barely fits the GPU" notice (fit(for:)); refreshed with the
    /// sizes, so a limit raised with sysctl shows at the next rescan.
    @Published private(set) var weights: [String: Int64] = [:]
    @Published private(set) var hardware: HardwareInfo?
    /// When each model was last loaded or sent a request (ModelUsageStore),
    /// for the Models list.
    @Published private(set) var lastUsed: [String: Date] = [:]
    /// Each installed image, music and voice model's size (by repo), in
    /// the models folder or the app's old one -- with the chat models'.
    @Published private(set) var mediaSizes: [String: Int64] = [:]
    var totalBytes: Int64 { sizes.values.reduce(0, +) + mediaSizes.values.reduce(0, +) }
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
        let scanned = ModelDiscovery.scanModels(root: root, downloading: DownloadQueue.fetchingChatModel)
        let scannedAliases = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, ModelAliasStore.alias(for: $0.id)) })
        if scanned != models { models = scanned }
        if scannedAliases != aliases { aliases = scannedAliases }
        let usage = ModelUsageStore()
        let used = Dictionary(uniqueKeysWithValues: scanned.compactMap { m in usage.lastUsed(m.id).map { (m.id, $0) } })
        if used != lastUsed { lastUsed = used }
        // Every rescan goes through here: the model card reads each model's
        // capabilities again (its next render, or the sizes landing).
        ModelCapabilities.invalidate()
        refreshUsage()
    }

    /// Recomputes model sizes and free space off the main thread.
    func refreshUsage() {
        usageTask?.cancel()
        let paths = models.map(\.path)
        let media = MediaModels.all.filter(MediaModels.isInstalled).map { ($0.repo, MediaModels.path($0)) }
        let root = root
        usageTask = Task.detached(priority: .utility) { [weak self] in
            let free = DiskUsage.freeSpace(at: root)
            let hardware = HardwareProbe.current()
            var sizes: [String: Int64] = [:]
            var weights: [String: Int64] = [:]
            for path in paths {
                if Task.isCancelled { return }
                sizes[path] = DiskUsage.directorySize(path)
                weights[path] = ModelWeights.bytes(inFolder: path)
            }
            var mediaSizes: [String: Int64] = [:]
            for (repo, path) in media {
                if Task.isCancelled { return }
                mediaSizes[repo] = DiskUsage.directorySize(path)
            }
            await MainActor.run { [weak self, sizes, weights, mediaSizes] in
                guard let self, !Task.isCancelled else { return }
                if self.mediaSizes != mediaSizes { self.mediaSizes = mediaSizes }
                if self.freeBytes != free { self.freeBytes = free }
                if self.sizes != sizes { self.sizes = sizes }
                if self.weights != weights { self.weights = weights }
                if self.hardware != hardware { self.hardware = hardware }
            }
        }
    }

    /// The model was loaded or sent a request (at most one write a minute).
    func recordUse(_ modelID: String?) {
        guard let modelID, ModelUsageStore().record(modelID) else { return }
        lastUsed[modelID] = ModelUsageStore().lastUsed(modelID)
    }

    /// Moves an installed model's folder to the Trash (an emptied <org>/
    /// folder with it) and forgets what LLMTray kept about it: its alias,
    /// profile assignment, last use, and the chat's selection of it. The
    /// caller makes sure it isn't loaded.
    func remove(_ model: LocalModel) throws {
        let download = HFModelBrowser.activeDownload.map { root + "/" + $0 }
        if let download, ModelRemoval.isSameOrInside(download, model.path) {
            throw ModelRemoval.Refusal.downloading
        }
        let url = try ModelRemoval.check(modelPath: model.path, root: root)
        let fm = FileManager.default
        try fm.trashItem(at: url, resultingItemURL: nil)
        // An emptied <org>/ folder, unless a download is filling it.
        for dir in ModelRemoval.emptyParents(of: url, root: root) where download.map({ !ModelRemoval.isSameOrInside($0, dir.path) }) ?? true {
            try? fm.trashItem(at: dir, resultingItemURL: nil)
        }
        ModelAliasStore.forget(model.id)
        ProfileManager.shared.assign(profileID: Profile.defaultID, to: model.id)
        ModelUsageStore().forget(model.id)
        if UserDefaults.standard[Pref.selectedModelID] == model.id { UserDefaults.standard[Pref.selectedModelID] = nil }
        rescan()
    }

    /// Moves an image, music or voice model to the Trash: from the models
    /// folder (checked like a chat model's, no config.json needed) or the
    /// app's old folder. Not while its generator works or downloads.
    func removeMedia(_ entry: MediaModels.Entry) throws {
        let busy: Bool
        switch entry.kind {
        case .image: busy = ChatTabs.shared.mflux.isBusy
        case .music: busy = ChatTabs.shared.music.isBusy
        case .voice: busy = VoiceModelStore.shared.isBusy || VoiceLabSession.shared.isActive
        }
        guard !busy else { throw ModelRemoval.Refusal.inUse }
        let path = MediaModels.path(entry)
        if let download = HFModelBrowser.activeDownload.map({ root + "/" + $0 }), ModelRemoval.isSameOrInside(download, path) {
            throw ModelRemoval.Refusal.downloading
        }
        let fm = FileManager.default
        if path != MediaModelLocation.preferred(repo: entry.repo, root: root) {
            // An earlier models folder's copy, or the app's own folder's.
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } else {
            let url = try ModelRemoval.check(modelPath: path, root: root, requireConfig: false)
            try fm.trashItem(at: url, resultingItemURL: nil)
            for dir in ModelRemoval.emptyParents(of: url, root: root) {
                try? fm.trashItem(at: dir, resultingItemURL: nil)
            }
        }
        refreshUsage()
    }

    /// The model barely fits the GPU (GPUFit), or nil: fits, or not
    /// measured yet.
    func fit(for modelID: String?) -> GPUFit? {
        guard let modelID, let bytes = weights[modelID], let hardware else { return nil }
        return GPUFit(weightsBytes: bytes, hardware: hardware)
    }

    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func format(_ bytes: Int64) -> String { byteFormatter.string(fromByteCount: bytes) }

    private static func canonical(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).resolvingSymlinksInPath
    }

    /// The `model` name requests use for a model: its alias, or its folder
    /// name when the alias was cleared.
    func requestName(for modelID: String) -> String {
        let alias = alias(for: modelID)
        return alias.isEmpty ? (modelID as NSString).lastPathComponent : alias
    }

    /// The name each model is requested by, for the proxy's /v1/models.
    var servedNames: [String] { models.map { requestName(for: $0.id) } }

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
        // An alias set in Settings wins over another model's folder name.
        if let byAlias = models.first(where: { alias(for: $0.id) == name }) {
            return byAlias.path
        }
        // A full path ("/Users/.../publisher/model", "~/..."): only a model
        // in the catalog, i.e. inside the models folder -- a client must not
        // get any directory on disk loaded.
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let wanted = Self.canonical(name)
            return models.first { Self.canonical($0.path) == wanted }?.path
        }
        return models.first {
            $0.displayName == name || ($0.path as NSString).lastPathComponent == name
        }?.path
    }
}
