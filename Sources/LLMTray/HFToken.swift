import Foundation
import Security

/// The user's Hugging Face access token, for gated models: kept in the
/// login Keychain, never in a file or the preferences.
enum HFToken {
    private static let service = "LLMTray.huggingface"
    private static let account = "token"

    static var value: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    @discardableResult
    static func set(_ token: String?) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return true }
        var item = baseQuery
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// `request` with the token, for huggingface.co only.
    static func authorize(_ request: inout URLRequest) {
        guard request.url?.host == "huggingface.co", let token = value else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
