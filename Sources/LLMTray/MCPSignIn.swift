import AppKit
import Foundation
import LLMTrayCore
import Network

/// Signing in to web MCP servers (adr/0028): the browser, a loopback
/// listener for the one callback, tokens in the Keychain, refreshed one at
/// a time per server.
@MainActor
final class MCPSignIn: ObservableObject {
    static let shared = MCPSignIn()

    /// Servers being signed in to now.
    @Published private(set) var signingIn: Set<UUID> = []
    /// Servers that need the user's own app (no client registration, like
    /// Slack): kept, off, until its client id is given in Configure.
    @Published var needsOwnApp: Set<UUID> = []
    private var refreshes: [UUID: Task<String?, Never>] = [:]
    /// Bumped by every sign-in and sign-out: a refresh that started before
    /// one commits nothing.
    private var generation: [UUID: Int] = [:]
    private let fetch = MCPOAuthHTTP()
    private var hub: MCPHub { MCPHub.shared }
    static let tokensName = "oauth.tokens"
    /// The secret of the user's own app (Slack and the like): Keychain only.
    static let clientSecretName = "oauth.clientSecret"

    // MARK: Tokens

    private func tokens(_ id: UUID) -> MCPOAuth.Tokens? {
        guard let text = MCPSecrets.get(server: id, name: Self.tokensName) else { return nil }
        return try? JSONDecoder().decode(MCPOAuth.Tokens.self, from: Data(text.utf8))
    }

    private func store(_ tokens: MCPOAuth.Tokens?, for id: UUID) {
        let text = tokens.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        MCPSecrets.set(text, server: id, name: Self.tokensName)
    }

    /// The access token for a request: refreshed first when it has expired
    /// (one refresh at a time per server); nil when there's none to use.
    func token(_ id: UUID) async -> String? {
        guard let config = hub.server(id), let state = config.oauth, !state.needsSignIn, let t = tokens(id) else { return nil }
        if !t.expired() { return t.accessToken }
        return await refresh(id)
    }

    /// A refresh (after expiry or a 401): rotated tokens stored at once; a
    /// refused grant marks "Sign in again"; a dropped dynamic registration
    /// is forgotten too; a network failure keeps what there is.
    func refresh(_ id: UUID) async -> String? {
        if let running = refreshes[id] { return await running.value }
        let started = generation[id, default: 0]
        let task = Task { @MainActor () -> String? in
            defer { refreshes.removeValue(forKey: id) }
            guard let config = hub.server(id), let state = config.oauth, let t = tokens(id) else { return nil }
            do {
                let fresh = try await MCPOAuth.refresh(t, tokenEndpoint: state.metadata.tokenEndpoint, clientID: state.clientID,
                                                       resource: state.resource,
                                                       clientSecret: state.registration == .manual ? MCPSecrets.get(server: id, name: Self.clientSecretName) : nil,
                                                       fetch: fetch)
                guard generation[id, default: 0] == started else { return tokens(id)?.accessToken }
                store(fresh, for: id)
                return fresh.accessToken
            } catch MCPOAuth.Failure.invalidGrant {
                if generation[id, default: 0] == started { markNeedsSignIn(id, dropRegistration: false) }
            } catch MCPOAuth.Failure.invalidClient {
                if generation[id, default: 0] == started { markNeedsSignIn(id, dropRegistration: state.registration == .dynamic) }
            } catch {}
            return nil
        }
        refreshes[id] = task
        return await task.value
    }

    private func markNeedsSignIn(_ id: UUID, dropRegistration: Bool) {
        guard var config = hub.server(id), var state = config.oauth else { return }
        state.needsSignIn = true
        config.oauth = state
        if dropRegistration { config.oauth = nil }
        store(nil, for: id)
        hub.update(config)
    }

    // MARK: Signing in

