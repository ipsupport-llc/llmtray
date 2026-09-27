import Foundation

/// What the ingest embeds documents with: the managed runner in the app
/// (`RunnerEmbedder`), a stand-in in tests.
public protocol ProjectEmbedder: AnyObject {
    /// What the vector set is keyed by (`EmbedderEntry.vectorSetModel`).
    var model: String { get }
    var dim: Int { get }
    var prepVersion: Int { get }
    /// Texts per request at most.
    var maxTexts: Int { get }
    /// A document's texts split into requests of one background slice each.
    func documentBatches(_ texts: [String]) -> [Range<Int>]
    func embedDocuments(_ texts: [String]) async throws -> EmbedResult
    /// Loads the model if it isn't (outside any background slice).
    func prepare() async throws
    /// Loaded: a request now is one slice's work, no cold start.
    var isReady: Bool { get }
}

extension ProjectEmbedder {
    public func prepare() async throws {}
    public var isReady: Bool { true }
}

/// An embedder entry's shared runner, as the ingest uses it.
public final class RunnerEmbedder: ProjectEmbedder {
    public let runner: EmbedRunner
    public let entry: EmbedderEntry
    /// One index request, the runner already started (`prepare`): a slice
    /// is ≤ ~3 s of work, so this is a hung runner, not a slow one.
    public var timeout: TimeInterval = 30

    public init(runner: EmbedRunner, entry: EmbedderEntry) {
        self.runner = runner
        self.entry = entry
    }

    public var model: String { entry.vectorSetModel }
    public var dim: Int { entry.dim }
    public var prepVersion: Int { entry.preprocessingVersion }
    public var maxTexts: Int { runner.configuration.maxTexts }
    public func documentBatches(_ texts: [String]) -> [Range<Int>] { runner.documentBatches(texts) }
    public func prepare() async throws {
        if runner.isPaused { throw EmbedRunner.Failure.paused }
        try await runner.start()
    }

    public var isReady: Bool { runner.readyInfo != nil }

    public func embedDocuments(_ texts: [String]) async throws -> EmbedResult {
        try await runner.embed(texts, kind: .document, timeout: timeout)
    }
}

/// The project indexer's engine (adr/0012, Pipeline and Scheduling): copies
/// added files into their project (ProjectIndex's staging protocol), runs
/// each through the supervised extractor, writes its pages and chunks
/// (searchable by words from then on), then embeds it in background slices
/// of the `GenerationQueue` -- one embed request each, no ticket held
/// across them -- so an image or music generation gets the GPU at the next
/// slice boundary. Every step waits while the chat model generates
/// (`isForegroundBusy`) or a generation runs or waits. Without an embedder
/// documents stay searchable and are embedded once one is there.
///
/// Pause / Resume per project (persisted by the caller through
/// `onPersist`), Stop (the queue cleared, whatever wasn't extracted
/// `not_indexed`), Index Now. When a project's queue runs dry: a
/// checkpoint and incremental vacuum, and the citation sweep when it has
/// tombstones. `forget` before a project's directory is deleted: its jobs
/// cancelled, its index closed, never reopened.
@MainActor
public final class ProjectIngestor {
    public struct Environment {
        public var registry: ProjectIndexRegistry
        /// The supervised extractor (`DocumentExtraction.run` with the app binary).
        public var extract: (URL) async throws -> DocumentExtraction.Document
        /// The embedder to use now; nil: words only (not installed, or the feature has none).
        public var embedder: () -> ProjectEmbedder?
        public var queue: GenerationQueue
        /// The chat model is generating: steps wait.
        public var isForegroundBusy: () -> Bool
        /// The pages the project's saved chats cite; nil when they couldn't
        /// all be read (the sweep is skipped then -- never on a partial list).
        public var citedPages: (UUID) async -> Set<PageRef>?
        public var pollInterval: TimeInterval
        /// After the 1st, 2nd, ... embedding failure in a row; past the
        /// last, embedding is off until `embedderChanged`.
        public var embedRetryDelays: [TimeInterval]

