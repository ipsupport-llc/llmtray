import CryptoKit
import Foundation

/// Signing in to a web MCP server (adr/0028): the MCP Authorization spec
/// as a native app (RFC 8252), a public client. Pure parts -- discovery
/// URLs, the checks, PKCE, the requests -- and the network steps behind a
/// fetcher the tests replace.
public enum MCPOAuth {
    public enum Failure: Error, Equatable, LocalizedError {
        case noMetadata
        case resourceMismatch
        case issuerMismatch
        case noS256
        case insecureURL
        case noRegistration
        case confidentialRegistration
        case mixUpRisk
        case badCallback(String)
        case denied(String)
        case token(String)
        case invalidGrant
        case invalidClient

        public var errorDescription: String? {
            switch self {
            case .noMetadata: return "it doesn't say how to sign in"
            case .resourceMismatch: return "its sign-in information names another server"
            case .issuerMismatch: return "its sign-in server's information doesn't match it"
            case .noS256: return "it doesn't support a safe sign-in (PKCE S256)"
            case .insecureURL: return "its sign-in addresses aren't https"
            case .noRegistration: return "it signs in a way LLMTray doesn't support yet (no client registration)"
            case .confidentialRegistration: return "it registered LLMTray as a client with a secret, which an app can't keep"
            case .mixUpRisk: return "its sign-in can't be told apart from another server's safely"
            case .badCallback(let why): return "the sign-in came back wrong (\(why))"
            case .denied(let why): return "the sign-in was refused (\(why))"
            case .token(let why): return "the sign-in server refused the token request (\(why))"
            case .invalidGrant: return "the sign-in expired: sign in again"
            case .invalidClient: return "the sign-in server no longer knows LLMTray"
            }
        }
    }

    /// Our client id where servers take a Client ID Metadata Document.
    public static let clientMetadataURL = "https://ipsupport.us/llmtray/oauth-client.json"

    // MARK: Canonical URLs

    /// Scheme and host lowercased, default port dropped, query and fragment
    /// dropped, a lone trailing slash on the root ignored (adr/0028).
    public static func canonical(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
        c.query = nil
        c.fragment = nil
        if c.path == "/" { c.path = "" }
        return c.string ?? url.absoluteString
    }

    public static func canonical(_ text: String) -> String? {
        URL(string: text).map(canonical)
    }

    /// Whether a token for `resource` may go to `server`: the same canonical
    /// URL, or `resource` is the root of the server's own origin.
    public static func covers(resource: String, server: URL) -> Bool {
        guard let r = canonical(resource) else { return false }
        if r == canonical(server) { return true }
        var root = URLComponents(url: server, resolvingAgainstBaseURL: false)
        root?.path = ""
        root?.query = nil
        return root?.url.map(canonical) == r
    }

    // MARK: Challenge

    public struct Challenge: Equatable {
        public var resourceMetadata: URL?
        public var scope: String?
        public var error: String?

        public init(resourceMetadata: URL? = nil, scope: String? = nil, error: String? = nil) {
            self.resourceMetadata = resourceMetadata
            self.scope = scope
            self.error = error
        }
    }

