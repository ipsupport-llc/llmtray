import XCTest
@testable import LLMTrayCore

final class IndexFusionTests: XCTestCase {
    func testRRFMath() {
        let r = RRF.fuse([[1, 2, 3], [3, 1], [4]], k: 60)
        XCTAssertEqual(r.map(\.id), [1, 3, 4, 2])
        XCTAssertEqual(r[0].score, 1.0 / 61 + 1.0 / 62, accuracy: 1e-12)
        XCTAssertEqual(r[1].score, 1.0 / 63 + 1.0 / 61, accuracy: 1e-12)
        XCTAssertEqual(r[2].score, 1.0 / 61, accuracy: 1e-12)
        XCTAssertEqual(r[3].score, 1.0 / 62, accuracy: 1e-12)
        XCTAssertEqual(RRF.fuse([[7, 7, 8], []]).map(\.id), [7, 8], "a duplicate counts once; empty lists are fine")
        XCTAssertEqual(RRF.fuse([[5, 6], [6, 5]]).map(\.id), [5, 6], "an exact tie: best single rank, then id")
        XCTAssertTrue(RRF.fuse([]).isEmpty)
        let a = RRF.fuse([Array(100..<109) + [1], Array(200..<209) + [1], Array(300..<309) + [1]], k: 60)
        XCTAssertEqual(a.first?.id, 1, "rank 10 in all three lists beats rank 1 in one")
    }

    func testGateDropsFrequentTermsButKeepsTheRarestMatch() {
        let df: [String: Int64] = ["в": 900, "и": 800, "договор": 30, "нет": 0]
        let g = IndexSearcher.gate(["в", "и", "договор", "нет"], total: 1000, share: 0.2, minimumChunks: 100) { df[$0]! }
        XCTAssertEqual(g.kept, ["договор", "нет"])
        XCTAssertEqual(g.dropped, ["в", "и"])
        let onlyCommon = IndexSearcher.gate(["в", "и"], total: 1000, share: 0.2, minimumChunks: 100) { df[$0]! }
        XCTAssertEqual(onlyCommon.kept, ["и"], "nothing useful left: the rarest matching term stays")
        XCTAssertEqual(IndexSearcher.gate(["в", "и"], total: 50, share: 0.2, minimumChunks: 100) { df[$0]! }.kept, ["в", "и"],
                       "a small index isn't gated")
        XCTAssertEqual(IndexSearcher.gate(["в", "и"], total: 1000, share: nil, minimumChunks: 100) { df[$0]! }.kept, ["в", "и"])
        XCTAssertEqual(IndexSearcher.gate(["в"], total: 1000, share: 0.2, minimumChunks: 100) { df[$0]! }.kept, ["в"],
                       "a single term is never gated")
    }

    func testGateOnARealIndexWithAConfigurableThreshold() throws {
        let idx = try ProjectIndex.testIndex()
        for i in 0..<30 {
            try idx.addText("общее слово здесь \(i). " + (i == 7 ? "редкоеслово" : "другое") + " \(String(repeating: "x\(i) ", count: 30))",
                            name: "d\(i).txt", embed: false)
        }
        let s = try idx.searcher()
        var options = IndexSearchOptions(limit: 10)
        options.gateMinimumChunks = 1
        let gated = try s.search("общее редкоеслово", options: options)
        XCTAssertEqual(gated.gatedTerms, ["общее"])
        XCTAssertEqual(gated.hits.first?.doc, 8)
        XCTAssertEqual(gated.hits.count, 1, "only the rare term ran")
        options.documentFrequencyGate = 1.0
        XCTAssertTrue(try s.search("общее редкоеслово", options: options).gatedTerms.isEmpty)
        options.documentFrequencyGate = nil
        XCTAssertGreaterThan(try s.search("общее редкоеслово", options: options).hits.count, 1)
    }
}

final class DenseVectorsTests: XCTestCase {
    func testTiledScoresMatchNaiveAndTopKIsExact() {
        let n = 3000, dim = 1024
        var g = SplitMix64(seed: 9)
        func r() -> Float { Float(Int(g.next() % 2001) - 1000) / 1000 }
        let vecs = (0..<n * dim).map { _ in Float16(r()) }
        let d = DenseVectors(setID: 1, dim: dim)
        d.append(ids: (0..<n).map { Int64($0 + 1) }, doc: 1, vectors: vecs)
        let q = (0..<dim).map { _ in r() }
        let naive: [Float] = (0..<n).map { i in
            var s: Float = 0
            for k in 0..<dim { s += Float(vecs[i * dim + k]) * q[k] }
            return s
        }
        for tile in [1, 100, 128, 5000] {
            let y = d.scores(q, tileRows: tile)
            for i in 0..<n { XCTAssertEqual(y[i], naive[i], accuracy: 1e-2, "tile \(tile) row \(i)") }
        }
        let top = d.top(d.scores(q), k: 50) { _ in true }
        let exact = naive.enumerated().sorted { $0.element > $1.element }.prefix(50).map { Int64($0.offset + 1) }
        XCTAssertEqual(top.map(\.chunk), exact)
        XCTAssertTrue(d.top([], k: 5) { _ in true }.isEmpty)

        let d2 = DenseVectors(setID: 1, dim: dim)
        d2.append(ids: [1, 2], doc: 1, vectors: Array(vecs[0..<2 * dim]))
        d2.append(ids: [3], doc: 2, vectors: Array(vecs[2 * dim..<3 * dim]))
        XCTAssertEqual(d2.top(d2.scores(q), k: 5) { $0 == 2 }.map(\.chunk), [3], "the document filter")
    }

