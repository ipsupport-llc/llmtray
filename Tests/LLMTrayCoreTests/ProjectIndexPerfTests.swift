import XCTest
@testable import LLMTrayCore

/// The spike's scale run, opt-in (minutes and ~2 GB of disk):
/// `LLMTRAY_INDEX_PERF=200000 swift test --filter ProjectIndexPerfTests`.
/// Prints ingest rate, size per 10k chunks and hybrid search p50/p95.
final class ProjectIndexPerfTests: XCTestCase {
    func testHybridSearchAtScale() throws {
        guard let n = ProcessInfo.processInfo.environment["LLMTRAY_INDEX_PERF"].flatMap(Int.init), n > 0 else {
            throw XCTSkip("set LLMTRAY_INDEX_PERF=<chunks> to run")
        }
        let idx = try ProjectIndex.testIndex(chunker: IndexChunker())
        defer { try? FileManager.default.removeItem(at: idx.directory) }   // ~2 GB
        let set = try idx.vectorSet(model: "random", dim: 1024, prepVersion: 1).id
        var gen = CorpusGenerator(seed: 42)
        var g = SplitMix64(seed: 7)
        let perDoc = 100
        let t0 = ContinuousClock.now
        for d in 0..<(n / perDoc) {
            let pages = (0..<perDoc).map { ExtractedPage(page: $0 + 1, text: gen.text(words: 280)) }
            try idx.db.run("INSERT INTO documents(name, ext, sha256, added_at, status) VALUES (?, 'txt', ?, 0, 'extracting')",
                           [.text("d\(d)"), .text("sha\(d)")])
            let doc = idx.db.lastInsertRowID
            try idx.commitExtraction(IndexJob(doc: doc, rev: 1, file: idx.directory, isReindex: false), pages: pages)
            let pending = try idx.pendingChunks(doc: doc, set: set, limit: 10_000)
            var v = [Float16](repeating: 0, count: pending.count * 1024)
            for i in v.indices { v[i] = Float16(Float(Int(g.next() % 2001) - 1000) / 32000) }
            try idx.commitVectors(doc: doc, rev: 1, set: set, chunks: pending.map(\.id), vectors: v)
        }
        let ingest = ContinuousClock.now - t0
        try idx.checkpoint()
        let storage = try idx.storage()
        print("perf: \(storage.liveChunks) chunks ingested in \(ingest), \((storage.fileBytes / max(1, storage.liveChunks / 10_000)) >> 20) MB per 10k chunks")

        let reader = try SQLiteConnection(path: idx.databaseURL.path, readOnly: true)
        let s = try IndexSearcher(db: reader)
        let dense = DenseVectors(setID: set, dim: 1024)
        let l0 = ContinuousClock.now
        try dense.refresh(from: reader)
        print("perf: vectors loaded in \(ContinuousClock.now - l0)")
        let queries = ["договор поставки", "неустойка за просрочку", "server config timeout", "в", "parseConfig",
                       "оплата счета", "как сбросить пароль", "7707083893", "поставки товара в срок", "index query cache"]
        var times: [Duration] = []
        for round in 0..<3 {
            for q in queries {
                let v = (0..<1024).map { _ in Float(Int(g.next() % 2001) - 1000) / 32000 }
                let a = ContinuousClock.now
                _ = try s.search(q, queryVector: v, dense: dense, options: IndexSearchOptions(limit: 10))
                if round > 0 { times.append(ContinuousClock.now - a) }
            }
        }
        times.sort()
        print("perf: hybrid search p50 \(times[times.count / 2]), p95 \(times[times.count * 95 / 100])")
    }
}
