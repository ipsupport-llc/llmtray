import Foundation

/// One open project's index (adr/0012, Concurrency): the writer on its own
/// serial queue, a read-only WAL connection on another, so searches from
/// any tab never queue behind an ingest. Work is handed over as synchronous
/// closures -- nothing can await while a transaction is open. When writes
/// go idle a TRUNCATE checkpoint and an incremental vacuum run.
public final class ProjectIndexHandle: @unchecked Sendable {
    public let project: UUID
    public let directory: URL
    private let writerQueue: DispatchQueue
    private let readerQueue: DispatchQueue
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

    init(project: UUID, directory: URL, idleDelay: TimeInterval, registry: ProjectIndexRegistry) throws {
        self.project = project
        self.directory = directory
        self.idleDelay = idleDelay
        self.registry = registry
        writerQueue = DispatchQueue(label: "LLMTray index writer \(project.uuidString.prefix(8))")
        readerQueue = DispatchQueue(label: "LLMTray index reader \(project.uuidString.prefix(8))")
        let index = try ProjectIndex(directory: directory)
        openReport = try index.reconcile()
        try? index.checkpoint()
        self.index = index
        try openReader()
    }

    private func openReader() throws {
        let db = try SQLiteConnection(path: directory.appendingPathComponent(ProjectIndex.databaseName).path, readOnly: true)
        db.setBusyTimeout(milliseconds: 2000)
        searcher = try IndexSearcher(db: db)
        reader = db
    }

    private func closeReader() {
        searcher = nil
        dense = nil
        reader?.close()
        reader = nil
    }

    /// Runs `body` on the writer, then schedules the idle maintenance.
    public func write<T>(_ body: @escaping (ProjectIndex) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writerQueue.async {
                guard let index = self.index else { return continuation.resume(throwing: Closed()) }
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

    /// Runs `body` on the reader connection.
    public func read<T>(_ body: @escaping (IndexSearcher) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            readerQueue.async {
                guard let searcher = self.searcher else { return continuation.resume(throwing: Closed()) }
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
                guard let searcher = self.searcher, let reader = self.reader else { return continuation.resume(throwing: Closed()) }
                do {
                    var vectors: DenseVectors?
                    if let queryVector {
                        vectors = try self.currentVectors(reader, dim: queryVector.count)
                    }
                    let r = try searcher.search(query, queryVector: queryVector, dense: vectors, options: options)
                    continuation.resume(returning: (r, vectors?.residentBytes ?? 0))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        if result.1 > 0 { registry?.noteVectorsResident(self, bytes: result.1) }
        return result.0
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

    public var residentVectorBytes: Int {
        readerQueue.sync { dense?.residentBytes ?? 0 }
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
    /// reopen after. Only with no ingest running (the caller's job).
    public func compact() async throws {
        try await write { index in
            try index.compact(holdingOthers: { swap in
                try self.readerQueue.sync {
                    self.closeReader()
                    defer { try? self.openReader() }
                    try swap()
                }
            })
        }
    }

    /// Closes both connections; later calls throw `Closed`. Waits for the
    /// work already queued.
    public func close() {
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

    /// The project's handle, opened (and reconciled) on first use.
    public func handle(for project: UUID) throws -> ProjectIndexHandle {
        lock.lock()
        defer { lock.unlock() }
        if let h = handles[project] { return h }
        let h = try ProjectIndexHandle(project: project, directory: directory(project), idleDelay: idleDelay, registry: self)
        handles[project] = h
        return h
    }

    public var openProjects: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(handles.keys)
    }

    /// Closes the project's connections (before its deletion).
    public func close(_ project: UUID) {
        lock.lock()
        let h = handles.removeValue(forKey: project)
        vectorUse.removeAll { $0.project == project }
        lock.unlock()
        h?.close()
    }

    public func closeAll() {
        lock.lock()
        let all = Array(handles.values)
        handles.removeAll()
        vectorUse.removeAll()
        lock.unlock()
        all.forEach { $0.close() }
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