    /// The whole sign-in: discovery, our client, the browser, the callback,
    /// the tokens. `stepUp`: scopes a 403 asked for (added to those granted).
    func signIn(_ id: UUID, challenge: MCPOAuth.Challenge?, stepUp: String? = nil) async throws {
        guard var config = hub.server(id), config.kind == .url, let server = URL(string: config.url) else { return }
        signingIn.insert(id)
        defer { signingIn.remove(id) }
        let discovery = try await MCPOAuth.discover(server: server, challenge: challenge, fetch: fetch)
        // A kept registration of this issuer -- unless the user has since given
        // their own app's client id.
        let kept: (id: String, registration: MCPOAuth.Registration)? = config.oauth.flatMap {
            MCPOAuth.canonical($0.metadata.issuer) == MCPOAuth.canonical(discovery.server.issuer)
                && (config.oauthClientID == nil || $0.clientID == config.oauthClientID) ? ($0.clientID, $0.registration) : nil
        }
        let client: (id: String, registration: MCPOAuth.Registration)
        do {
            client = try await MCPOAuth.client(for: discovery.server, kept: kept, pasted: config.oauthClientID, server: server, fetch: fetch)
            needsOwnApp.remove(id)
        } catch MCPOAuth.Failure.noRegistration {
            needsOwnApp.insert(id)
            throw MCPOAuth.Failure.noRegistration
        }
        guard MCPOAuth.mixUpSafe(discovery.server, registration: client.registration) else { throw MCPOAuth.Failure.mixUpRisk }
        var scope = discovery.scope
        if let stepUp { scope = MCPOAuth.scope(challenge: MCPOAuth.Challenge(scope: stepUp), metadata: discovery.resource, granted: tokens(id)?.scope ?? config.oauth?.scope) }
        // The user's own app: the fixed port its registered redirect names.
        let listener = try LoopbackCallback(port: client.registration == .manual ? MCPOAuth.manualPort : 0)
        defer { listener.stop() }
        let flow = MCPOAuth.Flow(metadata: discovery.server, clientID: client.id, registration: client.registration,
                                 resource: discovery.resourceURL, scope: scope, port: listener.port,
                                 clientSecret: client.registration == .manual ? MCPSecrets.get(server: id, name: Self.clientSecretName) : nil)
        // Only a callback that passes the flow's checks ends the wait.
        listener.accepts = { (try? flow.code(fromCallback: $0)) != nil || $0.contains("error=") && $0.contains("state=\(flow.state)") }
        NSWorkspace.shared.open(flow.authorizationURL)
        let target = try await listener.wait(timeout: 300)
        let fresh = try await MCPOAuth.exchange(flow, callback: target, fetch: fetch)
        generation[id, default: 0] += 1
        store(fresh, for: id)
        config = hub.server(id) ?? config
        config.oauth = MCPOAuthState(metadata: discovery.server, clientID: client.id, registration: client.registration,
                                     resource: discovery.resourceURL, scope: fresh.scope ?? scope, needsSignIn: false)
        if !config.secretNames.contains(Self.tokensName) { config.secretNames.append(Self.tokensName) }
        hub.update(config)
    }

    /// Tokens gone (revoked where the server can), "Sign in" again.
    func signOut(_ id: UUID) async {
        if let state = hub.server(id)?.oauth, let endpoint = state.metadata.revocationEndpoint, let t = tokens(id),
           let resource = URL(string: state.resource), MCPOAuth.fetchable(endpoint, for: resource) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let token = (t.refreshToken ?? t.accessToken).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            request.httpBody = Data("token=\(token)&client_id=\(state.clientID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".utf8)
            _ = try? await fetch.fetch(request)
        }
        generation[id, default: 0] += 1
        await hub.stop(id)
        markNeedsSignIn(id, dropRegistration: false)
    }
}

/// One sign-in's redirect: a listener on 127.0.0.1 and a random port that
/// takes the first request, answers it with a short page, and closes.
final class LoopbackCallback: @unchecked Sendable {
    private let listener: NWListener
    /// Whether a request target is the callback awaited; others get a 400
    /// and the wait goes on (a stray request can't end the sign-in).
    var accepts: (@Sendable (String) -> Bool)?
    private let queue = DispatchQueue(label: "LLMTray sign-in callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var received: String?
    private(set) var port: UInt16 = 0

    /// `port` 0: any free one.
    init(port fixed: UInt16 = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: fixed == 0 ? .any : (NWEndpoint.Port(rawValue: fixed) ?? .any))
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let p = listener.port?.rawValue, p != 0 else {
            listener.cancel()
            throw MCPOAuth.Failure.badCallback("no local port for the sign-in")
        }
        port = p
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let text = String(decoding: data ?? Data(), as: UTF8.self)
            let line = text.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            let target = parts.count >= 2 && parts[0] == "GET" ? String(parts[1]) : ""
            let ok = target.hasPrefix("/callback") && (self?.accepts?(target) ?? false)
            let page = ok
                ? "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>Signed in</h2><p>You can close this tab and go back to LLMTray.</p></body></html>"
                : "<html><body>Not this sign-in.</body></html>"
            let response = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if ok { self?.deliver(target) }
        }
    }

    private func deliver(_ target: String) {
        lock.lock()
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(returning: target)
        } else {
            if received == nil { received = target }
            lock.unlock()
        }
    }

    /// The callback's request target, or a time-out.
    func wait(timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                lock.lock()
                if let received {
                    lock.unlock()
                    c.resume(returning: received)
                    return
                }
                continuation = c
                lock.unlock()
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.fail(MCPOAuth.Failure.badCallback("no answer within 5 minutes")) }
            }
        } onCancel: { [weak self] in
            self?.fail(CancellationError())
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: error)
    }

    func stop() {
        listener.cancel()
        fail(CancellationError())
    }
}
