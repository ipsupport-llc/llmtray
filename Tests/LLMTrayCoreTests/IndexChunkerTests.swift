import XCTest
@testable import LLMTrayCore

final class IndexChunkerTests: XCTestCase {
    let chunker = IndexChunker()

    func verbatim(_ text: String, _ c: ChunkDraft) -> String {
        String(String.UnicodeScalarView(Array(text.unicodeScalars)[c.start..<(c.start + c.length)]))
    }

    /// Offsets are code points into the page, chunks in order, never
    /// overlapping, covering every non-space character.
    func assertTiles(_ text: String, _ chunks: [ChunkDraft], file: StaticString = #filePath, line: UInt = #line) {
        var end = 0
        var covered = 0
        for c in chunks {
            XCTAssertGreaterThanOrEqual(c.start, end, "no overlap", file: file, line: line)
            end = c.start + c.length
            covered += verbatim(text, c).unicodeScalars.filter { !$0.properties.isWhitespace }.count
        }
        XCTAssertEqual(covered, text.unicodeScalars.filter { !$0.properties.isWhitespace }.count, "nothing lost", file: file, line: line)
    }

    func testLongProseLandsInTheTargetRange() {
        var gen = CorpusGenerator(seed: 2)
        let paragraphs = (0..<40).map { _ in gen.text(words: 60) }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = chunker.chunk(pages: [(1, text)])
        assertTiles(text, chunks)
        XCTAssertGreaterThan(chunks.count, 4)
        for c in chunks.dropLast() {
            XCTAssertLessThanOrEqual(c.tokens, 500)
            XCTAssertGreaterThanOrEqual(c.tokens, 250, "\(c.tokens)")
        }
        XCTAssertEqual(chunks.map(\.ord), Array(0..<chunks.count))
        XCTAssertTrue(chunks.allSatisfy { $0.body == IndexText.normalize(verbatim(text, $0)) }, "no heading: the body is the text")
    }

    func testOneHugeParagraphIsCutAtSentencesThenWhitespace() {
        let sentence = "Поставщик обязуется поставить товар в срок, указанный в спецификации. "
        let text = String(repeating: sentence, count: 200)
        let chunks = chunker.chunk(pages: [(1, text)])
        assertTiles(text, chunks)
        XCTAssertTrue(chunks.allSatisfy { $0.tokens <= 500 })
        XCTAssertTrue(chunks.dropLast().allSatisfy { verbatim(text, $0).hasSuffix(".") }, "cut after a sentence end")
        let blob = String(repeating: "A", count: 10_000)   // no whitespace at all
        let hard = chunker.chunk(pages: [(1, blob)])
        assertTiles(blob, hard)
        XCTAssertTrue(hard.allSatisfy { $0.tokens <= 500 })
    }

    func testHeadingsStartChunksAndPrefixTheFollowingOnes() {
        var gen = CorpusGenerator(seed: 3)
        let text = """
        # Договор поставки

        \(gen.text(words: 40))

        ## 2. Оплата

        \((0..<12).map { _ in gen.text(words: 60) }.joined(separator: "\n\n"))

        ## 3. Ответственность

        Неустойка 0,1% в день.
        """
        let chunks = chunker.chunk(pages: [(1, text)])
        assertTiles(text, chunks)
        XCTAssertEqual(chunks[0].heading, "Договор поставки")
        XCTAssertTrue(verbatim(text, chunks[0]).hasPrefix("# Договор поставки"))
        XCTAssertTrue(chunks[0].body.hasPrefix("# договор поставки"), "its own heading isn't repeated as a prefix")
        let payment = chunks.filter { $0.heading == "Договор поставки › 2. Оплата" }
        XCTAssertGreaterThan(payment.count, 1)
        XCTAssertTrue(verbatim(text, payment[0]).hasPrefix("## 2. Оплата"), "a heading starts a chunk")
        XCTAssertTrue(payment[1].body.hasPrefix("договор поставки › 2. оплата\n"), "later chunks carry the path")
        let last = chunks.last!
        XCTAssertEqual(last.heading, "Договор поставки › 3. Ответственность", "a sibling replaces its level")
        XCTAssertTrue(last.body.hasPrefix("договор поставки\n## 3. ответственность"))
    }

    func testATableIsItsOwnChunkAndLongTablesRepeatTheHeader() {
        let small = """
        Текст до таблицы.

        | Товар | Цена |
        |---|---|
        | Гвозди | 10 |
        | Шурупы | 12 |

        Текст после.
        """
        let chunks = chunker.chunk(pages: [(1, small)])
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.isTable), [false, true, false])
        XCTAssertTrue(verbatim(small, chunks[1]).hasPrefix("| Товар | Цена |"))

        let rows = (0..<300).map { "| Позиция \($0) | артикул \($0 * 7) | \($0 * 13) руб. |" }
        let big = "| Наименование | Артикул | Цена |\n|---|---|---|\n" + rows.joined(separator: "\n")
        let tableChunks = chunker.chunk(pages: [(4, big)])
        XCTAssertGreaterThan(tableChunks.count, 2)
        XCTAssertTrue(tableChunks.allSatisfy { $0.isTable && $0.page == 4 && $0.tokens <= 500 })
        XCTAssertTrue(verbatim(big, tableChunks[0]).hasPrefix("| Наименование"), "the first holds the header")
        for c in tableChunks.dropFirst() {
            XCTAssertTrue(c.body.hasPrefix("| наименование | артикул | цена | |---|---|---|\n| позиция"), "later ones repeat it")
            XCTAssertTrue(verbatim(big, c).hasPrefix("| Позиция"))
        }
        assertTiles(big, tableChunks)

        let tabs = "Имя\tВозраст\tГород\nИван\t30\tМосква\nПётр\t40\tКазань"
        XCTAssertEqual(chunker.chunk(pages: [(1, tabs)]).map(\.isTable), [true], "tab-separated rows are a table")
    }

    func testChunksNeverCrossPagesAndHeadingsCarryOver() {
        let pages: [(page: Int, text: String)] = [(1, "# Раздел\n\nпервая страница"), (2, "вторая страница"), (3, "  \n ")]
        let chunks = chunker.chunk(pages: pages)
        XCTAssertEqual(chunks.map(\.page), [1, 2])
        XCTAssertEqual(chunks[1].heading, "Раздел")
        XCTAssertEqual(chunks[1].body, "раздел\nвторая страница")
        XCTAssertEqual(chunks.map(\.ord), [0, 1])
        XCTAssertTrue(chunker.chunk(pages: []).isEmpty)
    }

    func testNotAHeading() {
        let text = "#хэштег и #1\n\n####### семь решёток"
        let chunks = chunker.chunk(pages: [(1, text)])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertNil(chunks[0].heading)
    }
}
