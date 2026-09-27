import Foundation

/// What an ingest is doing to a document right now (adr/0012, UI statuses).
public enum IngestStage: String, Equatable, Sendable {
    case copying, reading, embedding
}

/// One project's indexing as the sidebar ring and the Files view show it:
/// "Indexing 120 of 450 files · reading · ~20 min left".
public struct ProjectIndexProgress: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        /// Nothing to do.
        case idle
        case running
        /// Work waits while the chat model or a generator runs.
        case waiting
        /// Paused by the user (the pause survives a relaunch).
        case paused
    }

    public var state: State
    public var stage: IngestStage?
    /// Files of this run (since the project's queue was last empty).
    public var total: Int
    /// Indexed as far as they go this run (searchable, or embedded).
    public var done: Int
    /// Failed, unsupported, or with no text.
    public var failed: Int
    /// Rough: the average time per finished file × the files left.
    public var remainingSeconds: Double?
    /// No embedder (not installed, or unavailable): search by words only.
    public var wordsOnly: Bool

    public static let idle = ProjectIndexProgress(state: .idle, stage: nil, total: 0, done: 0, failed: 0, remainingSeconds: nil, wordsOnly: false)

    public init(state: State, stage: IngestStage?, total: Int, done: Int, failed: Int, remainingSeconds: Double?, wordsOnly: Bool) {
        self.state = state
        self.stage = stage
        self.total = total
        self.done = done
        self.failed = failed
        self.remainingSeconds = remainingSeconds
        self.wordsOnly = wordsOnly
    }

    public var isActive: Bool { state != .idle }
}

/// The ingest's job queue, app-wide (adr/0012, Scheduling), as pure state:
/// what runs next, what a pause, a stop or a finished step does. One step
/// runs at a time -- one extraction, or one document's embedding (in
/// bounded slices the driver runs). Extraction comes first everywhere, so
/// every added file is searchable by its words before any is embedded;
/// projects take turns (round robin), documents go in the order added.
/// `ProjectIngestor` drives it.
public struct ProjectIngestQueue: Sendable {
    public enum Work: Hashable, Sendable {
        case extract(Int64)
        /// A new revision of an indexed document (the user's Re-index): in
        /// the extraction lane, its current revision searchable meanwhile.
        case reindex(Int64)
        case embed(Int64)

        public var doc: Int64 {
            switch self {
            case .extract(let d), .reindex(let d), .embed(let d): return d
            }
        }
    }

    public struct Item: Hashable, Sendable {
        public var project: UUID
        public var work: Work

        public init(project: UUID, work: Work) {
            self.project = project
            self.work = work
        }
    }

    /// How a step ended.
    public enum Outcome: Equatable, Sendable {
        /// The document is as indexed as it gets this run.
        case finished
        /// Failed, unsupported or empty: counted apart.
        case failed
        /// Extracted and searchable; its embedding is queued next.
        case needsEmbedding
        /// Paused or yielded before it was done: back to the front.
        case interrupted
        /// Stopped, removed or deleted under it: not counted.
        case dropped
    }

    struct Project: Sendable {
        var extract: [Int64] = []
        /// Which of `extract` are re-indexes.
        var reindex: Set<Int64> = []
        var embed: [Int64] = []
        var paused = false
        /// This run's documents.
        var run: Set<Int64> = []
        var done = 0
        var failed = 0
        var workSeconds: Double = 0
        /// How each of this run's documents counted (true: done, false:
        /// failed): once each, and taken back when it's re-indexed.
        var counted: [Int64: Bool] = [:]
        var hasWork: Bool { !extract.isEmpty || !embed.isEmpty }

        /// Takes back how `doc` counted (re-indexed, removed, dropped).
        mutating func uncount(_ doc: Int64) {
            guard let wasDone = counted.removeValue(forKey: doc) else { return }
            if wasDone { done -= 1 } else { failed -= 1 }
        }
    }

    private var projects: [UUID: Project] = [:]
    /// Round robin: the project served last goes to the end.
    private var order: [UUID] = []
    public private(set) var inFlight: Item?
    /// Embedding held back (the embedder is backing off after a failure):
    /// `next` hands out extraction only.
    public var embeddingBlocked = false

    public init() {}

    private mutating func touch(_ project: UUID) {
        if projects[project] == nil {
            projects[project] = Project()
            order.append(project)
        }
    }