        public init(registry: ProjectIndexRegistry,
                    extract: @escaping (URL) async throws -> DocumentExtraction.Document,
                    embedder: @escaping () -> ProjectEmbedder?,
                    queue: GenerationQueue,
                    isForegroundBusy: @escaping () -> Bool = { false },
                    citedPages: @escaping (UUID) async -> Set<PageRef>? = { _ in nil },
                    pollInterval: TimeInterval = 0.5,
                    embedRetryDelays: [TimeInterval] = [5, 30, 120]) {
            self.registry = registry
            self.extract = extract
            self.embedder = embedder
            self.queue = queue
            self.isForegroundBusy = isForegroundBusy
            self.citedPages = citedPages
            self.pollInterval = pollInterval
            self.embedRetryDelays = embedRetryDelays
        }
    }

    public enum AddResult: Equatable, Sendable {
        case added(Int64)
        case duplicate(of: Int64)
        /// Not a format this version indexes (refused at add).
        case notSupported
        case failed(String)
    }

    public struct Activity: Equatable, Sendable {
        public var doc: Int64?
        public var stage: IngestStage
    }

    public typealias Item = ProjectIngestQueue.Item

    private let env: Environment
    public private(set) var queue = ProjectIngestQueue()
    public private(set) var paused: Set<UUID>
    /// Stopped by the user: nothing is queued for it at open (Index Now or
    /// an add clears it).
    public private(set) var stopped: Set<UUID>
    /// (paused, stopped), whenever either changes.
    public var onPersist: ((Set<UUID>, Set<UUID>) -> Void)?
    /// Any published state changed (progress, documents, activity).
    public var onChange: (() -> Void)?
    /// Each open project's documents, refreshed after every step.
    public private(set) var documents: [UUID: [IndexedDocument]] = [:]
    public private(set) var activity: [UUID: Activity] = [:]
    /// The step in flight waits for the chat model or a generation.
    public private(set) var isWaiting = false
    /// Why embedding is off for this session (nil: it isn't).
    public private(set) var embeddingUnavailable: String?

    private var worker: Task<Void, Never>?
    private var extraction: (item: Item, task: Task<DocumentExtraction.Document, Error>)?
    /// Bumped by stop and forget: a step begun before sees it changed.
    private var epochs: [UUID: Int] = [:]
    /// A Stop or Index Now is writing (`beginTransition`); the next ones wait.
    private var transitioning: Set<UUID> = []
    private var transitionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    /// A stopped project's staged documents being made `not_indexed` at open.
    private var stopReconciles: [UUID: Task<Bool, Never>] = [:]
    private var deleted: Set<UUID> = []
    private var opened: Set<UUID> = []
    private var copying: [UUID: Int] = [:]
    private var embedFailures = 0
    private var unblock: Task<Void, Never>?
    private var maintenance: [UUID: Task<Void, Never>] = [:]
    private var isShutDown = false
    /// The step in flight's own time so far (its waits left out).
    private var activeSeconds: Double = 0
    /// Held (a download or removal of its files): tried again after this.
    private var heldRetry: TimeInterval { env.pollInterval * 10 }

    public init(environment: Environment, paused: Set<UUID> = [], stopped: Set<UUID> = []) {
        env = environment
        self.paused = paused
        self.stopped = stopped
        for p in paused { queue.setPaused(p, true) }
    }

    // MARK: - state for the UI

    public func progress(for project: UUID) -> ProjectIndexProgress {
        let stage = activity[project]?.stage ?? ((copying[project] ?? 0) > 0 ? .copying : nil)
        return queue.progress(project, stage: stage, waiting: isWaiting, wordsOnly: isWordsOnly)
    }

    /// Searching goes by words only (no embedder, or embedding is off).
    public var isWordsOnly: Bool { embeddingUnavailable != nil || env.embedder() == nil }

    public func displayStatus(_ d: IndexedDocument, in project: UUID) -> DocumentDisplayStatus {
        let a = activity[project]
        let queuedEmbed = !isWordsOnly && (queue.queued(project).contains(.embed(d.doc)) || queue.inFlight == Item(project: project, work: .embed(d.doc)))
        return DocumentDisplayStatus(d.status, activity: a?.doc == d.doc ? a?.stage : nil, embeddingQueued: queuedEmbed)
    }

