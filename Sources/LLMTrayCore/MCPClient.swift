import Foundation

/// How the client reaches a server (adr/0027): a child's stdin and stdout,
/// or HTTP. Messages arrive through `onMessage`, one JSON-RPC message (or
/// batch) per call; `onClose` comes once, with why.
public protocol MCPTransport: AnyObject, Sendable {
    func open(onMessage: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String) -> Void) async throws
    func send(_ data: Data) async throws
    /// After initialize: HTTP sends it as `MCP-Protocol-Version`.
    func agreed(version: String)
    func close() async
}

public enum MCPError: Error, Equatable, LocalizedError {
    case closed(String)
    case timedOut
    case server(code: Int, message: String)
    case unsupportedVersion(String)
    case sessionExpired
    case badReply

    public var errorDescription: String? {
        switch self {
        case .closed(let why): return "The server stopped: \(why)"
        case .timedOut: return "The server didn't answer in time."
        case .server(_, let message): return "The server said: \(message)"
        case .unsupportedVersion(let v): return "The server speaks MCP \(v), which LLMTray doesn't."
        case .sessionExpired: return "The server's session ended."
        case .badReply: return "The server's reply couldn't be read."
        }
    }
}

/// One server's connection: initialize, list tools, call them. A call's
/// outcome is never guessed: no answer in time (or a Stop) is "unknown",
/// and nothing is ever sent twice (adr/0027, "Time limits").
public actor MCPClient {
    public struct ServerInfo: Sendable, Equatable {
        public var name: String
        public var version: String
        public var protocolVersion: String
        public var instructions: String?
    }

    public enum CallOutcome: Sendable, Equatable {
        /// The server answered: its text, and whether it is an error.
        case result(text: String, isError: Bool)
        /// Sent, but no answer in time, or Stop: it may have happened.
        case unknown
        /// Not sent (the server isn't there): nothing happened.
        case notSent(String)
    }

    private let transport: MCPTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<MCP.Message, Error>] = [:]
    private var closedReason: String?
    private var onToolsChanged: (@Sendable () -> Void)?
    public private(set) var info: ServerInfo?

    public init(transport: MCPTransport) {
        self.transport = transport
    }

    public func setToolsChanged(_ handler: @escaping @Sendable () -> Void) { onToolsChanged = handler }

    public var isOpen: Bool { info != nil && closedReason == nil }

    /// Opens the transport and initializes; throws when the server can't be
    /// reached, answers with a version we don't speak, or takes longer than
    /// `timeout`.
    public func start(timeout: TimeInterval = 20) async throws -> ServerInfo {
        try await transport.open(onMessage: { [weak self] data in
            guard let self else { return }
            Task { await self.receive(data) }
        }, onClose: { [weak self] why in
            guard let self else { return }
            Task { await self.closed(why) }
        })
        let result: [String: Any]
        do {
            guard let r = try await request("initialize", MCP.initializeParams(), timeout: timeout).result else { throw MCPError.badReply }
            result = r
        } catch {
            // Whatever went wrong, the child (or the session) goes with it.
            await close()
            throw error
        }
        let version = result["protocolVersion"] as? String ?? ""
        guard MCP.protocolVersions.contains(version) else {
            await close()
            throw MCPError.unsupportedVersion(version.isEmpty ? "?" : version)
        }
        transport.agreed(version: version)
        let server = result["serverInfo"] as? [String: Any]
        let info = ServerInfo(name: server?["name"] as? String ?? "", version: server?["version"] as? String ?? "",
                              protocolVersion: version, instructions: result["instructions"] as? String)
        self.info = info
        try? await transport.send(MCP.notification("notifications/initialized"))
        return info
    }

    /// Every tool, page by page (at most 50 pages).
    public func listTools(timeout: TimeInterval = 20) async throws -> [MCP.Tool] {
        var tools: [MCP.Tool] = []
        var cursor: String?
        for _ in 0..<50 {
            let reply = try await request("tools/list", cursor.map { ["cursor": $0] }, timeout: timeout)
            guard let result = reply.result else { throw MCPError.badReply }
            let page = MCP.parseTools(result)
            tools += page.tools
            guard tools.count < 1000 else { break }
            guard let next = page.next, !next.isEmpty, next != cursor else { break }
            cursor = next
        }
        return tools
    }

    /// One call. Cancelled (Stop) or past `timeout`: the server is told
    /// (`notifications/cancelled`, best effort) and the outcome is unknown.
    public func call(_ name: String, arguments: [String: Any], timeout: TimeInterval = 60) async -> CallOutcome {
        guard closedReason == nil, info != nil else { return .notSent(closedReason ?? "not started") }
        let id = nextID
        nextID += 1
        let data = MCP.request(id: id, method: "tools/call", params: ["name": name, "arguments": arguments])
        do {
            let reply = try await send(data, id: id, timeout: timeout)
            if let error = reply.error { return .result(text: "Error from the server: \(error.message)", isError: true) }
            guard let result = reply.result else { return .unknown }
            let text = MCP.resultText(result)
            return .result(text: text.text, isError: text.isError)
        } catch {
            if error is CancellationError || (error as? MCPError) == .timedOut {
                // Not waited for: a server that stopped reading would hold it.
                let transport = transport
                Task { try? await transport.send(MCP.notification("notifications/cancelled",
                                                                  params: ["requestId": id, "reason": "The user stopped it, or it took too long."])) }
            }
            return .unknown
        }
    }

    public func close() async {
        await transport.close()
        closed("closed")
    }

    // MARK: Plumbing


    private func request(_ method: String, _ params: [String: Any]?, timeout: TimeInterval) async throws -> MCP.Message {
        let id = nextID
        nextID += 1
        let reply = try await send(MCP.request(id: id, method: method, params: params), id: id, timeout: timeout)
        if let error = reply.error { throw MCPError.server(code: error.code, message: error.message) }
        return reply
    }

    private func send(_ data: Data, id: Int, timeout: TimeInterval) async throws -> MCP.Message {
        if let closedReason { throw MCPError.closed(closedReason) }
        let deadline = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1e9))
            await self?.fail(id, MCPError.timedOut)
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MCP.Message, Error>) in
                pending[id] = continuation
                // Stopped before the continuation was stored: the cancel
                // handler found nothing to fail.
                if Task.isCancelled {
                    fail(id, CancellationError())
                    return
                }
                // A write or a POST that fails may still have reached the
                // server: from here on a call's outcome is unknown, not "not sent".
                Task {
                    do {
                        try await transport.send(data)
                    } catch {
                        fail(id, (error as? MCPError) ?? MCPError.closed(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            Task { await self.fail(id, CancellationError()) }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
        // A lost session needs a new initialize: the client is done (its
        // owner starts another); the call's outcome stays unknown.
        if (error as? MCPError) == .sessionExpired { closed("the session ended") }
    }

    private func receive(_ data: Data) async {
        for message in MCP.Message.parse(data) {
            if let method = message.method {
                if let rawID = message.rawID {
                    // The server's own request: a ping is answered, anything
                    // else (sampling, roots) wasn't offered.
                    try? await transport.send(MCP.reply(to: rawID, result: method == "ping" ? [:] : nil))
                } else if method == "notifications/tools/list_changed" {
                    onToolsChanged?()
                }
                continue
            }
            if let id = message.rawID as? Int { pending.removeValue(forKey: id)?.resume(returning: message) }
        }
    }

    private func closed(_ why: String) {
        guard closedReason == nil else { return }
        closedReason = why
        let waiting = pending
        pending = [:]
        for (_, continuation) in waiting { continuation.resume(throwing: MCPError.closed(why)) }
    }
}

// MARK: - stdio

/// A server run as a child (adr/0027): its own process group, only the
/// environment given, the protocol on stdout (a line over 8 MB ends it),
/// stderr to `onLog`. `close` closes stdin, then SIGTERM, SIGKILL after 3 s.
public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?
    private let onLog: @Sendable (String) -> Void
    private let lock = NSLock()
    private var process: RunnerProcess?

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String?,
                onLog: @escaping @Sendable (String) -> Void = { _ in }) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.onLog = onLog
    }

    public func open(onMessage: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String) -> Void) async throws {
        let p = try RunnerProcess.spawn(executable, arguments, environment: environment, maxLineBytes: 8 << 20,
                                        inheritEnvironment: false, workingDirectory: workingDirectory)
        lock.withLock { process = p }
        p.start(onLine: onMessage, onExit: { status, tail in
            let why = p.failure ?? (status == 0 ? "exited" : "exited (status \(status))\(tail.isEmpty ? "" : ": \(tail.suffix(300))")")
            onClose(why)
        }, onStderr: onLog)
    }

    public func send(_ data: Data) async throws {
        guard let p = lock.withLock({ process }) else { throw MCPError.closed("not started") }
        var line = data
        line.append(0x0A)
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in p.send(line) { c.resume(returning: $0) } }
        if !ok { throw MCPError.closed("its input is closed") }
    }

    public func agreed(version: String) {}

    public func close() async {
        guard let p = lock.withLock({ () -> RunnerProcess? in defer { process = nil }; return process }) else { return }
        p.closeStdinWhenWritten()
        if await p.waitForExit(timeout: 1) { return }
        p.terminate()
        if await p.waitForExit(timeout: 3) { return }
        p.kill()
    }

    /// The environment a server gets (adr/0027): PATH, HOME, USER, LANG and
    /// TMPDIR from the app, then the server's own variables.
    public static func environment(adding own: [String: String], from app: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        for key in ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"] { env[key] = app[key] }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        env.merge(own) { $1 }
        return env
    }
}

