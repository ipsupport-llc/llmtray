import XCTest
@testable import RAGIndex

final class QueryInjectionTests: XCTestCase {
    static let hostile: [String] = [
        "\"", "\"\"\"", "'", "`", "\\", "a\"b", "\"договор", "договор\"",
        "NEAR(a b)", "a NEAR b", "NEAR(\"договор\" \"поставки\", 5)", "NEAR",
        "*", "a*", "*a", "договор*", "^договор", "-a", "a - b", "--", "+", "a + b",
        "(", ")", "((a)", "a)", "()", String(repeating: "(", count: 2000),
        "a AND", "AND", "OR", "NOT", "NOT a", "a OR", "AND OR NOT", "a AND NOT",
        "body:a", "{body}: a", "body:", "rank:", "chunks_fts", "-body:x", "{body chunk}:a",
        ":", "a:b:c", "a.b.c", "@@@", "$", "%", "_", "%_%", ";DROP TABLE chunks;--",
        "'); DELETE FROM chunks; --", "\u{0}", "a\u{0}b", "\u{202E}договор", "🙂", "\u{301}\u{301}",
        "", "   ", "!!!", "договор\" OR \"*", "договор\" NOT \"поставки",
        String(repeating: "договор ", count: 5000), String(repeating: "я", count: 100_000),
    ]

    func testHostileQueriesNeverFailAndAreInert() throws {
        let idx = try ProjectIndex(dir: tempDir())
        idx.wordsPerChunk = 30
        var gen = CorpusGenerator(seed: 11)
        for _ in 0..<5 { try idx.addText(gen.text(words: 300) + " договор поставки NEAR body", embed: false) }
        let s = try Searcher(db: idx.db)
        let before = try idx.db.scalarInt("SELECT count(*) FROM chunks")
        var rawFailures = 0
        for q in Self.hostile {
            let lq = QueryBuilder.build(q)
            XCTAssertLessThanOrEqual(lq.terms.count, QueryBuilder.maxTerms)
            XCTAssertNoThrow(try s.words(lq), "words: \(q.prefix(40))")
            XCTAssertNoThrow(try s.trigram(lq), "trigram: \(q.prefix(40))")
            var t = HybridTimings()
            XCTAssertNoThrow(try s.hybrid(q, queryVector: ToyEmbedder().embed(q), dense: nil, allowedDocs: nil, timings: &t))
            // the same text passed raw would have been a syntax error / operator
            if (try? s.rawMatch(table: "chunks_fts", q)) == nil { rawFailures += 1 }
        }
        print("raw MATCH errors for \(rawFailures)/\(Self.hostile.count) hostile strings (all handled by QueryBuilder)")
        XCTAssertGreaterThan(rawFailures, 20)
        XCTAssertEqual(try idx.db.scalarInt("SELECT count(*) FROM chunks"), before)
        // operators are inert: the escaped attempt equals its plain words
        XCTAssertEqual(try s.words(QueryBuilder.build("договор\" OR \"*")), try s.words(QueryBuilder.build("договор")))
        XCTAssertEqual(try s.words(QueryBuilder.build("NEAR(договор поставки)")), try s.words(QueryBuilder.build("near договор поставки")))
        XCTAssertFalse(try s.words(QueryBuilder.build("NEAR")).isEmpty, "the word NEAR is searchable as a word")
        XCTAssertFalse(try s.words(QueryBuilder.build("body:")).isEmpty, "column-filter syntax is just the word 'body'")
    }

    func testBuiltExpressionsAreOnlyQuotedStringsJoinedByOR() {
        for q in Self.hostile {
            let lq = QueryBuilder.build(q)
            for expr in [lq.words, lq.trigram].compactMap({ $0 }) {
                // strip quoted strings; what remains must be only " OR " separators
                var rest = "", inQ = false
                for u in expr.unicodeScalars {   // scalars: SQLite sees code points, not graphemes
                    if u == "\"" { inQ.toggle(); continue }
                    if !inQ { rest.unicodeScalars.append(u) }
                }
                XCTAssertFalse(inQ, "unbalanced quotes for \(q.prefix(30))")
                XCTAssertTrue(rest.replacingOccurrences(of: " OR ", with: "").isEmpty, "stray syntax '\(rest)' for \(q.prefix(30))")
            }
        }
    }
}
