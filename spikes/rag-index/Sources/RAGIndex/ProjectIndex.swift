import Foundation
import CryptoKit

public enum DocStatus: String {
    case staged, extracting, searchable, embedded, failed, removing
}

public struct ChunkDraft {
    public var page: Int
    public var ord: Int
    public var body: String      // normalized
    public var start: Int        // code points into the page's raw text
    public var len: Int
}

/// Splits a page into ~wordsPerChunk-word chunks at whitespace, no overlap.
/// Offsets are in Unicode scalars (what SQLite's substr() counts for TEXT).
public enum Chunker {
    public static func chunk(pageText: String, page: Int, firstOrd: Int, wordsPerChunk: Int) -> [ChunkDraft] {
        let scalars = Array(pageText.unicodeScalars)
        var out: [ChunkDraft] = []
        var i = 0, ord = firstOrd
        while i < scalars.count {
            while i < scalars.count, scalars[i].properties.isWhitespace { i += 1 }
            guard i < scalars.count else { break }
            let start = i
            var words = 0
            var inWord = false
            var j = i
            while j < scalars.count {
                let ws = scalars[j].properties.isWhitespace
                if !ws && !inWord { words += 1; if words > wordsPerChunk { break } }
                inWord = !ws
                j += 1
            }
            var end = j
            while end > start, scalars[end - 1].properties.isWhitespace { end -= 1 }
            let raw = String(String.UnicodeScalarView(scalars[start..<end]))
            out.append(ChunkDraft(page: page, ord: ord, body: Normalizer.normalize(raw), start: start, len: end - start))
            ord += 1
            i = j
        }
        return out
    }
}

/// Toy embedder for the spike: feature-hashed bag of normalized words (and
/// their trigram pseudo-stems) into `dim` buckets, L2-normalized. Deterministic,
/// so dense results are meaningful enough to exercise fusion.
public struct ToyEmbedder {
    public let dim: Int
    public init(dim: Int = 1024) { self.dim = dim }
    public func embed(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        for t in QueryBuilder.terms(text) {
            let s = QueryBuilder.stemForTrigram(t)
            var h: UInt64 = 1469598103934665603
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            v[Int(h % UInt64(dim))] += (h >> 63) == 0 ? 1 : -1
        }
        var n: Float = 0
        for x in v { n += x * x }
        n = n.squareRoot()
        if n > 0 { for k in 0..<dim { v[k] /= n } }
        return v
    }
}

public struct ReconcileReport: Equatable, CustomStringConvertible {
    public var deletedPartFiles = 0
    public var deletedOrphanStaging = 0
    public var promotedStaged = 0
    public var droppedStagedWithoutFile = 0
    public var resetExtracting = 0
    public var finishedRemoving = 0
    public var deletedOrphanFiles = 0
    public var failedMissingFile = 0
    public var droppedPartialDerived = 0
    public var needExtraction: [Int64] = []
    public var needEmbedding: [Int64] = []
    public var description: String {
        "part=\(deletedPartFiles) orphanStaging=\(deletedOrphanStaging) promoted=\(promotedStaged) droppedStaged=\(droppedStagedWithoutFile) resetExtracting=\(resetExtracting) finishedRemoving=\(finishedRemoving) orphanFiles=\(deletedOrphanFiles) missingFile=\(failedMissingFile) partialDerived=\(droppedPartialDerived) needExtraction=\(needExtraction) needEmbedding=\(needEmbedding)"
    }
}

/// One project's index directory: files/, staging/, index.sqlite. Owns the
/// writer connection. Ingestion follows ADR 0012's states:
/// staged → extracting → searchable → embedded | failed | removing.
public final class ProjectIndex {
    public let dir: URL
    public let db: Database
    public var filesDir: URL { dir.appendingPathComponent("files") }
    public var stagingDir: URL { dir.appendingPathComponent("staging") }
    public var dbURL: URL { dir.appendingPathComponent("index.sqlite") }
    public var wordsPerChunk = 280
    public var embedBatch = 64
    public var embedder = ToyEmbedder()
    public var modelName = "toy-hash-1024"
    /// Test hook: called with a named point; a crash test child kills itself here.
    public var crashHook: ((String) -> Void)?

