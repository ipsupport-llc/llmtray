import Foundation

/// Reciprocal rank fusion: score = Σ over lists of 1 / (k + rank), rank
/// from 1; a duplicate inside one list counts once, at its first rank.
/// Ties go to the better single rank, then the smaller id: deterministic.
public enum RRF {
    public static func fuse(_ lists: [[Int64]], k: Double = 60) -> [(id: Int64, score: Double)] {
        var score: [Int64: Double] = [:]
        var best: [Int64: Int] = [:]
        for list in lists {
            var seen = Set<Int64>()
            for (i, id) in list.enumerated() where seen.insert(id).inserted {
                score[id, default: 0] += 1 / (k + Double(i + 1))
                best[id] = min(best[id] ?? .max, i + 1)
            }
        }
        return score.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            let a = best[$0.key]!, b = best[$1.key]!
            return a != b ? a < b : $0.key < $1.key
        }.map { ($0.key, $0.value) }
    }
}

/// Which ranked list found a hit.
public enum IndexList: String, Sendable, CaseIterable {
    case words, trigram, dense
}

public struct IndexHit: Equatable, Sendable {
    public var chunk: Int64
    public var doc: Int64
    public var rev: Int64
    public var page: Int
    public var heading: String?
    /// The document's file name (shown with the citation).
    public var name: String
    /// Verbatim, from `pages.text` by the chunk's offsets.
    public var text: String
    public var score: Double
    public var foundBy: Set<IndexList>
    /// Found by words, not by meaning -- said so in the tool result.
    public var isLexicalOnly: Bool { !foundBy.contains(.dense) }
}

public struct IndexSearchResult: Equatable, Sendable {
    public var hits: [IndexHit]
    /// False: no query vector or no vectors to score -- the whole search was
    /// lexical, and the tool says so.
    public var usedDense: Bool
    /// Query terms the document-frequency gate dropped.
    public var gatedTerms: [String]
}

public struct IndexSearchOptions: Sendable {
    /// Hits returned.
    public var limit = 5
    /// Only this document; lifts the per-document limit.
    public var document: Int64?
    /// At most this many hits per document, so a question across files isn't
    /// answered from one.
    public var perDocumentLimit = 2
    /// Candidates per ranked list; FTS5 ranks ~1.7× that before the status join.
    public var listLimit = 50
    /// Terms in more than this share of the chunks are dropped (the rarest
    /// matching one kept): their bm25 weight is ~0 and ranking every row
    /// holding "в" is what makes a query slow. nil: off. Set by the eval.
    public var documentFrequencyGate: Double? = 0.2
    /// The gate only applies from this many chunks on.
    public var gateMinimumChunks = 2000
    public var rrfK: Double = 60

    public init(limit: Int = 5, document: Int64? = nil) {
        self.limit = limit
        self.document = document
    }
}

/// A page of text as stored, current or kept for a citation.
public struct IndexPage: Equatable, Sendable {
    public var doc: Int64
    public var rev: Int64
    public var page: Int
    public var text: String
    /// False: a tombstone -- the document was re-indexed or removed since.
    public var isCurrent: Bool
}

/// Searches through one connection -- in the app the registry's read-only
/// WAL connection, so a search never queues behind an ingest. Every list
/// sees only documents in `searchable` / `embedded` state and their current
/// revision; each search runs in one read transaction (one snapshot) and
/// ends it at once, so it never holds back a checkpoint.
public final class IndexSearcher {
    public let db: SQLiteConnection

    public init(db: SQLiteConnection) throws {
        self.db = db
        try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS temp.chunks_fts_vocab USING fts5vocab(main, chunks_fts, row)")
        try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS temp.chunks_tri_vocab USING fts5vocab(main, chunks_tri, row)")
    }

    static let searchable = "('searchable','embedded')"

    /// Ranks inside FTS5 first (its own ORDER BY rank LIMIT, ~40% cheaper
    /// than joining first), then drops rows of documents that aren't
    /// searchable; the over-fetch covers the few hidden ones. With a
    /// document filter the join comes first: that document's rows may all
    /// rank below the rest.
    private static func lexicalSQL(_ table: String, filtered: Bool) -> String {
        if filtered {
            return """
            SELECT c.id FROM \(table) f JOIN chunks c ON c.id = f.rowid
            JOIN documents d ON d.doc = c.doc AND d.rev = c.rev
            WHERE \(table) MATCH ?1 AND c.doc = ?3 AND d.status IN \(searchable)
            ORDER BY f.rank LIMIT ?2
            """
        }
        return """
        SELECT f.id FROM (SELECT rowid AS id, rank AS r FROM \(table) WHERE \(table) MATCH ?1 ORDER BY rank LIMIT ?3) f
        JOIN chunks c ON c.id = f.id
        JOIN documents d ON d.doc = c.doc AND d.rev = c.rev
        WHERE d.status IN \(searchable)
        ORDER BY f.r LIMIT ?2
        """
    }

