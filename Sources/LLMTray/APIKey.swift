import Foundation
import LLMTrayCore
import Network
import Security

/// The API key clients may be asked for (APIKeyCheck): kept in the login
/// Keychain, read once and kept in memory -- the proxy checks it per
/// request.
@MainActor
enum APIKey {
    private static let service = "LLMTray.apiKey"
    private static let account = "key"
    private static var cached: String??

    static var value: String? {
        if let cached { return cached }
        let key = read()
        cached = .some(key)
        return key
    }

    /// The key, made and saved first if there's none yet.
    static func ensure() -> String? {
        if let value { return value }
        return regenerate()
    }

    /// A new key replaces the old one: clients using it stop getting in.
    @discardableResult
    static func regenerate() -> String? {
        let key = APIKeyCheck.generate()
        guard save(key) else { return nil }
        cached = .some(key)
        return key
    }

    private static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    private static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Whether a connection came from this Mac.
    nonisolated static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || (address.asIPv4?.isLoopback ?? false)
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }
}
