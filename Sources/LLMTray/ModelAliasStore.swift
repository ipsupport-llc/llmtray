import Foundation

/// Per-model --model-alias values, keyed by the model's disk path (the
/// same ID ModelDiscovery/LocalModel already use). A single shared
/// default meant "switch models, forget to set an alias, and every model
/// answers to the exact same generic name" -- the default is now each
/// model's own directory name instead, which is meaningful and (in
/// virtually every real case) already unique without the user ever having
/// to type anything.
enum ModelAliasStore {
    private static let key = "llmtray.modelAliases"

    static func defaultAlias(for modelID: String) -> String {
        (modelID as NSString).lastPathComponent
    }

    static func alias(for modelID: String) -> String {
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return dict[modelID] ?? defaultAlias(for: modelID)
    }

    static func setAlias(_ alias: String, for modelID: String) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        dict[modelID] = alias
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// A removed model's alias: a model installed at the same path later
    /// starts from its own default again.
    static func forget(_ modelID: String) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard dict.removeValue(forKey: modelID) != nil else { return }
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// True if some *other* model already resolves to this exact alias --
    /// two models sharing one alias means only whichever the client's
    /// `model` field happens to route to "wins," and the other becomes
    /// unreachable by name until someone notices and renames it.
    static func isAliasTaken(_ alias: String, excluding modelID: String, among allModelIDs: [String]) -> Bool {
        allModelIDs.contains { otherID in
            otherID != modelID && self.alias(for: otherID) == alias
        }
    }
}