    private func ranked(_ table: String, _ terms: [String], limit: Int, document: Int64?) throws -> [Int64] {
        guard let match = IndexQuery.expression(terms) else { return [] }
        let args: [SQLValue] = document.map { [.text(match), .int(Int64(limit)), .int($0)] }
            ?? [.text(match), .int(Int64(limit)), .int(Int64(limit + limit / 2 + 10))]
        return try db.rows(Self.lexicalSQL(table, filtered: document != nil), args) { $0.int(0) }
    }

    private func documentFrequency(vocab: String, _ term: String) throws -> Int64 {
        try db.scalarInt("SELECT doc FROM temp.\(vocab) WHERE term = ?", [.text(term)]) ?? 0
    }

    /// Trigram: an upper bound, the rarest of the term's trigrams.
    private func trigramFrequency(_ term: String) throws -> Int64 {
        let u = Array(term.unicodeScalars)
        guard u.count >= 3 else { return 0 }
        var best = Int64.max
        for i in 0...(u.count - 3) {
            best = min(best, try documentFrequency(vocab: "chunks_tri_vocab", String(String.UnicodeScalarView(u[i..<(i + 3)]))))
            if best == 0 { break }
        }
        return best
    }

    /// The gate: drops terms in more than `share` of `total` chunks; if that
    /// leaves nothing that matches, keeps the rarest term that does.
    static func gate(_ terms: [String], total: Int64, share: Double?, minimumChunks: Int,
                     frequency: (String) throws -> Int64) rethrows -> (kept: [String], dropped: [String]) {
        guard let share, terms.count > 1, total >= Int64(minimumChunks) else { return (terms, []) }
        let limit = Int64(Double(total) * share)
        let dfs = try terms.map { ($0, try frequency($0)) }
        var kept = dfs.filter { $0.1 <= limit }.map(\.0)
        if !dfs.contains(where: { $0.1 > 0 && $0.1 <= limit }),
           let rarest = dfs.filter({ $0.1 > 0 }).min(by: { $0.1 < $1.1 }) {
            kept.append(rarest.0)
        }
        return (kept, terms.filter { !kept.contains($0) })
    }

    /// The unicode61 list, gated.
    public func words(_ q: LexicalQuery, options: IndexSearchOptions = IndexSearchOptions()) throws -> (ids: [Int64], dropped: [String]) {
        let total = try chunkCount()
        let g = try Self.gate(q.terms, total: total, share: options.documentFrequencyGate, minimumChunks: options.gateMinimumChunks) {
            try documentFrequency(vocab: "chunks_fts_vocab", $0)
        }
        return (try ranked("chunks_fts", g.kept, limit: options.listLimit, document: options.document), g.dropped)
    }

    /// The trigram list (terms of 3+ characters, pseudo-stemmed), gated.
    public func trigram(_ q: LexicalQuery, options: IndexSearchOptions = IndexSearchOptions()) throws -> (ids: [Int64], dropped: [String]) {
        let total = try chunkCount()
        let g = try Self.gate(q.trigramTerms, total: total, share: options.documentFrequencyGate,
                              minimumChunks: options.gateMinimumChunks) { try trigramFrequency($0) }
        return (try ranked("chunks_tri", g.kept, limit: options.listLimit, document: options.document), g.dropped)
    }

    private func chunkCount() throws -> Int64 {
        try db.scalarInt("SELECT count(*) FROM chunks") ?? 0
    }

    /// Documents a search may return, by the current state.
    public func searchableDocuments() throws -> Set<Int64> {
        Set(try db.rows("SELECT doc FROM documents WHERE status IN \(Self.searchable)") { $0.int(0) })
    }

