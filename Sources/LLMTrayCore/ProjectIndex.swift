import CryptoKit
import Foundation

/// A document's state (adr/0012): staged → extracting → searchable →
/// embedded | failed | removing, plus `empty` (no text in it),
/// `unsupported` (a format this version doesn't index) and `not_indexed`
/// (stopped by the user; Index Now resumes it).
public enum DocumentStatus: String, Sendable, CaseIterable {
    case staged, extracting, searchable, embedded, failed, removing, empty, unsupported
    case notIndexed = "not_indexed"

    /// Answers searches (lexically at least).
    public var isSearchable: Bool { self == .searchable || self == .embedded }
}

public struct IndexedDocument: Equatable, Sendable {
    public var doc: Int64
    public var source: Int64
    public var rev: Int64
    public var name: String
    public var ext: String
    public var relativePath: String?
    public var sha256: String
    public var bytes: Int64
    public var status: DocumentStatus
    public var kind: String?
    public var pages: Int?
    public var error: String?
}

/// Extraction or re-index of one document, begun on the writer and
/// finished by `commitExtraction` -- the parsing itself happens in between,
/// outside any transaction.
public struct IndexJob: Equatable, Sendable {
    public var doc: Int64
    /// The revision the pages will be written as.
    public var rev: Int64
    public var file: URL
    public var isReindex: Bool
}

/// A chunk still without a vector in some set: what the embedder gets.
public struct PendingChunk: Equatable, Sendable {
    public var id: Int64
    public var rev: Int64
    /// The heading path and the verbatim chunk text.
    public var text: String
}

public struct VectorSet: Equatable, Sendable {
    public var id: Int64
    public var model: String
    public var dim: Int
    public var prepVersion: Int
    public var isActive: Bool
}

/// A cited page: what a citation names and a tombstone keeps.
public struct PageRef: Hashable, Sendable {
    public var doc: Int64
    public var rev: Int64
    public var page: Int

    public init(doc: Int64, rev: Int64, page: Int) {
        self.doc = doc
        self.rev = rev
        self.page = page
    }
}

public struct ReconcileReport: Equatable, Sendable {
    public var deletedPartials = 0
    public var deletedOrphanStaging = 0
    public var promoted = 0
    public var droppedStaged = 0
    public var resetExtracting = 0
    public var finishedRemoving = 0
    /// Removals that failed again (a copy that couldn't be deleted): still hidden, retried next time.
    public var failedRemovals = 0
    public var deletedOrphanFiles = 0
    /// Documents to extract (staged), in doc order.
    public var needExtraction: [Int64] = []
    /// Searchable documents still missing vectors of the active set.
    public var needEmbedding: [Int64] = []
}

public struct IndexStorage: Equatable, Sendable {
    public var fileBytes: Int64
    public var walBytes: Int64
    public var pageSize: Int64
    public var pageCount: Int64
    public var freePages: Int64
    /// Chunks deleted or re-indexed since the last compaction.
    public var churn: Int64
    public var liveChunks: Int64
    public var tombstonePages: Int64

    /// What the routine incremental vacuum returns to the OS.
    public var freeBytes: Int64 { freePages * pageSize }
    /// Fragmentation, not the free list, decides a full compaction: churn of
    /// 30% of the live chunks.
    public var needsCompaction: Bool { churn >= 500 && Double(churn) >= 0.3 * Double(max(liveChunks, 1)) }
}

/// One project's index (adr/0012): `files/` (the copies), `staging/`
/// (copies in progress) and `index.sqlite`, through the writer connection.
/// Every method is synchronous and each state change is one transaction;
/// nothing awaits while one is open. A crash anywhere leaves a state the
/// next `reconcile()` finishes or undoes.
public final class ProjectIndex {
    public let directory: URL
    public private(set) var db: SQLiteConnection
    public var chunker = IndexChunker()
    /// Free bytes on the index's volume; replaceable for tests.
    var freeSpace: () -> Int64? = { nil }
    /// Tests: called at named points of each protocol; throwing there is a
    /// crash (nothing after it runs, the open transaction rolls back).
    var crashHook: ((String) throws -> Void)?

    public static let databaseName = "index.sqlite"
    public var databaseURL: URL { directory.appendingPathComponent(Self.databaseName) }
    public var filesDirectory: URL { directory.appendingPathComponent("files") }
    public var stagingDirectory: URL { directory.appendingPathComponent("staging") }
    public static let vectorsPerBlock = 64

    public init(directory: URL) throws {
        try IndexSchema.checkRuntime()
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent("files"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("staging"), withIntermediateDirectories: true)
        try CompactionSwap.recover(in: directory)
        IndexMigration.discardLeftovers(in: directory)
        db = try Self.openWriter(directory: directory)
        freeSpace = { [directory] in Self.availableCapacity(at: directory) }
    }

    /// Creates a new database, or opens one of this schema; refuses a newer
    /// one without touching it.
    static func openWriter(directory: URL) throws -> SQLiteConnection {
        let path = directory.appendingPathComponent(databaseName).path
        var db = try SQLiteConnection(path: path)
        if try IndexSchema.isEmptyDatabase(db) {
            try IndexSchema.create(db)
            return db
        }
        guard let version = try IndexSchema.recordedVersion(db) else { throw ProjectIndexError.notAnIndex }
        if version > IndexSchema.version { throw ProjectIndexError.newerSchema(version) }
        if version < IndexSchema.version {
            db.close()
            try IndexMigration.migrate(directory: directory, from: version)
            db = try SQLiteConnection(path: path)
        }
        try IndexSchema.configureWriter(db)
        return db
    }

