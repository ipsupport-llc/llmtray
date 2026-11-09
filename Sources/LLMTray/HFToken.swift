import Foundation
import LLMTrayCore
import Security

/// A token kept in the login Keychain, never in a file or the preferences.
@MainActor
final class KeychainToken {
    private let service: String
    private let account = "token"

    init(service: String) { self.service = service }

    /// Read from the Keychain once, then kept in memory: an unsigned
    /// (ad-hoc) build can make every Keychain read ask the user after an
    /// update, and downloads read it per file.
    private var cached: String??

    var value: String? {
        if let cached { return cached }
        let token = read()
        cached = .some(token)
        return token
    }

    /// Forget what was read: each download reads the Keychain afresh, so a
    /// read the user refused (or a locked keychain) is retried then -- but
    /// not once per file.
    func refresh() { cached = nil }

    private func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Saves (updating one already there, so a failure can't lose it) or,
    /// with nil, removes the token. False if the Keychain refused.
    @discardableResult
    func set(_ token: String?) -> Bool {
        cached = nil   // re-read after any change
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(token.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

/// The user's Hugging Face access token, for gated models.
@MainActor
enum HFToken {
    private static let store = KeychainToken(service: "LLMTray.huggingface")

    static var value: String? { store.value }
    static func refresh() { store.refresh() }
    @discardableResult
    static func set(_ token: String?) -> Bool { store.set(token) }

    /// `request` with the token, for huggingface.co only.
    static func authorize(_ request: inout URLRequest) {
        guard request.url?.host == "huggingface.co", let token = value else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

/// The user's Kaggle API token, for gated or private Kaggle models only
/// (public ones download without it): a new-style access token (Bearer),
/// or the legacy "username:key" pair from kaggle.json (Basic).
@MainActor
enum KaggleToken {
    private static let store = KeychainToken(service: "LLMTray.kaggle")

    static var value: String? { store.value }
    static func refresh() { store.refresh() }
    @discardableResult
    static func set(_ token: String?) -> Bool { store.set(token) }

    /// The Authorization header for `token`.
    nonisolated static func header(_ token: String) -> String {
        if token.contains(":") { return "Basic " + Data(token.utf8).base64EncodedString() }
        return "Bearer " + token
    }

    /// `request` with the token, for www.kaggle.com only (never the signed
    /// storage links it redirects to).
    static func authorize(_ request: inout URLRequest) {
        guard request.url?.host == Kaggle.host, request.url?.scheme == "https", let token = value else { return }
        request.setValue(header(token), forHTTPHeaderField: "Authorization")
    }
}