    private func changed() { onChange?() }

    private func persist() { onPersist?(paused, stopped) }

    // MARK: - projects

    /// Opens a project with an index (at launch, or on first use): the
    /// reconcile at open finishes what a crash left, and what it lists is
    /// queued -- extraction of staged files, embedding of searchable ones
    /// (not for a stopped project).
    @discardableResult
    public func open(_ project: UUID) async -> Error? {
        do {
            let h = try await handle(project)
            await refreshDocuments(project, h)
            return nil
        } catch {
            return error
        }
    }

    private func handle(_ project: UUID) async throws -> ProjectIndexHandle {
        guard !deleted.contains(project), !isShutDown else { throw ProjectIndexHandle.Closed() }
        let h = try await env.registry.open(project)
        guard !deleted.contains(project), !isShutDown else { throw ProjectIndexHandle.Closed() }
        guard opened.insert(project).inserted else {
            // A stopped project's repair at open (below) comes first: an add
            // or an Index Now's write mustn't land before it.
            if let repair = stopReconciles[project] { _ = await repair.value }
            return h
        }
        if stopped.contains(project) {
            // Stopped, though what was staged wasn't made `not_indexed`
            // (a quit between the persisted Stop and its write): made so
            // now, and nothing queued. Failed, it's tried again at the
            // next use (and Index Now takes staged documents too).
            let write = Task { () -> Bool in (try? await h.write { try $0.stopIndexing() }) != nil }
            stopReconciles[project] = write
            let done = await write.value
            stopReconciles[project] = nil
            if !done { opened.remove(project) }
        } else {
            queue.enqueue(h.openReport.needExtraction.map(ProjectIngestQueue.Work.extract), in: project)
        }
        // Not the report's list: that one knows only an existing vector
        // set, and documents made searchable before the embedder was
        // installed have none yet.
        await queueEmbedding(project, h)
        if deleted.contains(project) { queue.remove(project) }
        kick()
        // Nothing to do: the maintenance a quit may have cut short (a
        // removal's tombstones not yet swept) is done now.
        if !queue.hasWork(project) { scheduleMaintenance(project) }
        return h
    }

    private func refreshDocuments(_ project: UUID, _ h: ProjectIndexHandle? = nil) async {
        var handle = h
        if handle == nil { handle = try? await self.handle(project) }
        guard let handle, let docs = try? await handle.write({ try $0.documents() }) else { return }
        guard !deleted.contains(project) else { return }
        documents[project] = docs.filter { $0.status != .removing }
        changed()
    }

    private func epoch(_ project: UUID) -> Int { epochs[project] ?? 0 }

    /// Copies `urls` into the project and queues them. Each file gets its
    /// own result; a format this version doesn't index is refused.
    public func add(_ urls: [URL], to project: UUID) async -> [AddResult] {
        copying[project, default: 0] += 1
        changed()
        defer {
            copying[project, default: 1] -= 1
            if copying[project] == 0 { copying[project] = nil }
            changed()
        }
        let h: ProjectIndexHandle
        do {
            h = try await handle(project)
        } catch {
            return urls.map { _ in .failed("\(error)") }
        }
        var results: [AddResult] = []
        let e = epoch(project)
        for url in urls {
            guard !deleted.contains(project) else {
                results.append(.failed("the project was deleted"))
                continue
            }
            // Stopped meanwhile: the rest isn't added.
            guard epoch(project) == e else {
                results.append(.failed("indexing was stopped"))
                continue
            }
            guard ProjectFileFormats.isOffered(url) else {
                results.append(.notSupported)
                continue
            }
            // In turn with Stop's and Index Now's writes: a Stop's
            // `not_indexed` never lands on a file queued after it.
            await beginTransition(project)
            defer { endTransition(project) }
            do {
                let doc = try await h.write { try $0.addCopy(of: url) }
                results.append(.added(doc))
                // A stop that came during the copy makes it `not_indexed`.
                guard epoch(project) == e, !deleted.contains(project) else { continue }
                if stopped.remove(project) != nil {
                    // A new file restarts a stopped project: what the stop
                    // left unembedded is queued again too.
                    persist()
                    await queueEmbedding(project, h)
                    guard epoch(project) == e, !deleted.contains(project) else { continue }
                }
                queue.enqueue([.extract(doc)], in: project)
                kick()
            } catch ProjectIndexError.duplicate(let existing) {
                results.append(.duplicate(of: existing))
            } catch {
                results.append(.failed("\(error)"))
            }
        }
        await refreshDocuments(project, h)
        return results
    }