    public func close() { db.close() }
    /// False after `close`, or when a compaction couldn't reopen the file.
    public var isOpen: Bool { db.isOpen }

    func point(_ name: String) throws { try crashHook?(name) }

    // MARK: - reading state

    public func document(_ doc: Int64) throws -> IndexedDocument? {
        try documents(where: "doc = ?", [.int(doc)]).first
    }

    public func documents() throws -> [IndexedDocument] {
        try documents(where: "1", [])
    }

    private func documents(where clause: String, _ args: [SQLValue]) throws -> [IndexedDocument] {
        try db.rows("""
            SELECT doc, source, rev, name, ext, rel_path, sha256, bytes, status, kind, pages, error
            FROM documents WHERE \(clause) ORDER BY doc
            """, args) {
            IndexedDocument(doc: $0.int(0), source: $0.int(1), rev: $0.int(2), name: $0.text(3), ext: $0.text(4),
                            relativePath: $0.optionalText(5), sha256: $0.text(6), bytes: $0.int(7),
                            status: DocumentStatus(rawValue: $0.text(8)) ?? .failed, kind: $0.optionalText(9),
                            pages: $0.isNull(10) ? nil : Int($0.int(10)), error: $0.optionalText(11))
        }
    }

    public func summary() throws -> ProjectIndexSummary { try ProjectIndexSummary.read(db) }

    public func status(_ doc: Int64) throws -> DocumentStatus? {
        try db.scalarText("SELECT status FROM documents WHERE doc = ?", [.int(doc)]).flatMap(DocumentStatus.init(rawValue:))
    }

    func fileURL(doc: Int64, ext: String) -> URL { filesDirectory.appendingPathComponent("\(doc).\(ext)") }

    /// Where a document's file is: its copy, or the file in its linked folder.
    public func file(of d: IndexedDocument) throws -> URL? {
        if d.source == 1 { return fileURL(doc: d.doc, ext: d.ext) }
        guard let root = try db.scalarText("SELECT path FROM sources WHERE id = ?", [.int(d.source)]), let rel = d.relativePath,
              Self.isSafeRelativePath(rel) else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent(rel)
    }