    /// A `WWW-Authenticate: Bearer …` header's parameters.
    public static func parseChallenge(_ header: String?) -> Challenge? {
        guard let header, header.lowercased().hasPrefix("bearer") else { return nil }
        var params: [String: String] = [:]
        var rest = Substring(header.dropFirst(6))
        while let eq = rest.firstIndex(of: "=") {
            let key = rest[..<eq].trimmingCharacters(in: CharacterSet(charactersIn: " ,")).lowercased()
            rest = rest[rest.index(after: eq)...]
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                if let end = rest.firstIndex(of: "\"") {
                    value = String(rest[..<end])
                    rest = rest[rest.index(after: end)...]
                }
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end].trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
            params[key] = value
        }
        return Challenge(resourceMetadata: params["resource_metadata"].flatMap(URL.init(string:)),
                         scope: params["scope"], error: params["error"])
    }

    // MARK: Protected resource metadata (RFC 9728)

    public enum LookupKind { case header, pathInserted, root }

    /// Where to look, in order: the challenge's URL, the path-inserted
    /// well-known URL, the root one.
    public static func resourceMetadataURLs(server: URL, challenge: Challenge?) -> [(URL, LookupKind)] {
        var out: [(URL, LookupKind)] = []
        if let header = challenge?.resourceMetadata { out.append((header, .header)) }
        guard let c = URLComponents(url: server, resolvingAgainstBaseURL: false), let scheme = c.scheme, let host = c.host else { return out }
        let origin = "\(scheme)://\(host)\(c.port.map { ":\($0)" } ?? "")"
        let path = c.path == "/" ? "" : c.path
        if !path.isEmpty, let u = URL(string: origin + "/.well-known/oauth-protected-resource" + path) { out.append((u, .pathInserted)) }
        if let u = URL(string: origin + "/.well-known/oauth-protected-resource") { out.append((u, .root)) }
        return out
    }

    public struct ResourceMetadata: Equatable {
        public var resource: String
        public var authorizationServers: [URL]
        public var scopesSupported: [String]
    }

    /// The metadata, checked: its resource equals the server's canonical URL
    /// (or its origin for the root lookup), every authorization server https.
    public static func resourceMetadata(_ data: Data, server: URL, kind: LookupKind) throws -> ResourceMetadata {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let resource = o["resource"] as? String, let servers = o["authorization_servers"] as? [String], !servers.isEmpty
        else { throw Failure.noMetadata }
        let expected: String
        switch kind {
        case .header, .pathInserted: expected = canonical(server)
        case .root:
            var c = URLComponents(url: server, resolvingAgainstBaseURL: false)
            c?.path = ""
            expected = c?.url.map(canonical) ?? canonical(server)
        }
        // Exact, or the root of the server's own origin (servers that name
        // their whole host -- the same trust domain); never another path or host.
        var root = URLComponents(url: server, resolvingAgainstBaseURL: false)
        root?.path = ""
        let originRoot = root?.url.map(canonical)
        guard canonical(resource) == expected || canonical(resource) == canonical(server) || canonical(resource) == originRoot
        else { throw Failure.resourceMismatch }
        let urls = servers.compactMap(URL.init(string:))
        guard !urls.isEmpty, urls.allSatisfy({ $0.scheme?.lowercased() == "https" }) else { throw Failure.insecureURL }
        return ResourceMetadata(resource: resource, authorizationServers: urls, scopesSupported: o["scopes_supported"] as? [String] ?? [])
    }

    // MARK: Authorization server metadata (RFC 8414, OIDC)

    /// For an issuer with a path: OAuth path-inserted, OIDC path-inserted,
    /// OIDC appended; without one: OAuth, then OIDC at the root.
    public static func serverMetadataURLs(issuer: URL) -> [URL] {
        guard let c = URLComponents(url: issuer, resolvingAgainstBaseURL: false), let scheme = c.scheme, let host = c.host else { return [] }
        let origin = "\(scheme)://\(host)\(c.port.map { ":\($0)" } ?? "")"
        let path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        if path.isEmpty {
            return [origin + "/.well-known/oauth-authorization-server", origin + "/.well-known/openid-configuration"].compactMap(URL.init(string:))
        }
        return [origin + "/.well-known/oauth-authorization-server" + path,
                origin + "/.well-known/openid-configuration" + path,
                origin + path + "/.well-known/openid-configuration"].compactMap(URL.init(string:))
    }

    public struct ServerMetadata: Equatable, Codable, Sendable {
        public var issuer: String
        public var authorizationEndpoint: URL
        public var tokenEndpoint: URL
        public var registrationEndpoint: URL?
        public var revocationEndpoint: URL?
        public var acceptsClientMetadataDocument: Bool
        public var sendsIssInResponse: Bool
    }

    /// The metadata, checked: `issuer` equals the issuer asked for, S256
    /// listed, every endpoint https.
    public static func serverMetadata(_ data: Data, issuer: URL) throws -> ServerMetadata {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let iss = o["issuer"] as? String,
              let auth = (o["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (o["token_endpoint"] as? String).flatMap(URL.init(string:))
        else { throw Failure.noMetadata }
        guard canonical(iss) == canonical(issuer) else { throw Failure.issuerMismatch }
        guard (o["code_challenge_methods_supported"] as? [String] ?? []).contains("S256") else { throw Failure.noS256 }
        let registration = (o["registration_endpoint"] as? String).flatMap(URL.init(string:))
        let revocation = (o["revocation_endpoint"] as? String).flatMap(URL.init(string:))
        for url in [auth, token] + [registration, revocation].compactMap({ $0 }) where url.scheme?.lowercased() != "https" {
            throw Failure.insecureURL
        }
        return ServerMetadata(issuer: iss, authorizationEndpoint: auth, tokenEndpoint: token, registrationEndpoint: registration,
                              revocationEndpoint: revocation,
                              acceptsClientMetadataDocument: o["client_id_metadata_document_supported"] as? Bool ?? false,
                              sendsIssInResponse: o["authorization_response_iss_parameter_supported"] as? Bool ?? false)
    }

    // MARK: Registration

    public enum Registration: String, Codable, Sendable { case metadataDocument, dynamic, manual }

    /// The callback path: per issuer for a dynamic registration (mix-up
    /// defence without `iss`), plain otherwise.
    public static func callbackPath(issuer: String, registration: Registration) -> String {
        guard registration != .metadataDocument else { return "/callback" }
        let hash = SHA256.hash(data: Data((canonical(issuer) ?? issuer).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "/callback/\(hash)"
    }

    /// Whether this issuer may be signed in to without being confused with
    /// another (adr/0028): `iss` in the response, or a per-issuer callback,
    /// or (a metadata document, no `iss`) its endpoints on its own origin.
    public static func mixUpSafe(_ m: ServerMetadata, registration: Registration) -> Bool {
        if m.sendsIssInResponse || registration != .metadataDocument { return true }
        guard let issuer = URL(string: m.issuer) else { return false }
        func origin(_ u: URL) -> String {
            let scheme = u.scheme?.lowercased() ?? ""
            return "\(scheme)://\(u.host?.lowercased() ?? ""):\(u.port ?? (scheme == "http" ? 80 : 443))"
        }
        return origin(m.authorizationEndpoint) == origin(issuer) && origin(m.tokenEndpoint) == origin(issuer)
    }

    /// The loopback port of a client the user registered themselves: fixed,
    /// so the redirect URL they register stays the same.
    public static let manualPort: UInt16 = 33418

    /// The redirect URL to register for a client of one's own.
    public static func manualRedirectURI(issuer: String) -> String {
        "http://127.0.0.1:\(manualPort)\(callbackPath(issuer: issuer, registration: .manual))"
    }

    /// RFC 7591: a public native client.
    public static func registrationRequest(redirectPath: String) -> Data {
        let body: [String: Any] = [
            "client_name": "LLMTray",
            "redirect_uris": ["http://127.0.0.1\(redirectPath)"],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// The registration's client id; a confidential one is refused.
    public static func registeredClientID(_ data: Data) throws -> String {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = o["client_id"] as? String, !id.isEmpty
        else { throw Failure.noRegistration }
        if o["client_secret"] != nil || ((o["token_endpoint_auth_method"] as? String).map { $0 != "none" } ?? false) {
            throw Failure.confidentialRegistration
        }
        return id
    }

    // MARK: PKCE, state, the authorization URL

    public static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        precondition(status == errSecSuccess, "no secure random bytes")
        return base64url(data)
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public struct PKCE: Equatable {
        public let verifier: String
        public var challenge: String { MCPOAuth.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
        public init(verifier: String = MCPOAuth.randomURLSafe(48)) { self.verifier = verifier }
    }

    /// One sign-in under way: everything its callback and token exchange are
    /// held to.
    public struct Flow: Equatable {
        public let issuer: String
        public let metadata: ServerMetadata
        public let clientID: String
        public let registration: Registration
        public let resource: String
        public let scope: String?
        public let redirectURI: String
        public let state: String
        public let pkce: PKCE
        /// A client the user registered with a secret (their own app): sent
        /// to the token endpoint only.
        public let clientSecret: String?

        public init(metadata: ServerMetadata, clientID: String, registration: Registration, resource: String, scope: String?,
                    port: UInt16, state: String = MCPOAuth.randomURLSafe(24), pkce: PKCE = PKCE(), clientSecret: String? = nil) {
            self.clientSecret = clientSecret
            issuer = metadata.issuer
            self.metadata = metadata
            self.clientID = clientID
            self.registration = registration
            self.resource = resource
            self.scope = scope
            redirectURI = "http://127.0.0.1:\(port)\(MCPOAuth.callbackPath(issuer: metadata.issuer, registration: registration))"
            self.state = state
            self.pkce = pkce
        }

        public var authorizationURL: URL {
            var c = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
            var items = c.queryItems ?? []
            items += [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID),
                      URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "state", value: state),
                      URLQueryItem(name: "code_challenge", value: pkce.challenge),
                      URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "resource", value: resource)]
            if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
            c.queryItems = items
            return c.url!
        }

        /// The callback's request target (`/callback?code=…&state=…`),
        /// checked: the path, the state, `iss` where required; the code.
        public func code(fromCallback target: String) throws -> String {
            guard let c = URLComponents(string: "http://127.0.0.1" + target) else { throw Failure.badCallback("unreadable") }
            let expectedPath = URLComponents(string: redirectURI)?.path ?? "/callback"
            guard c.path == expectedPath else { throw Failure.badCallback("another path") }
            let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            guard q["state"] == state else { throw Failure.badCallback("state") }
            if let iss = q["iss"] {
                guard canonical(iss) == canonical(issuer) else { throw Failure.badCallback("issuer") }
            } else if metadata.sendsIssInResponse {
                throw Failure.badCallback("no issuer")
            }
            if let error = q["error"] { throw Failure.denied(q["error_description"] ?? error) }
            guard let code = q["code"], !code.isEmpty else { throw Failure.badCallback("no code") }
            return code
        }

        public func tokenRequest(code: String) -> URLRequest {
            var fields = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                          "client_id": clientID, "code_verifier": pkce.verifier, "resource": resource]
            if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
            return MCPOAuth.formRequest(metadata.tokenEndpoint, fields)
        }
    }

    public static func refreshRequest(tokenEndpoint: URL, refreshToken: String, clientID: String, resource: String,
                                      clientSecret: String? = nil) -> URLRequest {
        var fields = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID, "resource": resource]
        if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        return formRequest(tokenEndpoint, fields)
    }

    static func formRequest(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // application/x-www-form-urlencoded: everything but letters, digits
        // and -._* percent-encoded.
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._*")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        return request
    }

    // MARK: Tokens

    public struct Tokens: Codable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?
        public var scope: String?

        public func expired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return now.addingTimeInterval(60) >= expiresAt
        }
    }

    /// A token response; `previous` keeps a refresh token the server didn't
    /// rotate. `invalid_grant` and `invalid_client` are told apart.
    public static func tokens(_ data: Data, status: Int, previous: Tokens? = nil, now: Date = Date()) throws -> Tokens {
        var o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // Slack-style: 200 with {"ok": false, "error": …}; a user token
        // under "authed_user".
        if o["ok"] as? Bool == false, (200..<300).contains(status) {
            let error = o["error"] as? String ?? "refused"
            if ["invalid_grant", "invalid_refresh_token", "token_expired", "invalid_code", "code_already_used"].contains(error) { throw Failure.invalidGrant }
            if ["invalid_client_id", "bad_client_secret", "invalid_client"].contains(error) { throw Failure.invalidClient }
            throw Failure.token(error)
        }
        if o["access_token"] == nil, let user = o["authed_user"] as? [String: Any] { o = user }
        guard (200..<300).contains(status) else {
            switch o["error"] as? String {
            case "invalid_grant": throw Failure.invalidGrant
            case "invalid_client", "unauthorized_client": throw Failure.invalidClient
            default: throw Failure.token((o["error_description"] as? String) ?? (o["error"] as? String) ?? "HTTP \(status)")
            }
        }
        // A bearer token; servers that name the type otherwise ("user") or
        // not at all are taken as bearer, a known other scheme isn't.
        let type = (o["token_type"] as? String)?.lowercased()
        guard let access = o["access_token"] as? String, !access.isEmpty, type == nil || type == "bearer" || type == "user"
        else { throw Failure.token("no bearer token") }
        let expires = (o["expires_in"] as? Double) ?? (o["expires_in"] as? Int).map(Double.init)
        return Tokens(accessToken: access, refreshToken: (o["refresh_token"] as? String) ?? previous?.refreshToken,
                      expiresAt: expires.map { now.addingTimeInterval($0) }, scope: (o["scope"] as? String) ?? previous?.scope)
    }

    /// The scopes to ask for: the challenge's, else the resource metadata's,
    /// else none; a step-up adds the challenged ones to those granted.
    public static func scope(challenge: Challenge?, metadata: ResourceMetadata?, granted: String? = nil) -> String? {
        if let challenged = challenge?.scope, !challenged.isEmpty {
            let union = Set((granted ?? "").split(separator: " ").map(String.init)).union(challenged.split(separator: " ").map(String.init))
            return union.sorted().joined(separator: " ")
        }
        let supported = metadata?.scopesSupported ?? []
        return supported.isEmpty ? nil : supported.joined(separator: " ")
    }
}