    public func pause(_ project: UUID) {
        guard paused.insert(project).inserted else { return }
        queue.setPaused(project, true)
        persist()
        changed()
    }

    public func resume(_ project: UUID) {
        guard paused.remove(project) != nil else { return }
        queue.setPaused(project, false)
        persist()
        kick()
        changed()
    }

    /// Stop: the queue cleared; what's indexed stays searchable, the rest
    /// becomes `not_indexed` (Index Now resumes it). The step in flight is
    /// cancelled.
    public func stop(_ project: UUID) async {
        epochs[project] = epoch(project) + 1
        stopped.insert(project)
        if paused.remove(project) != nil { queue.setPaused(project, false) }
        persist()
        queue.stop(project)
        if let e = extraction, e.item.project == project { e.task.cancel() }
        changed()
        await beginTransition(project)
        let h = try? await handle(project)
        if let h { _ = try? await h.write { try $0.stopIndexing() } }
        endTransition(project)
        if let h { await refreshDocuments(project, h) }
    }

    /// Index Now: `not_indexed` documents back in the queue, embedding
    /// resumed. A Stop meanwhile wins: nothing is queued after it.
    public func indexNow(_ project: UUID) async {
        // Saved once its write is in: a quit before that leaves it stopped
        // (the repair at open), never unstopped with files left
        // `not_indexed`. A write that failed leaves it stopped.
        let wasStopped = stopped.remove(project) != nil
        let e = epoch(project)
        let resumed = await resume(project)
        guard wasStopped else { return }
        if !resumed, epoch(project) == e, !deleted.contains(project) {
            // Stopped again, as it was: what opening the index queued
            // meanwhile (its staged files, its embeddings) goes too.
            epochs[project] = e + 1
            stopped.insert(project)
            queue.stop(project)
            if let x = extraction, x.item.project == project { x.task.cancel() }
            changed()
        } else if !deleted.contains(project) {
            persist()
        }
    }

    /// False when the index couldn't be opened or its write failed (not
    /// when a Stop meanwhile won).
    private func resume(_ project: UUID) async -> Bool {
        let e = epoch(project)
        await beginTransition(project)
        guard epoch(project) == e else {
            endTransition(project)
            return true
        }
        guard let h = try? await handle(project) else {
            endTransition(project)
            return false
        }
        let docs: [Int64]
        do {
            docs = try await h.write { try $0.resumeIndexing() }
        } catch {
            endTransition(project)
            return false
        }
        guard epoch(project) == e, !deleted.contains(project) else {
            endTransition(project)
            return true
        }
        queue.enqueue(docs.map(ProjectIngestQueue.Work.extract), in: project)
        await queueEmbedding(project, h)
        endTransition(project)
        kick()
        await refreshDocuments(project, h)
        return true
    }

