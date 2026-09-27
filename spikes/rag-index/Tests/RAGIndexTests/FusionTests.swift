import XCTest
@testable import RAGIndex

final class FusionTests: XCTestCase {
    func testRRFMath() {
        let r = RRF.fuse([[1, 2, 3], [3, 1], [4]], k: 60)
        XCTAssertEqual(r.map(\.id), [1, 3, 4, 2])
        XCTAssertEqual(r[0].score, 1.0 / 61 + 1.0 / 62, accuracy: 1e-12)
        XCTAssertEqual(r[1].score, 1.0 / 63 + 1.0 / 61, accuracy: 1e-12)
        XCTAssertEqual(r[2].score, 1.0 / 61, accuracy: 1e-12)
        XCTAssertEqual(r[3].score, 1.0 / 62, accuracy: 1e-12)
        // duplicates inside one list count once (first rank); empty lists are fine
        XCTAssertEqual(RRF.fuse([[7, 7, 8], []]).map(\.id), [7, 8])
        XCTAssertEqual(RRF.fuse([[5, 6], [6, 5]]).map(\.id), [5, 6], "exact tie → best single rank, then id")
        XCTAssertTrue(RRF.fuse([]).isEmpty)
        // a doc in all three lists at rank 10 beats a doc at rank 1 in one list
        let a = RRF.fuse([Array(100..<109) + [1], Array(200..<209) + [1], Array(300..<309) + [1]], k: 60)
        XCTAssertEqual(a.first?.id, 1)
    }

    func testDenseKernelsAgreeAndTopKIsExact() {
        let n = 3000, dim = 1024
        var g = SplitMix64(seed: 9)
        func r() -> Float { Float(Int(g.next() % 2001) - 1000) / 1000 }
        let vecs = (0..<n * dim).map { _ in Float16(r()) }
        let d = DenseIndex(dim: dim)
        d.append(ids: (0..<n).map { Int64($0 + 1) }, doc: 1, vectors: vecs)
        d.widen()
        let q = (0..<dim).map { _ in r() }
        let naive: [Float] = (0..<n).map { i in (0..<dim).reduce(0) { $0 + Float(vecs[i * dim + $1]) * q[$1] } }
        for (name, y) in [("sgemv", d.scoresSgemv(q)), ("sgemv8", d.scoresSgemvParallel(q)), ("f16", d.scoresF16(q)), ("f16tiled", d.scoresF16Tiled(q, tileRows: 100))] {
            for i in 0..<n { XCTAssertEqual(y[i], naive[i], accuracy: 1e-2, name) }
        }
        let top = d.topK(d.scoresF16(q), k: 50)
        let exact = naive.enumerated().sorted { $0.element > $1.element }.prefix(50).map { Int64($0.offset + 1) }
        XCTAssertEqual(top.map(\.id), exact)
        // doc filter
        let d2 = DenseIndex(dim: dim)
        d2.append(ids: [1, 2], doc: 1, vectors: Array(vecs[0..<2 * dim]))
        d2.append(ids: [3], doc: 2, vectors: Array(vecs[2 * dim..<3 * dim]))
        XCTAssertEqual(Set(d2.topK(d2.scoresF16(q), k: 5, allowed: { $0 == 2 }).map(\.id)), [3])
    }

    func testHybridEndToEndSmall() throws {
        let idx = try ProjectIndex(dir: tempDir())
        idx.wordsPerChunk = 50
        var gen = CorpusGenerator(seed: 21)
        for _ in 0..<10 { try idx.addText(gen.text(words: 500)) }
        let target = try idx.addText("Неустойка за просрочку поставки составляет 0,1% за каждый день. Уникальноеслово здесь.")
        let reader = try Database(path: idx.dbURL.path, readOnly: true)
        let s = try Searcher(db: reader)
        let dense = try DenseIndex.load(db: reader, setID: idx.activeSet, dim: 1024, widen: true)
        XCTAssertEqual(Int64(dense.count), try idx.db.scalarInt("SELECT count(*) FROM chunks"))
        var t = HybridTimings()
        let q = "неустойку за просрочку поставок уникальноеслово"
        let hits = try s.hybrid(q, queryVector: ToyEmbedder().embed(q), dense: dense, allowedDocs: nil, timings: &t)
        XCTAssertEqual(hits.first?.doc, target)
        XCTAssertTrue(hits.first!.text.hasPrefix("Неустойка"), "verbatim text")
        // a document being removed disappears from all three lists
        try idx.db.run("UPDATE documents SET status='removing' WHERE doc = ?", [.int(target)])
        let hits2 = try s.hybrid(q, queryVector: ToyEmbedder().embed(q), dense: dense, allowedDocs: [], timings: &t)
        XCTAssertFalse(hits2.contains { $0.doc == target })
    }
}
