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
///
/// While a generation holds or waits for the GenerationQueue the runner is
/// `paused` (`setPaused`, wired to `GenerationQueue.onInteractiveDemand`):
/// nothing starts it and every request throws `.paused` at once, so a
/// search falls back to lexical instead of loading 1.7 GB next to the
/// generation's model.
///
/// Index requests are bounded so one is one slice of the background lane
/// (adr/0012, Scheduling: ≤ ~3 s): at most `maxDocumentRequestTokens`
/// estimated tokens (`IndexText.estimatedTokens`) unless it is a single
/// text; `documentBatches` splits a document's chunks to fit. The runner's
/// own 262k-token limit is only its hard backstop.
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
        /// One index request, estimated tokens: ~10k is ≤ ~3 s of bge-m3 on
        /// an M-series GPU -- one background slice. Queries aren't capped.
        public var maxDocumentRequestTokens = 10_000
        /// After the SIGKILL, how long `stopAndWait` waits for the exit
        /// before it gives up on the process and marks the runner failed.
        public var exitTimeout: TimeInterval = 10
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
        /// A generation holds or waits for the GPU: nothing is embedded now
        /// (a search goes lexical-only).
        case paused

        public var description: String {
            switch self {
            case .runner(let code, let message): return "embedder: \(code) \(message)"
            case .fatal(let message): return "the embedder could not start: \(message)"
            case .died(let why): return "the embedder stopped: \(why)"
            case .unresponsive: return "the embedder stopped answering"
            case .unavailable(let why): return "the embedder is unavailable: \(why)"
            case .stopped: return "the embedder was stopped"
            case .protocolViolation(let why): return "the embedder broke its protocol: \(why)"
            case .paused: return "the embedder is paused while a generation runs"
            }
        }
    }

    public let configuration: Configuration

    private let lock = NSLock()
    private var process: RunnerProcess?
    private var info: EmbedRunnerReady?
    private var startWaiters: [(id: UUID, continuation: CheckedContinuation<EmbedRunnerReady, Error>)] = []
    private var pending: [String: Pending] = [:]
    private var nextID = 0
    private var crashes = 0
    private var backoffUntil: UInt64 = 0
    private var lastFailure = ""
    private var idleWork: DispatchWorkItem?
    private var documentBusy = false
    private var documentWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var paused = false
    /// A process that didn't exit even after SIGKILL: nothing new starts
    /// until it does (two runners would each hold the model).
    private var wedged: RunnerProcess?
    private let timers = DispatchQueue(label: "LLMTray embed runner timers")

    private final class Pending {
        let continuation: CheckedContinuation<EmbedResult, Error>
        let process: RunnerProcess
        /// What the answer must hold: one vector per text, of the ready dim.
        let count: Int
        let dim: Int
        var cancelled = false
        init(_ c: CheckedContinuation<EmbedResult, Error>, _ p: RunnerProcess, count: Int, dim: Int) {
            continuation = c
            process = p
            self.count = count
            self.dim = dim
        }
    }

    /// The runner went away between `start` and the request (a stop raced it).
    private struct NotReady: Error {}

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

    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    /// Paused: no request is sent and nothing starts the runner (requests
    /// throw `.paused`); callers waiting for a start get `.paused` once the
    /// runner is stopped. Doesn't stop a running one itself -- the
    /// generation's grant does (`stopAndWait`).
    public func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    /// Splits a document's texts into requests of at most
    /// `maxDocumentRequestTokens` estimated tokens and `maxTexts` texts (a
    /// longer text alone), in order.
    public func documentBatches(_ texts: [String]) -> [Range<Int>] {
        Self.batches(texts.map { IndexText.estimatedTokens($0) }, maxTokens: configuration.maxDocumentRequestTokens,
                     maxTexts: configuration.maxTexts)
    }

    static func batches(_ tokens: [Int], maxTokens: Int, maxTexts: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0, sum = 0
        for (i, t) in tokens.enumerated() {
            if i > start, sum + t > maxTokens || i - start >= maxTexts {
                out.append(start..<i)
                start = i
                sum = 0
            }
            sum += t
        }
        if start < tokens.count { out.append(start..<tokens.count) }
        return out
    }

    // MARK: - requests

    /// Embeds `texts`; `.query` is interactive, `.document` an index batch.
    /// Throws `Failure`, or `CancellationError` when the task was cancelled.
    public func embed(_ texts: [String], kind: EmbedRunnerMessage.Kind, timeout: TimeInterval = 30) async throws -> EmbedResult {
        try Task.checkCancellation()
        guard texts.count <= configuration.maxTexts else {
            throw Failure.runner(code: "too_large", message: "more than \(configuration.maxTexts) texts")
        }
        if kind == .document, texts.count > 1 {
            let tokens = texts.reduce(0) { $0 + IndexText.estimatedTokens($1) }
            guard tokens <= configuration.maxDocumentRequestTokens else {
                throw Failure.runner(code: "too_large", message: "~\(tokens) tokens in one index request, more than "
                                     + "\(configuration.maxDocumentRequestTokens) (split with documentBatches)")
            }
        }
        if texts.isEmpty { return EmbedResult(dim: readyInfo?.dim ?? 0, count: 0, vectors: [], tokens: [], truncated: [], milliseconds: 0) }
        if isPaused { throw Failure.paused }
        if kind == .document { try await acquireDocumentSlot() }
        defer { if kind == .document { releaseDocumentSlot() } }
        // A start can race a stop (the runner ready just as it was told to
        // exit): once more with the replacement, then a clear error.
        for attempt in 0..<2 {
            try Task.checkCancellation()
            if isPaused { throw Failure.paused }
            _ = try await start()
            do {
                return try await send(texts, kind: kind, timeout: timeout)
            } catch is NotReady {
                if attempt == 1 { throw notReadyFailure() }
            }
        }
        throw notReadyFailure()
    }

    private func notReadyFailure() -> Failure {
        lock.lock()
        defer { lock.unlock() }
        if paused { return .paused }
        if process?.stopping ?? false { return .stopped }
        return .died(lastFailure.isEmpty ? "the runner exited before the request could be sent" : lastFailure)
    }

    private func send(_ texts: [String], kind: EmbedRunnerMessage.Kind, timeout: TimeInterval) async throws -> EmbedResult {
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
                guard let process, let info, process.isHealthy, !paused else {
                    lock.unlock()
                    continuation.resume(throwing: NotReady())
                    return
                }
                let p = Pending(continuation, process, count: texts.count, dim: info.dim)
                pending[id] = p
                idleWork?.cancel()
                idleWork = nil
                lock.unlock()
                // The deadline and the cancel action first: the write itself
                // goes through the process's writer queue and never blocks here.
                timers.asyncAfter(deadline: .now() + timeout + configuration.grace) { [weak self] in
                    self?.expire(id, process: process)
                }
                box.onCancel { [weak self] in self?.cancel(id, process: process) }
                // A failed write: it's exiting, and its exit fails the request.
                process.send(line) { ok in if !ok { process.kill() } }
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
        guard let p else { return false }
        p.send(EmbedRunnerMessage.ping(id: "ping"))
        return true
    }

    private func cancel(_ id: String, process: RunnerProcess) {
        lock.lock()
        guard let p = pending[id], !p.cancelled else { lock.unlock(); return }
        p.cancelled = true
        lock.unlock()
        process.send(EmbedRunnerMessage.cancel(id: "c-\(id)", target: id))
        // The runner answers at its next batch boundary; past the grace it's stuck.
        timers.asyncAfter(deadline: .now() + configuration.grace) { [weak self] in self?.expire(id, process: process) }
    }

    /// Decided under the lock: once marked unresponsive the process takes no
    /// new request (`isHealthy`), so the kill can't hit one registered later.
    private func expire(_ id: String, process: RunnerProcess) {
        lock.lock()
        let stillPending = pending[id] != nil && pending[id]?.process === process
        if stillPending { process.unresponsive = true }
        lock.unlock()
        if stillPending { process.kill() }
    }

    // MARK: - lifecycle

    /// Starts the runner if needed and waits for `ready`.
    /// A cancelled task stops waiting at once (the runner keeps starting).
    @discardableResult
    public func start() async throws -> EmbedRunnerReady {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EmbedRunnerReady, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let info, let process, process.isHealthy {
                    lock.unlock()
                    continuation.resume(returning: info)
                    return
                }
                if process == nil, paused {
                    lock.unlock()
                    continuation.resume(throwing: Failure.paused)
                    return
                }
                if process == nil, wedged != nil {
                    lock.unlock()
                    continuation.resume(throwing: Failure.unavailable("the previous embed runner didn't exit after SIGKILL"))
                    return
                }
                let now = DispatchTime.now().uptimeNanoseconds
                if process == nil, now < backoffUntil {
                    let why = lastFailure
                    lock.unlock()
                    continuation.resume(throwing: Failure.unavailable(why))
                    return
                }
                startWaiters.append((waiter, continuation))
                // A runner on its way out is replaced once it has exited.
                if process == nil { spawnLocked() }
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let index = startWaiters.firstIndex { $0.id == waiter }
            let removed = index.map { startWaiters.remove(at: $0) }
            lock.unlock()
            removed?.continuation.resume(throwing: CancellationError())
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
            DispatchQueue.global().async { waiters.forEach { $0.continuation.resume(throwing: failure) } }
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
        timers.asyncAfter(deadline: .now() + configuration.grace) { p.kill() }
        p.closeStdinWhenWritten()
    }

    /// `stop()`, returning once the runner has exited (at most the grace
    /// later): what a generation waits for before it loads its model. A
    /// process still there `exitTimeout` after the SIGKILL is given up on:
    /// this returns, and the runner is failed (nothing new starts) until it
    /// is finally reaped.
    public func stopAndWait() async {
        guard let p = currentProcess() else { return }
        stop()
        guard await !p.waitForExit(timeout: configuration.grace + configuration.exitTimeout) else { return }
        giveUp(on: p)
    }

    /// The process didn't exit after SIGKILL: forgotten (its requests and
    /// start waiters fail), nothing new starts until it is reaped.
    private func giveUp(on p: RunnerProcess) {
        lock.lock()
        guard process === p else { lock.unlock(); return }
        p.unresponsive = true
        process = nil
        info = nil
        wedged = p
        lastFailure = "the embed runner (pid \(p.pid)) didn't exit after SIGKILL"
        noteCrashLocked()
        let inFlight = pending.values.filter { $0.process === p }
        pending = pending.filter { $0.value.process !== p }
        let waiters = startWaiters
        startWaiters = []
        let failure = Failure.unavailable(lastFailure)
        lock.unlock()
        for slot in inFlight { slot.continuation.resume(throwing: slot.cancelled ? CancellationError() : failure) }
        waiters.forEach { $0.continuation.resume(throwing: failure) }
    }

    private func currentProcess() -> RunnerProcess? {
        lock.lock()
        defer { lock.unlock() }
        return process
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

    /// Lock held (released here): the process broke the protocol. Nothing it
    /// says afterwards counts -- every request in flight on it fails now
    /// (a later, valid-looking answer can't succeed one) and it is killed.
    private func violatedLocked(_ p: RunnerProcess, _ why: String) {
        if !p.violation {
            p.failure = why
            p.violation = true
        }
        let inFlight = pending.values.filter { $0.process === p }
        pending = pending.filter { $0.value.process !== p }
        lock.unlock()
        let failure = Failure.protocolViolation(why)
        for slot in inFlight { slot.continuation.resume(throwing: slot.cancelled ? CancellationError() : failure) }
        p.kill()
    }

    private func received(_ line: Data, from p: RunnerProcess) {
        lock.lock()
        // After a violation every later line of that process is dropped.
        guard !p.violation else { lock.unlock(); return }
        guard let message = EmbedRunnerMessage(line: line) else {
            violatedLocked(p, "unreadable line")
            return
        }
        guard process === p else { lock.unlock(); return }
        switch message {
        case .ready(let r):
            info = r
            // A runner told to stop meanwhile is dying: its waiters stay
            // queued, and its exit starts the replacement for them.
            if p.stopping {
                lock.unlock()
                return
            }
            if paused {
                // Nobody may use it now: the waiters fall back, it goes.
                let waiters = startWaiters
                startWaiters = []
                lock.unlock()
                waiters.forEach { $0.continuation.resume(throwing: Failure.paused) }
                stop()
                return
            }
            let waiters = startWaiters
            startWaiters = []
            scheduleIdleLocked()
            lock.unlock()
            waiters.forEach { $0.continuation.resume(returning: r) }
        case .fatal(let code, let text):
            p.failure = "\(code): \(text)"
            p.fatal = true
            lock.unlock()
        case .result(let id, let result):
            if let slot = pending[id], result.count != slot.count || result.dim != slot.dim {
                violatedLocked(p, "answer to \(id): \(result.count) × \(result.dim) for \(slot.count) texts × \(slot.dim)")
                return
            }
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
        if wedged === p { wedged = nil }
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
        var waiters: [(id: UUID, continuation: CheckedContinuation<EmbedRunnerReady, Error>)] = []
        if !startWaiters.isEmpty {
            if paused {
                waiters = startWaiters
                startWaiters = []
            } else if p.stopping && !p.fatal && !p.unresponsive && !p.violation {
                spawnLocked()
            } else {
                waiters = startWaiters
                startWaiters = []
            }
        }
        let pausedNow = paused
        lock.unlock()
        for slot in inFlight { slot.continuation.resume(throwing: slot.cancelled ? CancellationError() : failure) }
        waiters.forEach { $0.continuation.resume(throwing: pausedNow ? Failure.paused : failure) }
    }

    // MARK: - one index batch at a time

    /// Waits for the index-batch slot; a cancelled task leaves the line.
    private func acquireDocumentSlot() async throws {
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if !documentBusy {
                    documentBusy = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    documentWaiters.append((waiter, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let index = documentWaiters.firstIndex { $0.id == waiter }
            let removed = index.map { documentWaiters.remove(at: $0) }
            lock.unlock()
            removed?.continuation.resume(throwing: CancellationError())
        }
    }

    private func releaseDocumentSlot() {
        lock.lock()
        if documentWaiters.isEmpty {
            documentBusy = false
            lock.unlock()
        } else {
            // The slot passes straight to the next waiter (still busy).
            let next = documentWaiters.removeFirst()
            lock.unlock()
            next.continuation.resume()
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
    /// The flags are written by the owner (under its lock) and by the stdout
    /// thread (a runaway line): each access takes `flagLock`.
    private let flagLock = NSLock()
    private var flags = (stopping: false, fatal: false, unresponsive: false, violation: false, failure: String?.none)
    var stopping: Bool {
        get { flagLock.withLock { flags.stopping } }
        set { flagLock.withLock { flags.stopping = newValue } }
    }
    var fatal: Bool {
        get { flagLock.withLock { flags.fatal } }
        set { flagLock.withLock { flags.fatal = newValue } }
    }
    var unresponsive: Bool {
        get { flagLock.withLock { flags.unresponsive } }
        set { flagLock.withLock { flags.unresponsive = newValue } }
    }
    var violation: Bool {
        get { flagLock.withLock { flags.violation } }
        set { flagLock.withLock { flags.violation = newValue } }
    }
    var failure: String? {
        get { flagLock.withLock { flags.failure } }
        set { flagLock.withLock { flags.failure = newValue } }
    }
    /// Takes new requests.
    var isHealthy: Bool { flagLock.withLock { !flags.stopping && !flags.unresponsive && !flags.violation && !flags.fatal } }
    /// Writes happen here, in order, so no caller blocks on a full pipe; a
    /// kill makes a blocked write fail (EPIPE).
    private let writer = DispatchQueue(label: "LLMTray embed runner stdin")
    private let exitGroup = DispatchGroup()

    private init(pid: pid_t, stdin: Int32, stdout: Int32, stderr: Int32, maxLineBytes: Int) {
        exitGroup.enter()
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
                    flagLock.withLock {
                        flags.violation = true
                        flags.failure = "a line over \(maxLineBytes) bytes"
                    }
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
            exitGroup.leave()
        }
        outThread.name = "LLMTray embed runner"
        outThread.start()
    }

    /// Queues `data` for the runner's stdin; `done` gets whether it all went.
    func send(_ data: Data, done: ((Bool) -> Void)? = nil) {
        writer.async { [self] in
            let ok = write(data)
            done?(ok)
        }
    }

    /// EOF after everything queued before it.
    func closeStdinWhenWritten() {
        writer.async { [self] in closeStdin() }
    }

    func waitForExit() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            exitGroup.notify(queue: .global()) { c.resume() }
        }
    }

    /// False: still not reaped after `timeout`.
    func waitForExit(timeout: TimeInterval) async -> Bool {
        let group = exitGroup
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { c.resume(returning: group.wait(timeout: .now() + timeout) == .success) }
        }
    }

    /// The whole line, or false (closed, or the runner is gone).
    private func write(_ data: Data) -> Bool {
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
