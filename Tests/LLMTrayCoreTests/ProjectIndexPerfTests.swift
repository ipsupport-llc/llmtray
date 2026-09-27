import XCTest
@testable import LLMTrayCore

/// The spike's scale run, opt-in (minutes and ~2 GB of disk); timings
/// mean something in release only:
/// `LLMTRAY_INDEX_PERF=200000 swift test -c release -Xswiftc -enable-testing --filter ProjectIndexPerfTests`.
/// `LLMTRAY_INDEX_PERF_DIR=<dir>` keeps the index there and reuses it on the
/// next run (no re-ingest); `LLMTRAY_INDEX_READER=<cacheKB>:<mmapMB>,...`
/// compares reader settings (default: the app's). Prints ingest rate, size
/// per 10k chunks, the vector load, and hybrid search p50/p95/p99/max over
/// 200 searches, per query and per stage.
final class ProjectIndexPerfTests: XCTestCase {
    func testHybridSearchAtScale() throws {
        let env = ProcessInfo.processInfo.environment
        guard let n = env["LLMTRAY_INDEX_PERF"].flatMap(Int.init), n > 0 else {
            throw XCTSkip("set LLMTRAY_INDEX_PERF=<chunks> to run")
        }
        let keep = env["LLMTRAY_INDEX_PERF_DIR"].map { URL(fileURLWithPath: $0) }
        let dir = keep ?? indexTempDir()
        let idx = try ProjectIndex.testIndex(dir, chunker: IndexChunker())
        defer { if keep == nil { try? FileManager.default.removeItem(at: idx.directory) } }   // ~2 GB
        let set = try idx.vectorSet(model: "random", dim: 1024, prepVersion: 1).id
        var g = SplitMix64(seed: 7)
        if try idx.count("SELECT count(*) FROM chunks") < Int64(n) * 9 / 10 {
            var gen = CorpusGenerator(seed: 42)
            let perDoc = 100
            let t0 = ContinuousClock.now
            for d in 0..<(n / perDoc) {
                let pages = (0..<perDoc).map { ExtractedPage(page: $0 + 1, text: gen.text(words: 200)) }
                try idx.db.run("INSERT INTO documents(name, ext, sha256, added_at, status) VALUES (?, 'txt', ?, 0, 'extracting')",
                               [.text("d\(d)"), .text("sha\(d)")])
                let doc = idx.db.lastInsertRowID
                try idx.commitExtraction(IndexJob(doc: doc, rev: 1, file: idx.directory, isReindex: false), pages: pages)
                let pending = try idx.pendingChunks(doc: doc, set: set, limit: 10_000)
                var v = [Float16](repeating: 0, count: pending.count * 1024)
                for i in v.indices { v[i] = Float16(Float(Int(g.next() % 2001) - 1000) / 32000) }
                try idx.commitVectors(doc: doc, rev: 1, set: set, chunks: pending.map(\.id), vectors: v)
            }
            print("perf: ingested in \(ContinuousClock.now - t0)")
        }
        try idx.checkpoint()
        let storage = try idx.storage()
        print("perf: \(storage.liveChunks) chunks, \((storage.fileBytes / max(1, storage.liveChunks / 10_000)) >> 20) MB per 10k chunks")

        let settings: [(cacheKB: Int, mmapMB: Int)] = env["LLMTRAY_INDEX_READER"].map {
            $0.split(separator: ",").map { s in
                let p = s.split(separator: ":").compactMap { Int($0) }
                return (p[0], p.count > 1 ? p[1] : 0)
            }
        } ?? [(IndexSchema.readerCacheKB, IndexSchema.readerMmapBytes >> 20)]
        let queries = ["договор поставки", "неустойка за просрочку", "server config timeout", "в", "parseConfig",
                       "оплата счета", "как сбросить пароль", "7707083893", "поставки товара в срок", "index query cache"]
        for setting in settings {
            let reader = try SQLiteConnection(path: idx.databaseURL.path, readOnly: true)
            try IndexSchema.configureReader(reader, cacheKB: setting.cacheKB, mmapBytes: setting.mmapMB << 20)
            let s = try IndexSearcher(db: reader)
            var loads: [Duration] = []
            var dense = DenseVectors(setID: set, dim: 1024)
            for _ in 0..<3 {
                dense = DenseVectors(setID: set, dim: 1024)
                let l0 = ContinuousClock.now
                try dense.refresh(from: reader)
                loads.append(ContinuousClock.now - l0)
            }
            print("perf [cache \(setting.cacheKB) KB, mmap \(setting.mmapMB) MB]: \(dense.count) vectors (\(dense.residentBytes >> 20) MB) loaded in \(loads.map { "\($0)" }.joined(separator: " / "))")
            var times: [Duration] = [], perQuery: [String: [Duration]] = [:]
            var stages: [String: [Duration]] = [:]
            for round in 0..<21 {
                for q in queries {
                    let v = (0..<1024).map { _ in Float(Int(g.next() % 2001) - 1000) / 32000 }
                    let a = ContinuousClock.now
                    _ = try s.search(q, queryVector: v, dense: dense, options: IndexSearchOptions(limit: 10))
                    let t = ContinuousClock.now - a
                    guard round > 0 else { continue }   // the first round warms the cache
                    times.append(t)
                    perQuery[q, default: []].append(t)
                    let st = s.lastTimings
                    for (name, d) in [("words", st.words), ("trigram", st.trigram), ("dense", st.dense), ("fetch", st.fetch)] {
                        stages[name, default: []].append(d)
                    }
                }
            }
            func pct(_ xs: [Duration], _ p: Int) -> Duration {
                let s = xs.sorted()
                return s[min(s.count - 1, (s.count * p + 99) / 100 - 1)]
            }
            func ms(_ d: Duration) -> String { String(format: "%.1f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
            print("perf:   search over \(times.count): p50 \(ms(pct(times, 50))) ms, p95 \(ms(pct(times, 95))) ms, p99 \(ms(pct(times, 99))) ms, max \(ms(times.max()!)) ms")
            for name in ["words", "trigram", "dense", "fetch"] {
                print("perf:   stage \(name): p50 \(ms(pct(stages[name]!, 50))) ms, p95 \(ms(pct(stages[name]!, 95))) ms")
            }
            for q in queries { print("perf:   \"\(q)\": p50 \(ms(pct(perQuery[q]!, 50))) ms, max \(ms(perQuery[q]!.max()!)) ms") }
            // Lexical only (no query vector: the embedder paused or absent).
            var lexical: [Duration] = []
            for round in 0..<11 {
                for q in queries {
                    let a = ContinuousClock.now
                    _ = try s.search(q, options: IndexSearchOptions(limit: 10))
                    if round > 0 { lexical.append(ContinuousClock.now - a) }
                }
            }
            print("perf:   lexical-only over \(lexical.count): p50 \(ms(pct(lexical, 50))) ms, p95 \(ms(pct(lexical, 95))) ms, max \(ms(lexical.max()!)) ms")
            reader.close()
        }
    }
}
