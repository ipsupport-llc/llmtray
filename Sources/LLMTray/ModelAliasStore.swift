import Foundation

/// Per-model --model-alias values, keyed by the model's disk path (the
/// same ID ModelDiscovery/LocalModel already use). A single global alias
/// meant "switch models, forget to update the alias, and whatever tool
/// you've got pointed at the old alias silently starts talking to the
/// wrong model" -- this remembers one alias per model instead.
enum ModelAliasStore {
    private static let key = "llmtray.modelAliases"
    static let defaultAlias = "n"

    static func alias(for modelID: String) -> String {
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return dict[modelID] ?? defaultAlias
    }

    static func setAlias(_ alias: String, for modelID: String) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        dict[modelID] = alias
        UserDefaults.standard.set(dict, forKey: key)
    }
}
