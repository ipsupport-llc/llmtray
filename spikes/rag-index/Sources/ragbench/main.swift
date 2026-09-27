import Foundation
import RAGIndex
import SQLite3

// ragbench — spike driver.
//   info
//   crash --dir D --op add|remove|reindex --at POINT [--file F] [--doc N]
//   bench --dir D --chunks N [--detail full|none]
//   concurrency --dir D            (run after bench on D)
//   size --dir D --chunks N [--detail full|none] [--page-size P]

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let clock = ContinuousClock()
func log(_ s: String) { print(s); fflush(stdout) }
func pct(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted(); guard !s.isEmpty else { return .nan }
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
func f(_ x: Double) -> String { String(format: "%.2f", x) }
func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
func fileSize(_ p: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: p)[.size]) as? NSNumber)?.int64Value ?? 0 }

let cmd = args.count > 1 ? args[1] : "info"

// MARK: - corpus build

func buildCorpus(dir: URL, chunks: Int, chunksPerDoc: Int = 100, wordsPerChunk: Int = 250, options: IndexOptions, embed: Bool = true) throws -> (ProjectIndex, Double) {
    try? FileManager.default.removeItem(at: dir)
    let idx = try ProjectIndex(dir: dir, options: options)
    idx.wordsPerChunk = wordsPerChunk
    idx.embedBatch = 64
    var gen = CorpusGenerator(seed: 42)
    let tmp = dir.appendingPathComponent("src"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let docs = (chunks + chunksPerDoc - 1) / chunksPerDoc
    let t0 = clock.now
    var genTime = 0.0
    for d in 0..<docs {
        let g0 = clock.now
        // ~5 chunks per page, pages separated by form feed; each page a whole number of chunks
        var pages: [String] = []
        let n = min(chunksPerDoc, chunks - d * chunksPerDoc)
        for p in 0..<((n + 4) / 5) {
            let k = min(5, n - p * 5)
            pages.append((0..<k).map { _ in gen.text(words: wordsPerChunk, russian: d % 10 < 7) }.joined(separator: " "))
        }
        let url = tmp.appendingPathComponent("doc\(d).txt")
        try pages.joined(separator: "\u{0C}").write(to: url, atomically: false, encoding: .utf8)
        genTime += ms(clock.now - g0)
        try idx.add(file: url, embed: embed)
        try? FileManager.default.removeItem(at: url)
        if d % 200 == 199 { log("  … \(d + 1)/\(docs) docs, \(f(ms(clock.now - t0) / 1000)) s") }
    }
    return (idx, ms(clock.now - t0) - genTime)
}

func sizeBreakdown(_ db: Database) throws -> [(String, Int64)] {
    let st = try db.prepare("SELECT name, sum(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC")
    var out: [(String, Int64)] = []
    while try st.step() { out.append((st.text(0), st.int(1))) }
    return out
}

func groupSizes(_ rows: [(String, Int64)]) -> [String: Int64] {
    var g: [String: Int64] = [:]
    for (n, s) in rows {
        let k = n.hasPrefix("chunks_fts") ? "fts(unicode61)" : n.hasPrefix("chunks_tri") ? "fts(trigram)"
            : n.hasPrefix("vec") ? "vectors" : n.hasPrefix("chunks") ? "chunks" : n.hasPrefix("pages") || n.hasPrefix("sqlite_autoindex_pages") ? "pages" : "other"
        g[k, default: 0] += s
    }
    return g
}

let benchQueries: [String] = [
    "договора", "поставки", "неустойка", "обязательств", "претензию",
    "срок оплаты по договору", "претензия о неустойке за просрочку поставки",
    "database transaction commit timeout", "server config error",
    "parseConfig", "loadIndex", "7707083893", "ИП", "г.",
    "какой срок исполнения обязательства по настоящему договору и что будет если оплата не поступит",
    "в", "и в на с по",
    "fetchVector", "письменное уведомление сторон", "invoice payment terms of the agreement",
]

// MARK: - bench

func runBench() throws {
    let dir = URL(fileURLWithPath: arg("--dir")!)
    let n = Int(arg("--chunks") ?? "50000")!
    let detail = arg("--detail") ?? "full"
    log("== bench: \(n) chunks, trigram detail=\(detail)")
    let idx: ProjectIndex, ingestMs: Double
    if args.contains("--reuse") { idx = try ProjectIndex(dir: dir); ingestMs = .nan }
    else { (idx, ingestMs) = try buildCorpus(dir: dir, chunks: n, options: IndexOptions(trigramDetail: detail)) }
    let nChunks = try idx.db.scalarInt("SELECT count(*) FROM chunks")!
    let avgChars = try idx.db.scalarInt("SELECT avg(length(body)) FROM chunks")!
    let avgBytes = try idx.db.scalarInt("SELECT avg(length(CAST(body AS BLOB))) FROM chunks")!
    log("ingest (stage+extract+FTS triggers+toy embed, excl. text generation): \(f(ingestMs / 1000)) s for \(nChunks) chunks = \(f(Double(nChunks) / (ingestMs / 1000))) chunks/s; avg chunk \(avgChars) chars / \(avgBytes) bytes")
    _ = idx.db.checkpoint(mode: SQLITE_CHECKPOINT_TRUNCATE)
    let dbPath = idx.dbURL.path
    log("db file \(mb(fileSize(dbPath)))")
    for (k, v) in groupSizes(try sizeBreakdown(idx.db)).sorted(by: { $0.value > $1.value }) { log("  \(k): \(mb(v))") }

    // reader connection, like the app's search connection
    let reader = try Database(path: dbPath, readOnly: true)
    let s = try Searcher(db: reader)
    let t0 = clock.now
    let dense = try DenseIndex.load(db: reader, setID: 1, dim: 1024, widen: false)
    let loadMs = ms(clock.now - t0)
    let t1 = clock.now
    dense.widen()
    log("dense load \(dense.count) vectors from SQLite: \(f(loadMs)) ms; widen f16→f32 \(f(ms(clock.now - t1))) ms; RAM f16 \(mb(Int64(dense.f16.count * 2))) f32 \(mb(Int64(dense.f32.count * 4)))")

    // kernel comparison
    var g = SplitMix64(seed: 7)
    let qv = (0..<1024).map { _ in Float(Int(g.next() % 2001) - 1000) / 1000 }
    for (name, kern) in [("sgemv f32 (1 call)", { (d: DenseIndex, q: [Float]) in d.scoresSgemv(q) }),
                         ("sgemv f32 x8 blocks", { (d: DenseIndex, q: [Float]) in d.scoresSgemvParallel(q) }),
                         ("f16 SIMD x8 blocks", { (d: DenseIndex, q: [Float]) in d.scoresF16(q) }),
                         ("f16 SIMD x16 blocks", { (d: DenseIndex, q: [Float]) in d.scoresF16(q, blocks: 16) }),
                         ("f16 tiles→f32 sgemv x8", { (d: DenseIndex, q: [Float]) in d.scoresF16Tiled(q) }),
                         ("f16 tiles→f32 sgemv x10", { (d: DenseIndex, q: [Float]) in d.scoresF16Tiled(q, blocks: 10) })] {
        var ts: [Double] = []
        for _ in 0..<30 { let a = clock.now; _ = kern(dense, qv); ts.append(ms(clock.now - a)) }
        log("  dense \(name): p50 \(f(pct(ts, 0.5))) ms p95 \(f(pct(ts, 0.95))) ms")
    }
    let a0 = clock.now
    let sc = dense.scoresF16(qv)
    var topTs: [Double] = []
    for _ in 0..<20 { let a = clock.now; _ = dense.topK(sc, k: 50); topTs.append(ms(clock.now - a)) }
    _ = a0
    log("  top-50 selection p50 \(f(pct(topTs, 0.5))) ms")
    // check f16 kernel against sgemv
    let ref = dense.scoresSgemv(qv)
    var maxErr: Float = 0
    for i in 0..<ref.count { maxErr = max(maxErr, abs(ref[i] - sc[i])) }
    log("  f16 kernel vs sgemv max |Δ| = \(maxErr)")

    let embedder = ToyEmbedder()
    try lexicalBench(s, label: "fresh (unoptimized segments)")
    try hybridBench(s, dense: dense, embedder: embedder, label: "hybrid f16 tiled kernel", kernel: { $0.scoresF16Tiled($1) })
    try hybridBench(s, dense: dense, embedder: embedder, label: "hybrid sgemv f32", kernel: { $0.scoresSgemv($1) })

    let o0 = clock.now
    try Schema.optimize(idx.db)
    _ = idx.db.checkpoint(mode: SQLITE_CHECKPOINT_TRUNCATE)
    log("fts 'optimize' both tables: \(f(ms(clock.now - o0) / 1000)) s; db file now \(mb(fileSize(dbPath)))")
    let s2 = try Searcher(db: try Database(path: dbPath, readOnly: true))
    try lexicalBench(s2, label: "after optimize")
    try hybridBench(s2, dense: dense, embedder: embedder, label: "hybrid f16 tiled, after optimize", kernel: { $0.scoresF16Tiled($1) })
    s2.dfGate = nil
    try lexicalBench(s2, label: "after optimize, df gate OFF")
    try hybridBench(s2, dense: dense, embedder: embedder, label: "hybrid f16 tiled, after optimize, df gate OFF", kernel: { $0.scoresF16Tiled($1) })
    try gateOverlap(dbPath: dbPath)

    let r0 = clock.now
    try Schema.rebuild(idx.db)
    log("fts 'rebuild' both tables (\(nChunks) chunks): \(f(ms(clock.now - r0) / 1000)) s")
    let i0 = clock.now
    try Schema.integrityCheck(idx.db)
    log("fts integrity-check (rank=1) both tables: \(f(ms(clock.now - i0) / 1000)) s — ok")
}

func lexicalBench(_ s: Searcher, label: String) throws {
    log("-- lexical per query (\(label)), ms, 5 runs each: words | trigram | #hits words/tri")
    for q in benchQueries {
        let lq = QueryBuilder.build(q)
        var tw: [Double] = [], tt: [Double] = []
        var nw = 0, nt = 0
        for _ in 0..<5 {
            s.lastGatedReset()
            var a = clock.now; nw = try s.words(lq).count; tw.append(ms(clock.now - a))
            a = clock.now; nt = try s.trigram(lq).count; tt.append(ms(clock.now - a))
        }
        let gated = Set(s.lastGated)
        log("  \(f(pct(tw, 0.5)))\t| \(f(pct(tt, 0.5)))\t| \(nw)/\(nt)\t\(q.prefix(60))\(gated.isEmpty ? "" : "  [gated: \(gated.sorted().joined(separator: ","))]")")
    }
}

func hybridBench(_ s: Searcher, dense: DenseIndex, embedder: ToyEmbedder, label: String, kernel: @escaping (DenseIndex, [Float]) -> [Float]) throws {
    var totals: [Double] = [], parts: [[Double]] = [[], [], [], [], []]
    for _ in 0..<5 {
        for q in benchQueries {
            var t = HybridTimings()
            _ = try s.hybrid(q, queryVector: embedder.embed(q), dense: dense, allowedDocs: nil, k: 10, kernel: kernel, timings: &t)
            totals.append(t.total)
            for (i, v) in [t.words, t.trigram, t.dense, t.fuse, t.fetch].enumerated() { parts[i].append(v) }
        }
    }
    let names = ["words", "trigram", "dense", "rrf", "fetch"]
    let detail = zip(names, parts).map { "\($0) p50 \(f(pct($1, 0.5)))/p95 \(f(pct($1, 0.95)))" }.joined(separator: ", ")
    log("-- \(label), \(dense.count) vectors: total p50 \(f(pct(totals, 0.5))) ms, p95 \(f(pct(totals, 0.95))) ms, max \(f(totals.max()!)) ms  [\(detail)]")
}

/// How much does the df gate change the lists? Share of the ungated top-10
/// that is still in the gated top-50, per list.
func gateOverlap(dbPath: String) throws {
    let on = try Searcher(db: try Database(path: dbPath, readOnly: true))
    let off = try Searcher(db: try Database(path: dbPath, readOnly: true)); off.dfGate = nil
    var w: [Double] = [], t: [Double] = []
    for q in benchQueries {
        let lq = QueryBuilder.build(q)
        let (w0, w1) = (Array(try off.words(lq).prefix(10)), Set(try on.words(lq)))
        let (t0, t1) = (Array(try off.trigram(lq).prefix(10)), Set(try on.trigram(lq)))
        if !w0.isEmpty { w.append(Double(w0.filter(w1.contains).count) / Double(w0.count)) }
        if !t0.isEmpty { t.append(Double(t0.filter(t1.contains).count) / Double(t0.count)) }
    }
    log("df gate: ungated top-10 kept in gated top-50 — words mean \(f(w.reduce(0, +) / Double(w.count))), min \(f(w.min() ?? 1)); trigram mean \(f(t.reduce(0, +) / Double(t.count))), min \(f(t.min() ?? 1))")
}

// MARK: - concurrency

func runConcurrency() throws {
    let dir = URL(fileURLWithPath: arg("--dir")!)
    let idx = try ProjectIndex(dir: dir)
    idx.wordsPerChunk = 250
    let dbPath = idx.dbURL.path
    let reader = try Database(path: dbPath, readOnly: true)
    let s = try Searcher(db: reader)
    let base = try idx.db.scalarInt("SELECT count(*) FROM chunks")!
    log("== concurrency on \(base) chunks; WAL before: \(mb(fileSize(dbPath + "-wal")))")

    // a 5k-chunk document, text generated up front
    var gen = CorpusGenerator(seed: 99)
    var pages: [String] = []
    for _ in 0..<1000 { pages.append((0..<5).map { _ in gen.text(words: 250) }.joined(separator: " ") + " zzmarkerbig") }
    let src = dir.appendingPathComponent("big.txt")
    try pages.joined(separator: "\u{0C}").write(to: src, atomically: false, encoding: .utf8)

    // idle baseline
    var idle: [Double] = []
    for i in 0..<60 { var t = HybridTimings(); _ = try s.hybrid(benchQueries[i % benchQueries.count], queryVector: nil, dense: nil, allowedDocs: nil, timings: &t); idle.append(t.total) }
    log("reader idle lexical+fetch: p50 \(f(pct(idle, 0.5))) ms p95 \(f(pct(idle, 0.95))) ms")

    let doc = try idx.stage(file: src)
    // a second reader that holds a snapshot from before the big write (a slow
    // search, or a statement someone forgot to reset)
    let pinnedDB = try Database(path: dbPath, readOnly: true)
    let pin = try pinnedDB.prepare("SELECT id FROM chunks")
    _ = try pin.step()
    let running = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var during: [Double] = [], sawMarkerDuringTxn = false, busyErrors = 0
    var writerDone = false, commitStarted = false
    let readerThread = Thread {
        running.signal()
        var i = 0
        while true {
            lock.lock(); let done = writerDone; lock.unlock()
            if done { break }
            var t = HybridTimings()
            let a = clock.now
            do {
                _ = try s.hybrid(benchQueries[i % benchQueries.count], queryVector: nil, dense: nil, allowedDocs: nil, timings: &t)
                // explicit read txn: the snapshot is fixed at the first step; if the
                // writer had not started COMMIT by then, any hit is a visibility bug
                try reader.exec("BEGIN")
                let seen = !(try s.words(QueryBuilder.build("zzmarkerbig")).isEmpty)
                lock.lock(); let beforeCommit = !commitStarted; lock.unlock()
                try reader.exec("COMMIT")
                if beforeCommit && seen { sawMarkerDuringTxn = true }
            } catch { busyErrors += 1 }
            lock.lock(); during.append(ms(clock.now - a)); lock.unlock()
            i += 1
        }
    }
    readerThread.start(); running.wait()
    let w0 = clock.now
    let text = try String(contentsOf: src, encoding: .utf8)
    var commitMs = 0.0, txnMs = 0.0
    try idx.db.exec("BEGIN IMMEDIATE")
    let pagesArr = text.components(separatedBy: "\u{0C}")
    let insPage = try idx.db.prepare("INSERT INTO pages(doc, rev, page, text, tier) VALUES (?, 1, ?, ?, 1)")
    let insChunk = try idx.db.prepare("INSERT INTO chunks(doc, rev, page, ord, body, start, len) VALUES (?, 1, ?, ?, ?, ?, ?)")
    var ord = 0
    for (i, p) in pagesArr.enumerated() {
        try insPage.bind([.int(doc), .int(Int64(i + 1)), .text(p)]); try insPage.step()
        for c in Chunker.chunk(pageText: p, page: i + 1, firstOrd: ord, wordsPerChunk: 250) {
            try insChunk.bind([.int(doc), .int(Int64(i + 1)), .int(Int64(c.ord)), .text(c.body), .int(Int64(c.start)), .int(Int64(c.len))]); try insChunk.step()
            ord += 1
        }
    }
    try idx.db.run("UPDATE documents SET status='searchable', pages=? WHERE doc=?", [.int(Int64(pagesArr.count)), .int(doc)])
    txnMs = ms(clock.now - w0)
    let walMid = fileSize(dbPath + "-wal")
    lock.lock(); commitStarted = true; lock.unlock()
    let c0 = clock.now
    try idx.db.exec("COMMIT")
    commitMs = ms(clock.now - c0)
    lock.lock(); let duringCopy = during; writerDone = true; lock.unlock()
    Thread.sleep(forTimeInterval: 0.2)
    log("writer: \(ord) chunks in one txn, \(f(txnMs / 1000)) s open (WAL grew to \(mb(walMid)) before COMMIT — cache spill), COMMIT \(f(commitMs)) ms")
    log("reader during txn: \(duringCopy.count) searches, p50 \(f(pct(duringCopy, 0.5))) ms p95 \(f(pct(duringCopy, 0.95))) ms max \(f(duringCopy.max() ?? 0)) ms; busy errors \(busyErrors); saw uncommitted doc: \(sawMarkerDuringTxn)")
    let afterHits = try s.words(QueryBuilder.build("zzmarkerbig"), limit: 10000).count
    log("WAL frames: see checkpoint lines; page_count \(try idx.db.scalarInt("PRAGMA page_count")!)")
    log("reader after commit sees marker in \(afterHits) chunks")
    log("WAL after commit: \(mb(fileSize(dbPath + "-wal")))")

    // checkpoint while a reader holds a snapshot from before the commit
    let p1 = idx.db.checkpoint(mode: SQLITE_CHECKPOINT_PASSIVE)
    log("PASSIVE checkpoint with a reader pinned to a pre-commit snapshot: rc=\(p1.rc) log=\(p1.log) checkpointed=\(p1.ckpt)")
    idx.db.setBusyTimeout(ms: 200)
    let t2 = clock.now
    let p2 = idx.db.checkpoint(mode: SQLITE_CHECKPOINT_TRUNCATE)
    log("TRUNCATE checkpoint with that reader still open (busy_timeout 200 ms): rc=\(p2.rc) (\(p2.rc == SQLITE_BUSY ? "BUSY" : "ok")) log=\(p2.log) ckpt=\(p2.ckpt) in \(f(ms(clock.now - t2))) ms")
    pin.reset()
    let t3 = clock.now
    let p3 = idx.db.checkpoint(mode: SQLITE_CHECKPOINT_TRUNCATE)
    log("TRUNCATE checkpoint after the reader released: rc=\(p3.rc) log=\(p3.log) ckpt=\(p3.ckpt) in \(f(ms(clock.now - t3))) ms; WAL now \(mb(fileSize(dbPath + "-wal")))")
    // cleanup so the bench db stays reusable
    try idx.remove(doc: doc)
    _ = idx.db.checkpoint(mode: SQLITE_CHECKPOINT_TRUNCATE)
}

// MARK: - size

func runSize() throws {
    let dir = URL(fileURLWithPath: arg("--dir")!)
    let n = Int(arg("--chunks") ?? "10000")!
    let detail = arg("--detail") ?? "full"
    let pageSize = Int(arg("--page-size") ?? "4096")!
    let (idx, _) = try buildCorpus(dir: dir, chunks: n, options: IndexOptions(trigramDetail: detail, pageSize: pageSize))
    _ = idx.db.checkpoint(mode: SQLITE_CHECKPOINT_TRUNCATE)
    let textBytes = try idx.db.scalarInt("SELECT sum(length(CAST(body AS BLOB))) FROM chunks")!
    let actual = try idx.db.scalarInt("SELECT count(*) FROM chunks")!
    let scale = 10_000.0 / Double(actual)
    func per10k(_ b: Int64) -> String { mb(Int64(Double(b) * scale)) }
    log("== size: \(actual) chunks (numbers below scaled to 10k chunks), trigram detail=\(detail), page_size=\(try idx.db.scalarInt("PRAGMA page_size")!); normalized body text \(per10k(textBytes)), avg \(textBytes / actual) B/chunk")
    log("db file \(per10k(fileSize(idx.dbURL.path)))")
    for (k, v) in groupSizes(try sizeBreakdown(idx.db)).sorted(by: { $0.value > $1.value }) { log("  \(k): \(per10k(v))") }
    // trigram exactness: FTS match set vs a substring scan (detail=none/column lose positions)
    let s = try Searcher(db: idx.db)
    for probe in ["договор", "поставк", "обязательств", "parseconfig", "оплат", "неустойк", "ция", "config", "срок", "требован"] {
        var viaFTS = Set<Int64>()
        var tf = 0.0
        for _ in 0..<3 {   // best of 3 (warm cache)
            let a = clock.now
            if detail == "full" {
                viaFTS = Set(try s.rawMatch(table: "chunks_tri", "\"\(probe)\""))
            } else {  // phrase MATCH is unsupported with detail!=full; LIKE still uses the trigram index (unranked)
                let st = try idx.db.prepare("SELECT rowid FROM chunks_tri WHERE body LIKE ?")
                try st.bind([.text("%\(probe)%")]); viaFTS = []
                while try st.step() { viaFTS.insert(st.int(0)) }
            }
            tf = tf == 0 ? ms(clock.now - a) : min(tf, ms(clock.now - a))
        }
        var oracle = Set<Int64>()
        let st = try idx.db.prepare("SELECT id FROM chunks WHERE instr(body, ?) > 0")
        try st.bind([.text(probe)])
        while try st.step() { oracle.insert(st.int(0)) }
        log("  trigram '\(probe)': fts \(viaFTS.count) vs substring \(oracle.count) (false+ \(viaFTS.subtracting(oracle).count), missed \(oracle.subtracting(viaFTS).count)) \(f(tf)) ms \(detail == "full" ? "MATCH ORDER BY rank" : "LIKE, unranked")")
    }
    // one-row-per-chunk vector layout, for comparison
    try idx.db.exec("CREATE TABLE vec_rows(set_id INTEGER NOT NULL, chunk INTEGER NOT NULL, v BLOB NOT NULL, PRIMARY KEY(set_id, chunk))")
    let e = ToyEmbedder()
    try idx.db.transaction {
        let st = try idx.db.prepare("INSERT INTO vec_rows VALUES (1, ?, ?)")
        let c = try idx.db.prepare("SELECT id, body FROM chunks")
        while try c.step() {
            let v = e.embed(c.text(1)).map(Float16.init)
            try st.bind([.int(c.int(0)), .blob(v.withUnsafeBufferPointer { Data(buffer: $0) })]); try st.step()
        }
    }
    var rowsSize: Int64 = 0
    for (name, s) in try sizeBreakdown(idx.db) where name.hasPrefix("vec_rows") || name.hasPrefix("sqlite_autoindex_vec_rows") { rowsSize += s }
    log("  vectors as one row per chunk (for comparison): \(per10k(rowsSize)) = \(rowsSize / actual) B/vector (raw f16 = 2048 B)")
}

// top-level dispatch last: globals in main.swift initialize in order
switch cmd {
case "info":
    let i = Schema.runtimeInfo()
    log("sqlite \(i.version) fts5=\(i.fts5) load_extension=\(i.loadExtension) threadsafe=\(sqlite3_threadsafe())")

case "crash":
    let dir = URL(fileURLWithPath: arg("--dir")!)
    let point = arg("--at")!
    let idx = try ProjectIndex(dir: dir)
    idx.wordsPerChunk = Int(arg("--words") ?? "40")!
    idx.embedBatch = 4
    idx.crashHook = { p in if p == point { log("KILL at \(p)"); kill(getpid(), SIGKILL) } }
    switch arg("--op")! {
    case "add": try idx.add(file: URL(fileURLWithPath: arg("--file")!))
    case "remove": try idx.remove(doc: Int64(arg("--doc")!)!)
    case "reindex": try idx.reindex(doc: Int64(arg("--doc")!)!, newText: try String(contentsOfFile: arg("--file")!, encoding: .utf8))
    default: fatalError("op")
    }
    log("DONE without hitting \(point)")

case "bench":
    try runBench()

case "concurrency":
    try runConcurrency()

case "size":
    try runSize()

default:
    log("unknown command")
}

