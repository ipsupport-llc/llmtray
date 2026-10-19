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
    private static var cached: String?
    /// The last read that found nothing, or failed: tried again after a
    /// while (a locked Keychain opens), not on every request.
    private static var lastMiss: Date?
    /// The last read failed for another reason than "no key" (a locked or
    /// refused Keychain): Settings says so, and no new key replaces it.
    private(set) static var unreadable = false

    static var value: String? {
        if let cached { return cached }
        if let lastMiss, Date().timeIntervalSince(lastMiss) < 10 { return nil }
        switch read() {
        case .success(let key):
            cached = key
            lastMiss = nil
            unreadable = false
            return key
        case .failure(let error):
            lastMiss = Date()
            unreadable = error.status != errSecItemNotFound
            return nil
        }
    }

    /// Read again now (Settings opened).
    static func refresh() {
        cached = nil
        lastMiss = nil
    }

    /// The key, made and saved first if there's none yet -- never over one
    /// that's there but can't be read now.
    static func ensure() -> String? {
        refresh()
        if let value { return value }
        guard !unreadable else { return nil }
        return regenerate()
    }

    /// A new key replaces the old one: clients using it stop getting in.
    @discardableResult
    static func regenerate() -> String? {
        let key = APIKeyCheck.generate()
        guard save(key) else { return nil }
        cached = key
        lastMiss = nil
        unreadable = false
        return key
    }

    private struct ReadError: Error { let status: OSStatus }

    private static func read() -> Result<String, ReadError> {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return .failure(ReadError(status: status == errSecSuccess ? errSecItemNotFound : status)) }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? .failure(ReadError(status: errSecItemNotFound)) : .success(key)
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

    /// Whether a connection came from this Mac: a loopback address, or
    /// one of its own (an app using the Mac's LAN address or .local name).
    nonisolated static func isThisMac(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback || LocalAddresses.current().contains(address.rawValue)
        case .ipv6(let address):
            if address.isLoopback { return true }
            if let v4 = address.asIPv4 { return v4.isLoopback || LocalAddresses.current().contains(v4.rawValue) }
            return LocalAddresses.current().contains(address.rawValue)
        case .name: return false
        @unknown default: return false
        }
    }
}

/// This Mac's own interface addresses (getifaddrs), raw bytes, read again
/// at most every few seconds (a network change brings new ones).
enum LocalAddresses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (at: Date, addresses: Set<Data>)?

    static func current() -> Set<Data> {
        lock.lock()
        defer { lock.unlock() }
        if let cache, Date().timeIntervalSince(cache.at) < 5 { return cache.addresses }
        var addresses = Set<Data>()
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let entry = p {
                if let sa = entry.pointee.ifa_addr {
                    switch Int32(sa.pointee.sa_family) {
                    case AF_INET:
                        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                            var a = sin.pointee.sin_addr
                            addresses.insert(Data(bytes: &a, count: MemoryLayout<in_addr>.size))
                        }
                    case AF_INET6:
                        sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                            var a = sin6.pointee.sin6_addr
                            addresses.insert(Data(bytes: &a, count: MemoryLayout<in6_addr>.size))
                        }
                    default: break
                    }
                }
                p = entry.pointee.ifa_next
            }
            freeifaddrs(first)
        }
        cache = (Date(), addresses)
        return addresses
    }
}
