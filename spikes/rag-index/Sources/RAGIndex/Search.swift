import Foundation

public enum RRF {
    /// Reciprocal rank fusion: score(d) = Σ_lists 1 / (k + rank), rank from 1.
    /// Ties broken by best single rank, then id, so output is deterministic.
    public static func fuse(_ lists: [[Int64]], k: Double = 60, limit: Int = .max) -> [(id: Int64, score: Double)] {
        var score: [Int64: Double] = [:]
        var best: [Int64: Int] = [:]
        for list in lists {
            var seen = Set<Int64>()
            for (i, id) in list.enumerated() where seen.insert(id).inserted {
                score[id, default: 0] += 1.0 / (k + Double(i + 1))
                best[id] = min(best[id] ?? .max, i + 1)
            }
        }
        return score.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            if best[$0.key]! != best[$1.key]! { return best[$0.key]! < best[$1.key]! }
            return $0.key < $1.key
        }.prefix(limit).map { ($0.key, $0.value) }
    }
}

public struct Hit {
    public let id: Int64, doc: Int64, page: Int64
    public let text: String   // verbatim, from pages.text via start/len
}

public struct HybridTimings {
    public var words = 0.0, trigram = 0.0, dense = 0.0, fuse = 0.0, fetch = 0.0
    public var total: Double { words + trigram + dense + fuse + fetch }
    public init() {}
}

/// Searches over one connection (the app's read-only WAL connection).
/// Every list is restricted to documents in searchable/embedded state.
public final class Searcher {
    public let db: Database
    let wordsSt: Statement, triSt: Statement, fetchSt: Statement
    let wordsDF: Statement, triDF: Statement, countSt: Statement
    public var listLimit = 50
    /// Drop query terms whose document frequency exceeds this share of all
    /// chunks (bm25 gives them ~no weight, but ranking every row that contains
    /// "в" or "и" is what makes a lexical query slow). nil = off. The rarest
    /// term is always kept.
    public var dfGate: Double? = 0.2
    public var dfGateMinChunks = 2000
    public private(set) var lastGated: [String] = []
    public func lastGatedReset() { lastGated = [] }

    public init(db: Database) throws {
        self.db = db
        // Rank inside FTS5 first (its own ORDER BY rank LIMIT), then drop rows of
        // documents that are not searchable. Over-fetch covers the few hidden ones.
        let lexical = { (table: String) in """
            SELECT f.id FROM (SELECT rowid AS id, rank AS r FROM \(table) WHERE \(table) MATCH ?1 ORDER BY rank LIMIT ?2) f
            JOIN chunks c ON c.id = f.id
            JOIN documents d ON d.doc = c.doc
            WHERE d.status IN ('searchable','embedded')
            ORDER BY f.r LIMIT ?3
            """ }
        wordsSt = try db.prepare(lexical("chunks_fts"))
        triSt = try db.prepare(lexical("chunks_tri"))
        fetchSt = try db.prepare("""
            SELECT c.doc, c.page, substr(p.text, c.start + 1, c.len) FROM chunks c
            JOIN pages p ON p.doc = c.doc AND p.rev = c.rev AND p.page = c.page
            WHERE c.id = ?
            """)
        try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS temp.chunks_fts_v USING fts5vocab(main, chunks_fts, row)")
        try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS temp.chunks_tri_v USING fts5vocab(main, chunks_tri, row)")
        wordsDF = try db.prepare("SELECT doc FROM temp.chunks_fts_v WHERE term = ?")
        triDF = try db.prepare("SELECT doc FROM temp.chunks_tri_v WHERE term = ?")
        countSt = try db.prepare("SELECT count(*) FROM chunks")
    }

    func run(_ st: Statement, _ match: String?, _ limit: Int) throws -> [Int64] {
        guard let match else { return [] }
        try st.bind([.text(match), .int(Int64(limit + limit / 2 + 10)), .int(Int64(limit))])
        var out: [Int64] = []
        while try st.step() { out.append(st.int(0)) }
        return out
    }

