import Foundation
import Security

/// The API key a client may be asked for (Settings › Server › Require an
/// API key): off by default; when on, every request to the proxy needs it
/// but the app's own (AppRequestToken) and, unless the user says
/// otherwise, this Mac's.
public enum APIKeyCheck {
    /// The key a request carries: `Authorization: Bearer <key>` (OpenAI
    /// clients) or `x-api-key: <key>` (Anthropic's). Header names are
    /// lowercased by the proxy's parser.
    public static func presented(_ headers: [String: String]) -> String? {
        if let auth = headers["authorization"] {
            let parts = auth.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return headers["x-api-key"]?.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the request may go on.
    /// - `key`: the key in the Keychain; nil while none was made (a
    ///   required key that can't be read refuses every outside request).
    /// - `fromLoopback`: the connection came from this Mac.
    /// - `fromApp`: LLMTray's own request (its chat, the CLI).
    public static func allows(headers: [String: String], key: String?, required: Bool, networkOnly: Bool,
                              fromLoopback: Bool, fromApp: Bool) -> Bool {
        guard required, !fromApp, !(networkOnly && fromLoopback) else { return true }
        guard let key, !key.isEmpty, let given = presented(headers) else { return false }
        return equal(given, key)
    }

    /// Compared in time that doesn't depend on where they differ.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    /// A new key: "llmtray-" and 32 random letters and digits.
    public static func generate() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return "llmtray-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        // 248 of 256 values map evenly onto 62 letters (4 × 62); the rest
        // are drawn again.
        var out = ""
        var pool = bytes[...]
        while out.count < 32 {
            if pool.isEmpty {
                var more = [UInt8](repeating: 0, count: 32)
                _ = SecRandomCopyBytes(kSecRandomDefault, more.count, &more)
                pool = more[...]
            }
            let byte = pool.removeFirst()
            if byte < 248 { out.append(alphabet[Int(byte) % 62]) }
        }
        return "llmtray-" + out
    }

    /// The refusal: Anthropic's shape on its routes, OpenAI's elsewhere.
    public static func unauthorizedBody(route: String) -> [String: Any] {
        let message = "This LLMTray server requires an API key: send it as 'Authorization: Bearer <key>' or 'x-api-key: <key>'. It's in LLMTray's Settings › Server."
        if route.hasPrefix("/v1/messages") {
            return ["type": "error", "error": ["type": "authentication_error", "message": message] as [String: Any]]
        }
        return ["error": ["message": message, "type": "invalid_request_error", "code": "invalid_api_key"] as [String: Any]]
    }
}