    public init(dir: URL, options: IndexOptions = IndexOptions()) throws {
        self.dir = dir
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("files"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("staging"), withIntermediateDirectories: true)
        db = try Database(path: dir.appendingPathComponent("index.sqlite").path)
        try Schema.configure(db, pageSize: options.pageSize)
        try Schema.create(db, options: options)
        if try db.scalarInt("SELECT count(*) FROM vec_sets") == 0 {
            try db.run("INSERT INTO vec_sets(model, dim, active) VALUES (?, ?, 1)", [.text(modelName), .int(Int64(embedder.dim))])
        }
    }

    func hit(_ point: String) { crashHook?(point) }

    public var activeSet: Int64 {
        (try? db.scalarInt("SELECT id FROM vec_sets WHERE active = 1 LIMIT 1")) ?? 1
    }

    public func status(_ doc: Int64) throws -> DocStatus? {
        try db.scalarText("SELECT status FROM documents WHERE doc = ?", [.int(doc)]).flatMap(DocStatus.init)
    }

    func fileURL(doc: Int64, ext: String) -> URL { filesDir.appendingPathComponent("\(doc).\(ext)") }

    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: add

    /// Full add pipeline: stage → row → promote → extract → embed.
    @discardableResult
    public func add(file src: URL, embed: Bool = true) throws -> Int64 {
        let doc = try stage(file: src)
        try extract(doc: doc)
        if embed { try self.embed(doc: doc) }
        return doc
    }

