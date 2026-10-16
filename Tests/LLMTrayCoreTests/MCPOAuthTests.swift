import XCTest
@testable import LLMTrayCore

/// adr/0028: discovery, the checks, PKCE, the callback, tokens -- and what a
/// hostile server's metadata must not get through.
final class MCPOAuthTests: XCTestCase {
    final class Fixtures: MCPOAuthFetching, @unchecked Sendable {
        var answers: [String: (Any, Int)] = [:]
        var asked: [URLRequest] = []
        func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            asked.append(request)
            guard let (body, status) = answers[request.url!.absoluteString] else { return (Data(), 404) }
            let data = (body as? Data) ?? (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            return (data, status)
        }
    }

    let server = URL(string: "https://mcp.example.com/mcp")!

    func asMetadata(issuer: String = "https://auth.example.com", s256: Bool = true, cimd: Bool = false, iss: Bool = false,
                    registration: Bool = true, token: String = "https://auth.example.com/token") -> [String: Any] {
        var m: [String: Any] = ["issuer": issuer, "authorization_endpoint": issuer + "/authorize", "token_endpoint": token,
                                "code_challenge_methods_supported": s256 ? ["S256"] : ["plain"]]
        if registration { m["registration_endpoint"] = issuer + "/register" }
        if cimd { m["client_id_metadata_document_supported"] = true }
        if iss { m["authorization_response_iss_parameter_supported"] = true }
        return m
    }

    // MARK: Pure parts

    func testCanonicalURLs() {
        XCTAssertEqual(MCPOAuth.canonical(URL(string: "HTTPS://MCP.Example.com:443/mcp?x=1#f")!), "https://mcp.example.com/mcp")
        XCTAssertEqual(MCPOAuth.canonical(URL(string: "https://a.example/")!), MCPOAuth.canonical(URL(string: "https://a.example")!))
        XCTAssertNotEqual(MCPOAuth.canonical(URL(string: "https://a.example/mcp")!), MCPOAuth.canonical(URL(string: "https://a.example/mcp2")!))
    }