// MARK: - The network steps

/// What a sign-in step asks the network for (tests answer from fixtures).
public protocol MCPOAuthFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

/// Requests without cookies or credentials that follow no redirect to
/// another origin (adr/0028).
public final class MCPOAuthHTTP: NSObject, MCPOAuthFetching, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public override init() {}

    public func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url,
              from.scheme == to.scheme, from.host?.lowercased() == to.host?.lowercased(), from.port == to.port,
              task.originalRequest?.httpMethod ?? "GET" == "GET" else { return nil }
        return request
    }
}

extension MCPOAuth {
    public struct Discovery: Equatable {
        public var resource: ResourceMetadata
        public var server: ServerMetadata
        /// The canonical server URL: the `resource` of every request.
        public var resourceURL: String
        public var scope: String?
    }

    /// Whether `url` may be fetched while signing in to `server`: no private,
    /// loopback or link-local hosts unless the server itself is one. IP
    /// literals in any form inet_aton / inet_pton take (127.1, 0x7f000001,
    /// 0177.0.0.1, [::ffff:127.0.0.1]) and names that resolve to such an
    /// address count. A name that resolves differently by the time it's
    /// fetched (DNS rebinding) isn't caught here.
    public static func fetchable(_ url: URL, for server: URL,
                                 resolve: (String) -> [IPAddress] = IPAddress.resolve) -> Bool {
        guard let host = url.host else { return false }
        return !isLocal(host, resolve: resolve) || isLocal(server.host ?? "", resolve: resolve)
    }

