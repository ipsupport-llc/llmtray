import Foundation
import Network
import LLMTrayCore

/// The public port: a small reverse proxy that picks the model by each
/// request's `model` field and switches mlx_lm.server (one model per
/// process) as needed. Scoped to JSON bodies sized by Content-Length.
/// Why it exists and the rules it keeps: adr/0002-model-proxy-and-lifecycle.md.
@MainActor
final class ModelProxyServer {
    private let server: ServerManager
    private var listener: NWListener?
    private(set) var publicPort: Int?
    /// Whether the running listener takes connections from the network.
    private(set) var listensOnLAN = false

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
        listensOnLAN = UserDefaults.standard[Pref.allowLAN]
        if listensOnLAN {
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

    /// Connections still sending their request: each may hold a body of up
    /// to maxBodyBytes for requestReadTimeout (with LAN on, from anyone).
    private static let maxReadingConnections = 32

    private func accept(_ connection: NWConnection, internalPort: Int) {
        guard readingConnections.count < Self.maxReadingConnections else {
            connection.start(queue: .main)
            sendError(connection: connection, status: "503 Service Unavailable", message: "too many requests in progress")
            return
        }
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
                    self.readingConnections.remove(ObjectIdentifier(connection))
                    self.sendError(connection: connection, status: status, message: message)
                case .needMoreData:
                    if isComplete || error != nil {
                        self.readingConnections.remove(ObjectIdentifier(connection))
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
            let buffer = BodyBuffer(bodySoFar, capacity: head.contentLength)
            readBody(
                connection: connection, buffer: buffer, contentLength: head.contentLength,
                method: head.method, path: head.path, headers: head.headers, internalPort: internalPort
            )
        }
    }

    /// One growing buffer for a request body: appending to a Data copied
    /// per chunk made a 50 MB image body cost gigabytes of copying on the
    /// main thread.
    private final class BodyBuffer {
        var data: Data
        init(_ start: Data, capacity: Int) {
            data = Data(capacity: capacity)
            data.append(start)
        }
    }

    private func readBody(
        connection: NWConnection, buffer: BodyBuffer, contentLength: Int,
        method: String, path: String, headers: [String: String], internalPort: Int
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(1 << 20, max(1, contentLength - buffer.data.count))) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data { buffer.data.append(data) }
                if buffer.data.count >= contentLength {
                    self.route(method: method, path: path, headers: headers, body: buffer.data.prefix(contentLength), connection: connection, internalPort: internalPort)
                } else if isComplete || error != nil {
                    self.readingConnections.remove(ObjectIdentifier(connection))
                    connection.cancel()
                } else {
                    self.readBody(
                        connection: connection, buffer: buffer, contentLength: contentLength,
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
        // The model list comes from the catalog: mlx_lm.server's own lists
        // its Hugging Face cache (image models included), names this proxy
        // would refuse below.
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if route.hasPrefix("/v1/models") || route.hasPrefix("/api/v0/models") {
            serveModels(route: route, method: method, headers: headers, connection: connection)
            return
        }
        // CORS preflight: answered here (mlx_lm.server answers it the same
        // way), not a reason to load or wait for a model.
        if method == "OPTIONS" {
            let asked = headers["access-control-request-headers"].map { $0.filter { $0 != "\r" && $0 != "\n" } }
            let allowed = asked.map { "\($0), Authorization" } ?? "*, Authorization"
            let response = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: *\r\nAccess-Control-Allow-Headers: \(allowed)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        // A body Foundation can't read as a JSON object (NaN, a lone
        // surrogate, 1e999: Python's json takes them) would pass unchecked
        // -- model allowlist and rewrite skipped -- and mlx_lm.server would
        // load whatever it names. Refused.
        if !bodyData.isEmpty, (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] == nil {
            sendError(connection: connection, status: "400 Bad Request", message: "the request body must be a JSON object")
            return
        }
        let modelName = ProxyRequestBody.requestedModel(bodyData)
        let targetPath = modelName.flatMap { ModelCatalog.shared.resolve(modelName: $0) ?? server.modelPath(launchedAs: $0) }
        // A name the catalog doesn't know must not reach mlx_lm.server: it
        // would load it itself -- any path, or a Hugging Face repo,
        // downloading it -- bypassing the model switch and its profile.
        if let modelName, targetPath == nil {
            let known = ModelCatalog.shared.servedNames
            sendJSON(connection: connection, status: "404 Not Found", Self.notFound(
                "The model '\(modelName)' is not in LLMTray's models folder. Available: \(known.isEmpty ? "none" : known.joined(separator: ", "))"
            ))
            return
        }
        // A bodyless probe (GET /health) isn't use: it mustn't keep the
        // model from idle-unloading.
        let activity = !bodyData.isEmpty
        server.beginRequest(activity: activity)
        Task {
            do {
                // Switches to the requested model (or reloads the last one
                // if it was idle-unloaded), serialized with every other
                // transition; the request then counts as in flight on the
                // model until forward() ends it.
                try await self.server.acquireModel(modelPath: targetPath, alias: modelName ?? "", loadIfUnloaded: !bodyData.isEmpty)
            } catch {
                self.server.endRequest(forwarded: false, activity: activity)
                self.sendError(connection: connection, message: "model load failed: \(error.localizedDescription)")
                return
            }
            // Only now: the backend's name for its model is the one the
            // model just acquired was launched with (no switch can happen
            // while this request counts as forwarding).
            // The profile's sampling where the client set none: current
            // values, so changing them never needs a restart.
            let body = ProxyRequestBody.rewrite(bodyData, backendModel: self.server.backendModelName, defaults: self.server.requestDefaults())
            self.forward(method: method, path: path, headers: headers, body: body, connection: connection, internalPort: internalPort, activity: activity)
        }
    }

    /// GET /v1/models (and /v1/models/<id>, LM Studio's /api/v0/models)
    /// from the catalog: mlx_lm.server's own lists its Hugging Face cache,
    /// image models included -- names this proxy refuses.
    private func serveModels(route: String, method: String, headers: [String: String], connection: NWConnection) {
        if method == "OPTIONS" {
            // CORS preflight. "*" doesn't cover Authorization, so the
            // headers asked for are allowed by name.
            let asked = headers["access-control-request-headers"].map { $0.filter { $0 != "\r" && $0 != "\n" } }
            let allowed = asked.map { "\($0), Authorization" } ?? "*, Authorization"
            let response = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, OPTIONS\r\nAccess-Control-Allow-Headers: \(allowed)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        guard method == "GET" else {
            sendJSON(connection: connection, status: "405 Method Not Allowed", ["error": ["message": "use GET", "type": "invalid_request_error"] as [String: Any]])
            return
        }
        let names = ModelCatalog.shared.servedNames
        let prefix = route.hasPrefix("/v1/models") ? "/v1/models" : "/api/v0/models"
        let id = String(route.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
        if id.isEmpty {
            sendJSON(connection: connection, Self.modelList(names))
        } else if let entry = (Self.modelList(names)["data"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) {
            sendJSON(connection: connection, entry)
        } else {
            sendJSON(connection: connection, status: "404 Not Found", Self.notFound("The model '\(id)' does not exist"))
        }
    }

    private static func notFound(_ message: String) -> [String: Any] {
        ["error": ["message": message, "type": "invalid_request_error", "param": "model", "code": "model_not_found"] as [String: Any]]
    }

    /// OpenAI's GET /v1/models shape.
    static func modelList(_ names: [String]) -> [String: Any] {
        var seen = Set<String>()
        let data: [[String: Any]] = names.filter { seen.insert($0).inserted }.map {
            ["id": $0, "object": "model", "created": 0, "owned_by": "llmtray"]
        }
        return ["object": "list", "data": data]
    }

    // MARK: - Forwarding

    private func forward(method: String, path: String, headers: [String: String], body: Data, connection: NWConnection, internalPort: Int, activity: Bool = true) {
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
        let delegate = ProxyForwardDelegate(connection: connection, server: server, activity: activity)
        let queue = OperationQueue()
        queue.underlyingQueue = .main
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)
        delegate.own(session)
        session.dataTask(with: request).resume()
    }

    private func sendJSON(connection: NWConnection, status: String = "200 OK", _ object: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        // CORS as mlx_lm.server sends it (browser clients read these too).
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendError(connection: NWConnection, status: String = "502 Bad Gateway", message: String) {
        let body = String(decoding: (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8), as: UTF8.self)
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

    // No headers and no data for this long = stuck, not slow; fires well
    // inside the request's 300 s timeout (Settings; adr/0002).
    private let stallThreshold: TimeInterval

    /// Counts toward idle (see ServerManager.beginRequest).
    private let activity: Bool

    init(connection: NWConnection, server: ServerManager, activity: Bool = true) {
        self.connection = connection
        self.server = server
        self.activity = activity
        let configured = UserDefaults.standard[Pref.stallThresholdSeconds]
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
            // Only once the response has started: before its headers,
            // silence is normal -- a non-streaming request sends nothing
            // until it's done, and one queued behind another (always, with
            // an MTP drafter) waits. That stretch is the request timeout's
            // (didCompleteWithError).
            guard !finished, headersSent, Date().timeIntervalSince(lastActivityAt) > stallThreshold else { return }
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
                server?.endRequestStalled(activity: activity)
            } else {
                server?.endRequest(activity: activity)
            }
            guard stalled else { return }
            session?.invalidateAndCancel()
            if headersSent {
                connection.cancel()
            } else {
                let body = "{\"error\":\"upstream stalled with no response\"}"
                let response = "HTTP/1.1 504 Gateway Timeout\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [connection] _ in
                    connection.cancel()
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
        // Nothing for the whole request timeout (before or after the
        // headers): a stall -- it counts toward restarting a wedged process.
        if let error, (error as NSError).code == NSURLErrorTimedOut {
            _ = finish(stalled: true)
            return
        }
        guard finish(stalled: false) else { return }
        // Done either way: a URLSession keeps its delegate (and this
        // connection) until it's invalidated.
        defer { session.finishTasksAndInvalidate() }
        if error != nil, headersSent {
            // Cut off mid-response (the process died or was switched): no
            // clean terminator, or the client takes a truncated answer for
            // a whole one.
            connection.cancel()
            return
        }
        if let error, !headersSent {
            // Failed before ever getting a response (e.g. the internal
            // mlx_lm.server wasn't reachable) -- a bare chunk terminator
            // with no status line ahead of it isn't valid HTTP and reads
            // to clients as a truncated/garbage response (curl reports
            // this as "Received HTTP/0.9 when not allowed"). Send a real
            // status line so the failure is at least legible.
            let body = "{\"error\":\"\(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))\"}"
            let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            // The connection strongly: invalidating the session can release
            // this delegate before the send completes.
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
            return
        }
        connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}
