import XCTest
@testable import LLMTrayCore

final class ModelCardTextTests: XCTestCase {
    func testHTMLHeaderBecomesLinks() {
        let card = """
        <div align="center">
          <img
            src="https://example.com/logo.png"
            alt="Liquid AI"
            style="width: 100%; max-width: 100%; height: auto;"
          />
          <div style="display: flex; gap: 0.5em;">
            <a data-href="bad" title="a > b" href="https://playground.liquid.ai/"><strong>Try LFM</strong></a> •
            <a href='https://docs.liquid.ai/'><strong>Docs</strong></a>
          </div>
        </div>

        # Model
        """
        XCTAssertEqual(ModelCardText.clean(card), """
        [Try LFM](https://playground.liquid.ai/) •
        [Docs](https://docs.liquid.ai/)

        # Model
        """)
    }

    /// Only HTML blocks change: prose, inline code and inline HTML, lists,
    /// indented and fenced code, entities and blank lines stay as written.
    func testEverythingElseIsLeftAsWritten() {
        let cards = [
            "# Title\n\n- one\n  - <strong>child</strong>\n\n    <b>indented code</b>\n\n| a | b |\n|---|---|",
            "Use `<T>` and `&amp;`, [download](<model>), a <https://example.com> link.<br>  \nnext",
            "a\n\n\n\nb\n\nbefore\n\n```\nx\n```\n\nafter",
            "````html\n```\n<b>keep</b>\n````\n\n```html\n```not-a-close\n<div>keep</div>\n```",
            "&lt;div&gt;not a tag&lt;/div&gt;\nfoo\n|\nbar",
            "<b>keep</b> in prose\ntext <b>inline</b>",
            "- ```html\n  <div>keep</div>\n  ```",
            "para\n<span>not a block start</span>",
        ]
        for card in cards { XCTAssertEqual(ModelCardText.clean(card), card) }
    }

    func testBlockEndsAtABlankLine() {
        XCTAssertEqual(ModelCardText.clean("<p align=\"center\">\n    hello <a href=\"u\">x</a>\n</p>\n\n    code"),
                       "hello [x](u)\n\n    code")
        XCTAssertEqual(ModelCardText.clean("<!-- note -->\ntext"), "text")
        XCTAssertEqual(ModelCardText.clean("<!-- note -->\n    <b>code</b>"), "    <b>code</b>", "a comment ends at -->")
        XCTAssertEqual(ModelCardText.clean("<!--\nmulti\nline -->\nafter"), "after")
        XCTAssertEqual(ModelCardText.clean("<div><a href=\"has space\">x</a></div>"), "[x](<has space>)")
        XCTAssertEqual(ModelCardText.clean("<div><a href=\"https://e.com/a(b)\">Docs</a></div>"), "[Docs](<https://e.com/a(b)>)")
        XCTAssertEqual(ModelCardText.clean("<div><a title=\"hint href='wrong'\" href=\"https://e.com\">Docs</a></div>"), "[Docs](https://e.com)")
        XCTAssertEqual(ModelCardText.clean("<div><a href=\"https://e.com\">A [B</a></div>"), "[A \\[B](https://e.com)")
        XCTAssertEqual(ModelCardText.clean("\n<img src=\"logo.png\" />\n\ntext"), "\n\ntext", "a lone tag after a blank line")
        XCTAssertEqual(ModelCardText.clean("# Model\n<a href=\"https://chat.qwen.ai/\">\nChat\n</a>"), "# Model\n[Chat](https://chat.qwen.ai/)", "after a heading")
        XCTAssertEqual(ModelCardText.clean("<table>\n<tr><td>Accuracy</td><td>90%</td></tr>\n</table>\n\ntext"), "Accuracy 90%\n\ntext")
    }

    func testHostileBlockStaysFast() {
        let card = "<div " + String(repeating: "a=\"", count: 5000) + "\n" + String(repeating: "<a href=x>", count: 3000)
        let start = Date()
        _ = ModelCardText.clean(card)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
