import Foundation
import LLMTrayCore
import Network

/// The only way a page read (WebPageReader) reaches the network: an HTTP
/// CONNECT proxy on this Mac's loopback, one per read. It resolves each
/// host itself, refuses one that is (or resolves to) this Mac or a local or
/// private network, and connects to the very address it checked -- so a
/// name can't pass the check and then point elsewhere (DNS rebinding), and
/// a page's images, scripts, fetches and WebSockets go through the same
/// check as the page. It also caps what one read may download and how long
/// it may take.
final class WebPageProxy: @unchecked Sendable {
    /// What one read may download in all (the page and what it asks for).
    static let budgetBytes = 25 << 20
    /// How long one read may take.
    static let deadline: TimeInterval = 25
    /// Ports a page may reach.
    static let ports: Set<UInt16> = [80, 443]

    private let queue = DispatchQueue(label: "LLMTray.webPageProxy")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var received = 0
    private var stopped = false
    /// Its start was answered (ready or failed).
    private var listening = false

    /// The proxy's port once it listens.
    private(set) var port: UInt16 = 0

    /// Starts listening on 127.0.0.1 (a free port).
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // On the proxy's queue only.
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.listening else { return }
                switch state {
                case .ready:
                    self.listening = true
                    self.port = listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    self.listening = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        // The deadline: everything stops then.
        queue.asyncAfter(deadline: .now() + Self.deadline) { [weak self] in self?.stopNow() }
    }

    func stop() { queue.async { [weak self] in self?.stopNow() } }

    private func stopNow() {
        guard !stopped else { return }
        stopped = true
        listener?.cancel()
        connections.forEach { $0.cancel() }
        connections = []
    }

    // MARK: Connections

    private func accept(_ client: NWConnection) {
        guard !stopped else { client.cancel(); return }
        connections.append(client)
        client.start(queue: queue)
        readHead(client, Data())
    }

    /// Reads the CONNECT request (its head, at most 8 KB).
    private func readHead(_ client: NWConnection, _ buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self, !self.stopped else { client.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.connect(client, head: buffer[..<end.lowerBound], rest: buffer[end.upperBound...])
            } else if done || error != nil || buffer.count > 8192 {
                client.cancel()
            } else {
                self.readHead(client, buffer)
            }
        }
    }

    private func refuse(_ client: NWConnection, _ status: String) {
        client.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in client.cancel() })
    }

    private func connect(_ client: NWConnection, head: Data, rest: Data) {
        let line = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "CONNECT", let target = Self.hostPort(String(parts[1])),
              Self.ports.contains(target.port) else {
            return refuse(client, "405 Method Not Allowed")
        }
        // Resolved here, off the proxy's queue: getaddrinfo blocks.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let address = Self.publicAddress(target.host) else {
                self.queue.async { self.refuse(client, "403 Forbidden") }
                return
            }
            self.queue.async { self.open(client, to: address, port: target.port, rest: rest) }
        }
    }

    private func open(_ client: NWConnection, to address: String, port: UInt16, rest: Data) {
        guard !stopped, let p = NWEndpoint.Port(rawValue: port) else { return client.cancel() }
        // The address that was checked, not the name again.
        let server = NWConnection(host: NWEndpoint.Host(address), port: p, using: .tcp)
        connections.append(server)
        server.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                if !rest.isEmpty { server.send(content: rest, completion: .contentProcessed { _ in }) }
                self.pipe(from: client, to: server, counted: false)
                self.pipe(from: server, to: client, counted: true)
            case .failed, .cancelled:
                client.cancel()
            default: break
            }
        }
        server.start(queue: queue)
    }

    /// Bytes from one side to the other; what comes from the sites counts
    /// against the read's budget.
    private func pipe(from source: NWConnection, to sink: NWConnection, counted: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                if counted {
                    self.received += data.count
                    if self.received > Self.budgetBytes { return self.stopNow() }
                }
                sink.send(content: data, completion: .contentProcessed { _ in })
            }
            if done || error != nil {
                sink.send(content: nil, isComplete: true, completion: .contentProcessed { _ in sink.cancel() })
                source.cancel()
                return
            }
            self.pipe(from: source, to: sink, counted: counted)
        }
    }

    // MARK: Addresses

    /// "host:port" or "[v6]:port".
    static func hostPort(_ s: String) -> (host: String, port: UInt16)? {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            guard after.hasPrefix(":"), let port = UInt16(after.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":"), let port = UInt16(s[s.index(after: colon)...]) else { return nil }
        return (String(s[..<colon]), port)
    }

    /// The host's first address when none of its addresses is this Mac or a
    /// local or private network; nil when one is, or it doesn't resolve.
    static func publicAddress(_ host: String) -> String? {
        if MCPOAuth.isLocal(host, resolve: { _ in [] }) { return nil }
        if let literal = MCPOAuth.IPAddress(literal: host) {
            return literal.isLocal ? nil : literal.text
        }
        let addresses = MCPOAuth.IPAddress.resolve(host)
        guard !addresses.isEmpty, !addresses.contains(where: \.isLocal) else { return nil }
        return addresses.first?.text
    }
}
