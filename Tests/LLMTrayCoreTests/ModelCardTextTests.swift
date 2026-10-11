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
        ]
        for card in cards { XCTAssertEqual(ModelCardText.clean(card), card) }
    }

    func testBlockEndsAtABlankLine() {
        XCTAssertEqual(ModelCardText.clean("<p align=\"center\">\n    hello <a href=\"u\">x</a>\n</p>\n\n    code"),
                       "hello [x](u)\n\n    code")
        XCTAssertEqual(ModelCardText.clean("<!-- note -->\ntext"), "text")
        XCTAssertEqual(ModelCardText.clean("<a href=\"has space\">x</a>"), "x", "an address Markdown can't carry")
    }

    func testHostileBlockStaysFast() {
        let card = "<div " + String(repeating: "a=\"", count: 5000) + "\n" + String(repeating: "<a href=x>", count: 3000)
        let start = Date()
        _ = ModelCardText.clean(card)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