    func testRefreshAppendsNewBlocksAndReloadsAfterDeletes() throws {
        let idx = try ProjectIndex.testIndex()
        let a = try idx.addText("первый документ о поставке и оплате товара по договору", name: "a.txt")
        let dense = DenseVectors(setID: idx.toySet, dim: 64)
        XCTAssertTrue(try dense.refresh(from: idx.db))
        let first = dense.count
        XCTAssertEqual(Int64(first), try idx.count("SELECT count(*) FROM chunks"))
        XCTAssertFalse(try dense.refresh(from: idx.db), "nothing new")
        let b = try idx.addText("второй документ про сервер и конфигурацию индекса", name: "b.txt")
        XCTAssertTrue(try dense.refresh(from: idx.db))
        XCTAssertEqual(Set(dense.docs), [a, b])
        try idx.remove(doc: a)
        try dense.refresh(from: idx.db)
        XCTAssertEqual(Set(dense.docs), [b], "a deletion bumps the epoch: reloaded")
    }

    func testBlockEncodingRoundTrips() {
        let ids: [Int64] = [1, -2, .max, 42]
        let data = DenseVectors.encode(ids: ids)
        XCTAssertEqual(data.count, 32)
        XCTAssertEqual(data.withUnsafeBytes { DenseVectors.decodeIDs($0) }, ids)
        let v: [Float16] = [1, -0.5, 65504]
        XCTAssertEqual(DenseVectors.encode(vectors: v).count, 6)
    }
}

final class IndexHybridSearchTests: XCTestCase {
    func testHybridEndToEnd() throws {
        let idx = try ProjectIndex.testIndex()
        var gen = CorpusGenerator(seed: 21)
        for i in 0..<10 { try idx.addText(gen.text(words: 300), name: "d\(i).txt") }
        let target = try idx.addText("Неустойка за просрочку поставки составляет 0,1% за каждый день. Уникальноеслово здесь.", name: "t.txt")
        let reader = try SQLiteConnection(path: idx.databaseURL.path, readOnly: true)
        let s = try IndexSearcher(db: reader)
        let dense = DenseVectors(setID: idx.toySet, dim: 64)
        try dense.refresh(from: reader)
        XCTAssertEqual(Int64(dense.count), try idx.count("SELECT count(*) FROM chunks"))
        let q = "неустойку за просрочку поставок уникальноеслово"
        let r = try s.search(q, queryVector: ToyEmbedder().embed(q), dense: dense)
        XCTAssertTrue(r.usedDense)
        XCTAssertEqual(r.hits.first?.doc, target)
        XCTAssertTrue(r.hits.first!.text.hasPrefix("Неустойка"), "verbatim text")
        XCTAssertEqual(r.hits.first?.foundBy, [.words, .trigram, .dense])
        XCTAssertFalse(r.hits.first!.isLexicalOnly)
        // A document being removed disappears from all three lists at once.
        try idx.db.run("UPDATE documents SET status = 'removing' WHERE doc = ?", [.int(target)])
        XCTAssertFalse(try s.search(q, queryVector: ToyEmbedder().embed(q), dense: dense).hits.contains { $0.doc == target })
        // Without a vector: lexical only, and said so.
        try idx.db.run("UPDATE documents SET status = 'embedded' WHERE doc = ?", [.int(target)])
        let lexical = try s.search(q)
        XCTAssertFalse(lexical.usedDense)
        XCTAssertEqual(lexical.hits.first?.doc, target)
        XCTAssertTrue(lexical.hits.allSatisfy(\.isLexicalOnly))
    }

    func testAtMostTwoHitsPerDocumentUnlessFiltered() throws {
        let idx = try ProjectIndex.testIndex()
        let big = try idx.addText((0..<20).map { "Раздел \($0): договор поставки и оплата по договору, пункт \($0)." }.joined(separator: "\n\n"),
                                  name: "big.txt")
        let other = try idx.addText("Этот договор короткий.", name: "small.txt")
        let third = try idx.addText("Ещё один договор, про аренду.", name: "third.txt")
        XCTAssertGreaterThan(try idx.count("SELECT count(*) FROM chunks WHERE doc = ?", [.int(big)]), 4)
        let s = try idx.searcher()
        let r = try s.search("договор", options: IndexSearchOptions(limit: 10))
        let perDoc = Dictionary(grouping: r.hits, by: \.doc).mapValues(\.count)
        XCTAssertEqual(perDoc[big], 2)
        XCTAssertEqual(Set(perDoc.keys), [big, other, third])
        let narrowed = try s.search("договор", options: IndexSearchOptions(limit: 10, document: big))
        XCTAssertGreaterThan(narrowed.hits.count, 2)
        XCTAssertTrue(narrowed.hits.allSatisfy { $0.doc == big })
        XCTAssertEqual(try s.search("договор", options: IndexSearchOptions(limit: 3)).hits.count, 3)
        XCTAssertTrue(try s.search("договор", options: IndexSearchOptions(limit: 0)).hits.isEmpty)
    }
}