    /// Whether a host is this Mac, a private network or link-local.
    public static func isLocal(_ host: String, resolve: (String) -> [IPAddress]) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        if h.isEmpty { return true }
        if let ip = IPAddress(literal: h) { return ip.isLocal }
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        return resolve(h).contains { $0.isLocal }
    }

    /// An IPv4 or IPv6 address.
    public enum IPAddress: Equatable {
        case v4(UInt32)
        case v6([UInt8])

        /// An address written as an IP literal (inet_aton's IPv4 forms, or IPv6).
        public init?(literal: String) {
            var a4 = in_addr()
            if literal.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }), inet_aton(literal, &a4) != 0 {
                self = .v4(UInt32(bigEndian: a4.s_addr))
                return
            }
            var a6 = in6_addr()
            if inet_pton(AF_INET6, literal, &a6) == 1 {
                self = .v6(withUnsafeBytes(of: &a6) { Array($0) })
                return
            }
            return nil
        }

        /// This Mac, a private or local network, link-local, multicast or
        /// broadcast: nothing an outside fetch may reach.
        public var isLocal: Bool {
            switch self {
            case .v4(let a):
                let b0 = a >> 24, b1 = (a >> 16) & 0xff
                return b0 == 0 || b0 == 10 || b0 == 127 || (b0 == 169 && b1 == 254) || b0 >= 224
                    || (b0 == 198 && (b1 == 18 || b1 == 19))
                    || (b0 == 172 && (16...31).contains(b1)) || (b0 == 192 && b1 == 168)
                    || (b0 == 100 && (64...127).contains(b1))
            case .v6(let b):
                if b.allSatisfy({ $0 == 0 }) { return true }  // ::
                if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }  // ::1
                if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }  // fe80::/10
                if b[0] & 0xfe == 0xfc { return true }  // fc00::/7
                if b[0] == 0xff { return true }  // multicast
                // NAT64 (64:ff9b::/96) and 6to4 (2002::/16) carry an IPv4
                // address the network translates to: as local as it is.
                if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) {
                    return IPAddress.v4(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])).isLocal
                }
                if b[0] == 0x20, b[1] == 0x02 {
                    return IPAddress.v4(UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])).isLocal
                }
                // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d).
                if b[0..<10].allSatisfy({ $0 == 0 }) && ((b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0)) {
                    let v4 = UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
                    return IPAddress.v4(v4).isLocal
                }
                return false
            }
        }

        /// As written for a connection ("93.184.216.34", "2606:2800::1").
        public var text: String {
            switch self {
            case .v4(let a):
                return "\(a >> 24).\((a >> 16) & 0xff).\((a >> 8) & 0xff).\(a & 0xff)"
            case .v6(var b):
                var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                _ = b.withUnsafeMutableBytes { inet_ntop(AF_INET6, $0.baseAddress, &out, socklen_t(INET6_ADDRSTRLEN)) }
                return String(cString: out)
            }
        }

        /// The addresses a name resolves to (none when it doesn't).
        public static func resolve(_ name: String) -> [IPAddress] {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return [] }
            defer { freeaddrinfo(list) }
            var out: [IPAddress] = []
            var node: UnsafeMutablePointer<addrinfo>? = first
            while let n = node {
                if let sa = n.pointee.ai_addr {
                    if n.pointee.ai_family == AF_INET {
                        let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                        out.append(.v4(UInt32(bigEndian: a)))
                    } else if n.pointee.ai_family == AF_INET6 {
                        var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                        out.append(.v6(withUnsafeBytes(of: &a) { Array($0) }))
                    }
                }
                node = n.pointee.ai_next
            }
            return out
        }
    }

    /// The server's resource and authorization server metadata, checked.
    public static func discover(server: URL, challenge: Challenge?, fetch: MCPOAuthFetching) async throws -> Discovery {
        var resource: ResourceMetadata?
        for (url, kind) in resourceMetadataURLs(server: server, challenge: challenge) {
            guard url.scheme?.lowercased() == "https" || (server.scheme == "http" && fetchable(url, for: server)),
                  fetchable(url, for: server) else { continue }
            guard let (data, status) = try? await fetch.fetch(URLRequest(url: url)), status == 200 else { continue }
            resource = try resourceMetadata(data, server: server, kind: kind)
            break
        }
        // A server of the 2025-03-26 revision publishes no resource
        // metadata: its own origin is the authorization server.
        if resource == nil, var origin = URLComponents(url: server, resolvingAgainstBaseURL: false) {
            origin.path = ""
            origin.query = nil
            if let issuer = origin.url {
                resource = ResourceMetadata(resource: canonical(server), authorizationServers: [issuer], scopesSupported: [])
            }
        }
        guard let resource, let issuer = resource.authorizationServers.first else { throw Failure.noMetadata }
        var metadata: ServerMetadata?
        for url in serverMetadataURLs(issuer: issuer) where fetchable(url, for: server) {
            guard let (data, status) = try? await fetch.fetch(URLRequest(url: url)), status == 200 else { continue }
            metadata = try serverMetadata(data, issuer: issuer)
            break
        }
        guard let metadata else { throw Failure.noMetadata }
        // The resource asked for is the one the server named (checked above).
        return Discovery(resource: resource, server: metadata, resourceURL: canonical(resource.resource) ?? canonical(server),
                         scope: scope(challenge: challenge, metadata: resource))
    }

    /// Who we are to this server: a kept registration, our metadata document,
    /// a dynamic registration, else the user's pasted client id.
    public static func client(for m: ServerMetadata, kept: (id: String, registration: Registration)?, pasted: String?,
                              server: URL, fetch: MCPOAuthFetching) async throws -> (id: String, registration: Registration) {
        if let kept { return kept }
        // The user's own app first, when they gave one.
        if let pasted, !pasted.isEmpty { return (pasted, .manual) }
        if m.acceptsClientMetadataDocument, mixUpSafe(m, registration: .metadataDocument) {
            return (clientMetadataURL, .metadataDocument)
        }
        if let endpoint = m.registrationEndpoint, fetchable(endpoint, for: server) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = registrationRequest(redirectPath: callbackPath(issuer: m.issuer, registration: .dynamic))
            let (data, status) = try await fetch.fetch(request)
            guard (200..<300).contains(status) else { throw Failure.noRegistration }
            return (try registeredClientID(data), .dynamic)
        }
        throw m.acceptsClientMetadataDocument ? Failure.mixUpRisk : Failure.noRegistration
    }

    public static func exchange(_ flow: Flow, callback target: String, fetch: MCPOAuthFetching) async throws -> Tokens {
        let code = try flow.code(fromCallback: target)
        guard let resource = URL(string: flow.resource), fetchable(flow.metadata.tokenEndpoint, for: resource) else { throw Failure.insecureURL }
        let (data, status) = try await fetch.fetch(flow.tokenRequest(code: code))
        return try tokens(data, status: status)
    }

    public static func refresh(_ tokens: Tokens, tokenEndpoint: URL, clientID: String, resource: String, clientSecret: String? = nil,
                               fetch: MCPOAuthFetching) async throws -> Tokens {
        guard let refreshToken = tokens.refreshToken else { throw Failure.invalidGrant }
        guard let r = URL(string: resource), fetchable(tokenEndpoint, for: r) else { throw Failure.insecureURL }
        let (data, status) = try await fetch.fetch(refreshRequest(tokenEndpoint: tokenEndpoint, refreshToken: refreshToken,
                                                                  clientID: clientID, resource: resource, clientSecret: clientSecret))
        return try MCPOAuth.tokens(data, status: status, previous: tokens)
    }
}