    /// Copy into staging (.part), hash, rename to staging/<sha>.<ext>, insert the
    /// `staged` row, then rename into files/<doc>.<ext>.
    public func stage(file src: URL) throws -> Int64 {
        let fm = FileManager.default
        let ext = src.pathExtension.isEmpty ? "bin" : src.pathExtension.lowercased()
        let part = stagingDir.appendingPathComponent(UUID().uuidString + ".part")
        try fm.copyItem(at: src, to: part)
        hit("staging.copied")
        let sha = try Self.sha256(part)
        let staged = stagingDir.appendingPathComponent("\(sha).\(ext)")
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        try fm.moveItem(at: part, to: staged)
        hit("staging.hashed")
        let bytes = (try fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? 0
        let doc: Int64 = try db.transaction {
            try db.run("""
                INSERT INTO documents(source, rev, name, ext, sha256, bytes, added_at, status)
                VALUES (1, 1, ?, ?, ?, ?, ?, 'staged')
                """, [.text(src.lastPathComponent), .text(ext), .text(sha), .int(bytes), .double(Date().timeIntervalSince1970)])
            return db.lastInsertRowID
        }
        hit("staged.row")
        try fm.moveItem(at: staged, to: fileURL(doc: doc, ext: ext))
        hit("staged.promoted")
        return doc
    }

    /// "Extraction" for the spike: UTF-8 text, pages split by form feed.
    /// Everything derived is written in ONE transaction that also flips the
    /// status to searchable.
    public func extract(doc: Int64) throws {
        guard let ext = try db.scalarText("SELECT ext FROM documents WHERE doc = ?", [.int(doc)]),
              let rev = try db.scalarInt("SELECT rev FROM documents WHERE doc = ?", [.int(doc)]) else { return }
        try db.run("UPDATE documents SET status = 'extracting' WHERE doc = ?", [.int(doc)])
        hit("extracting.set")
        // Extraction happens outside any transaction (ADR: no await with a txn open).
        let text = try String(contentsOf: fileURL(doc: doc, ext: ext), encoding: .utf8)
        let pages = text.components(separatedBy: "\u{0C}")
        try db.transaction {
            try writeDerived(doc: doc, rev: rev, pages: pages, midHook: "extracting.midtxn")
            try db.run("UPDATE documents SET status = 'searchable', pages = ? WHERE doc = ?", [.int(Int64(pages.count)), .int(doc)])
            hit("extracting.beforecommit")
        }
        hit("searchable.committed")
    }

    func writeDerived(doc: Int64, rev: Int64, pages: [String], midHook: String?) throws {
        let insPage = try db.prepare("INSERT INTO pages(doc, rev, page, text, tier) VALUES (?, ?, ?, ?, 1)")
        let insChunk = try db.prepare("INSERT INTO chunks(doc, rev, page, ord, heading, body, start, len) VALUES (?, ?, ?, ?, NULL, ?, ?, ?)")
        var ord = 0
        var total = 0
        let drafts: [ChunkDraft] = pages.enumerated().flatMap { (i, p) -> [ChunkDraft] in
            let c = Chunker.chunk(pageText: p, page: i + 1, firstOrd: ord, wordsPerChunk: wordsPerChunk)
            ord += c.count
            return c
        }
        for (i, p) in pages.enumerated() {
            try insPage.bind([.int(doc), .int(rev), .int(Int64(i + 1)), .text(p)])
            try insPage.step()
        }
        for d in drafts {
            try insChunk.bind([.int(doc), .int(rev), .int(Int64(d.page)), .int(Int64(d.ord)), .text(d.body), .int(Int64(d.start)), .int(Int64(d.len))])
            try insChunk.step()
            total += 1
            if total == drafts.count / 2, let midHook { hit(midHook) }
        }
    }

    /// Embeds missing chunks of a searchable document in batches, one commit per
    /// batch (a crash costs at most one batch); flips to embedded at the end.
    public func embed(doc: Int64) throws {
        let set = activeSet
        guard let rev = try db.scalarInt("SELECT rev FROM documents WHERE doc = ? AND status IN ('searchable','embedded')", [.int(doc)]) else { return }
        // chunks not yet covered by a block of this set
        var covered = Set<Int64>()
        let q = try db.prepare("SELECT chunk_ids FROM vec_blocks WHERE set_id = ? AND doc = ? AND rev = ?")
        try q.bind([.int(set), .int(doc), .int(rev)])
        while try q.step() { covered.formUnion(Self.decodeIDs(q.blob(0))) }
        var todo: [(Int64, String)] = []
        let c = try db.prepare("SELECT id, body FROM chunks WHERE doc = ? AND rev = ? ORDER BY ord")
        try c.bind([.int(doc), .int(rev)])
        while try c.step() { if !covered.contains(c.int(0)) { todo.append((c.int(0), c.text(1))) } }
        var batchNo = 0
        for start in stride(from: 0, to: todo.count, by: embedBatch) {
            let batch = Array(todo[start..<min(start + embedBatch, todo.count)])
            // model runs outside the transaction
            var f16 = [Float16](); f16.reserveCapacity(batch.count * embedder.dim)
            for (_, body) in batch { f16.append(contentsOf: embedder.embed(body).map(Float16.init)) }
            try db.transaction {
                let ins = try db.prepare("INSERT INTO vec_blocks(set_id, doc, rev, n, chunk_ids, v) VALUES (?, ?, ?, ?, ?, ?)")
                let ids = batch.map(\.0)
                try ins.bind([.int(set), .int(doc), .int(rev), .int(Int64(batch.count)), .blob(Self.encodeIDs(ids)),
                              .blob(f16.withUnsafeBufferPointer { Data(buffer: $0) })])
                try ins.step()
                batchNo += 1
                if batchNo == 2 { hit("embedding.midtxn") }
            }
            if batchNo == 1 { hit("embedding.batchcommitted") }
        }
        try db.run("UPDATE documents SET status = 'embedded' WHERE doc = ? AND status = 'searchable'", [.int(doc)])
        hit("embedded.committed")
    }

    static func encodeIDs(_ ids: [Int64]) -> Data { ids.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func decodeIDs(_ p: UnsafeRawBufferPointer) -> [Int64] {
        Array(p.bindMemory(to: Int64.self))
    }

    // MARK: re-index (linked-folder style): old rev stays searchable until commit.

    public func reindex(doc: Int64, newText: String) throws {
        let pages = newText.components(separatedBy: "\u{0C}")
        try db.transaction {
            guard let rev = try db.scalarInt("SELECT rev FROM documents WHERE doc = ?", [.int(doc)]) else { return }
            try db.run("DELETE FROM chunks WHERE doc = ?", [.int(doc)])
            try db.run("DELETE FROM vec_blocks WHERE doc = ?", [.int(doc)])
            hit("reindex.deletedold")
            try writeDerived(doc: doc, rev: rev + 1, pages: pages, midHook: "reindex.midtxn")
            // old pages (rev) are kept for citations; garbage-collected elsewhere
            try db.run("UPDATE documents SET rev = ?, status = 'searchable', pages = ? WHERE doc = ?",
                       [.int(rev + 1), .int(Int64(pages.count)), .int(doc)])
        }
    }

    // MARK: remove

    public func remove(doc: Int64) throws {
        guard let ext = try db.scalarText("SELECT ext FROM documents WHERE doc = ?", [.int(doc)]) else { return }
        try db.run("UPDATE documents SET status = 'removing' WHERE doc = ?", [.int(doc)])
        hit("removing.set")
        try? FileManager.default.removeItem(at: fileURL(doc: doc, ext: ext))
        hit("removing.filedeleted")
        try deleteRows(doc: doc)
    }

    func deleteRows(doc: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM vec_blocks WHERE doc = ?", [.int(doc)])
            try db.run("DELETE FROM chunks WHERE doc = ?", [.int(doc)])
            hit("removing.midtxn")
            try db.run("DELETE FROM pages WHERE doc = ?", [.int(doc)])
            try db.run("DELETE FROM documents WHERE doc = ?", [.int(doc)])
        }
    }

    // MARK: reconcile (at project open)

    public func reconcile() throws -> ReconcileReport {
        var r = ReconcileReport()
        let fm = FileManager.default
        struct Row { let doc: Int64; let ext: String; let sha: String; let status: DocStatus }
        func rows() throws -> [Row] {
            let st = try db.prepare("SELECT doc, ext, sha256, status FROM documents")
            var out: [Row] = []
            while try st.step() {
                out.append(Row(doc: st.int(0), ext: st.text(1), sha: st.text(2), status: DocStatus(rawValue: st.text(3)) ?? .failed))
            }
            return out
        }

        // 1. removing → finish (file first, then rows). Idempotent.
        for row in try rows() where row.status == .removing {
            try? fm.removeItem(at: fileURL(doc: row.doc, ext: row.ext))
            try deleteRows(doc: row.doc)
            r.finishedRemoving += 1
        }

        // 2. staged: make sure the file reached files/; else promote from staging; else drop the row.
        var stagingNames = Set((try? fm.contentsOfDirectory(atPath: stagingDir.path)) ?? [])
        for row in try rows() where row.status == .staged {
            let dest = fileURL(doc: row.doc, ext: row.ext)
            if fm.fileExists(atPath: dest.path) { r.needExtraction.append(row.doc); continue }
            let stagedName = "\(row.sha).\(row.ext)"
            if stagingNames.contains(stagedName) {
                try fm.moveItem(at: stagingDir.appendingPathComponent(stagedName), to: dest)
                stagingNames.remove(stagedName)
                r.promotedStaged += 1
                r.needExtraction.append(row.doc)
            } else {
                try db.run("DELETE FROM documents WHERE doc = ?", [.int(row.doc)])
                r.droppedStagedWithoutFile += 1
            }
        }

        // 3. staging leftovers: .part copies and hashed copies no row claims.
        for name in stagingNames {
            try? fm.removeItem(at: stagingDir.appendingPathComponent(name))
            if name.hasSuffix(".part") { r.deletedPartFiles += 1 } else { r.deletedOrphanStaging += 1 }
        }

        // 4. extracting → staged again; drop any derived rows (the derive txn is
        //    atomic, so there should be none; defensive for re-index variants).
        for row in try rows() where row.status == .extracting {
            try db.transaction {
                try db.run("DELETE FROM chunks WHERE doc = ?", [.int(row.doc)])
                r.droppedPartialDerived += db.changes
                try db.run("DELETE FROM pages WHERE doc = ?", [.int(row.doc)])
                try db.run("DELETE FROM vec_blocks WHERE doc = ?", [.int(row.doc)])
                try db.run("UPDATE documents SET status = 'staged' WHERE doc = ?", [.int(row.doc)])
            }
            r.resetExtracting += 1
            r.needExtraction.append(row.doc)
        }

        // 5. files without rows (only under files/, never linked folders) and rows without files.
        let known = Dictionary(uniqueKeysWithValues: try rows().map { ("\($0.doc).\($0.ext)", $0) })
        for name in (try? fm.contentsOfDirectory(atPath: filesDir.path)) ?? [] where known[name] == nil {
            try? fm.removeItem(at: filesDir.appendingPathComponent(name))
            r.deletedOrphanFiles += 1
        }
        for row in try rows() where row.status != .failed && !fm.fileExists(atPath: fileURL(doc: row.doc, ext: row.ext).path) {
            try db.run("UPDATE documents SET status = 'failed', error = 'file missing' WHERE doc = ?", [.int(row.doc)])
            r.failedMissingFile += 1
        }

        // 6. searchable → needs (the rest of) its embedding.
        for row in try rows() where row.status == .searchable { r.needEmbedding.append(row.doc) }
        r.needExtraction.sort()
        return r
    }

    /// Reconcile, then run the queued work (what the app's background ingest would do).
    @discardableResult
    public func reconcileAndResume() throws -> ReconcileReport {
        let r = try reconcile()
        for d in r.needExtraction { try extract(doc: d); try embed(doc: d) }
        for d in r.needEmbedding { try embed(doc: d) }
        return r
    }
}
