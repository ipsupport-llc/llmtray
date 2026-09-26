import XCTest
@testable import LLMTrayCore

final class MarkdownTableTests: XCTestCase {
    func testTableWithoutSeparatorRow() {
        // As in the screenshot: no |---| row, markdown in the cells.
        let source = """
            Итоговое сравнение:

            | Параметр | Газовая | Электрическая |
            | **Стоимость** | ⭐⭐⭐⭐⭐ (дешево) | ⭐⭐⭐⭐ |
            | **Сложность** | Нужно уметь | Нажал кнопку |

            Мой вердикт:
            """
        let blocks = MarkdownBlock.split(source)
        XCTAssertEqual(blocks.count, 3)
        guard case .table(let table) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(table.header, ["Параметр", "Газовая", "Электрическая"])
        XCTAssertEqual(table.rows, [["**Стоимость**", "⭐⭐⭐⭐⭐ (дешево)", "⭐⭐⭐⭐"], ["**Сложность**", "Нужно уметь", "Нажал кнопку"]])
        XCTAssertEqual(blocks[0], .text("Итоговое сравнение:\n"))
    }

    func testSeparatorAlignmentsAndRaggedRows() {
        let table = MarkdownTable(lines: ["| a | b | c |", "|:--|:-:|--:|", "| 1 | 2 |", "| x | y | z | extra |"])!
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing, .leading])
        XCTAssertEqual(table.header, ["a", "b", "c", ""])
        XCTAssertEqual(table.rows, [["1", "2", "", ""], ["x", "y", "z", "extra"]])
    }

    func testEscapedPipeAndCodeFence() {
        XCTAssertEqual(MarkdownTable.cells(#"| a \| b | c |"#), ["a | b", "c"])
        let fenced = MarkdownBlock.split("```\n| not | a table |\n| x | y |\n```")
        XCTAssertEqual(fenced.count, 1)
        if case .table = fenced[0] { XCTFail("a table inside a code fence stays code") }
    }

    func testPipeInsideCodeStaysInTheCell() {
        XCTAssertEqual(MarkdownTable.cells("| `a | b` | union |"), ["`a | b`", "union"])
        XCTAssertEqual(MarkdownTable.cells("| `oops | next |"), ["`oops", "next"])
        XCTAssertEqual(MarkdownTable.cells("| ``a | b`` | c |"), ["``a | b``", "c"])
        XCTAssertEqual(MarkdownTable.cells(#"| \`literal` | next |"#), [#"\`literal`"#, "next"])
        XCTAssertEqual(MarkdownTable.cells("| `x` | `y | z` |"), ["`x`", "`y | z`"])
        XCTAssertEqual(MarkdownTable.cells(#"| a \\|"#), [#"a \\"#])
        XCTAssertEqual(MarkdownTable.cells(#"| a \|"#), ["a |"])
    }

    func testSingleRowIsText() {
        XCTAssertEqual(MarkdownBlock.split("| just one row |"), [.text("| just one row |")])
    }
}
