import Foundation
import LLMTrayCore
import Network

/// The only way a page read (WebPageReader) reaches the network: an HTTP
/// CONNECT proxy on this Mac's loopback, one per read, open only to that
/// read (a password of its own). It resolves each host itself, refuses one
/// that is (or resolves to) this Mac, a local or private network, or a
/// network this Mac is on, and connects to the very address it checked --
/// so a name can't pass the check and then point elsewhere (DNS
/// rebinding), and a page's images, scripts, fetches and WebSockets go
/// through the same check as the page. It also caps what one read may
/// move and how long it may take.
final class WebPageProxy: @unchecked Sendable {
    /// What one read may download in all (the page and what it asks for).
    static let budgetBytes = 25 << 20
    /// What it may send (requests, uploads a page starts).
    static let sendBudgetBytes = 2 << 20
    /// How long one read may take.
    static let deadline: TimeInterval = 25
    /// Ports a page may reach.
    static let ports: Set<UInt16> = [80, 443]
    /// Connections at once.
    static let maxConnections = 48

    /// The read's credentials: only it can use the proxy.
    let user = "llmtray"
    let password = UUID().uuidString

    private let queue = DispatchQueue(label: "LLMTray.webPageProxy")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var received = 0
    private var sent = 0
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
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, !self.listening else { return }
                switch state {
                case .ready:
                    self.listening = true
                    self.port = listener?.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    self.listening = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        // The deadline: everything stops then (held strongly till then).
        queue.asyncAfter(deadline: .now() + Self.deadline) { self.stopNow() }
    }

    /// Ends it now; held until done, whoever lets go of the proxy first.
    func stop() { queue.async { self.stopNow() } }

    private func stopNow() {
        guard !stopped else { return }
        stopped = true
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections = [:]
    }

    // MARK: Connections

    private func track(_ c: NWConnection) -> Bool {
        guard !stopped, connections.count < Self.maxConnections else { c.cancel(); return false }
        connections[ObjectIdentifier(c)] = c
        return true
    }

    private func drop(_ c: NWConnection) {
        c.cancel()
        connections[ObjectIdentifier(c)] = nil
    }

    private func accept(_ client: NWConnection) {
        guard track(client) else { return }
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
                self.drop(client)
            } else {
                self.readHead(client, buffer)
            }
        }
    }

    private func refuse(_ client: NWConnection, _ status: String, extra: String = "") {
        client.send(content: Data("HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { [weak self] _ in self?.queue.async { self?.drop(client) } })
    }

    private func connect(_ client: NWConnection, head: Data, rest: Data) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        // Only this read: its password, or a 407 asking for it.
        let expected = "basic " + Data("\(user):\(password)".utf8).base64EncodedString().lowercased()
        let auth = lines.dropFirst().first { $0.lowercased().hasPrefix("proxy-authorization:") }
            .map { $0.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces).lowercased() }
        guard auth == expected else {
            return refuse(client, "407 Proxy Authentication Required", extra: "Proxy-Authenticate: Basic realm=\"LLMTray\"\r\n")
        }
        guard parts.count >= 2, parts[0] == "CONNECT", let target = Self.hostPort(String(parts[1])),
              Self.ports.contains(target.port) else {
            return refuse(client, "405 Method Not Allowed")
        }
        // Resolved here, off the proxy's queue: getaddrinfo blocks.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let address = Self.publicAddress(target.host)
            self.queue.async {
                guard let address else { return self.refuse(client, "403 Forbidden") }
                self.open(client, to: address, port: target.port, rest: rest)
            }
        }
    }

    private func open(_ client: NWConnection, to address: String, port: UInt16, rest: Data) {
        guard !stopped, let p = NWEndpoint.Port(rawValue: port) else { return drop(client) }
        // The address that was checked, not the name again.
        let server = NWConnection(host: NWEndpoint.Host(address), port: p, using: .tcp)
        guard track(server) else { return drop(client) }
        server.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                if !rest.isEmpty { server.send(content: rest, completion: .contentProcessed { _ in }) }
                self.pipe(from: client, to: server, upstream: true)
                self.pipe(from: server, to: client, upstream: false)
            case .failed, .cancelled:
                self.drop(client)
                self.drop(server)
            default: break
            }
        }
        server.start(queue: queue)
    }

    /// Bytes from one side to the other, the next read only once these are
    /// sent (nothing piles up); both directions count against the read's
    /// budgets.
    private func pipe(from source: NWConnection, to sink: NWConnection, upstream: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, !self.stopped else { return }
            let finish = {
                sink.send(content: nil, isComplete: true, completion: .contentProcessed { _ in })
                self.drop(source)
                self.drop(sink)
            }
            guard let data, !data.isEmpty else {
                if done || error != nil { finish() } else { self.pipe(from: source, to: sink, upstream: upstream) }
                return
            }
            if upstream { self.sent += data.count } else { self.received += data.count }
            if self.received > Self.budgetBytes || self.sent > Self.sendBudgetBytes { return self.stopNow() }
            sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                self?.queue.async {
                    guard let self, !self.stopped else { return }
                    if sendError != nil || done || error != nil { return finish() }
                    self.pipe(from: source, to: sink, upstream: upstream)
                }
            })
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

    /// The host's first address when none of its addresses is this Mac, a
    /// local or private network, or on a network this Mac is on; nil when
    /// one is, or it doesn't resolve.
    static func publicAddress(_ host: String) -> String? {
        if MCPOAuth.isLocal(host, resolve: { _ in [] }) { return nil }
        let addresses: [MCPOAuth.IPAddress]
        if let literal = MCPOAuth.IPAddress(literal: host) {
            addresses = [literal]
        } else {
            addresses = MCPOAuth.IPAddress.resolve(host)
        }
        let networks = LocalNetworks.current()
        guard !addresses.isEmpty, !addresses.contains(where: { $0.isLocal || networks.contains($0) }) else { return nil }
        return addresses.first?.text
    }
}

/// The networks this Mac is on (its interfaces' addresses and masks): a
/// publicly numbered LAN or this Mac's own global IPv6 address is as local
/// as 192.168.x.x.
enum LocalNetworks {
    struct Network {
        let address: [UInt8]
        let mask: [UInt8]
        func contains(_ ip: [UInt8]) -> Bool {
            ip.count == address.count && zip(zip(ip, address), mask).allSatisfy { ($0.0 & $1) == ($0.1 & $1) }
        }
    }

    static func current() -> [Network] {
        var out: [Network] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(first) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = p {
            if let sa = entry.pointee.ifa_addr, let nm = entry.pointee.ifa_netmask {
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                    let m = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                    out.append(Network(address: a, mask: m))
                case AF_INET6:
                    let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                    let m = nm.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                    out.append(Network(address: a, mask: m))
                default: break
                }
            }
            p = entry.pointee.ifa_next
        }
        return out
    }
}

extension Array where Element == LocalNetworks.Network {
    func contains(_ ip: MCPOAuth.IPAddress) -> Bool {
        let bytes: [UInt8]
        switch ip {
        case .v4(let a): bytes = [UInt8(a >> 24), UInt8((a >> 16) & 0xff), UInt8((a >> 8) & 0xff), UInt8(a & 0xff)]
        case .v6(let b): bytes = b
        }
        return contains { $0.contains(bytes) }
    }
}