    func testChallengeParsing() {
        let c = MCPOAuth.parseChallenge(#"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", scope="read write", error="invalid_token""#)
        XCTAssertEqual(c?.resourceMetadata?.absoluteString, "https://mcp.example.com/.well-known/oauth-protected-resource/mcp")
        XCTAssertEqual(c?.scope, "read write")
        XCTAssertEqual(c?.error, "invalid_token")
        XCTAssertNil(MCPOAuth.parseChallenge("Basic realm=x"))
    }

    func testDiscoveryURLsInOrder() {
        let urls = MCPOAuth.resourceMetadataURLs(server: server, challenge: nil).map { $0.0.absoluteString }
        XCTAssertEqual(urls, ["https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
                              "https://mcp.example.com/.well-known/oauth-protected-resource"])
        XCTAssertEqual(MCPOAuth.serverMetadataURLs(issuer: URL(string: "https://auth.example.com/tenant1")!).map(\.absoluteString),
                       ["https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
                        "https://auth.example.com/.well-known/openid-configuration/tenant1",
                        "https://auth.example.com/tenant1/.well-known/openid-configuration"])
        XCTAssertEqual(MCPOAuth.serverMetadataURLs(issuer: URL(string: "https://auth.example.com")!).map(\.absoluteString),
                       ["https://auth.example.com/.well-known/oauth-authorization-server",
                        "https://auth.example.com/.well-known/openid-configuration"])
    }

    func testResourceMustMatchExactly() throws {
        let good = try JSONSerialization.data(withJSONObject: ["resource": "https://mcp.example.com/mcp", "authorization_servers": ["https://auth.example.com"]])
        XCTAssertNoThrow(try MCPOAuth.resourceMetadata(good, server: server, kind: .pathInserted))
        // The root of the server's own origin is accepted (servers that name
        // their whole host); another path on it isn't.
        let root = try JSONSerialization.data(withJSONObject: ["resource": "https://mcp.example.com/", "authorization_servers": ["https://auth.example.com"]])
        XCTAssertNoThrow(try MCPOAuth.resourceMetadata(root, server: server, kind: .header))
        let sibling = try JSONSerialization.data(withJSONObject: ["resource": "https://mcp.example.com/other", "authorization_servers": ["https://auth.example.com"]])
        XCTAssertThrowsError(try MCPOAuth.resourceMetadata(sibling, server: server, kind: .header)) { XCTAssertEqual($0 as? MCPOAuth.Failure, .resourceMismatch) }
        let other = try JSONSerialization.data(withJSONObject: ["resource": "https://evil.example/mcp", "authorization_servers": ["https://auth.example.com"]])
        XCTAssertThrowsError(try MCPOAuth.resourceMetadata(other, server: server, kind: .header))
        let insecure = try JSONSerialization.data(withJSONObject: ["resource": "https://mcp.example.com/mcp", "authorization_servers": ["http://auth.example.com"]])
        XCTAssertThrowsError(try MCPOAuth.resourceMetadata(insecure, server: server, kind: .header)) { XCTAssertEqual($0 as? MCPOAuth.Failure, .insecureURL) }
    }

    func testServerMetadataChecks() throws {
        let issuer = URL(string: "https://auth.example.com")!
        XCTAssertNoThrow(try MCPOAuth.serverMetadata(JSONSerialization.data(withJSONObject: asMetadata()), issuer: issuer))
        XCTAssertThrowsError(try MCPOAuth.serverMetadata(JSONSerialization.data(withJSONObject: asMetadata(s256: false)), issuer: issuer)) {
            XCTAssertEqual($0 as? MCPOAuth.Failure, .noS256)
        }
        XCTAssertThrowsError(try MCPOAuth.serverMetadata(JSONSerialization.data(withJSONObject: asMetadata(issuer: "https://evil.example")), issuer: issuer)) {
            XCTAssertEqual($0 as? MCPOAuth.Failure, .issuerMismatch)
        }
        XCTAssertThrowsError(try MCPOAuth.serverMetadata(JSONSerialization.data(withJSONObject: asMetadata(token: "http://auth.example.com/token")), issuer: issuer)) {
            XCTAssertEqual($0 as? MCPOAuth.Failure, .insecureURL)
        }
    }

    func testMixUpDefence() throws {
        let honest = try MCPOAuth.serverMetadata(JSONSerialization.data(withJSONObject: asMetadata()), issuer: URL(string: "https://auth.example.com")!)
        XCTAssertTrue(MCPOAuth.mixUpSafe(honest, registration: .metadataDocument))   // its own origin
        // A hostile issuer pairing someone's authorization endpoint with its own token endpoint.
        var hostile = honest
        hostile.authorizationEndpoint = URL(string: "https://honest-idp.example/authorize")!
        XCTAssertFalse(MCPOAuth.mixUpSafe(hostile, registration: .metadataDocument))
        XCTAssertTrue(MCPOAuth.mixUpSafe(hostile, registration: .dynamic))   // a per-issuer callback path
        XCTAssertTrue(MCPOAuth.mixUpSafe(hostile, registration: .manual))    // the same for one's own app
        XCTAssertEqual(MCPOAuth.manualRedirectURI(issuer: "https://mcp.slack.com"),
                       "http://127.0.0.1:33418" + MCPOAuth.callbackPath(issuer: "https://mcp.slack.com", registration: .manual))
        hostile.sendsIssInResponse = true
        XCTAssertTrue(MCPOAuth.mixUpSafe(hostile, registration: .metadataDocument))   // iss checked
        XCTAssertNotEqual(MCPOAuth.callbackPath(issuer: "https://a.example", registration: .dynamic),
                          MCPOAuth.callbackPath(issuer: "https://b.example", registration: .dynamic))
    }

    func testPKCE() {
        let pkce = MCPOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")   // RFC 7636 appendix B
        XCTAssertGreaterThanOrEqual(MCPOAuth.PKCE().verifier.count, 43)
    }

    func flow(iss: Bool = false, registration: MCPOAuth.Registration = .metadataDocument) throws -> MCPOAuth.Flow {
        let m = try MCPOAuth.serverMetadata(JSONSerialization.data(withJSONObject: asMetadata(iss: iss)), issuer: URL(string: "https://auth.example.com")!)
        return MCPOAuth.Flow(metadata: m, clientID: MCPOAuth.clientMetadataURL, registration: registration, resource: "https://mcp.example.com/mcp",
                             scope: "read", port: 51234, state: "s1")
    }

    func testAuthorizationURLCarriesEverything() throws {
        let f = try flow()
        let items = Dictionary((URLComponents(url: f.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["resource"], "https://mcp.example.com/mcp")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:51234/callback")
        XCTAssertEqual(items["state"], "s1")
        XCTAssertEqual(items["scope"], "read")
    }

    func testCallbackChecks() throws {
        let f = try flow()
        XCTAssertEqual(try f.code(fromCallback: "/callback?code=abc&state=s1"), "abc")
        XCTAssertThrowsError(try f.code(fromCallback: "/callback?code=abc&state=other"))
        XCTAssertThrowsError(try f.code(fromCallback: "/elsewhere?code=abc&state=s1"))
        XCTAssertThrowsError(try f.code(fromCallback: "/callback?code=abc&state=s1&iss=https://evil.example"))
        XCTAssertThrowsError(try f.code(fromCallback: "/callback?error=access_denied&state=s1")) {
            XCTAssertEqual($0 as? MCPOAuth.Failure, .denied("access_denied"))
        }
        let withIss = try flow(iss: true)
        XCTAssertThrowsError(try withIss.code(fromCallback: "/callback?code=abc&state=s1"))   // advertised, missing
        XCTAssertEqual(try withIss.code(fromCallback: "/callback?code=abc&state=s1&iss=https://auth.example.com"), "abc")
        let dynamic = try flow(registration: .dynamic)
        XCTAssertThrowsError(try dynamic.code(fromCallback: "/callback?code=abc&state=s1"))   // the per-issuer path only
    }

    func testTokenRequestsCarryResource() throws {
        let f = try flow()
        let body = String(decoding: f.tokenRequest(code: "abc").httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("resource=https%3A%2F%2Fmcp.example.com%2Fmcp"))
        XCTAssertTrue(body.contains("code_verifier="))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        let refresh = String(decoding: MCPOAuth.refreshRequest(tokenEndpoint: URL(string: "https://auth.example.com/token")!, refreshToken: "r+1",
                                                               clientID: "c", resource: "https://mcp.example.com/mcp").httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(refresh.contains("refresh_token=r%2B1"))
        XCTAssertTrue(refresh.contains("resource="))
    }

    func testTokens() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let t = try MCPOAuth.tokens(JSONSerialization.data(withJSONObject: ["access_token": "a", "token_type": "Bearer", "expires_in": 3600, "refresh_token": "r1"]),
                                    status: 200, now: now)
        XCTAssertEqual(t.refreshToken, "r1")
        XCTAssertFalse(t.expired(now: now))
        XCTAssertTrue(t.expired(now: now.addingTimeInterval(3590)))
        // Not rotated: the old refresh token stays; rotated: replaced.
        let kept = try MCPOAuth.tokens(JSONSerialization.data(withJSONObject: ["access_token": "b", "token_type": "bearer"]), status: 200, previous: t)
        XCTAssertEqual(kept.refreshToken, "r1")
        let rotated = try MCPOAuth.tokens(JSONSerialization.data(withJSONObject: ["access_token": "b", "token_type": "bearer", "refresh_token": "r2"]), status: 200, previous: t)
        XCTAssertEqual(rotated.refreshToken, "r2")
        XCTAssertThrowsError(try MCPOAuth.tokens(JSONSerialization.data(withJSONObject: ["error": "invalid_grant"]), status: 400)) {
            XCTAssertEqual($0 as? MCPOAuth.Failure, .invalidGrant)
        }
        XCTAssertThrowsError(try MCPOAuth.tokens(JSONSerialization.data(withJSONObject: ["error": "invalid_client"]), status: 401)) {
            XCTAssertEqual($0 as? MCPOAuth.Failure, .invalidClient)
        }
        XCTAssertThrowsError(try MCPOAuth.tokens(JSONSerialization.data(withJSONObject: ["access_token": "x", "token_type": "mac"]), status: 200))
        // Slack-style answers.
        XCTAssertThrowsError(try MCPOAuth.tokens(JSONSerialization.data(withJSONObject: ["ok": false, "error": "invalid_code"]), status: 200)) {
            XCTAssertEqual($0 as? MCPOAuth.Failure, .invalidGrant)
        }
        let slack = try MCPOAuth.tokens(JSONSerialization.data(withJSONObject: ["ok": true, "authed_user": ["access_token": "xoxp-1", "token_type": "user", "refresh_token": "xoxe-1"]]), status: 200)
        XCTAssertEqual(slack.accessToken, "xoxp-1")
        XCTAssertEqual(slack.refreshToken, "xoxe-1")
    }

    func testScopes() {
        let metadata = MCPOAuth.ResourceMetadata(resource: "r", authorizationServers: [], scopesSupported: ["a", "b"])
        XCTAssertEqual(MCPOAuth.scope(challenge: MCPOAuth.Challenge(scope: "x"), metadata: metadata), "x")
        XCTAssertEqual(MCPOAuth.scope(challenge: nil, metadata: metadata), "a b")
        XCTAssertNil(MCPOAuth.scope(challenge: nil, metadata: nil))
        XCTAssertEqual(MCPOAuth.scope(challenge: MCPOAuth.Challenge(scope: "write"), metadata: metadata, granted: "read"), "read write")
    }

    func testPrivateAddressesOnlyForLocalServers() {
        XCTAssertFalse(MCPOAuth.fetchable(URL(string: "https://169.254.169.254/latest")!, for: server))
        XCTAssertFalse(MCPOAuth.fetchable(URL(string: "https://192.168.1.10/x")!, for: server))
        XCTAssertFalse(MCPOAuth.fetchable(URL(string: "https://localhost/x")!, for: server))
        XCTAssertTrue(MCPOAuth.fetchable(URL(string: "https://auth.example.com/x")!, for: server))
        XCTAssertTrue(MCPOAuth.fetchable(URL(string: "http://localhost:9000/x")!, for: URL(string: "http://localhost:8000/mcp")!))
    }

    func testRegistrationRefusesASecret() throws {
        XCTAssertEqual(try MCPOAuth.registeredClientID(JSONSerialization.data(withJSONObject: ["client_id": "c1", "token_endpoint_auth_method": "none"])), "c1")
        XCTAssertThrowsError(try MCPOAuth.registeredClientID(JSONSerialization.data(withJSONObject: ["client_id": "c1", "client_secret": "s"]))) {
            XCTAssertEqual($0 as? MCPOAuth.Failure, .confidentialRegistration)
        }
        let body = String(decoding: MCPOAuth.registrationRequest(redirectPath: "/callback/ab"), as: UTF8.self)
        XCTAssertTrue(body.contains(#""token_endpoint_auth_method":"none""#))
        XCTAssertTrue(body.contains("http://127.0.0.1/callback/ab"))
    }

    // MARK: The network steps

    func testDiscoveryFromChallengeThenRegistration() async throws {
        let f = Fixtures()
        f.answers["https://mcp.example.com/.well-known/oauth-protected-resource/mcp"] =
            (["resource": "https://mcp.example.com/mcp", "authorization_servers": ["https://auth.example.com"], "scopes_supported": ["mcp"]], 200)
        f.answers["https://auth.example.com/.well-known/oauth-authorization-server"] = (asMetadata(), 200)
        f.answers["https://auth.example.com/register"] = (["client_id": "dyn-1", "token_endpoint_auth_method": "none"], 201)
        let challenge = MCPOAuth.parseChallenge(#"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp""#)
        let d = try await MCPOAuth.discover(server: server, challenge: challenge, fetch: f)
        XCTAssertEqual(d.scope, "mcp")
        XCTAssertEqual(d.resourceURL, "https://mcp.example.com/mcp")
        let client = try await MCPOAuth.client(for: d.server, kept: nil, pasted: nil, fetch: f)
        XCTAssertEqual(client.id, "dyn-1")
        XCTAssertEqual(client.registration, .dynamic)
        // No credentials in discovery requests.
        XCTAssertTrue(f.asked.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testOlderServersWithoutResourceMetadata() async throws {
        let f = Fixtures()
        f.answers["https://mcp.example.com/.well-known/oauth-authorization-server"] = (asMetadata(issuer: "https://mcp.example.com"), 200)
        let d = try await MCPOAuth.discover(server: server, challenge: nil, fetch: f)
        XCTAssertEqual(d.server.issuer, "https://mcp.example.com")
        XCTAssertEqual(d.resourceURL, "https://mcp.example.com/mcp")
    }

    func testDiscoveryRefusesAHostileMetadataURL() async {
        let f = Fixtures()
        let challenge = MCPOAuth.parseChallenge(#"Bearer resource_metadata="https://169.254.169.254/meta""#)
        f.answers["https://169.254.169.254/meta"] = (["resource": "https://mcp.example.com/mcp", "authorization_servers": ["https://auth.example.com"]], 200)
        do {
            _ = try await MCPOAuth.discover(server: server, challenge: challenge, fetch: f)
            XCTFail("discovered")
        } catch {
            XCTAssertFalse(f.asked.contains { $0.url?.host == "169.254.169.254" })
        }
    }

    func testClientChoice() async throws {
        let f = Fixtures()
        let cimd = try MCPOAuth.serverMetadata(JSONSerialization.data(withJSONObject: asMetadata(cimd: true)), issuer: URL(string: "https://auth.example.com")!)
        let a = try await MCPOAuth.client(for: cimd, kept: nil, pasted: nil, fetch: f)
        XCTAssertEqual(a.id, MCPOAuth.clientMetadataURL)
        let none = try MCPOAuth.serverMetadata(JSONSerialization.data(withJSONObject: asMetadata(registration: false)), issuer: URL(string: "https://auth.example.com")!)
        let pasted = try await MCPOAuth.client(for: none, kept: nil, pasted: "my-client", fetch: f)
        XCTAssertEqual(pasted.registration, .manual)
        do {
            _ = try await MCPOAuth.client(for: none, kept: nil, pasted: nil, fetch: f)
            XCTFail("registered")
        } catch {
            XCTAssertEqual(error as? MCPOAuth.Failure, .noRegistration)
        }
    }

    func testExchangeAndRefresh() async throws {
        let f = Fixtures()
        let flow = try flow()
        f.answers["https://auth.example.com/token"] = (["access_token": "a1", "token_type": "Bearer", "expires_in": 60, "refresh_token": "r1"], 200)
        let tokens = try await MCPOAuth.exchange(flow, callback: "/callback?code=c&state=s1", fetch: f)
        XCTAssertEqual(tokens.accessToken, "a1")
        f.answers["https://auth.example.com/token"] = (["access_token": "a2", "token_type": "Bearer", "refresh_token": "r2"], 200)
        let refreshed = try await MCPOAuth.refresh(tokens, tokenEndpoint: flow.metadata.tokenEndpoint, clientID: flow.clientID,
                                                   resource: flow.resource, fetch: f)
        XCTAssertEqual(refreshed.refreshToken, "r2")
        // A callback with the wrong state never reaches the token endpoint.
        let before = f.asked.count
        do {
            _ = try await MCPOAuth.exchange(flow, callback: "/callback?code=c&state=evil", fetch: f)
            XCTFail("exchanged")
        } catch {
            XCTAssertEqual(f.asked.count, before)
        }
    }
}

/// Discovery against real servers, opt-in (MCP_OAUTH_LIVE=url,url): metadata
/// only, no registration, no sign-in.
final class MCPOAuthLiveTests: XCTestCase {
    func testDiscoverRealServers() async throws {
        guard let list = ProcessInfo.processInfo.environment["MCP_OAUTH_LIVE"] else { throw XCTSkip("MCP_OAUTH_LIVE not set") }
        let http = MCPOAuthHTTP()
        for text in list.split(separator: ",") {
            let server = URL(string: String(text))!
            var request = URLRequest(url: server)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"LLMTray","version":"test"}}}"#.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            let http401 = response as? HTTPURLResponse
            let challenge = MCPOAuth.parseChallenge(http401?.value(forHTTPHeaderField: "WWW-Authenticate"))
            do {
                let d = try await MCPOAuth.discover(server: server, challenge: challenge, fetch: http)
                let m = d.server
                print("\(server): status=\(http401?.statusCode ?? 0) issuer=\(m.issuer) cimd=\(m.acceptsClientMetadataDocument) dcr=\(m.registrationEndpoint != nil) iss=\(m.sendsIssInResponse) scope=\(d.scope ?? "-") mixUpSafe(dcr)=\(MCPOAuth.mixUpSafe(m, registration: .dynamic)) mixUpSafe(cimd)=\(MCPOAuth.mixUpSafe(m, registration: .metadataDocument))")
            } catch {
                print("\(server): status=\(http401?.statusCode ?? 0) challenge=\(String(describing: challenge)) -> \(error)")
            }
        }
    }
}
