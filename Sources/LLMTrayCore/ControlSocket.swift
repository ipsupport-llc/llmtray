import Darwin
import Foundation

/// The control socket's transport (adr/0019 §1): a Unix domain socket,
/// owner-only. Here rather than in the app so the round trip -- bind,
/// accept, a request in, reply lines out -- is tested in-process, and the
/// CLI shares the client half. What the commands do is the app's
/// (ControlCommands); this only carries lines.
///
/// POSIX sockets rather than NWListener: NWListener binds and listens in
/// one step, with no moment to make the file private before connections
/// come in. Here it's bind, chmod 0600, then listen -- a connect() before
/// listen() is refused, so there's no window.
public enum UnixSocket {
    public static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// A connected descriptor, or nil: nothing listens at `path` (no file,
    /// a stale file, no permission).
    public static func connect(_ path: String) -> Int32? {
        guard path.utf8.count <= ControlProtocol.maxSocketPathBytes else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Writes all of `data`; false when the peer is gone (or the send
    /// timeout passed).
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, base + offset, buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }
}

/// Where a command's reply lines go, and whether anyone still reads them.
public protocol ControlReplySink: AnyObject, Sendable {
    func send(_ reply: ControlReply)
    /// The client hung up (Ctrl-C): a streaming command stops watching.
    var isClosed: Bool { get }
}

/// The listening end, in the app: `handler` runs each request on the main
/// actor, one at a time per connection, until its final line.
@MainActor
public final class ControlSocketServer {
    public typealias Handler = @MainActor (ControlCommand, ControlReplySink) async -> Void

    public enum StartError: LocalizedError, Equatable {
        case pathTooLong(String)
        /// A live listener answers there (another LLMTray).
        case inUse(String)
        case system(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .pathTooLong(let path): return "the control socket's path is too long for a Unix socket: \(path)"
            case .inUse(let path): return "another LLMTray answers at \(path)"
            case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
            }
        }
    }

    public let path: String
    private let handler: Handler
    private var acceptSource: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var connections: [ObjectIdentifier: ControlConnection] = [:]

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public var isListening: Bool { listenFD >= 0 }