    func df(_ st: Statement, _ term: String) throws -> Int64 {
        try st.bind([.text(term)])
        defer { st.reset() }
        return try st.step() ? st.int(0) : 0
    }

    /// Trigram df upper bound: the rarest of the term's trigrams.
    func triDFBound(_ term: String) throws -> Int64 {
        let u = Array(term.unicodeScalars)
        var best = Int64.max
        for i in 0...(u.count - 3) {
            let tg = String(String.UnicodeScalarView(u[i..<i + 3]))
            best = min(best, try df(triDF, tg))
            if best == 0 { break }
        }
        return best
    }

    func gate(_ terms: [String], dfOf: (String) throws -> Int64) throws -> [String] {
        guard let g = dfGate, terms.count > 1 else { return terms }
        try countSt.bind([]); _ = try countSt.step()
        let n = countSt.int(0); countSt.reset()
        guard n >= dfGateMinChunks else { return terms }
        let limit = Int64(Double(n) * g)
        let dfs = try terms.map { ($0, try dfOf($0)) }
        var kept = dfs.filter { $0.1 <= limit }.map(\.0)
        // terms that match nothing don't count: if nothing useful is left, keep
        // the rarest term that does match
        if !dfs.contains(where: { $0.1 > 0 && $0.1 <= limit }),
           let rarest = dfs.filter({ $0.1 > 0 }).min(by: { $0.1 < $1.1 }) { kept.append(rarest.0) }
        lastGated += terms.filter { !kept.contains($0) }
        return kept
    }

    public func words(_ q: LexicalQuery, limit: Int? = nil) throws -> [Int64] {
        let ts = try gate(q.terms) { try df(wordsDF, $0) }
        return try run(wordsSt, QueryBuilder.expression(ts), limit ?? listLimit)
    }
    public func trigram(_ q: LexicalQuery, limit: Int? = nil) throws -> [Int64] {
        let ts = try gate(q.triTerms) { try triDFBound($0) }
        return try run(triSt, QueryBuilder.expression(ts), limit ?? listLimit)
    }

    /// Unfiltered raw MATCH, for tests that probe FTS5 syntax handling.
    public func rawMatch(table: String, _ expr: String) throws -> [Int64] {
        let st = try db.prepare("SELECT rowid FROM \(table) WHERE \(table) MATCH ? ORDER BY rank")
        try st.bind([.text(expr)])
        var out: [Int64] = []
        while try st.step() { out.append(st.int(0)) }
        return out
    }

    public func fetch(_ id: Int64) throws -> Hit? {
        try fetchSt.bind([.int(id)])
        guard try fetchSt.step() else { return nil }
        let h = Hit(id: id, doc: fetchSt.int(0), page: fetchSt.int(1), text: fetchSt.text(2))
        fetchSt.reset()
        return h
    }

    /// Search: both FTS lists, the dense list (if given), RRF, fetch top k texts.
    public func hybrid(_ raw: String, queryVector: [Float]?, dense: DenseIndex?, allowedDocs: Set<Int64>?,
                       k: Int = 10, kernel: (DenseIndex, [Float]) -> [Float] = { $0.scoresF16($1) },
                       timings: inout HybridTimings) throws -> [Hit] {
        let clock = ContinuousClock()
        let q = QueryBuilder.build(raw)
        lastGated = []
        var t0 = clock.now
        let w = try words(q)
        timings.words = ms(clock.now - t0); t0 = clock.now
        let t = try trigram(q)
        timings.trigram = ms(clock.now - t0); t0 = clock.now
        var dl: [Int64] = []
        if let dense, let queryVector, dense.count > 0 {
            let s = kernel(dense, queryVector)
            dl = dense.topK(s, k: listLimit, allowed: allowedDocs.map { set in { set.contains($0) } }).map(\.id)
        }
        timings.dense = ms(clock.now - t0); t0 = clock.now
        let fused = RRF.fuse([w, t, dl], k: 60, limit: k)
        timings.fuse = ms(clock.now - t0); t0 = clock.now
        let hits = try fused.compactMap { try fetch($0.id) }
        timings.fetch = ms(clock.now - t0)
        return hits
    }
}

@inline(__always) public func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