// MARK: - HTTP

/// Streamable HTTP (adr/0027): a POST per message; a reply is JSON or an
/// SSE stream; the session id kept; the agreed version sent; a 404 on a
/// session means it ended. No OAuth.
public final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    public let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    private var sessionID: String?
    private var version: String?
    private var onMessage: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (String) -> Void)?
    private var closed = false
    /// SSE replies being read: cancelled by `close`.
    private var readers: [UUID: Task<Void, Never>] = [:]
    static let maxBody = 8 << 20

    public init(url: URL, headers: [String: String], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    public func open(onMessage: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String) -> Void) async throws {
        lock.withLock {
            self.onMessage = onMessage
            self.onClose = onClose
        }
    }

    public func agreed(version: String) { lock.withLock { self.version = version } }

    public func send(_ data: Data) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (sid, version, isClosed) = lock.withLock { (sessionID, self.version, closed) }
        if isClosed { throw MCPError.closed("closed") }
        // Delivered only while open: nothing comes in after close.
        let deliver: @Sendable (Data) -> Void = { [weak self] data in
            guard let self, let handler = self.lock.withLock({ self.closed ? nil : self.onMessage }) else { return }
            handler(data)
        }
        if let sid { request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.badReply }
        if let new = http.value(forHTTPHeaderField: "Mcp-Session-Id") { lock.withLock { sessionID = new } }
        if http.statusCode == 404, sid != nil {
            lock.withLock { sessionID = nil }
            throw MCPError.sessionExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.closed("HTTP \(http.statusCode)")
        }
        if http.statusCode == 202 { return }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("text/event-stream") {
            // Read on: the reply comes as an event, maybe after others. At
            // most 8 MB per event and 32 MB per stream; cancelled by close.
            let key = UUID()
            let reader = Task.detached { [weak self] in
                var event = ""
                var total = 0
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        total += line.utf8.count + 1
                        if total > Self.maxBody * 4 { break }
                        if line.hasPrefix("data:") {
                            event += (event.isEmpty ? "" : "\n") + line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if event.utf8.count > Self.maxBody { break }
                        } else if line.isEmpty, !event.isEmpty {
                            deliver(Data(event.utf8))
                            event = ""
                        }
                    }
                    if !event.isEmpty, !Task.isCancelled { deliver(Data(event.utf8)) }
                } catch {}
                self?.lock.withLock { _ = self?.readers.removeValue(forKey: key) }
            }
            lock.withLock { readers[key] = reader }
        } else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > Self.maxBody { throw MCPError.badReply }
            }
            if !body.isEmpty { deliver(body) }
        }
    }

    public func close() async {
        let (sid, closer, running) = lock.withLock { () -> (String?, (@Sendable (String) -> Void)?, [Task<Void, Never>]) in
            defer { sessionID = nil; onClose = nil; closed = true; readers = [:] }
            return (sessionID, onClose, Array(readers.values))
        }
        running.forEach { $0.cancel() }
        if let sid {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            _ = try? await session.data(for: request)
        }
        closer?("closed")
    }
}
