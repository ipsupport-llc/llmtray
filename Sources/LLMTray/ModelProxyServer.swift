import Foundation
import Network
import LLMTrayCore

/// Fronts the public port with a minimal hand-rolled HTTP reverse proxy
/// that can swap the model backing mlx_lm.server mid-flight, based on the
/// `model` field of each incoming request -- mlx_lm.server itself is a
/// single-model process with no hot-swap, so the public-facing port has
/// to be something this app controls directly, not the model process
/// itself. This is what makes "point any OpenAI-compatible client at any
/// local model by name" (the way LM Studio's server works) possible here.
///
/// Scoped deliberately to what this server's actual clients send: JSON
/// POST bodies sized by Content-Length (chat/completions clients don't
/// send chunked request bodies), and a small number of known endpoints.
/// No dependency was pulled in for this -- see the doc comment on
/// ModelRouter for why that trade-off was made deliberately.
@MainActor
final class ModelProxyServer {
    private let server: ServerManager
    private var listener: NWListener?
    private(set) var publicPort: Int?

    /// Largest request body accepted -- chat requests with a few inline
    /// images stay far below this; anything bigger is refused before it's
    /// buffered in memory.
    static let maxBodyBytes = 256 * 1024 * 1024

    init(server: ServerManager) {
        self.server = server
    }

