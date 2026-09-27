import Darwin
import Foundation

/// The client of the embed runner (adr/0012, Dense retrieval): one
/// long-lived, bidirectional child, unlike `ProcessRunner`'s one-shot runs.
/// Requests carry ids and are answered in any order; each has a timeout the
/// runner enforces at batch boundaries, plus a grace period after which the
/// client kills the runner (a stuck kernel can't answer). Cancelling a task
/// sends `cancel`. A crash fails what was in flight and the next request
/// starts a new runner -- after a backoff that grows with repeated crashes.
/// Query embeddings go straight to the runner (which serves them first);
/// index batches go one at a time, so a query never waits behind a queue of
/// them. With nothing to do for `idleTimeout` it exits (its ~1.7 GB freed),
/// and `stop()` ends it now -- what an image or music generation asks for.
public final class EmbedRunner: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
        /// Spawn to `ready`: model load and the reference check.
        public var readyTimeout: TimeInterval = 120
        /// Past a request's timeout (and after a cancel or stop) before the kill.
        public var grace: TimeInterval = 5
        public var idleTimeout: TimeInterval = 120
        /// The runner's answers: 256 vectors of 1024 dims are ~0.7 MB of base64.
        public var maxLineBytes = 16 << 20
        /// The runner's own limits (runtime/llmtray_embed_runner.py).
        public var maxRequestBytes = 8 << 20
        public var maxTexts = 256
        /// Waits after the 1st, 2nd, ... consecutive crash.
        public var restartBackoff: [TimeInterval] = [0.5, 2, 8, 30]

        public init(executable: String, arguments: [String], environment: [String: String] = [:]) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The runner refused the request: bad_request, too_large, timeout, internal.
        case runner(code: String, message: String)
        /// It refused to start (load failed, reference check failed).
        case fatal(String)
        /// It exited or was killed with this request in flight.
        case died(String)
        /// No answer within timeout + grace: it was killed.
        case unresponsive
        /// Backing off after crashes; try again later.
        case unavailable(String)
        /// `stop()` ended it first.
        case stopped
        case protocolViolation(String)

        public var description: String {
            switch self {
            case .runner(let code, let message): return "embedder: \(code) \(message)"
            case .fatal(let message): return "the embedder could not start: \(message)"
            case .died(let why): return "the embedder stopped: \(why)"
            case .unresponsive: return "the embedder stopped answering"
            case .unavailable(let why): return "the embedder is unavailable: \(why)"
            case .stopped: return "the embedder was stopped"
            case .protocolViolation(let why): return "the embedder broke its protocol: \(why)"
            }
        }
    }

    public let configuration: Configuration

    private let lock = NSLock()
    private var process: RunnerProcess?
    private var info: EmbedRunnerReady?
    private var startWaiters: [CheckedContinuation<EmbedRunnerReady, Error>] = []
    private var pending: [String: Pending] = [:]
    private var nextID = 0
    private var crashes = 0
    private var backoffUntil: UInt64 = 0
    private var lastFailure = ""
    private var idleWork: DispatchWorkItem?
    private var documentBusy = false
    private var documentWaiters: [CheckedContinuation<Void, Never>] = []
    private let timers = DispatchQueue(label: "LLMTray embed runner timers")

    private final class Pending {
        let continuation: CheckedContinuation<EmbedResult, Error>
        let process: RunnerProcess
        var cancelled = false
        init(_ c: CheckedContinuation<EmbedResult, Error>, _ p: RunnerProcess) { continuation = c; process = p }
    }

    /// Set from any thread before `onCancel` or registration, whichever is first.
    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var action: (() -> Void)?
        func cancel() {
            lock.lock()
            cancelled = true
            let a = action
            action = nil
            lock.unlock()
            a?()
        }
        /// Runs `a` now if already cancelled, else on cancel.
        func onCancel(_ a: @escaping () -> Void) {
            lock.lock()
            if cancelled { lock.unlock(); a(); return }
            action = a
            lock.unlock()
        }
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        process?.kill()
    }

    /// The runner is up (spawned and ready).
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return info != nil
    }

    /// The pid of the current runner, if any.
    public var pid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return process?.pid
    }

    public var readyInfo: EmbedRunnerReady? {
        lock.lock()
        defer { lock.unlock() }
        return info
    }

    // MARK: - requests

    /// Embeds `texts`; `.query` is interactive, `.document` an index batch.
    /// Throws `Failure`, or `CancellationError` when the task was cancelled.
    public func embed(_ texts: [String], kind: EmbedRunnerMessage.Kind, timeout: TimeInterval = 30) async throws -> EmbedResult {
        try Task.checkCancellation()
        guard texts.count <= configuration.maxTexts else {
            throw Failure.runner(code: "too_large", message: "more than \(configuration.maxTexts) texts")
        }
        if texts.isEmpty { return EmbedResult(dim: readyInfo?.dim ?? 0, count: 0, vectors: [], tokens: [], truncated: [], milliseconds: 0) }
        if kind == .document { await acquireDocumentSlot() }
        defer { if kind == .document { releaseDocumentSlot() } }
        try Task.checkCancellation()
        _ = try await start()

        let id = makeID()
        let line = EmbedRunnerMessage.embedRequest(id: id, kind: kind, texts: texts,
                                                   timeoutMilliseconds: max(1, Int(timeout * 1000)))
        guard line.count <= configuration.maxRequestBytes else {
            throw Failure.runner(code: "too_large", message: "request of \(line.count) bytes")
        }
        let box = CancelBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EmbedResult, Error>) in
                lock.lock()
                guard let process, info != nil else {
                    lock.unlock()
                    continuation.resume(throwing: Failure.died(lastFailure))
                    return
                }
                let p = Pending(continuation, process)
                pending[id] = p
                idleWork?.cancel()
                idleWork = nil
                lock.unlock()
                if !process.write(line) {
                    // It's exiting; its exit fails the request (unless that already happened).
                    process.kill()
                    return
                }
                timers.asyncAfter(deadline: .now() + timeout + configuration.grace) { [weak self] in
                    self?.expire(id, process: process)
                }
                box.onCancel { [weak self] in self?.cancel(id, process: process) }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private func makeID() -> String {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return "r\(nextID)"
    }

    /// Checks the runner answers (`ping`); false when it isn't running.
    public func ping() -> Bool {
        lock.lock()
        let p = info != nil ? process : nil
        lock.unlock()
        return p?.write(EmbedRunnerMessage.ping(id: "ping")) ?? false
    }

    private func cancel(_ id: String, process: RunnerProcess) {
        lock.lock()
        guard let p = pending[id], !p.cancelled else { lock.unlock(); return }
        p.cancelled = true
        lock.unlock()
        _ = process.write(EmbedRunnerMessage.cancel(id: "c-\(id)", target: id))
        // The runner answers at its next batch boundary; past the grace it's stuck.
        timers.asyncAfter(deadline: .now() + configuration.grace) { [weak self] in self?.expire(id, process: process) }
    }

    private func expire(_ id: String, process: RunnerProcess) {
        lock.lock()
        let stillPending = pending[id] != nil && pending[id]?.process === process
        if stillPending { process.unresponsive = true }
        lock.unlock()
        if stillPending { process.kill() }
    }

    // MARK: - lifecycle

    /// Starts the runner if needed and waits for `ready`.
    @discardableResult
    public func start() async throws -> EmbedRunnerReady {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EmbedRunnerReady, Error>) in
            lock.lock()
            if let info, let process, !process.stopping {
                lock.unlock()
                continuation.resume(returning: info)
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if process == nil, now < backoffUntil {
                let why = lastFailure
                lock.unlock()
                continuation.resume(throwing: Failure.unavailable(why))
                return
            }
            startWaiters.append(continuation)
            // A runner on its way out is replaced once it has exited.
            if process == nil { spawnLocked() }
            lock.unlock()
        }
    }

    /// Lock held.
    private func spawnLocked() {
        var environment = configuration.environment
        environment[OrphanScan.embedRunnerMarker] = "1"
        do {
            let p = try RunnerProcess.spawn(configuration.executable, configuration.arguments, environment: environment,
                                            maxLineBytes: configuration.maxLineBytes)
            process = p
            info = nil
            p.start(onLine: { [weak self] line in self?.received(line, from: p) },
                    onExit: { [weak self] status, tail in self?.exited(p, status: status, stderrTail: tail) })
            timers.asyncAfter(deadline: .now() + configuration.readyTimeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stuck = self.process === p && self.info == nil
                if stuck { p.failure = "not ready after \(Int(self.configuration.readyTimeout)) s" }
                self.lock.unlock()
                if stuck { p.kill() }
            }
        } catch {
            lastFailure = "cannot start: \(error)"
            noteCrashLocked()
            let waiters = startWaiters
            startWaiters = []
            let failure = Failure.died(lastFailure)
            DispatchQueue.global().async { waiters.forEach { $0.resume(throwing: failure) } }
        }
    }

    /// Ends the runner: stdin closed (it finishes the current batch, answers
    /// the rest `cancelled`, exits), killed if it hasn't after the grace.
    public func stop() {
        lock.lock()
        guard let p = process, !p.stopping else { lock.unlock(); return }
        p.stopping = true
        idleWork?.cancel()
        idleWork = nil
        lock.unlock()
        p.closeStdin()
        timers.asyncAfter(deadline: .now() + configuration.grace) { p.kill() }
    }

    /// Forgets earlier crashes (the user fixed something, e.g. re-downloaded).
    public func resetBackoff() {
        lock.lock()
        crashes = 0
        backoffUntil = 0
        lock.unlock()
    }

    /// Lock held.
    private func noteCrashLocked() {
        crashes += 1
        let waits = configuration.restartBackoff
        let wait = waits.isEmpty ? 0 : waits[min(crashes - 1, waits.count - 1)]
        backoffUntil = DispatchTime.now().uptimeNanoseconds + UInt64(wait * 1e9)
    }

    /// Lock held: exits after `idleTimeout` with nothing in flight.
    private func scheduleIdleLocked() {
        guard pending.isEmpty, let p = process, !p.stopping else { return }
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let idle = self.pending.isEmpty && self.process === p
            self.lock.unlock()
            if idle { self.stop() }
        }
        idleWork = work
        timers.asyncAfter(deadline: .now() + configuration.idleTimeout, execute: work)
    }

    // MARK: - the runner's side

    private func received(_ line: Data, from p: RunnerProcess) {
        guard let message = EmbedRunnerMessage(line: line) else {
            lock.lock()
            p.failure = "unreadable line"
            p.violation = true
            lock.unlock()
            p.kill()
            return
        }
        lock.lock()
        guard process === p else { lock.unlock(); return }
        switch message {
        case .ready(let r):
            info = r
            let waiters = startWaiters
            startWaiters = []
            scheduleIdleLocked()
            lock.unlock()
            waiters.forEach { $0.resume(returning: r) }
        case .fatal(let code, let text):
            p.failure = "\(code): \(text)"
            p.fatal = true
            lock.unlock()
        case .result(let id, let result):
            let slot = pending.removeValue(forKey: id)
            crashes = 0
            scheduleIdleLocked()
            lock.unlock()
            slot?.continuation.resume(returning: result)
        case .failure(let id, let code, let text):
            guard let id, let slot = pending.removeValue(forKey: id) else {
                lock.unlock()
                return
            }
            let stopping = p.stopping
            scheduleIdleLocked()
            lock.unlock()
            if code == "cancelled" {
                slot.continuation.resume(throwing: slot.cancelled ? CancellationError() : (stopping ? Failure.stopped : Failure.runner(code: code, message: text)))
            } else {
                slot.continuation.resume(throwing: Failure.runner(code: code, message: text))
            }
        case .pong:
            lock.unlock()
        }
    }

    private func exited(_ p: RunnerProcess, status: Int32, stderrTail: String) {
        lock.lock()
        guard process === p else { lock.unlock(); return }
        process = nil
        info = nil
        idleWork?.cancel()
        idleWork = nil
        let describe = p.failure ?? (status & 0x7F != 0 ? "signal \(status & 0x7F)" : "exit \((status >> 8) & 0xFF)")
        let why = stderrTail.isEmpty ? describe : "\(describe): \(stderrTail)"
        let failure: Failure
        if p.violation {
            failure = .protocolViolation(why)
        } else if p.fatal {
            failure = .fatal(p.failure ?? why)
        } else if p.unresponsive {
            failure = .unresponsive
        } else if p.stopping {
            failure = .stopped
        } else {
            failure = .died(why)
        }
        if !p.stopping || p.fatal || p.unresponsive || p.violation {
            lastFailure = why
            noteCrashLocked()
        }
        let inFlight = pending.values.filter { $0.process === p }
        pending = pending.filter { $0.value.process !== p }
        // Waiting to start: a stopped runner is replaced right away; after a
        // crash they fail (and the next request backs off).
        var waiters: [CheckedContinuation<EmbedRunnerReady, Error>] = []
        if !startWaiters.isEmpty {
            if p.stopping && !p.fatal && !p.unresponsive && !p.violation {
                spawnLocked()
            } else {
                waiters = startWaiters
                startWaiters = []
            }
        }
        lock.unlock()
        for slot in inFlight { slot.continuation.resume(throwing: slot.cancelled ? CancellationError() : failure) }
        waiters.forEach { $0.resume(throwing: failure) }
    }

    // MARK: - one index batch at a time

    private func acquireDocumentSlot() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !documentBusy {
                documentBusy = true
                lock.unlock()
                continuation.resume()
            } else {
                documentWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func releaseDocumentSlot() {
        lock.lock()
        if documentWaiters.isEmpty {
            documentBusy = false
            lock.unlock()
        } else {
            let next = documentWaiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// The child and the parent's ends of its pipes: stdin to write requests,
/// stdout read line by line (bounded) on a thread of its own, stderr's tail
/// kept for the error. Started with posix_spawn in its own process group,
/// so a kill reaches whatever it starts.
final class RunnerProcess: @unchecked Sendable {
    let pid: pid_t
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let maxLineBytes: Int
    private let writeLock = NSLock()
    private var stdinOpen = true
    private let stateLock = NSLock()
    private var reaped = false
    // Guarded by the owner's lock.
    var stopping = false
    var fatal = false
    var unresponsive = false
    var violation = false
    var failure: String?

    private init(pid: pid_t, stdin: Int32, stdout: Int32, stderr: Int32, maxLineBytes: Int) {
        self.pid = pid
        stdinFD = stdin
        stdoutFD = stdout
        stderrFD = stderr
        self.maxLineBytes = maxLineBytes
    }

    static func spawn(_ executable: String, _ arguments: [String], environment: [String: String],
                      maxLineBytes: Int) throws -> RunnerProcess {
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        func fail() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard pipe(&inPipe) == 0 else { throw fail() }
        guard pipe(&outPipe) == 0 else { inPipe.forEach { close($0) }; throw fail() }
        guard pipe(&errPipe) == 0 else { (inPipe + outPipe).forEach { close($0) }; throw fail() }
        for fd in inPipe + outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // A write to a runner that just died fails instead of raising SIGPIPE.
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults: sigset_t = 1 << (UInt32(SIGPIPE) - 1)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask: sigset_t = 0
        posix_spawnattr_setsigmask(&attr, &mask)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { $1 }
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            [inPipe[1], outPipe[0], errPipe[0]].forEach { close($0) }
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }
        return RunnerProcess(pid: pid, stdin: inPipe[1], stdout: outPipe[0], stderr: errPipe[0], maxLineBytes: maxLineBytes)
    }

    /// Starts the readers. `onExit` comes once, after the last line, with the
    /// wait status.
    func start(onLine: @escaping (Data) -> Void, onExit: @escaping (Int32, String) -> Void) {
        let tail = StderrTail()
        let stderrDone = DispatchSemaphore(value: 0)
        let errThread = Thread { [stderrFD] in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16384)
            defer { buffer.deallocate() }
            while true {
                let n = read(stderrFD, buffer, 16384)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                tail.append(buffer, n)
            }
            close(stderrFD)
            stderrDone.signal()
        }
        errThread.name = "LLMTray embed runner stderr"
        errThread.start()
        let outThread = Thread { [self] in
            let size = 256 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            var line = Data()
            reading: while true {
                let n = read(stdoutFD, buffer, size)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                var start = 0
                for i in 0..<n where buffer[i] == 0x0A {
                    line.append(buffer + start, count: i - start)
                    if !line.isEmpty { onLine(line) }
                    line = Data()
                    start = i + 1
                }
                line.append(buffer + start, count: n - start)
                if line.count > maxLineBytes {
                    // Bounded messages: a runaway line ends the runner.
                    violation = true
                    failure = "a line over \(maxLineBytes) bytes"
                    kill()
                    break reading
                }
            }
            close(stdoutFD)
            // stdout is gone, so it can't answer any more: the group goes
            // (anything it started with it) before it's reaped.
            kill()
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            stateLock.lock()
            reaped = true
            stateLock.unlock()
            _ = stderrDone.wait(timeout: .now() + 2)
            closeStdin()
            onExit(status, tail.text)
        }
        outThread.name = "LLMTray embed runner"
        outThread.start()
    }

    /// The whole line, or false (closed, or the runner is gone).
    func write(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard stdinOpen else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(stdinFD, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                p += n
                left -= n
            }
            return true
        }
    }

    /// EOF on the runner's stdin: its normal stop.
    func closeStdin() {
        writeLock.lock()
        defer { writeLock.unlock() }
        if stdinOpen {
            close(stdinFD)
            stdinOpen = false
        }
    }

    /// SIGKILL to the group -- only while it's ours (a reaped pid can be reused).
    func kill() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if !reaped { Darwin.kill(-pid, SIGKILL) }
    }
}

private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ p: UnsafePointer<UInt8>, _ n: Int) {
        lock.lock()
        data.append(p, count: n)
        if data.count > 8192 { data = Data(data.suffix(4096)) }
        lock.unlock()
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data.suffix(1500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
