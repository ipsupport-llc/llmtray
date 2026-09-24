import Combine
import Foundation

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
    private(set) var root: String = ModelDiscovery.currentModelsRoot()
    private var observers: [AnyCancellable] = []

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

    func rescan() {
        root = ModelDiscovery.currentModelsRoot()
        models = ModelDiscovery.scanModels(root: root)
        aliases = Dictionary(uniqueKeysWithValues: models.map { ($0.id, ModelAliasStore.alias(for: $0.id)) })
    }

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
    /// the real name works without an alias. A name not found triggers one
    /// rescan (a model copied in by hand since the last scan).
    func resolve(modelName: String) -> String? {
        guard !modelName.isEmpty else { return nil }
        if let path = lookup(modelName) { return path }
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