    /// Binds and listens. A socket file a crashed run left behind is
    /// removed; one a live listener answers on is left to it (the app is
    /// single-instance: that's a second copy handing over and quitting).
    public func start() throws {
        guard listenFD < 0 else { return }
        guard path.utf8.count <= ControlProtocol.maxSocketPathBytes else { throw StartError.pathTooLong(path) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var info = stat()
        if lstat(path, &info) == 0 {
            if let fd = UnixSocket.connect(path) {
                close(fd)
                throw StartError.inUse(path)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket", errno) }
        var address = UnixSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StartError.system("bind", code)
        }
        // Private before anyone can connect: listen() comes after.
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartError.system("listen", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptPending() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    /// Closes the socket and removes its file (quit).
    static let maxConnections = 64

    public func stop() {
        guard listenFD >= 0 else { return }
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(path)
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }

    private func acceptPending() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }   // EAGAIN: none left
            // The file is 0600, but the peer is checked too: whatever its
            // mode ends up as, only this user's processes get in.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            // A client that opens connections and never closes them runs
            // out of these, not the app out of descriptors.
            guard connections.count < Self.maxConnections else {
                close(fd)
                continue
            }
            let connection = ControlConnection(fd: fd)
            let id = ObjectIdentifier(connection)
            connections[id] = connection
            let handler = handler
            connection.start(
                onLine: { [weak connection] line in
                    guard let connection else { return }
                    connection.enqueue(line) { line in
                        switch ControlProtocol.decodeRequest(line) {
                        case .success(let request): await handler(request.command, connection)
                        case .failure(let error): connection.send(.failure(error.localizedDescription))
                        }
                    }
                },
                onClose: { [weak self] in self?.connections[id] = nil }
            )
        }
    }
}

/// One client, on the app's side. Reads on its own queue, line by line,
/// into main-actor requests; writes there too, so a slow reader (a 10 MB
/// image line) never blocks the main thread. Blocking writes with a
/// timeout: a client that stops reading is dropped rather than holding the
/// queue forever.
public final class ControlConnection: ControlReplySink, @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "us.ipsupport.llmtray.control-connection")
    // Queue-confined.
    private var source: DispatchSourceRead?
    private var lines = ControlLineBuffer(maxLineBytes: ControlProtocol.maxRequestBytes)
    private var closeHandler: (@MainActor () -> Void)?
    private let lock = NSLock()
    private var closed = false
    // Main-actor: the requests waiting for the one running.
    @MainActor private var pending: [(Data, @MainActor (Data) async -> Void)] = []
    @MainActor private var running = false

    init(fd: Int32) {
        self.fd = fd
        // Blocking (accept() handed over the listener's O_NONBLOCK), no
        // SIGPIPE on a write to a client that's gone, and a send timeout.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func start(onLine: @escaping @MainActor (Data) -> Void, onClose: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            closeHandler = onClose
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(onLine) }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            source.resume()
            self.source = source
        }
    }

    /// On the queue.
    private func readAvailable(_ onLine: @escaping @MainActor (Data) -> Void) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else {
            // EOF or an error: the client is gone.
            if count == 0 || (errno != EAGAIN && errno != EINTR) { close() }
            return
        }
        do {
            for line in try lines.append(Data(chunk[0..<count])) {
                DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
            }
        } catch {
            if let data = try? ControlProtocol.line(ControlReply.failure("request too long (over \(ControlProtocol.maxRequestBytes) bytes)")) {
                _ = UnixSocket.writeAll(fd, data)
            }
            close()
        }
    }

    /// Runs `handle` for `line` once the requests before it are answered.
    @MainActor
    func enqueue(_ line: Data, handle: @escaping @MainActor (Data) async -> Void) {
        pending.append((line, handle))
        guard !running else { return }
        running = true
        Task { @MainActor in
            while !pending.isEmpty, !isClosed {
                let (next, run) = pending.removeFirst()
                await run(next)
            }
            pending.removeAll()
            running = false
        }
    }

    public func send(_ reply: ControlReply) {
        guard !isClosed else { return }
        let data = (try? ControlProtocol.line(reply)) ?? (try? ControlProtocol.line(ControlReply.failure("couldn't encode the reply")))
        queue.async { [weak self] in
            guard let self, let data, !self.isClosed else { return }
            if !UnixSocket.writeAll(self.fd, data) { self.close() }
        }
    }

    /// Idempotent, from any thread.
    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.source?.cancel()   // its cancel handler closes the descriptor
            self.source = nil
            let handler = self.closeHandler
            DispatchQueue.main.async { MainActor.assumeIsolated { handler?() } }
        }
    }
}

/// The CLI's end: one connection per command, blocking reads -- a CLI waits
/// for its answer anyway.
public final class ControlSocketClient {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    private let fd: Int32
    private var lines = ControlLineBuffer(maxLineBytes: ControlProtocol.maxReplyBytes)
    private var ready: [Data] = []

    private init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    /// nil: nothing listens at `path`.
    public static func connect(path: String) -> ControlSocketClient? {
        UnixSocket.connect(path).map(ControlSocketClient.init(fd:))
    }

    public func send(_ command: ControlCommand) throws {
        guard UnixSocket.writeAll(fd, try ControlProtocol.line(ControlRequest(command))) else {
            throw Failure("couldn't talk to LLMTray: \(String(cString: strerror(errno)))")
        }
    }

    /// The next reply line; throws when the app hangs up before the final one.
    public func next() throws -> ControlReply {
        while ready.isEmpty {
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Failure("LLMTray closed the connection (did it quit?)") }
            do {
                ready += try lines.append(Data(chunk[0..<n]))
            } catch {
                throw Failure("LLMTray's reply was too long")
            }
        }
        let line = ready.removeFirst()
        do {
            return try ControlProtocol.decodeReply(line)
        } catch {
            throw Failure("LLMTray's reply couldn't be read: \(String(decoding: line.prefix(200), as: UTF8.self))")
        }
    }

    /// Sends `command` and hands each event line to `onEvent`; returns the
    /// final `done` line, throws its `error`.
    @discardableResult
    public func run(_ command: ControlCommand, onEvent: (ControlReply) -> Void = { _ in }) throws -> ControlReply {
        try send(command)
        while true {
            let reply = try next()
            if let error = reply.error { throw Failure(error) }
            if reply.done == true { return reply }
            onEvent(reply)
        }
    }
}