    /// The hybrid search: unicode61 + trigram + dense (when a query vector
    /// and vectors are given), fused by RRF, at most `perDocumentLimit` hits
    /// per document unless `options.document` narrows it. `dense` must be of
    /// the active set and refreshed from this connection.
    public func search(_ query: String, queryVector: [Float]? = nil, dense: DenseVectors? = nil,
                       options: IndexSearchOptions = IndexSearchOptions()) throws -> IndexSearchResult {
        try search(query, queryVector: queryVector, vectors: { _ in dense }, options: options)
    }

    /// `vectors` runs inside the search's read transaction, so the vectors it
    /// loads or refreshes are of the same snapshot as the lexical lists.
    public func search(_ query: String, queryVector: [Float]?, vectors: (SQLiteConnection) throws -> DenseVectors?,
                       options: IndexSearchOptions = IndexSearchOptions()) throws -> IndexSearchResult {
        let q = IndexQuery.build(query)
        return try db.transaction(immediate: false) {
            let dense = queryVector == nil ? nil : try vectors(db)
            let w = try words(q, options: options)
            let t = try trigram(q, options: options)
            var denseList: [Int64] = []
            var usedDense = false
            if let dense, let queryVector, dense.count > 0, queryVector.count == dense.dim {
                let allowed = try searchableDocuments()
                let filter = options.document
                let scores = dense.scores(queryVector)
                denseList = dense.top(scores, k: options.listLimit) { doc in
                    allowed.contains(doc) && (filter == nil || doc == filter)
                }.map(\.chunk)
                usedDense = true
            }
            let lists: [(IndexList, [Int64])] = [(.words, w.ids), (.trigram, t.ids), (.dense, denseList)]
            var found: [Int64: Set<IndexList>] = [:]
            for (name, ids) in lists { for id in ids { found[id, default: []].insert(name) } }
            var perDoc: [Int64: Int] = [:]
            var hits: [IndexHit] = []
            let limit = max(0, options.limit)
            for candidate in RRF.fuse(lists.map(\.1), k: options.rrfK) where hits.count < limit {
                guard var hit = try fetch(candidate.id) else { continue }
                if options.document == nil {
                    guard perDoc[hit.doc, default: 0] < options.perDocumentLimit else { continue }
                    perDoc[hit.doc, default: 0] += 1
                }
                hit.score = candidate.score
                hit.foundBy = found[candidate.id] ?? []
                hits.append(hit)
            }
            var seen = Set<String>()
            let dropped = (w.dropped + t.dropped).filter { seen.insert($0).inserted }
            return IndexSearchResult(hits: hits, usedDense: usedDense, gatedTerms: dropped)
        }
    }

    /// One chunk as a hit, if its document is still searchable at its revision.
    public func fetch(_ chunk: Int64) throws -> IndexHit? {
        try db.rows("""
            SELECT c.doc, c.rev, c.page, c.heading, substr(p.text, c.start + 1, c.len), d.name
            FROM chunks c
            JOIN documents d ON d.doc = c.doc AND d.rev = c.rev
            JOIN pages p ON p.doc = c.doc AND p.rev = c.rev AND p.page = c.page
            WHERE c.id = ? AND d.status IN \(Self.searchable)
            """, [.int(chunk)]) {
            IndexHit(chunk: chunk, doc: $0.int(0), rev: $0.int(1), page: Int($0.int(2)), heading: $0.optionalText(3),
                     name: $0.text(5), text: $0.text(4), score: 0, foundBy: [])
        }.first
    }

    /// A page by (doc, rev, page) -- what a citation names -- current or a tombstone.
    public func page(doc: Int64, rev: Int64, page: Int) throws -> IndexPage? {
        try db.rows("""
            SELECT p.text, EXISTS (SELECT 1 FROM documents d WHERE d.doc = p.doc AND d.rev = p.rev)
            FROM pages p WHERE p.doc = ? AND p.rev = ? AND p.page = ?
            """, [.int(doc), .int(rev), .int(Int64(page))]) {
            IndexPage(doc: doc, rev: rev, page: page, text: $0.text(0), isCurrent: $0.int(1) != 0)
        }.first
    }

    /// Raw FTS5 MATCH, unfiltered and unescaped: for tests of FTS5 itself.
    func rawMatch(table: String, _ expression: String) throws -> [Int64] {
        let st = try db.prepare("SELECT rowid FROM \(table) WHERE \(table) MATCH ? ORDER BY rank")
        try st.bind([.text(expression)])
        var out: [Int64] = []
        while try st.step() { out.append(st.int(0)) }
        return out
    }
}
