import Foundation
import Network

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
    private var currentModelPath: String?

    init(server: ServerManager) {
        self.server = server
    }

    func start(publicPort: Int, internalPort: Int) throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(publicPort)) else {
            throw NSError(domain: "ModelProxyServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid port \(publicPort)"])
        }
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            // NWListener's callback isn't statically MainActor-isolated even
            // though listener.start(queue: .main) guarantees it runs on the
            // main thread -- same bridging this file needs at every other
            // Network.framework callback below.
            Task { @MainActor [weak self] in
                self?.accept(connection, internalPort: internalPort)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        self.publicPort = publicPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        publicPort = nil
    }

    /// Set once by ServerManager right after its own initial launch --
    /// without this, the very first request would see currentModelPath as
    /// nil and (harmlessly, but pointlessly) trigger a "switch" to the
    /// model that's already loaded.
    func noteCurrentModel(_ path: String) {
        currentModelPath = path
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection, internalPort: Int) {
        connection.start(queue: .main)
        readHeaders(connection: connection, buffer: Data(), internalPort: internalPort)
    }

    private static let headerTerminator = Data([13, 10, 13, 10]) // \r\n\r\n

    private func readHeaders(connection: NWConnection, buffer: Data, internalPort: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let range = buf.range(of: Self.headerTerminator) {
                    self.finishHeaders(buf, headerEnd: range, connection: connection, internalPort: internalPort)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.readHeaders(connection: connection, buffer: buf, internalPort: internalPort)
                }
            }
        }
    }

    private func finishHeaders(_ buf: Data, headerEnd: Range<Data.Index>, connection: NWConnection, internalPort: Int) {
        guard let headerText = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) else {
            connection.cancel()
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodySoFar = Data(buf[headerEnd.upperBound...])
        if bodySoFar.count >= contentLength {
            route(method: method, path: path, headers: headers, body: bodySoFar.prefix(contentLength), connection: connection, internalPort: internalPort)
        } else {
            readBody(
                connection: connection, partialBody: bodySoFar, contentLength: contentLength,
                method: method, path: path, headers: headers, internalPort: internalPort
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
        let bodyData = Data(body)
        Task {
            if let modelName = Self.extractModelField(from: bodyData),
               let targetPath = ModelRouter.resolve(modelName: modelName),
               targetPath != self.currentModelPath {
                do {
                    try await self.server.switchModel(modelPath: targetPath, alias: modelName)
                    self.currentModelPath = targetPath
                } catch {
                    self.sendError(connection: connection, message: "model switch failed: \(error.localizedDescription)")
                    return
                }
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

        let delegate = ProxyForwardDelegate(connection: connection)
        let queue = OperationQueue()
        queue.underlyingQueue = .main
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)
        delegate.own(session)
        session.dataTask(with: request).resume()
    }

    private func sendError(connection: NWConnection, message: String) {
        let escaped = message.replacingOccurrences(of: "\"", with: "'")
        let body = "{\"error\":\"\(escaped)\"}"
        let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
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
    private var session: URLSession?
    private var headersSent = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func own(_ session: URLSession) {
        self.session = session
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
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
        guard !data.isEmpty else { return }
        var chunk = Data(String(format: "%x\r\n", data.count).utf8)
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        connection.send(content: chunk, completion: .contentProcessed { _ in })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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
