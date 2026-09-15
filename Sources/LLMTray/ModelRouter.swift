import Foundation

/// Resolves whatever a client puts in a request's `model` field to a local
/// model path -- checked against each model's own remembered alias first
/// (the explicit, intentional mapping), then falling back to matching the
/// model's own directory name, so typing the real folder name works even
/// for a model nobody's bothered to set a custom alias for.
enum ModelRouter {
    static func resolve(modelName: String) -> String? {
        guard !modelName.isEmpty else { return nil }
        let models = ModelDiscovery.scanModels(root: ModelDiscovery.currentModelsRoot())

        if let byAlias = models.first(where: { ModelAliasStore.alias(for: $0.id) == modelName }) {
            return byAlias.path
        }
        if let byName = models.first(where: {
            $0.displayName == modelName || ($0.path as NSString).lastPathComponent == modelName
        }) {
            return byName.path
        }
        return nil
    }
}