    /// Queues work for documents (each once: already queued or running is skipped).
    public mutating func enqueue(_ work: [Work], in project: UUID) {
        touch(project)
        for w in work {
            guard inFlight != Item(project: project, work: w) else { continue }
            switch w {
            case .extract(let d):
                // A first extraction (Index Now) supersedes a queued re-index:
                // a staged document can't be re-indexed.
                projects[project]!.reindex.remove(d)
                guard !projects[project]!.extract.contains(d) else { continue }
                projects[project]!.extract.append(d)
            case .reindex(let d):
                // Already queued (a first extraction, or a re-index): that one does.
                guard !projects[project]!.extract.contains(d), inFlight != Item(project: project, work: .extract(d)) else { continue }
                projects[project]!.extract.append(d)
                projects[project]!.reindex.insert(d)
                // Finished earlier this run: it counts again when it's done again.
                projects[project]!.uncount(d)
            case .embed(let d):
                guard !projects[project]!.embed.contains(d) else { continue }
                projects[project]!.embed.append(d)
            }
            projects[project]!.run.insert(w.doc)
        }
    }

    public func isPaused(_ project: UUID) -> Bool { projects[project]?.paused ?? false }

    public mutating func setPaused(_ project: UUID, _ paused: Bool) {
        touch(project)
        projects[project]!.paused = paused
    }

    public func hasWork(_ project: UUID) -> Bool {
        (projects[project]?.hasWork ?? false) || inFlight?.project == project
    }

    public func queued(_ project: UUID) -> [Work] {
        guard let p = projects[project] else { return [] }
        return p.extract.map { p.reindex.contains($0) ? .reindex($0) : .extract($0) } + p.embed.map(Work.embed)
    }

    /// The next step, marked in flight; nil when one already runs or
    /// nothing may run (paused projects, blocked embedding).
    public mutating func next() -> Item? {
        guard inFlight == nil else { return nil }
        for extracting in [true, false] where extracting || !embeddingBlocked {
            for project in order {
                guard var p = projects[project], !p.paused else { continue }
                let item: Item
                if extracting {
                    guard !p.extract.isEmpty else { continue }
                    let doc = p.extract.removeFirst()
                    item = Item(project: project, work: p.reindex.remove(doc) != nil ? .reindex(doc) : .extract(doc))
                } else {
                    guard !p.embed.isEmpty else { continue }
                    item = Item(project: project, work: .embed(p.embed.removeFirst()))
                }
                projects[project] = p
                order.removeAll { $0 == project }
                order.append(project)
                inFlight = item
                return item
            }
        }
        return nil
    }

    /// The step `item` ended with `outcome` after `seconds` of work. True
    /// when its project's run is over (nothing queued or running): the
    /// driver's cue for maintenance.
    @discardableResult
    public mutating func finish(_ item: Item, _ outcome: Outcome, seconds: Double = 0) -> Bool {
        if inFlight == item { inFlight = nil }
        guard var p = projects[item.project] else { return false }
        let doc = item.work.doc
        // Counted once, and not while a re-index of it waits (an embedding
        // that ends after the Re-index click counts when the new one does).
        let counted = p.run.contains(doc) && p.counted[doc] == nil && !p.reindex.contains(doc)
        switch outcome {
        case .finished:
            if counted {
                p.done += 1
                p.counted[doc] = true
            }
            p.workSeconds += seconds
        case .failed:
            if counted {
                p.failed += 1
                p.counted[doc] = false
            }
            p.workSeconds += seconds
        case .needsEmbedding:
            p.workSeconds += seconds
            if !p.embed.contains(doc) { p.embed.append(doc) }
        case .interrupted:
            switch item.work {
            case .extract: if !p.extract.contains(doc) { p.extract.insert(doc, at: 0) }
            case .reindex:
                if !p.extract.contains(doc) {
                    p.extract.insert(doc, at: 0)
                    p.reindex.insert(doc)
                }
            case .embed: if !p.embed.contains(doc) { p.embed.insert(doc, at: 0) }
            }
        case .dropped:
            p.run.remove(doc)
            p.uncount(doc)
        }
        projects[item.project] = p
        return endRunIfIdle(item.project)
    }

    private mutating func endRunIfIdle(_ project: UUID) -> Bool {
        guard var p = projects[project], !p.hasWork, inFlight?.project != project, !p.run.isEmpty else { return false }
        p.run = []
        p.counted = [:]
        p.done = 0
        p.failed = 0
        p.workSeconds = 0
        projects[project] = p
        return true
    }

    /// Stop: the project's queue cleared and its run ended. Returns whether
    /// one of its steps is in flight (the driver cancels it).
    @discardableResult
    public mutating func stop(_ project: UUID) -> Bool {
        if var p = projects[project] {
            p.extract = []
            p.reindex = []
            p.embed = []
            p.run = []
            p.counted = [:]
            p.done = 0
            p.failed = 0
            p.workSeconds = 0
            projects[project] = p
        }
        return inFlight?.project == project
    }

    /// The project is gone (deleted): forgotten entirely.
    public mutating func remove(_ project: UUID) {
        projects[project] = nil
        order.removeAll { $0 == project }
    }

    /// One document removed: out of the queue and the run.
    public mutating func drop(_ doc: Int64, in project: UUID) {
        guard var p = projects[project] else { return }
        p.extract.removeAll { $0 == doc }
        p.reindex.remove(doc)
        p.embed.removeAll { $0 == doc }
        p.run.remove(doc)
        p.uncount(doc)
        projects[project] = p
    }