    /// `completion` gets .success once the listener is actually listening,
    /// or .failure if it can't (port taken, invalid) -- also later, if a
    /// listening listener fails. Called on the main actor.
    func start(publicPort: Int, internalPort: Int, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard listener == nil else { return completion(.success(())) }
        guard (1...65_535).contains(publicPort), let port = NWEndpoint.Port(rawValue: UInt16(publicPort)) else {
            return completion(.failure(NSError(domain: "ModelProxyServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid port \(publicPort)"])))
        }
        do {
            try startListener(port: port, internalPort: internalPort, completion: completion)
            self.publicPort = publicPort
        } catch {
            completion(.failure(error))
        }
    }

    private func startListener(port: NWEndpoint.Port, internalPort: Int, completion: @escaping @MainActor (Result<Void, Error>) -> Void) throws {
        // NWListener binds every interface (confirmed live: `lsof` showed
        // "*:8765", reachable from any device on the same network) unless
        // explicitly constrained -- default here is loopback-only, opt-in
        // via the Advanced "Allow connections from local network" toggle,
        // not opt-out. Confirmed live which constructor actually does this:
        // requiredLocalEndpoint conflicts with also passing `on: port` (NWListener
        // throws POSIXErrorCode 22, "Invalid argument") since the endpoint
        // already carries its own port -- the port must come from
        // requiredLocalEndpoint alone here, not from a separate parameter.
        let listener: NWListener
        if UserDefaults.standard.bool(forKey: "llmtray.allowLAN") {
            listener = try NWListener(using: .tcp, on: port)
        } else {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: parameters)
        }
        listener.newConnectionHandler = { [weak self] connection in
            // NWListener's callback isn't statically MainActor-isolated even
            // though listener.start(queue: .main) guarantees it runs on the
            // main thread -- same bridging this file needs at every other
            // Network.framework callback below.
            Task { @MainActor [weak self] in
                self?.accept(connection, internalPort: internalPort)
            }
        }
        let listenerID = ObjectIdentifier(listener)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                // Ignore a listener that was already replaced / stopped.
                guard let self, let current = self.listener, ObjectIdentifier(current) == listenerID else { return }
                switch state {
                case .ready:
                    completion(.success(()))
                case .failed(let error):
                    self.stop()
                    completion(.failure(error))
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        publicPort = nil
    }

    // MARK: - Connection handling

    /// Connections whose request hasn't been read completely yet. A client
    /// that declares a big body and then stalls would otherwise keep its
    /// buffer (up to maxBodyBytes) forever -- reachable from the LAN when
    /// that's enabled.
    private var readingConnections: Set<ObjectIdentifier> = []
    private static let requestReadTimeout: TimeInterval = 120

    private func accept(_ connection: NWConnection, internalPort: Int) {
        connection.start(queue: .main)
        let id = ObjectIdentifier(connection)
        readingConnections.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestReadTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.readingConnections.remove(id) != nil else { return }
                // Cancelling fails the pending receive, which drops its buffer.
                connection.cancel()
            }
        }
        readHeaders(connection: connection, buffer: Data(), internalPort: internalPort)
    }

    private func readHeaders(connection: NWConnection, buffer: Data, internalPort: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                // Parsing and validation (sizes, Content-Length, request
                // line) live in LLMTrayCore.HTTPRequestParser, unit-tested.
                switch HTTPRequestParser.parseHead(buf, maxBodyBytes: Self.maxBodyBytes) {
                case .request(let head, let bodyOffset):
                    self.startBody(head, bodySoFar: Data(buf.dropFirst(bodyOffset)), connection: connection, internalPort: internalPort)
                case .reject(let status, let message):
                    self.sendError(connection: connection, status: status, message: message)
                case .needMoreData:
                    if isComplete || error != nil {
                        connection.cancel()
                    } else {
                        self.readHeaders(connection: connection, buffer: buf, internalPort: internalPort)
                    }
                }
            }
        }
    }

    private func startBody(_ head: HTTPRequestHead, bodySoFar: Data, connection: NWConnection, internalPort: Int) {
        if bodySoFar.count >= head.contentLength {
            route(method: head.method, path: head.path, headers: head.headers, body: bodySoFar.prefix(head.contentLength), connection: connection, internalPort: internalPort)
        } else {
            readBody(
                connection: connection, partialBody: bodySoFar, contentLength: head.contentLength,
                method: head.method, path: head.path, headers: head.headers, internalPort: internalPort
            )
        }
    }

    private func readBody(
        connection: NWConnection, partialBody: Data, contentLength: Int,
        method: String, path: String, headers: [String: String], internalPort: Int
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var body = partialBody
                if let data { body.append(data) }
                if body.count >= contentLength {
                    self.route(method: method, path: path, headers: headers, body: body.prefix(contentLength), connection: connection, internalPort: internalPort)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.readBody(
                        connection: connection, partialBody: body, contentLength: contentLength,
                        method: method, path: path, headers: headers, internalPort: internalPort
                    )
                }
            }
        }
    }

    // MARK: - Routing

    private func route(method: String, path: String, headers: [String: String], body: Data.SubSequence, connection: NWConnection, internalPort: Int) {
        readingConnections.remove(ObjectIdentifier(connection))
        let bodyData = Data(body)
        // Marked busy for the whole request, not just the eventual forward()
        // below -- a model switch (stopping the old process, loading the
        // new one) can itself take tens of seconds, and that's exactly the
        // kind of stretch a "busy" indicator should cover, not just the
        // per-token generation after it. Every exit path below -- switch
        // failure, forward()'s own invalid-URL guard, or eventual proxy
        // completion -- balances this with exactly one endRequest() call.
        server.beginRequest()
        Task {
            let modelName = Self.extractModelField(from: bodyData)
            let targetPath = modelName.flatMap(ModelCatalog.shared.resolve(modelName:))
            do {
                // Switches to the requested model (or reloads the last one
                // if it was idle-unloaded), serialized with every other
                // transition; the request then counts as in flight on the
                // model until forward() ends it.
                try await self.server.acquireModel(modelPath: targetPath, alias: modelName ?? "")
            } catch {
                self.server.endRequest(forwarded: false)
                self.sendError(connection: connection, message: "model load failed: \(error.localizedDescription)")
                return
            }
            self.forward(method: method, path: path, headers: headers, body: bodyData, connection: connection, internalPort: internalPort)
        }
    }

    private static func extractModelField(from body: Data) -> String? {
        guard !body.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj["model"] as? String
    }

    // MARK: - Forwarding

    private func forward(method: String, path: String, headers: [String: String], body: Data, connection: NWConnection, internalPort: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(internalPort)\(path)") else {
            server.endRequest()
            connection.cancel()
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers where key != "host" && key != "content-length" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !body.isEmpty {
            request.httpBody = body
        }
        request.timeoutInterval = 300

        // Balances route()'s beginRequest() -- called once, exactly when the
        // internal mlx_lm.server call fully finishes (success or failure)
        // *or* the stall watchdog below gives up on it, not when the last
        // byte reaches the downstream client afterward (that's just local
        // I/O, not model activity).
        let delegate = ProxyForwardDelegate(connection: connection, server: server)
        let queue = OperationQueue()
        queue.underlyingQueue = .main
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)
        delegate.own(session)
        session.dataTask(with: request).resume()
    }

    private func sendError(connection: NWConnection, status: String = "502 Bad Gateway", message: String) {
        let escaped = message.replacingOccurrences(of: "\"", with: "'")
        let body = "{\"error\":\"\(escaped)\"}"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Streams the internal mlx_lm.server's response back onto the original
/// downstream connection. URLSession already de-chunks whatever transfer
/// encoding the internal server used, so the response is always
/// re-emitted as our own fresh chunked stream -- forwarding an original
/// "Transfer-Encoding: chunked" header while sending already-decoded
/// bytes would desync the downstream client's own framing.
private final class ProxyForwardDelegate: NSObject, URLSessionDataDelegate {
    private let connection: NWConnection
    private weak var server: ServerManager?
    private var session: URLSession?
    private var headersSent = false
    // Guards against double-handling: the stall watchdog and the normal
    // didCompleteWithError path can both fire for the same request (once
    // the watchdog cancels the session, that cancellation itself triggers
    // didCompleteWithError again) -- everything that matters (endRequest(),
    // sending a response, tearing down the connection) must happen exactly
    // once regardless of which path gets there first.
    private var finished = false
    private var lastActivityAt = Date()
    private var stallTimer: Timer?

    // No response headers *and* no streamed data for this long means
    // something is actually stuck -- a hung model process, a GPU deadlock,
    // whatever -- not just a slow one; a legitimate long prompt prefill
    // still streams a "Starting httpd"-adjacent response and then tokens
    // well within a minute in every case seen so far. Comfortably inside
    // forward()'s own URLRequest.timeoutInterval (300s) so this fires
    // first, leaving a diagnosable log line and a real error response for
    // the caller instead of the busy indicator staying lit indefinitely
    // and the caller hanging silently until that much longer timeout.
    // Configurable (Advanced settings) since "comfortably inside 300s" is
    // a judgment call that depends on how slow this machine's prefill
    // legitimately gets on a big model/prompt.
    private let stallThreshold: TimeInterval

    init(connection: NWConnection, server: ServerManager) {
        self.connection = connection
        self.server = server
        let configured = UserDefaults.standard.object(forKey: "llmtray.stallThresholdSeconds") as? Int ?? 60
        self.stallThreshold = TimeInterval(configured)
        super.init()
        // Polls rather than a single one-shot timer so activity resets the
        // clock without needing to cancel/reschedule anything from
        // didReceive -- it only has to bump lastActivityAt.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForStall()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    func own(_ session: URLSession) {
        self.session = session
        watchDownstream()
    }

    /// The client went away (Stop in the chat, a cancelled benchmark, a
    /// closed curl): cancel the upstream generation too. Otherwise it keeps
    /// running to max_tokens, holds the GPU, and a model switch or restart
    /// waiting for in-flight requests waits on it. A pending receive is how
    /// NWConnection notices the peer closing; clients send nothing more
    /// after the request body.
    private func watchDownstream() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                if isComplete || error != nil {
                    self.cancelUpstream()
                } else if data != nil {
                    self.watchDownstream()
                }
            }
        }
    }

    private func cancelUpstream() {
        MainActor.assumeIsolated {
            guard !finished else { return }
            // didCompleteWithError(cancelled) follows and ends the request.
            session?.invalidateAndCancel()
        }
    }

    private func checkForStall() {
        MainActor.assumeIsolated {
            guard !finished, Date().timeIntervalSince(lastActivityAt) > stallThreshold else { return }
            server?.appendLog(
                "--- proxy: no response from mlx_lm.server for \(Int(stallThreshold))s -- treating as stalled and resetting ---\n"
            )
            _ = finish(stalled: true)
        }
    }

    /// The single place endRequest() actually gets called for this
    /// delegate's request, from whichever path (normal completion or
    /// stall) reaches it first. Returns whether *this* call was the one
    /// that actually did it -- callers that also want to react (send their
    /// own response, etc.) must check this, since cancelling the session
    /// on the stall path makes URLSession call didCompleteWithError again
    /// afterward, and that second call must not repeat any of this.
    @discardableResult
    private func finish(stalled: Bool) -> Bool {
        var didFinish = false
        MainActor.assumeIsolated {
            guard !finished else { return }
            finished = true
            didFinish = true
            stallTimer?.invalidate()
            // Stalled and normal completions are tracked separately --
            // ServerManager only restarts the process on an unbroken streak
            // of stalls, so a genuine completion needs to actually reset
            // that streak, not just decrement the same busy counter.
            if stalled {
                server?.endRequestStalled()
            } else {
                server?.endRequest()
            }
            guard stalled else { return }
            session?.invalidateAndCancel()
            if headersSent {
                connection.cancel()
            } else {
                let body = "{\"error\":\"upstream stalled with no response\"}"
                let response = "HTTP/1.1 504 Gateway Timeout\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
                    self?.connection.cancel()
                })
            }
        }
        return didFinish
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        MainActor.assumeIsolated { lastActivityAt = Date() }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
        for (key, value) in http.allHeaderFields {
            guard let keyStr = key as? String else { continue }
            let lower = keyStr.lowercased()
            if lower == "connection" || lower == "transfer-encoding" || lower == "content-length" { continue }
            head += "\(keyStr): \(value)\r\n"
        }
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        connection.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in })
        headersSent = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated { lastActivityAt = Date() }
        guard !data.isEmpty else { return }
        var chunk = Data(String(format: "%x\r\n", data.count).utf8)
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            self?.cancelUpstream()
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // The internal mlx_lm.server call is fully done at this point
        // (successfully or not) regardless of which branch below runs --
        // that's the actual end of "busy," not whenever the last byte
        // finishes being written back to the downstream client. Bails
        // entirely if the stall watchdog already handled (and responded
        // to) this request -- this fires again once that watchdog's own
        // session.invalidateAndCancel() completes, and sending a second
        // response after the 504 already went out would be wrong.
        guard finish(stalled: false) else { return }
        if let error, !headersSent {
            // Failed before ever getting a response (e.g. the internal
            // mlx_lm.server wasn't reachable) -- a bare chunk terminator
            // with no status line ahead of it isn't valid HTTP and reads
            // to clients as a truncated/garbage response (curl reports
            // this as "Received HTTP/0.9 when not allowed"). Send a real
            // status line so the failure is at least legible.
            let body = "{\"error\":\"\(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))\"}"
            let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
                self?.session = nil
            })
            return
        }
        connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.session = nil
        })
    }
}
