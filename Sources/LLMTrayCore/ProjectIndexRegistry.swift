import Foundation

/// One open project's index (adr/0012, Concurrency): the writer on its own
/// serial queue, a read-only WAL connection on another, so searches from
/// any tab never queue behind an ingest. Work is handed over as synchronous
/// closures -- nothing can await while a transaction is open. When writes
/// go idle a TRUNCATE checkpoint and an incremental vacuum run.
public final class ProjectIndexHandle: @unchecked Sendable {
    public let project: UUID
    public let directory: URL
    private let writer: ConnectionQueue
    private let reading: ConnectionQueue
    private var writerQueue: DispatchQueue { writer.queue }
    private var readerQueue: DispatchQueue { reading.queue }
    /// Writer queue only.
    private var index: ProjectIndex?
    /// Reader queue only.
    private var reader: SQLiteConnection?
    private var searcher: IndexSearcher?
    private var dense: DenseVectors?
    private let idleDelay: TimeInterval
    private var idleWork: DispatchWorkItem?   // writer queue only
    private weak var registry: ProjectIndexRegistry?
    public let openReport: ReconcileReport

    public struct Closed: Error {}
    /// The handle can't be used any more (a compaction swapped the file but
    /// it couldn't be reopened); the registry opens a new one on next use.
    public struct Failed: Error, CustomStringConvertible {
        public let reason: String
        public var description: String { "the project index failed: \(reason)" }
    }
    private let failureLock = NSLock()
    private var failure: Failed?
    public var isFailed: Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        return failure != nil
    }
    private func fail(_ error: Error) {
        failureLock.lock()
        if failure == nil { failure = Failed(reason: "\(error)") }
        failureLock.unlock()
    }
    private var failed: Failed? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return failure
    }

    init(project: UUID, directory: URL, idleDelay: TimeInterval, registry: ProjectIndexRegistry) throws {
        self.project = project
        self.directory = directory
        self.idleDelay = idleDelay
        self.registry = registry
        writer = ConnectionQueue(label: "LLMTray index writer \(project.uuidString.prefix(8))")
        reading = ConnectionQueue(label: "LLMTray index reader \(project.uuidString.prefix(8))")
        let index = try ProjectIndex(directory: directory)
        openReport = try index.reconcile()
        try? index.checkpoint()
        // From here on its connection answers on the writer queue only.
        index.owner = writer
        self.index = index
        try openReader()
    }

    private func openReader() throws {
        let db = try SQLiteConnection(path: directory.appendingPathComponent(ProjectIndex.databaseName).path, readOnly: true)
        db.setBusyTimeout(milliseconds: 2000)
        try IndexSchema.configureReader(db)
        searcher = try IndexSearcher(db: db)
        db.owner = reading
        reader = db
    }

    private func closeReader() {
        searcher = nil
        dense = nil
        reader?.close()
        reader = nil
    }

    /// Runs `body` on the writer, then schedules the idle maintenance. The
    /// index is only valid inside `body`: its connection refuses (throws
    /// SQLITE_MISUSE) any call from outside the writer queue, so a leaked
    /// one can't race it.
    public func write<T>(_ body: @escaping (ProjectIndex) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writerQueue.async {
                guard let index = self.index else { return continuation.resume(throwing: self.failed ?? Closed()) }
                do {
                    let result = try body(index)
                    self.scheduleIdle()
                    continuation.resume(returning: result)
                } catch {
                    self.scheduleIdle()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs `body` on the reader connection; like `write`, the searcher is
    /// only valid inside it (it refuses calls from anywhere else).
    public func read<T>(_ body: @escaping (IndexSearcher) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            readerQueue.async {
                guard let searcher = self.searcher else { return continuation.resume(throwing: self.failed ?? Closed()) }
                do { continuation.resume(returning: try body(searcher)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// The hybrid search on the reader. The active set's vectors are loaded
    /// (or brought up to date) first when a query vector comes with it.
    public func search(_ query: String, queryVector: [Float]? = nil,
                       options: IndexSearchOptions = IndexSearchOptions()) async throws -> IndexSearchResult {
        let result: (IndexSearchResult, Int) = try await withCheckedThrowingContinuation { continuation in
            readerQueue.async {
                guard let searcher = self.searcher else { return continuation.resume(throwing: self.failed ?? Closed()) }
                do {
                    var vectors: DenseVectors?
                    let r = try searcher.search(query, queryVector: queryVector, vectors: { db in
                        vectors = try self.currentVectors(db, dim: queryVector?.count ?? 0)
                        return vectors
                    }, options: options)
                    continuation.resume(returning: (r, vectors?.residentBytes ?? 0))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        if result.1 > 0 { registry?.noteVectorsResident(self, bytes: result.1) }
        return result.0
    }

    /// Document counts on the reader: one small query, never behind an ingest.
    public func summary() async throws -> ProjectIndexSummary {
        try await read { try $0.summary() }
    }

    /// Reader queue: the active set's vectors, refreshed.
    private func currentVectors(_ db: SQLiteConnection, dim: Int) throws -> DenseVectors? {
        let active = try db.rows("SELECT set_id, dim FROM vec_sets WHERE active = 1") { ($0.int(0), Int($0.int(1))) }.first
        guard let active, active.1 == dim else {
            dense = nil
            return nil
        }
        if dense?.setID != active.0 { dense = DenseVectors(setID: active.0, dim: active.1) }
        try dense?.refresh(from: db)
        return dense
    }

    /// Drops the in-memory vectors (LRU eviction); the next search reloads them.
    func evictVectors() {
        readerQueue.async { self.dense = nil }
    }

    /// Safe from anywhere, a `read` closure included (it's already on the
    /// reader queue then: no sync onto it).
    public var residentVectorBytes: Int {
        if reading.isCurrent { return dense?.residentBytes ?? 0 }
        return readerQueue.sync { dense?.residentBytes ?? 0 }
    }

    private func scheduleIdle() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.maintainIdle() }
        idleWork = work
        writerQueue.asyncAfter(deadline: .now() + idleDelay, execute: work)
    }

    /// Writer queue, after `idleDelay` without writes.
    private func maintainIdle() {
        guard let index else { return }
        try? index.checkpoint()
        // From here on its connection answers on the writer queue only.
        index.owner = writer
        _ = try? index.incrementalVacuum(pages: 512)
    }

    /// The idle step now (tests; before the app quits).
    public func maintainNow() async throws {
        try await write { index in
            try index.checkpoint()
            _ = try index.incrementalVacuum(pages: 512)
        }
    }

    /// Full compaction with the swap: new searches wait on the reader queue
    /// while it closes, every connection is closed for the rename, both
    /// reopen after. Only with no ingest running (the caller's job). When a
    /// connection can't be reopened after the swap the handle is `Failed`
    /// (every call throws it) and the registry replaces it on next use.
    public func compact() async throws {
        try await write { index in
            do {
                try index.compact(holdingOthers: { swap in
                    // The reader queue is held (closed reader, new searches
                    // waiting) while the swap runs here, on the writer: the
                    // writer's connection answers on its own queue only.
                    let closed = DispatchSemaphore(value: 0), swapped = DispatchSemaphore(value: 0), reopened = DispatchSemaphore(value: 0)
                    self.readerQueue.async {
                        self.closeReader()
                        closed.signal()
                        swapped.wait()
                        do { try self.openReader() } catch { self.fail(error) }
                        reopened.signal()
                    }
                    closed.wait()
                    defer {
                        swapped.signal()
                        reopened.wait()
                    }
                    try swap()
                })
            } catch {
                if !index.isOpen { self.fail(error) }
                if self.failed == nil { throw error }
            }
            guard let failure = self.failed else { return }
            // Nothing can be trusted any more: both connections go.
            index.close()
            self.index = nil
            self.readerQueue.sync { self.closeReader() }
            throw failure
        }
    }

    /// Closes both connections; later calls throw `Closed`. Waits for the
    /// work already queued -- so never from inside `write` or `read`.
    public func close() {
        dispatchPrecondition(condition: .notOnQueue(writerQueue))
        dispatchPrecondition(condition: .notOnQueue(readerQueue))
        writerQueue.sync {
            idleWork?.cancel()
            try? index?.checkpoint()
            index?.close()
            index = nil
        }
        readerQueue.sync { closeReader() }
    }
}

/// App-wide: one handle per open project (tabs don't own connections --
/// `ChatToolbox` is per tab), and the vectors of at most two projects in
/// memory (LRU, ~800 MB budget).
public final class ProjectIndexRegistry: @unchecked Sendable {
    private let lock = NSLock()
    /// Opening and closing a project are serialized per project, so it never
    /// has two writers (a close finishes before the next open of it starts),
    /// while opening one -- a reconcile may hash big files -- doesn't hold up
    /// any other project.
    private var lifecycles: [UUID: NSLock] = [:]
    private var handles: [UUID: ProjectIndexHandle] = [:]
    private var vectorUse: [(project: UUID, bytes: Int)] = []   // most recent last
    private let directory: (UUID) -> URL
    private let idleDelay: TimeInterval
    public var maxResidentVectorSets = 2
    public var vectorBudgetBytes = 800 << 20

    /// `directory`: where a project's index lives (ProjectStorage's
    /// `projects/<id>`).
    public init(directory: @escaping (UUID) -> URL, idleDelay: TimeInterval = 2) {
        self.directory = directory
        self.idleDelay = idleDelay
    }

    func lifecycleLock(_ project: UUID) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let l = lifecycles[project] { return l }
        let l = NSLock()
        lifecycles[project] = l
        return l
    }

    /// The project's handle, opened (and reconciled) on first use; a failed
    /// one is replaced. Blocks while it opens: off the main thread, `open`.
    public func handle(for project: UUID) throws -> ProjectIndexHandle {
        let lifecycle = lifecycleLock(project)
        lifecycle.lock()
        defer { lifecycle.unlock() }
        lock.lock()
        let existing = handles[project]
        lock.unlock()
        if let existing {
            guard existing.isFailed else { return existing }
            existing.close()
        }
        let h = try ProjectIndexHandle(project: project, directory: directory(project), idleDelay: idleDelay, registry: self)
        lock.lock()
        handles[project] = h
        lock.unlock()
        return h
    }

    /// `handle(for:)` off the caller's thread: the first open reconciles.
    public func open(_ project: UUID) async throws -> ProjectIndexHandle {
        try await ProcessRunner.offMain { [self] in try handle(for: project) }
    }

    /// The project's counts: from its open handle, else read-only from its
    /// file without opening it (`.empty` when it has no index).
    public func summary(for project: UUID) async throws -> ProjectIndexSummary {
        if let open = openHandle(project) { return try await open.summary() }
        let dir = directory(project)
        return try await ProcessRunner.offMain { try ProjectIndexSummary.read(directory: dir) }
    }

    private func openHandle(_ project: UUID) -> ProjectIndexHandle? {
        lock.lock()
        defer { lock.unlock() }
        return handles[project]
    }

    public var openProjects: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(handles.keys)
    }

    /// Closes the project's connections (before its deletion).
    public func close(_ project: UUID) {
        let lifecycle = lifecycleLock(project)
        lifecycle.lock()
        defer { lifecycle.unlock() }
        lock.lock()
        let h = handles.removeValue(forKey: project)
        vectorUse.removeAll { $0.project == project }
        lock.unlock()
        h?.close()
    }

    public func closeAll() {
        for project in openProjects { close(project) }
    }

    /// A search loaded vectors: the least recently used beyond the count or
    /// the budget are dropped.
    func noteVectorsResident(_ handle: ProjectIndexHandle, bytes: Int) {
        lock.lock()
        vectorUse.removeAll { $0.project == handle.project }
        vectorUse.append((handle.project, bytes))
        var evict: [ProjectIndexHandle] = []
        while vectorUse.count > 1,
              vectorUse.count > maxResidentVectorSets || vectorUse.reduce(0, { $0 + $1.bytes }) > vectorBudgetBytes {
            let oldest = vectorUse.removeFirst()
            if let h = handles[oldest.project] { evict.append(h) }
        }
        lock.unlock()
        evict.forEach { $0.evictVectors() }
    }

    /// Projects whose vectors are in memory, least recently used first.
    public var residentVectorProjects: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return vectorUse.map(\.project)
    }
}