    /// Stop's and Index Now's writes run one at a time per project, in the
    /// order they were asked for: a Stop's `not_indexed` never lands before
    /// the Index Now it follows, nor an Index Now's `staged` after it.
    private func beginTransition(_ project: UUID) async {
        guard transitioning.insert(project).inserted else {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                transitionWaiters[project, default: []].append(c)
            }
            return   // handed over by endTransition, still marked
        }
    }

    private func endTransition(_ project: UUID) {
        guard var waiters = transitionWaiters[project], !waiters.isEmpty else {
            transitioning.remove(project)
            return
        }
        let next = waiters.removeFirst()
        transitionWaiters[project] = waiters.isEmpty ? nil : waiters
        next.resume()
    }

    /// Queues the project's searchable documents that lack vectors. Nothing
    /// when it was stopped or deleted meanwhile.
    private func queueEmbedding(_ project: UUID, _ h: ProjectIndexHandle) async {
        guard !stopped.contains(project), let embedder = env.embedder(), embeddingUnavailable == nil else { return }
        let e = epoch(project)
        let docs: [Int64] = (try? await h.write { idx -> [Int64] in
            guard let set = try Self.vectorSet(idx, for: embedder, create: false) else { return [] }
            return try idx.documentsToEmbed(set: set.id)
        }) ?? []
        guard epoch(project) == e, !stopped.contains(project), !deleted.contains(project) else { return }
        queue.enqueue(docs.map(ProjectIngestQueue.Work.embed), in: project)
    }

    /// The set the project embeds into with `embedder`: its active set if it
    /// is this embedder's, created (active) when the project has none; nil
    /// when the project's vectors are another embedder's (words only for
    /// it -- a switch isn't part of v1a). `create: false`: none yet counts
    /// as a set to fill.
    static func vectorSet(_ idx: ProjectIndex, for e: ProjectEmbedder, create: Bool) throws -> VectorSet? {
        if let active = try idx.activeVectorSet() {
            return active.model == e.model && active.dim == e.dim && active.prepVersion == e.prepVersion ? active : nil
        }
        if create { return try idx.vectorSet(model: e.model, dim: e.dim, prepVersion: e.prepVersion) }
        return VectorSet(id: -1, model: e.model, dim: e.dim, prepVersion: e.prepVersion, isActive: true)
    }

    /// Removes one document (its copy, its rows; cited pages stay as tombstones).
    public func removeDocument(_ doc: Int64, from project: UUID) async throws {
        let h = try await handle(project)
        queue.drop(doc, in: project)
        if let e = extraction, e.item.project == project, e.item.work.doc == doc { e.task.cancel() }
        try await h.write { try $0.remove(doc: doc) }
        await refreshDocuments(project, h)
        if !queue.hasWork(project) { scheduleMaintenance(project) }
    }

    /// Before the project's directory is deleted: its jobs cancelled, its
    /// index closed (after the write in progress), and it's never opened again.
    public func forget(_ project: UUID) async {
        deleted.insert(project)
        epochs[project] = epoch(project) + 1
        queue.remove(project)
        if let e = extraction, e.item.project == project { e.task.cancel() }
        maintenance.removeValue(forKey: project)?.cancel()
        documents[project] = nil
        activity[project] = nil
        opened.remove(project)
        let wasPaused = paused.remove(project) != nil
        if stopped.remove(project) != nil || wasPaused { persist() }
        let registry = env.registry
        try? await ProcessRunner.offMain { registry.retire(project) }
        changed()
    }

    /// Stops everything (the feature turned off, the app quitting). The
    /// caller closes the registry's handles.
    public func shutdown() {
        isShutDown = true
        worker?.cancel()
        worker = nil
        extraction?.task.cancel()
        unblock?.cancel()
        maintenance.values.forEach { $0.cancel() }
        maintenance = [:]
    }

    /// The embedder was installed or removed: embedding resumes (or stops)
    /// for every open project.
    public func embedderChanged() async {
        embeddingUnavailable = nil
        embedFailures = 0
        unblock?.cancel()
        unblock = nil
        queue.embeddingBlocked = false
        for project in opened where !deleted.contains(project) {
            if let h = try? await handle(project) { await queueEmbedding(project, h) }
        }
        kick()
        changed()
    }

    // MARK: - the worker

    private func kick() {
        guard worker == nil, !isShutDown else { return }
        worker = Task { [weak self] in await self?.work() }
    }

    private func work() async {
        while !Task.isCancelled, !isShutDown, let item = queue.next() {
            changed()
            activeSeconds = 0
            let outcome = await perform(item)
            activity[item.project] = nil
            if isWaiting { isWaiting = false }
            // Work only, not the waits (the chat, a generation, a slice): the ETA's base.
            let ended = queue.finish(item, outcome, seconds: activeSeconds)
            if outcome != .interrupted { await refreshDocuments(item.project) }
            // Also a dropped step that was the last (its document removed
            // while it ran): the run's end went with the removal.
            if ended || (outcome == .dropped && !queue.hasWork(item.project)) { scheduleMaintenance(item.project) }
            changed()
        }
        worker = nil
    }

    /// The step began before a stop or a deletion: its result doesn't count.
    private func isCurrent(_ item: Item, _ e: Int) -> Bool {
        epoch(item.project) == e && !deleted.contains(item.project) && !isShutDown
    }

    private func outcomeWhenCut(_ item: Item, _ e: Int) -> ProjectIngestQueue.Outcome {
        isCurrent(item, e) ? .interrupted : .dropped
    }

    /// Waits while the chat model generates or a generation runs or waits.
    /// False: interrupted meanwhile (stopped, deleted, or -- `pauses` --
    /// paused).
    private func waitForForeground(_ item: Item, _ e: Int, pauses: Bool) async -> Bool {
        while env.isForegroundBusy() || env.queue.hasInteractiveDemand {
            if !isCurrent(item, e) || (pauses && paused.contains(item.project)) || Task.isCancelled { return false }
            if !isWaiting {
                isWaiting = true
                changed()
            }
            try? await Task.sleep(nanoseconds: UInt64(env.pollInterval * 1e9))
        }
        if isWaiting {
            isWaiting = false
            changed()
        }
        return isCurrent(item, e) && !(pauses && paused.contains(item.project)) && !Task.isCancelled
    }

    private func perform(_ item: Item) async -> ProjectIngestQueue.Outcome {
        switch item.work {
        case .extract(let doc): return await extract(doc, item)
        case .embed(let doc): return await embed(doc, item)
        }
    }

    private func extract(_ doc: Int64, _ item: Item) async -> ProjectIngestQueue.Outcome {
        let e = epoch(item.project)
        guard await waitForForeground(item, e, pauses: true) else { return outcomeWhenCut(item, e) }
        activity[item.project] = Activity(doc: doc, stage: .reading)
        changed()
        let started = Date()
        defer { activeSeconds += Date().timeIntervalSince(started) }
        let h: ProjectIndexHandle
        let job: IndexJob
        do {
            h = try await handle(item.project)
            job = try await h.write { try $0.beginExtraction(doc: doc) }
        } catch {
            // Removed or stopped meanwhile, or the project is gone.
            if Self.isStale(error) || !isCurrent(item, e) { return .dropped }
            NSLog("LLMTray: project file %lld couldn't be read for indexing: %@", doc, "\(error)")
            if let h = try? await handle(item.project) {
                _ = try? await h.write { try $0.failStaged(doc: doc, error: "\(error)") }
            }
            return .failed
        }
        // Stopped while it began: not read at all.
        guard isCurrent(item, e) else { return .dropped }
        let extract = env.extract
        let file = job.file
        let task = Task { try await extract(file) }
        extraction = (item, task)
        let result = await task.result
        extraction = nil
        guard isCurrent(item, e) else { return .dropped }
        do {
            let status: DocumentStatus
            switch result {
            case .success(let document):
                status = try await h.write { try $0.commitExtraction(job, pages: document.pages, kind: document.kind.rawValue) }
            case .failure(let error as ExtractionError):
                switch error {
                case .empty, .junk:
                    // No text (a scan, without OCR): indexed as empty, with why.
                    status = try await h.write { try $0.commitExtraction(job, pages: [], note: error == .junk ? error.description : nil) }
                case .unsupported, .unavailableOnSystem:
                    try await h.write { try $0.failExtraction(job, error: error.description, unsupported: true) }
                    status = .unsupported
                default:
                    try await h.write { try $0.failExtraction(job, error: error.description) }
                    status = .failed
                }
            case .failure(is CancellationError):
                return .dropped
            case .failure(let error):
                try await h.write { try $0.failExtraction(job, error: "\(error)") }
                status = .failed
            }
            switch status {
            case .searchable:
                return !stopped.contains(item.project) && !isWordsOnly ? .needsEmbedding : .finished
            case .embedded:
                return .finished
            default:
                return .failed
            }
        } catch {
            // Stopped or removed while it was read.
            if Self.isStale(error) || !isCurrent(item, e) { return .dropped }
            // A real write failure (a full disk, I/O): failed, with why --
            // never left `extracting` for the rest of the session.
            _ = try? await h.write { try $0.failExtraction(job, error: "\(error)") }
            return .failed
        }
    }

    /// The document or the project changed state under a step: its result doesn't count.
    static func isStale(_ error: Error) -> Bool {
        if error is ProjectIndexHandle.Closed { return true }
        switch error as? ProjectIndexError {
        case .stale?, .noSuchDocument?: return true
        default: return false
        }
    }

    private func embed(_ doc: Int64, _ item: Item) async -> ProjectIngestQueue.Outcome {
        let e = epoch(item.project)
        guard embeddingUnavailable == nil, let embedder = env.embedder() else { return .finished }
        let h: ProjectIndexHandle
        let set: VectorSet
        do {
            h = try await handle(item.project)
            guard let s = try await h.write({ try Self.vectorSet($0, for: embedder, create: true) }) else { return .finished }
            set = s
        } catch {
            return .dropped
        }
        while true {
            guard await waitForForeground(item, e, pauses: true) else { return outcomeWhenCut(item, e) }
            // Removed or replaced meanwhile: picked up again with what there is now.
            guard env.embedder() === embedder, embeddingUnavailable == nil else { return .interrupted }
            let pending: [PendingChunk]
            do {
                pending = try await h.write { idx -> [PendingChunk] in
                    let chunks = try idx.pendingChunks(doc: doc, set: set.id, limit: embedder.maxTexts)
                    if chunks.isEmpty, let d = try idx.document(doc), d.status.isSearchable {
                        // Every chunk has its vector: the document is complete.
                        try idx.commitVectors(doc: doc, rev: d.rev, set: set.id, chunks: [], vectors: [])
                    }
                    return chunks
                }
            } catch {
                return await vectorWriteFailed(error, item, e, doc: doc)
            }
            if pending.isEmpty { return .finished }
            let range = embedder.documentBatches(pending.map(\.text)).first ?? 0..<pending.count
            let batch = Array(pending[range])
            activity[item.project] = Activity(doc: doc, stage: .embedding)
            changed()
            // The model loads outside the slice (and not while the chat
            // model generates): a slice is one request (≤ ~3 s), not a cold
            // start a generation would wait behind.
            guard await waitForForeground(item, e, pauses: true) else { return outcomeWhenCut(item, e) }
            do {
                try await embedder.prepare()
            } catch {
                return await embedFailed(error, item, e)
            }
            let slice: GenerationQueue.Slice
            do {
                slice = try await env.queue.acquireBackground(isCancelled: { [weak self] in
                    guard let self else { return true }
                    return !self.isCurrent(item, e) || self.paused.contains(item.project)
                })
            } catch {
                return outcomeWhenCut(item, e)
            }
            // The chat model may have started while the slice was waited
            // for, or a generation's grant (or the idle timeout) ended the
            // runner: back to the top, the model loaded outside a slice.
            if env.isForegroundBusy() || !embedder.isReady {
                slice.release()
                continue
            }
            let result: EmbedResult
            let sent = Date()
            do {
                result = try await embedder.embedDocuments(batch.map(\.text))
                slice.release()
                activeSeconds += Date().timeIntervalSince(sent)
            } catch {
                slice.release()
                return await embedFailed(error, item, e, doc: doc)
            }
            guard result.count == batch.count, result.dim == set.dim, result.vectors.count == batch.count * set.dim else {
                return await embedFailed(EmbedRunner.Failure.protocolViolation("\(result.count) × \(result.dim) for \(batch.count) × \(set.dim)"), item, e, doc: doc)
            }
            guard isCurrent(item, e) else { return .dropped }
            do {
                let complete = try await h.write {
                    try $0.commitVectors(doc: doc, rev: batch[0].rev, set: set.id, chunks: batch.map(\.id), vectors: result.vectors)
                }
                embedFailures = 0
                if complete { return .finished }
            } catch {
                return await vectorWriteFailed(error, item, e, doc: doc)
            }
        }
    }

    /// Re-indexed, removed or stopped meanwhile: dropped. A real write
    /// failure (a full disk, I/O) isn't lost silently: it backs off and is
    /// tried again like an embedder failure, and past the last try
    /// embedding is off for the session, with why.
    private func vectorWriteFailed(_ error: Error, _ item: Item, _ e: Int, doc: Int64) async -> ProjectIngestQueue.Outcome {
        if Self.isStale(error) || !isCurrent(item, e) { return .dropped }
        NSLog("LLMTray: project file %lld's vectors couldn't be written: %@", doc, "\(error)")
        return await embedFailed(error, item, e)
    }

    /// Paused by a generation (or held for a download), or stopped at a
    /// grant: tried again once it may run. Anything else backs off; past the
    /// last delay embedding is off for the session and documents stay
    /// searchable by words.
    private func embedFailed(_ error: Error, _ item: Item, _ e: Int, doc: Int64? = nil) async -> ProjectIngestQueue.Outcome {
        guard isCurrent(item, e) else { return .dropped }
        if error is CancellationError { return .interrupted }
        let failure = error as? EmbedRunner.Failure
        if failure == .paused || failure == .stopped {
            if env.queue.hasInteractiveDemand {
                // A generation: waited out in waitForForeground.
                try? await Task.sleep(nanoseconds: UInt64(env.pollInterval * 1e9))
                // Stopped meanwhile: not put back in its cleared queue.
                guard isCurrent(item, e) else { return .dropped }
            } else {
                // Held while its files are replaced or removed: not polled
                // every beat; `embedderChanged` (the download's end) lifts it.
                blockEmbedding(for: heldRetry)
            }
            return .interrupted
        }
        if let doc, let failure {
            switch failure {
            case .runner(code: "bad_request", _), .runner(code: "too_large", _), .protocolViolation:
                // This document's request was refused (a text the runner
                // won't take, an answer of the wrong shape): it stays
                // searchable by words, and the rest goes on.
                NSLog("LLMTray: project file %lld not embedded: %@", doc, "\(error)")
                return .finished
            default:
                break
            }
        }
        embedFailures += 1
        let delays = env.embedRetryDelays
        guard embedFailures <= delays.count else {
            embeddingUnavailable = "\(error)"
            NSLog("LLMTray: project embedding is off for this session: %@", "\(error)")
            for project in queue.finishEmbeddingAsWordsOnly() { scheduleMaintenance(project) }
            return .finished
        }
        blockEmbedding(for: delays[embedFailures - 1])
        return .interrupted
    }

    private func blockEmbedding(for delay: TimeInterval) {
        queue.embeddingBlocked = true
        unblock?.cancel()
        unblock = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard let self, !Task.isCancelled else { return }
            self.unblock = nil
            self.queue.embeddingBlocked = false
            self.kick()
        }
    }

    // MARK: - maintenance

    /// The project's queue ran dry: a TRUNCATE checkpoint and an
    /// incremental vacuum; with tombstones, the citation sweep.
    private func scheduleMaintenance(_ project: UUID) {
        guard !deleted.contains(project), !isShutDown, maintenance[project] == nil else { return }
        let cited = env.citedPages
        maintenance[project] = Task { [weak self] in
            defer { self?.maintenance[project] = nil }
            guard let self, let h = try? await self.handle(project) else { return }
            try? await h.maintainNow()
            let tombstones = (try? await h.write { try $0.storage().tombstonePages }) ?? 0
            guard tombstones > 0, !Task.isCancelled, let keep = await cited(project), !Task.isCancelled,
                  !self.deleted.contains(project) else { return }
            _ = try? await h.write { try $0.sweepTombstones(keeping: keep) }
        }
    }

    /// Waits for scheduled maintenance (tests).
    public func maintenanceFinished() async {
        while let task = maintenance.values.first { await task.value }
    }

    /// True once nothing is queued or running anywhere (tests).
    public var isIdle: Bool { worker == nil && queue.inFlight == nil && maintenance.isEmpty && unblock == nil }
}