    /// Embedding became impossible for this session: every queued
    /// embedding counts as finished (searchable by words). Returns the
    /// projects whose run ended.
    public mutating func finishEmbeddingAsWordsOnly() -> [UUID] {
        var ended: [UUID] = []
        for id in order {
            guard var p = projects[id], !p.embed.isEmpty else { continue }
            for d in p.embed where p.run.contains(d) && p.counted[d] == nil && !p.reindex.contains(d) {
                p.done += 1
                p.counted[d] = true
            }
            p.embed = []
            projects[id] = p
            if endRunIfIdle(id) { ended.append(id) }
        }
        return ended
    }

    public func progress(_ project: UUID, stage: IngestStage? = nil, waiting: Bool = false, wordsOnly: Bool = false) -> ProjectIndexProgress {
        guard let p = projects[project] else {
            return ProjectIndexProgress(state: stage == nil ? .idle : .running, stage: stage, total: 0, done: 0, failed: 0,
                                        remainingSeconds: nil, wordsOnly: wordsOnly)
        }
        let running = inFlight?.project == project
        let state: ProjectIndexProgress.State
        if p.hasWork || running || stage != nil {
            if p.paused && !running { state = .paused } else if waiting && running { state = .waiting } else { state = .running }
        } else {
            state = .idle
        }
        let remaining = max(0, p.run.count - p.done - p.failed)
        let finished = p.done + p.failed
        let eta = finished > 0 && remaining > 0 ? p.workSeconds / Double(finished) * Double(remaining) : nil
        return ProjectIndexProgress(state: state, stage: state == .idle ? nil : stage, total: p.run.count, done: p.done,
                                    failed: p.failed, remainingSeconds: eta, wordsOnly: wordsOnly)
    }
}

/// The formats the add flow accepts (adr/0012, "Formats offered", v1a
/// exactly): plain text, Markdown, code, the PDF text layer, docx/doc/odt/
/// rtf, HTML. Checked by extension at add -- anything else is refused with
/// "not yet supported"; the extractor then tells the type from the content
/// (a spreadsheet renamed .txt still ends `unsupported`, never searchable).
public enum ProjectFileFormats {
    public static let documents: Set<String> = ["pdf", "docx", "doc", "odt", "rtf", "html", "htm", "xhtml"]
    public static let text: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "mkd", "rst", "org", "adoc", "asciidoc", "tex", "log",
        "csv", "tsv", "json", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "properties", "xml",
    ]
    public static let code: Set<String> = [
        "swift", "py", "pyi", "js", "mjs", "cjs", "ts", "tsx", "jsx", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm",
        "java", "kt", "kts", "go", "rs", "rb", "php", "pl", "pm", "lua", "r", "scala", "sh", "bash", "zsh", "fish", "ps1",
        "bat", "cmd", "sql", "css", "scss", "sass", "less", "vue", "svelte", "dart", "cs", "fs", "hs", "ml", "ex", "exs",
        "erl", "clj", "el", "vim", "gradle", "cmake", "mk", "dockerfile", "tf", "proto", "graphql", "ipynb", "zig", "nim",
    ]

    /// Offered for adding: by extension, case-insensitive; a file without
    /// one (Makefile, README) goes to the extractor as text.
    public static func isOffered(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || documents.contains(ext) || text.contains(ext) || code.contains(ext)
    }
}

/// The one mapping of a document's state to what the user sees (adr/0012,
/// UI): copying / reading / embedding / ready / empty / failed / not
/// supported, plus queued and not indexed. `searchable` is "ready (words
/// only)" until its embedding is done.
public enum DocumentDisplayStatus: String, Equatable, Sendable {
    case queued, copying, reading, embedding
    case readyWordsOnly = "ready-words-only"
    case ready, empty, failed
    case notSupported = "not-supported"
    case notIndexed = "not-indexed"
    case removing

    /// `reindexQueued`: a Re-index waits its turn (the current revision
    /// stays searchable meanwhile, but the row says what's coming).
    public init(_ status: DocumentStatus, activity: IngestStage? = nil, embeddingQueued: Bool = false, reindexQueued: Bool = false) {
        if let activity {
            switch activity {
            case .copying: self = .copying
            case .reading: self = .reading
            case .embedding: self = .embedding
            }
            return
        }
        if reindexQueued, status != .removing {
            self = .queued
            return
        }
        switch status {
        case .staged: self = .queued
        case .extracting: self = .reading
        case .searchable: self = embeddingQueued ? .embedding : .readyWordsOnly
        case .embedded: self = .ready
        case .empty: self = .empty
        case .failed: self = .failed
        case .unsupported: self = .notSupported
        case .notIndexed: self = .notIndexed
        case .removing: self = .removing
        }
    }
}