    /// A path inside its folder: relative, no `.`/`..` component, no NUL.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.unicodeScalars.contains("\u{0}") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func sanitizedExtension(_ ext: String) -> String {
        let e = ext.lowercased()
        guard !e.isEmpty, e.count <= 10, e.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else { return "bin" }
        return e
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func availableCapacity(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private func bump(_ key: String, by n: Int64) throws {
        guard n != 0 else { return }
        try db.run("UPDATE meta SET value = value + ? WHERE key = ?", [.int(n), .text(key)])
    }

    // MARK: - adding copies

    /// Adds `source` as an immutable copy (adr/0012, Consistency): the
    /// `staged` row first (its doc allocated), then `staging/<doc>.part`,
    /// hashed, renamed to `staging/<doc>.<ext>`, the hash recorded, renamed to
    /// `files/<doc>.<ext>` -- every staged path belongs to exactly one row. A
    /// file already in the project (same hash) is refused. The document
    /// stays `staged` until extracted.
    @discardableResult
    public func addCopy(of link: URL, name: String? = nil) throws -> Int64 {
        let fm = FileManager.default
        // A symlink is copied as its target's bytes (copyItem would copy the
        // link itself: a "copy" pointing at the user's file, sized as a link).
        // Anything but a regular file is refused.
        let source = link.resolvingSymlinksInPath()
        guard let attributes = try? fm.attributesOfItem(atPath: source.path), attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ProjectIndexError.notARegularFile(link.lastPathComponent)
        }
        let ext = Self.sanitizedExtension(link.pathExtension.isEmpty ? source.pathExtension : link.pathExtension)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if let free = freeSpace(), free < size + size / 2 + (1 << 20) {
            throw ProjectIndexError.insufficientDisk(needed: size + size / 2 + (1 << 20), available: free)
        }
        let doc = try db.transaction {
            try db.run("INSERT INTO documents(source, rev, name, ext, added_at, status) VALUES (1, 1, ?, ?, ?, 'staged')",
                       [.text(name ?? link.lastPathComponent), .text(ext), .double(Date().timeIntervalSince1970)])
            return db.lastInsertRowID
        }
        try point("add.row")
        let part = stagingDirectory.appendingPathComponent("\(doc).part")
        let staged = stagingDirectory.appendingPathComponent("\(doc).\(ext)")
        func abandon() {
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: staged)
            try? db.run("DELETE FROM documents WHERE doc = ? AND status = 'staged'", [.int(doc)])
        }
        let sha: String, bytes: Int64
        do {
            try? fm.removeItem(at: part)
            try fm.copyItem(at: source, to: part)
            try point("add.copied")
            sha = try Self.sha256(of: part)
            let copied = try fm.attributesOfItem(atPath: part.path)
            guard copied[.type] as? FileAttributeType == .typeRegular else { throw ProjectIndexError.notARegularFile(link.lastPathComponent) }
            bytes = (copied[.size] as? NSNumber)?.int64Value ?? 0
            try fm.moveItem(at: part, to: staged)
            try point("add.hashed")
        } catch let crash as SimulatedCrash {
            throw crash
        } catch {
            abandon()
            throw error
        }
        if let existing = try db.scalarInt("SELECT doc FROM documents WHERE sha256 = ? AND source = 1 AND doc != ? AND status != 'removing'",
                                           [.text(sha), .int(doc)]) {
            abandon()
            throw ProjectIndexError.duplicate(existing: existing)
        }
        try db.run("UPDATE documents SET sha256 = ?, bytes = ? WHERE doc = ?", [.text(sha), .int(bytes), .int(doc)])
        try point("add.recorded")
        try fm.moveItem(at: staged, to: fileURL(doc: doc, ext: ext))
        try point("add.promoted")
        return doc
    }

    // MARK: - linked folders (the schema's side; FSEvents and bookmarks come in v1b)

    /// A linked folder: read only, never written to or deleted from.
    public func addFolderSource(path: String, bookmark: Data? = nil) throws -> Int64 {
        try db.transaction {
            try db.run("INSERT INTO sources(kind, bookmark, path) VALUES ('folder', ?, ?)", [bookmark.map { .blob($0) } ?? .null, .text(path)])
            return db.lastInsertRowID
        }
    }

    /// A file of a linked folder, `staged` for extraction; the file stays the user's.
    @discardableResult
    public func addLinkedDocument(source: Int64, relativePath: String, mtime: Double, sha256: String, bytes: Int64) throws -> Int64 {
        guard Self.isSafeRelativePath(relativePath) else { throw ProjectIndexError.invalidRelativePath(relativePath) }
        let ext = Self.sanitizedExtension((relativePath as NSString).pathExtension)
        return try db.transaction {
            guard try db.scalarText("SELECT kind FROM sources WHERE id = ?", [.int(source)]) == "folder" else {
                throw ProjectIndexError.noSuchDocument(source)
            }
            try db.run("""
                INSERT INTO documents(source, rev, name, ext, rel_path, mtime, sha256, bytes, added_at, status)
                VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, 'staged')
                """, [.int(source), .text((relativePath as NSString).lastPathComponent), .text(ext), .text(relativePath),
                      .double(mtime), .text(sha256), .int(bytes), .double(Date().timeIntervalSince1970)])
            return db.lastInsertRowID
        }
    }

    // MARK: - extraction

    /// staged → extracting; the caller parses `file` (outside any
    /// transaction), then commits or fails the job.
    public func beginExtraction(doc: Int64) throws -> IndexJob {
        guard let d = try document(doc) else { throw ProjectIndexError.noSuchDocument(doc) }
        guard d.status == .staged || d.status == .extracting, let file = try file(of: d) else { throw ProjectIndexError.stale(doc) }
        try db.run("UPDATE documents SET status = 'extracting' WHERE doc = ? AND status IN ('staged','extracting')", [.int(doc)])
        try point("extract.begun")
        return IndexJob(doc: doc, rev: d.rev, file: file, isReindex: false)
    }

    /// A new revision of an indexed document; the current one stays
    /// searchable until the new one commits.
    public func beginReindex(doc: Int64) throws -> IndexJob {
        guard let d = try document(doc) else { throw ProjectIndexError.noSuchDocument(doc) }
        let allowed: Set<DocumentStatus> = [.searchable, .embedded, .failed, .empty, .unsupported, .notIndexed]
        guard allowed.contains(d.status), let file = try file(of: d) else { throw ProjectIndexError.stale(doc) }
        return IndexJob(doc: doc, rev: d.rev + 1, file: file, isReindex: true)
    }

    /// Pages, chunks and both FTS indexes in one transaction, the status
    /// with them: `searchable`, or `empty` when no page has text. A re-index
    /// replaces the derived rows of the old revision in the same
    /// transaction; its pages stay behind as tombstones for citations.
    /// For a linked file, `identity` is the hash and mtime the caller checked
    /// *after* parsing (the file may change meanwhile -- then it discards the
    /// pages and retries): the revision is recorded with the content it holds.
    @discardableResult
    public func commitExtraction(_ job: IndexJob, pages: [ExtractedPage], kind: String? = nil,
                                 identity: (sha256: String, mtime: Double)? = nil) throws -> DocumentStatus {
        try db.transaction {
            guard let d = try document(job.doc) else { throw ProjectIndexError.stale(job.doc) }
            if job.isReindex {
                guard d.rev == job.rev - 1, d.status != .removing, d.status != .staged, d.status != .extracting else {
                    throw ProjectIndexError.stale(job.doc)
                }
                let old = try db.scalarInt("SELECT count(*) FROM chunks WHERE doc = ?", [.int(job.doc)]) ?? 0
                try db.run("DELETE FROM chunks WHERE doc = ?", [.int(job.doc)])
                try point("reindex.deleted")
                try db.run("DELETE FROM vec_blocks WHERE doc = ?", [.int(job.doc)])
                if db.changes > 0 { try bump("vec_epoch", by: 1) }
                try bump("churn", by: old)
            } else {
                guard d.status == .extracting, d.rev == job.rev else { throw ProjectIndexError.stale(job.doc) }
            }
            let status = try writeDerived(doc: job.doc, rev: job.rev, pages: pages)
            try db.run("UPDATE documents SET rev = ?, status = ?, pages = ?, kind = ?, error = NULL WHERE doc = ?",
                       [.int(job.rev), .text(status.rawValue), .int(Int64(pages.count)), kind.map { .text($0) } ?? .null, .int(job.doc)])
            if let identity {
                try db.run("UPDATE documents SET sha256 = ?, mtime = ? WHERE doc = ?",
                           [.text(identity.sha256), .double(identity.mtime), .int(job.doc)])
            }
            try point("extract.beforeCommit")
            return status
        }
    }

    private func writeDerived(doc: Int64, rev: Int64, pages: [ExtractedPage]) throws -> DocumentStatus {
        let insertPage = try db.cached("INSERT INTO pages(doc, rev, page, text, tier, status, error) VALUES (?, ?, ?, ?, ?, ?, ?)")
        var indexable: [(page: Int, text: String)] = []
        for var p in pages {
            // SQLite's substr() and text functions stop at U+0000, so a NUL
            // would cut every chunk after it: a space instead (one code
            // point for one, so the chunks' start/len stay right).
            if p.text.unicodeScalars.contains("\u{0}") {
                p.text = String(String.UnicodeScalarView(p.text.unicodeScalars.map { $0 == "\u{0}" ? " " : $0 }))
            }
            // A page without a usable text layer isn't indexed (a later tier
            // retries it from here); its text is still stored.
            let status = p.error != nil || p.isJunk ? "failed" : (p.hasText ? "ok" : "empty")
            let error = p.error ?? (p.isJunk ? "no usable text layer" : nil)
            try insertPage.bind([.int(doc), .int(rev), .int(Int64(p.page)), .text(p.text), .int(Int64(p.tier)),
                                 .text(status), error.map { .text($0) } ?? .null])
            try insertPage.step()
            if status == "ok" { indexable.append((p.page, p.text)) }
        }
        let insertChunk = try db.cached("INSERT INTO chunks(doc, rev, page, ord, heading, start, len, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        let drafts = chunker.chunk(pages: indexable)
        for (i, c) in drafts.enumerated() {
            try insertChunk.bind([.int(doc), .int(rev), .int(Int64(c.page)), .int(Int64(c.ord)), c.heading.map { .text($0) } ?? .null,
                                  .int(Int64(c.start)), .int(Int64(c.length)), .text(c.body)])
            try insertChunk.step()
            if i == drafts.count / 2 { try point("extract.midTransaction") }
        }
        return drafts.isEmpty ? .empty : .searchable
    }

    /// The extraction failed: a first extraction ends `failed` (or
    /// `unsupported`) with the reason; a failed re-index keeps the current
    /// revision and records why.
    public func failExtraction(_ job: IndexJob, error: String, unsupported: Bool = false) throws {
        if job.isReindex {
            try db.run("UPDATE documents SET error = ? WHERE doc = ? AND rev = ?", [.text(error), .int(job.doc), .int(job.rev - 1)])
        } else {
            try db.run("UPDATE documents SET status = ?, error = ? WHERE doc = ? AND rev = ? AND status = 'extracting'",
                       [.text(unsupported ? "unsupported" : "failed"), .text(error), .int(job.doc), .int(job.rev)])
        }
    }

    // MARK: - stop / resume

    /// Stop: whatever isn't searchable yet becomes `not_indexed`; indexed
    /// documents stay searchable. Returns how many were stopped.
    @discardableResult
    public func stopIndexing() throws -> Int {
        try db.run("UPDATE documents SET status = 'not_indexed' WHERE status IN ('staged','extracting')")
        return db.changes
    }

    /// Index Now: `not_indexed` back to `staged`; returns them.
    public func resumeIndexing() throws -> [Int64] {
        try db.transaction {
            let docs = try db.rows("SELECT doc FROM documents WHERE status = 'not_indexed' ORDER BY doc") { $0.int(0) }
            try db.run("UPDATE documents SET status = 'staged' WHERE status = 'not_indexed'")
            return docs
        }
    }

    // MARK: - vectors

    /// The set for this embedder, created if new; the first set is active.
    public func vectorSet(model: String, dim: Int, prepVersion: Int) throws -> VectorSet {
        try db.transaction {
            if let set = try vectorSets().first(where: { $0.model == model && $0.dim == dim && $0.prepVersion == prepVersion }) { return set }
            let first = try db.scalarInt("SELECT count(*) FROM vec_sets") == 0
            try db.run("INSERT INTO vec_sets(model, dim, prep_version, active, created_at) VALUES (?, ?, ?, ?, ?)",
                       [.text(model), .int(Int64(dim)), .int(Int64(prepVersion)), .int(first ? 1 : 0), .double(Date().timeIntervalSince1970)])
            return VectorSet(id: db.lastInsertRowID, model: model, dim: dim, prepVersion: prepVersion, isActive: first)
        }
    }

    public func vectorSets() throws -> [VectorSet] {
        try db.rows("SELECT set_id, model, dim, prep_version, active FROM vec_sets ORDER BY set_id") {
            VectorSet(id: $0.int(0), model: $0.text(1), dim: Int($0.int(2)), prepVersion: Int($0.int(3)), isActive: $0.int(4) != 0)
        }
    }

    public func activeVectorSet() throws -> VectorSet? { try vectorSets().first(where: \.isActive) }

    /// The embedder switch: one transaction flips `active`, drops the other
    /// sets' vectors and sets each searchable document's `embedded` by the
    /// new set.
    public func activate(set: Int64) throws {
        try db.transaction {
            guard try db.scalarInt("SELECT count(*) FROM vec_sets WHERE set_id = ?", [.int(set)]) == 1 else {
                throw ProjectIndexError.stale(set)
            }
            try db.run("UPDATE vec_sets SET active = 0 WHERE active = 1")
            try db.run("UPDATE vec_sets SET active = 1 WHERE set_id = ?", [.int(set)])
            try db.run("DELETE FROM vec_blocks WHERE set_id != ?", [.int(set)])
            try db.run("DELETE FROM vec_sets WHERE set_id != ?", [.int(set)])
            try bump("vec_epoch", by: 1)
            for doc in try db.rows("SELECT doc FROM documents WHERE status IN ('searchable','embedded')", [], { $0.int(0) }) {
                let complete = try pendingChunks(doc: doc, set: set, limit: 1).isEmpty
                try db.run("UPDATE documents SET status = ? WHERE doc = ?", [.text(complete ? "embedded" : "searchable"), .int(doc)])
            }
        }
    }

    /// Searchable documents with chunks lacking a vector of `set`, in doc order.
    public func documentsToEmbed(set: Int64) throws -> [Int64] {
        let active = try activeVectorSet()?.id == set
        let docs = try db.rows("SELECT doc FROM documents WHERE status IN \(active ? "('searchable')" : "('searchable','embedded')") ORDER BY doc") { $0.int(0) }
        return try docs.filter { try !pendingChunks(doc: $0, set: set, limit: 1).isEmpty }
    }

    private func coveredChunks(doc: Int64, rev: Int64, set: Int64) throws -> Set<Int64> {
        var covered = Set<Int64>()
        let st = try db.cached("SELECT chunk_ids FROM vec_blocks WHERE set_id = ? AND doc = ? AND rev = ?")
        defer { st.reset() }
        try st.bind([.int(set), .int(doc), .int(rev)])
        while try st.step() { covered.formUnion(DenseVectors.decodeIDs(st.blob(0))) }
        return covered
    }

    /// Up to `limit` chunks of the document's current revision without a
    /// vector of `set`, in order: the heading path and the verbatim text.
    public func pendingChunks(doc: Int64, set: Int64, limit: Int) throws -> [PendingChunk] {
        guard let rev = try db.scalarInt("SELECT rev FROM documents WHERE doc = ? AND status IN ('searchable','embedded')", [.int(doc)]) else {
            return []
        }
        let covered = try coveredChunks(doc: doc, rev: rev, set: set)
        var out: [PendingChunk] = []
        let st = try db.cached("""
            SELECT c.id, c.heading, substr(p.text, c.start + 1, c.len) FROM chunks c
            JOIN pages p ON p.doc = c.doc AND p.rev = c.rev AND p.page = c.page
            WHERE c.doc = ? AND c.rev = ? ORDER BY c.ord
            """)
        defer { st.reset() }
        try st.bind([.int(doc), .int(rev)])
        while out.count < limit, try st.step() {
            let id = st.int(0)
            guard !covered.contains(id) else { continue }
            let text = st.text(2)
            out.append(PendingChunk(id: id, rev: rev, text: st.optionalText(1).map { $0 + "\n" + text } ?? text))
        }
        return out
    }

    /// One embedding batch, one transaction, in blocks of ≤ 64 vectors; a
    /// crash costs this batch only. Chunks already covered are skipped (a
    /// repeated commit adds nothing). When the active set covers the whole
    /// document it becomes `embedded`. Returns whether it is complete.
    @discardableResult
    public func commitVectors(doc: Int64, rev: Int64, set: Int64, chunks: [Int64], vectors: [Float16]) throws -> Bool {
        guard let dim = try db.scalarInt("SELECT dim FROM vec_sets WHERE set_id = ?", [.int(set)]).map(Int.init) else {
            throw ProjectIndexError.stale(set)
        }
        let (expected, overflow) = chunks.count.multipliedReportingOverflow(by: dim)
        guard !overflow, vectors.count == expected else { throw ProjectIndexError.vectorMismatch(expected: expected, got: vectors.count) }
        return try db.transaction {
            guard let current = try document(doc), current.rev == rev, current.status.isSearchable else { throw ProjectIndexError.stale(doc) }
            let valid = Set(try db.rows("SELECT id FROM chunks WHERE doc = ? AND rev = ?", [.int(doc), .int(rev)]) { $0.int(0) })
            let covered = try coveredChunks(doc: doc, rev: rev, set: set)
            var rows: [Int] = []
            var seen = Set<Int64>()
            for (i, id) in chunks.enumerated() where valid.contains(id) && !covered.contains(id) && seen.insert(id).inserted { rows.append(i) }
            let insert = try db.cached("INSERT INTO vec_blocks(set_id, doc, rev, n, chunk_ids, v) VALUES (?, ?, ?, ?, ?, ?)")
            for start in stride(from: 0, to: rows.count, by: Self.vectorsPerBlock) {
                let block = rows[start..<min(rows.count, start + Self.vectorsPerBlock)]
                var v: [Float16] = []
                v.reserveCapacity(block.count * dim)
                for i in block { v.append(contentsOf: vectors[(i * dim)..<((i + 1) * dim)]) }
                try insert.bind([.int(set), .int(doc), .int(rev), .int(Int64(block.count)),
                                 .blob(DenseVectors.encode(ids: block.map { chunks[$0] })), .blob(DenseVectors.encode(vectors: v))])
                try insert.step()
                try point("embed.block")
            }
            let complete = try pendingChunks(doc: doc, set: set, limit: 1).isEmpty
            if complete, try activeVectorSet()?.id == set {
                try db.run("UPDATE documents SET status = 'embedded' WHERE doc = ? AND status = 'searchable'", [.int(doc)])
            }
            return complete
        }
    }

    // MARK: - removal

    /// `removing` in a transaction, the copy deleted (never a linked
    /// folder's file), the rows deleted in a transaction. The pages stay as
    /// tombstones until the sweep finds no citation of them.
    public func remove(doc: Int64) throws {
        guard let d = try document(doc) else { return }
        try db.run("UPDATE documents SET status = 'removing' WHERE doc = ?", [.int(doc)])
        try point("remove.marked")
        try finishRemoval(d)
    }

    private func finishRemoval(_ d: IndexedDocument) throws {
        if d.source == 1 {
            // A copy that can't be deleted keeps its row `removing` (hidden),
            // so the next reconcile tries again -- never a file without a row.
            let fm = FileManager.default
            for url in [fileURL(doc: d.doc, ext: d.ext), stagingDirectory.appendingPathComponent("\(d.doc).\(d.ext)"),
                        stagingDirectory.appendingPathComponent("\(d.doc).part")] where fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
        try point("remove.fileDeleted")
        try db.transaction {
            try db.run("DELETE FROM vec_blocks WHERE doc = ?", [.int(d.doc)])
            if db.changes > 0 { try bump("vec_epoch", by: 1) }
            let chunks = try db.scalarInt("SELECT count(*) FROM chunks WHERE doc = ?", [.int(d.doc)]) ?? 0
            try db.run("DELETE FROM chunks WHERE doc = ?", [.int(d.doc)])
            try bump("churn", by: chunks)
            try point("remove.midTransaction")
            try db.run("DELETE FROM documents WHERE doc = ?", [.int(d.doc)])
        }
    }

    /// A linked folder and its documents' rows -- never its files.
    /// The source and all its documents are marked in one transaction, so a
    /// crash halfway is finished by the next reconcile.
    public func removeSource(_ source: Int64) throws {
        guard source != 1 else { return }
        try db.transaction {
            try db.run("UPDATE sources SET removing = 1 WHERE id = ?", [.int(source)])
            try db.run("UPDATE documents SET status = 'removing' WHERE source = ?", [.int(source)])
        }
        try point("removeSource.marked")
        try finishSourceRemovals()
    }

    private func finishSourceRemovals() throws {
        for d in try documents(where: "source IN (SELECT id FROM sources WHERE removing = 1)", []) { try finishRemoval(d) }
        try db.run("DELETE FROM sources WHERE removing = 1 AND id != 1 AND NOT EXISTS (SELECT 1 FROM documents WHERE source = sources.id)")
    }

    // MARK: - reconcile

    /// At project open: finishes or undoes every state a crash can leave
    /// (adr/0012, Consistency). `.part` files and staged copies no row claims
    /// are deleted; a staged copy whose hash matches its row is promoted;
    /// `extracting` goes back to `staged`; `removing` is finished; searchable
    /// documents are listed for embedding. Only `files/` and `staging/` are
    /// ever deleted from.
    @discardableResult
    public func reconcile() throws -> ReconcileReport {
        var r = ReconcileReport()
        let fm = FileManager.default

        for d in try documents(where: "status = 'removing'", []) {
            // One copy that can't be deleted now doesn't stop the rest.
            do {
                try finishRemoval(d)
                r.finishedRemoving += 1
            } catch let crash as SimulatedCrash {
                throw crash
            } catch {
                r.failedRemovals += 1
            }
        }
        try? finishSourceRemovals()

        var staging = Set((try? fm.contentsOfDirectory(atPath: stagingDirectory.path)) ?? [])
        for d in try documents(where: "status = 'staged' AND source = 1", []) {
            let final = fileURL(doc: d.doc, ext: d.ext)
            let stagedName = "\(d.doc).\(d.ext)"
            staging.remove("\(d.doc).part")
            try? fm.removeItem(at: stagingDirectory.appendingPathComponent("\(d.doc).part"))
            if fm.fileExists(atPath: final.path), !d.sha256.isEmpty {
                if staging.remove(stagedName) != nil { try? fm.removeItem(at: stagingDirectory.appendingPathComponent(stagedName)) }
                continue
            }
            if staging.contains(stagedName), !d.sha256.isEmpty,
               (try? Self.sha256(of: stagingDirectory.appendingPathComponent(stagedName))) == d.sha256 {
                try? fm.removeItem(at: final)
                try fm.moveItem(at: stagingDirectory.appendingPathComponent(stagedName), to: final)
                staging.remove(stagedName)
                r.promoted += 1
                continue
            }
            // The add never completed: its copy (if any) and its row go.
            if staging.remove(stagedName) != nil { try? fm.removeItem(at: stagingDirectory.appendingPathComponent(stagedName)) }
            try? fm.removeItem(at: final)
            try db.run("DELETE FROM documents WHERE doc = ?", [.int(d.doc)])
            r.droppedStaged += 1
        }
        for name in staging {
            try? fm.removeItem(at: stagingDirectory.appendingPathComponent(name))
            if name.hasSuffix(".part") { r.deletedPartials += 1 } else { r.deletedOrphanStaging += 1 }
        }

        // The derive transaction is atomic: an `extracting` document has no
        // rows of its revision. Defensive all the same.
        for d in try documents(where: "status = 'extracting'", []) {
            try db.transaction {
                try db.run("DELETE FROM chunks WHERE doc = ? AND rev = ?", [.int(d.doc), .int(d.rev)])
                try db.run("DELETE FROM pages WHERE doc = ? AND rev = ?", [.int(d.doc), .int(d.rev)])
                try db.run("DELETE FROM vec_blocks WHERE doc = ? AND rev = ?", [.int(d.doc), .int(d.rev)])
                try db.run("UPDATE documents SET status = 'staged' WHERE doc = ?", [.int(d.doc)])
            }
            r.resetExtracting += 1
        }

        // Copies no row claims (our own naming only; anything else is left).
        let claimed = Set(try documents(where: "source = 1", []).map { "\($0.doc).\($0.ext)" })
        for name in (try? fm.contentsOfDirectory(atPath: filesDirectory.path)) ?? [] where !claimed.contains(name) {
            let parts = name.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, Int64(parts[0]) != nil else { continue }
            try? fm.removeItem(at: filesDirectory.appendingPathComponent(name))
            r.deletedOrphanFiles += 1
        }

        r.needExtraction = try db.rows("SELECT doc FROM documents WHERE status = 'staged' ORDER BY doc") { $0.int(0) }
        if let set = try activeVectorSet() { r.needEmbedding = try documentsToEmbed(set: set.id) }
        return r
    }

    // MARK: - citations

    /// The sweep (adr/0012, Retention): drops every tombstoned page -- one
    /// not of its document's current revision -- that `cited` doesn't name.
    /// Idempotent; returns how many went.
    @discardableResult
    public func sweepTombstones(keeping cited: Set<PageRef>) throws -> Int {
        try db.transaction {
            try db.exec("CREATE TEMP TABLE IF NOT EXISTS cited(doc INTEGER, rev INTEGER, page INTEGER, PRIMARY KEY (doc, rev, page)) WITHOUT ROWID")
            try db.exec("DELETE FROM temp.cited")
            for ref in cited {
                try db.run("INSERT OR IGNORE INTO temp.cited(doc, rev, page) VALUES (?, ?, ?)", [.int(ref.doc), .int(ref.rev), .int(Int64(ref.page))])
            }
            try db.run("""
                DELETE FROM pages
                WHERE NOT EXISTS (SELECT 1 FROM documents d WHERE d.doc = pages.doc AND d.rev = pages.rev)
                  AND NOT EXISTS (SELECT 1 FROM temp.cited c WHERE c.doc = pages.doc AND c.rev = pages.rev AND c.page = pages.page)
                """)
            let n = db.changes
            try db.exec("DELETE FROM temp.cited")
            return n
        }
    }

    // MARK: - maintenance

    public func storage() throws -> IndexStorage {
        let fm = FileManager.default
        func size(_ suffix: String) -> Int64 {
            ((try? fm.attributesOfItem(atPath: databaseURL.path + suffix))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return IndexStorage(
            fileBytes: size(""), walBytes: size("-wal"),
            pageSize: try db.scalarInt("PRAGMA page_size") ?? 0,
            pageCount: try db.scalarInt("PRAGMA page_count") ?? 0,
            freePages: try db.scalarInt("PRAGMA freelist_count") ?? 0,
            churn: try db.scalarInt("SELECT value FROM meta WHERE key = 'churn'") ?? 0,
            liveChunks: try db.scalarInt("SELECT count(*) FROM chunks") ?? 0,
            tombstonePages: try db.scalarInt("""
                SELECT count(*) FROM pages p WHERE NOT EXISTS (SELECT 1 FROM documents d WHERE d.doc = p.doc AND d.rev = p.rev)
                """) ?? 0)
    }

    /// The routine step, when ingest goes idle: up to `pages` free pages
    /// back to the OS. Returns how many.
    @discardableResult
    public func incrementalVacuum(pages: Int = 256) throws -> Int {
        let before = try db.scalarInt("PRAGMA freelist_count") ?? 0
        try db.exec("PRAGMA incremental_vacuum(\(max(1, pages)))")
        return Int(before - (try db.scalarInt("PRAGMA freelist_count") ?? 0))
    }

    /// A PASSIVE checkpoint (never waits), then TRUNCATE, retried while a
    /// reader's snapshot holds it. The busy timeout is `busyMilliseconds`
    /// meanwhile, not the writer's 5 s: a long read must not stall ingest
    /// for attempts × 5 s -- it throws BUSY after ~`attempts` × 150 ms.
    public func checkpoint(attempts: Int = 5, busyMilliseconds: Int32 = 100) throws {
        db.setBusyTimeout(milliseconds: busyMilliseconds)
        defer { db.setBusyTimeout(milliseconds: IndexSchema.writerBusyTimeout) }
        _ = try? db.checkpoint(truncate: false)
        for attempt in 1...max(1, attempts) {
            do {
                try db.checkpoint(truncate: true)
                return
            } catch let e as SQLiteError where e.isBusy && attempt < attempts {
                usleep(50_000)
            }
        }
    }

    public func optimizeFTS() throws { try IndexSchema.optimizeFTS(db) }
    public func integrityCheck() throws { try IndexSchema.integrityCheck(db) }
    public func rebuildFTS() throws { try IndexSchema.rebuildFTS(db) }

    /// Full compaction, first half (adr/0012, Maintenance): FTS `optimize`,
    /// free disk checked, `VACUUM INTO` a temp file, `quick_check` on it, the
    /// churn reset there, the marker written. The live file stays in use
    /// until `CompactionSwap.swap`.
    func prepareCompaction() throws {
        let storage = try storage()
        let needed = (storage.fileBytes + storage.walBytes) * 6 / 5
        if let free = freeSpace(), free < needed { throw ProjectIndexError.insufficientDisk(needed: needed, available: free) }
        try optimizeFTS()
        let target = directory.appendingPathComponent(CompactionSwap.compactName)
        CompactionSwap.removeFamily(target)
        try point("compact.optimized")
        do {
            try db.run("VACUUM INTO ?", [.text(target.path)])
            try point("compact.vacuumed")
            let copy = try SQLiteConnection(path: target.path)
            try IndexSchema.quickCheck(copy)
            try copy.run("UPDATE meta SET value = 0 WHERE key = 'churn'")
            copy.close()
            try CompactionSwap.writeMarker(in: directory)
        } catch {
            if !(error is SimulatedCrash) { CompactionSwap.removeFamily(target) }
            throw error
        }
    }

    /// Full compaction when this is the only connection (tests, tools). The
    /// registry's version also closes its reader for the swap.
    public func compact() throws {
        try compact(holdingOthers: { try $0() })
    }

    /// `holdingOthers` runs the swap with every other connection to the file
    /// closed and new searches held, reopening them after (the registry
    /// does it on its reader queue).
    func compact(holdingOthers: (() throws -> Void) throws -> Void) throws {
        try prepareCompaction()
        try holdingOthers {
            do {
                try checkpoint()
            } catch {
                // Not swapped: the copy and its marker go, the live file stays.
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(CompactionSwap.markerName))
                CompactionSwap.removeFamily(directory.appendingPathComponent(CompactionSwap.compactName))
                throw error
            }
            db.close()
            do {
                try CompactionSwap.swap(in: directory, crash: { try self.point($0) })
            } catch let crash as SimulatedCrash {
                throw crash
            } catch {
                // Whatever happened, the file in place is a complete index again.
                try? CompactionSwap.recover(in: directory)
                db = try Self.openWriter(directory: directory)
                throw error
            }
            db = try Self.openWriter(directory: directory)
        }
    }
}

/// What a test's crash hook throws.
struct SimulatedCrash: Error, Equatable {
    let point: String
}

/// The compaction swap (adr/0012, Maintenance), WAL-safe: with every
/// connection closed after a TRUNCATE checkpoint, the live file (and its
/// -wal/-shm) is moved aside, the compacted one renamed in, the old one
/// deleted. The marker -- written once the compacted copy passed its check,
/// independent of `meta` -- lets the next open finish a swap a crash
/// interrupted or roll it back.
public enum CompactionSwap {
    public static let compactName = "index.compact.sqlite"
    public static let oldName = "index.old.sqlite"
    public static let markerName = "index.swap"
    static let suffixes = ["", "-wal", "-shm", "-journal"]

    static func removeFamily(_ url: URL) {
        for s in suffixes { try? FileManager.default.removeItem(atPath: url.path + s) }
    }

    static func writeMarker(in dir: URL) throws {
        try Data("compacted copy verified\n".utf8).write(to: dir.appendingPathComponent(markerName), options: .atomic)
    }

    /// Moves `path` and its -wal/-shm to `target`'s names. The target's
    /// whole family goes first: a stale -wal/-shm left beside the new main
    /// file (a crash between two renames) would be replayed into it.
    static func moveFamily(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        for s in suffixes where fm.fileExists(atPath: to.path + s) { try fm.removeItem(atPath: to.path + s) }
        for s in suffixes where fm.fileExists(atPath: from.path + s) {
            try fm.moveItem(atPath: from.path + s, toPath: to.path + s)
        }
    }

    static func swap(in dir: URL, crash: (String) throws -> Void = { _ in }) throws {
        let live = dir.appendingPathComponent(ProjectIndex.databaseName)
        let old = dir.appendingPathComponent(oldName)
        removeFamily(old)
        try moveFamily(live, to: old)
        try crash("swap.movedOld")
        try moveFamily(dir.appendingPathComponent(compactName), to: live)
        try crash("swap.movedNew")
        removeFamily(old)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(markerName))
    }

    /// At open, before any connection: finishes or rolls back a swap.
    static func recover(in dir: URL) throws {
        let fm = FileManager.default
        let live = dir.appendingPathComponent(ProjectIndex.databaseName)
        let compact = dir.appendingPathComponent(compactName)
        let old = dir.appendingPathComponent(oldName)
        let marker = dir.appendingPathComponent(markerName)
        let hasLive = fm.fileExists(atPath: live.path)
        let hasOld = fm.fileExists(atPath: old.path)
        let hasCompact = fm.fileExists(atPath: compact.path)
        if fm.fileExists(atPath: marker.path) {
            if !hasLive {
                // The old file was moved aside: the verified copy goes in,
                // or, if it's gone too, the old one comes back.
                if hasCompact {
                    try moveFamily(compact, to: live)
                } else if hasOld {
                    try moveFamily(old, to: live)
                }
            } else if hasCompact {
                // The swap hadn't started moving: roll back.
                removeFamily(compact)
            }
            removeFamily(old)
            try? fm.removeItem(at: marker)
            return
        }
        // No marker: an unverified or unfinished copy, never used.
        removeFamily(compact)
        if hasOld {
            if hasLive { removeFamily(old) } else { try moveFamily(old, to: live) }
        }
    }
}
