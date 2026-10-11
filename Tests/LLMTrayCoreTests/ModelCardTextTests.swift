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
            <a href="https://playground.liquid.ai/"><strong>Try LFM</strong></a> •
            <a href="https://docs.liquid.ai/"><strong>Docs</strong></a>
          </div>
        </div>

        # Model

        Text with a <https://example.com> autolink, a < b, &amp; more.<br>Next line.
        """
        let out = ModelCardText.clean(card)
        XCTAssertFalse(out.contains("<div"), out)
        XCTAssertFalse(out.contains("<img"), out)
        XCTAssertFalse(out.contains("style="), out)
        XCTAssertTrue(out.contains("[Try LFM](https://playground.liquid.ai/)"), out)
        XCTAssertTrue(out.contains("[Docs](https://docs.liquid.ai/)"), out)
        XCTAssertTrue(out.contains("<https://example.com>"), out)
        XCTAssertTrue(out.contains("a < b, & more.\nNext line."), out)
        XCTAssertTrue(out.contains("# Model"), out)
        // No line keeps a code-block indent.
        XCTAssertFalse(out.components(separatedBy: "\n").contains { $0.hasPrefix("    ") }, out)
    }

    func testFencedCodeIsLeftAsWritten() {
        let card = "Run:\n\n```html\n<div class=\"x\">\n    <b>keep</b>\n</div>\n```\n\n<p>after</p>"
        let out = ModelCardText.clean(card)
        XCTAssertTrue(out.contains("```html\n<div class=\"x\">\n    <b>keep</b>\n</div>\n```"), out)
        XCTAssertTrue(out.hasSuffix("after"), out)
    }

    func testPlainMarkdownUnchanged() {
        let card = "# Title\n\n- one\n- two\n\n    indented code\n\n| a | b |\n|---|---|"
        XCTAssertEqual(ModelCardText.clean(card), card)
    }
}
