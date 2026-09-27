import XCTest
@testable import LLMTrayCore

final class HTMLTextTests: XCTestCase {
    func testStructure() {
        let html = """
        <html><head><title>Договор &laquo;A&raquo;</title><style>p { color: red }</style>
        <script>var x = "<p>not text</p>";</script></head>
        <body><h1>Heading</h1><p>First   paragraph
        over two lines.</p><p>Second&nbsp;one &amp; more</p>
        <ul><li>one</li><li>two</li></ul>
        <table><tr><th>Name</th><th>Qty</th></tr><tr><td>Bolt</td><td>12</td></tr></table>
        <pre>  keep
          this</pre><!-- a comment --><p>end</p></body></html>
        """
        XCTAssertEqual(HTMLText.text(html), """
        Договор «A»

        Heading

        First paragraph over two lines.

        Second one & more

        - one
        - two

        Name | Qty
        Bolt | 12

          keep
          this

        end
        """)
    }

    func testSkippedElementsAndAttributes() {
        let html = """
        <body><svg><text>vector</text></svg><noscript>enable js</noscript><template><p>t</p></template>
        <img src="http://127.0.0.1/x.png" alt="a > b"><a href="https://x" title='>'>link</a><svg/> after</body>
        """
        XCTAssertEqual(HTMLText.text(html), "link after")
    }

    func testNestedSkippedElements() {
        XCTAssertEqual(HTMLText.text("<template><template>a</template>hidden</template>shown"), "shown")
        XCTAssertEqual(HTMLText.text("<svg><svg><text>x</text></svg><text>y</text></svg>ok"), "ok")
        // Raw text doesn't nest: a "<script>" in a script is a string.
        XCTAssertEqual(HTMLText.text("<script>var s = '<script>';</script>after"), "after")
        XCTAssertEqual(HTMLText.text("<script>if (a <!-- b) {}</script>visible"), "visible")
        XCTAssertEqual(HTMLText.text("<style>/* <!-- */</style>visible"), "visible")
    }

    func testEntitiesThroughWebParsing() {
        XCTAssertEqual(HTMLText.text("<p>&#1044;&#x43E; &mdash; &hellip; &unknown; &amp;lt;</p>"), "До — … &unknown; &lt;")
        XCTAssertEqual(HTMLText.text("a &lt;b&gt; c"), "a <b> c")
        XCTAssertEqual(HTMLText.text("x < y and y > z"), "x < y and y > z")
    }

    func testHostileMarkup() {
        // An unclosed comment, tag or script runs to the end without trouble.
        XCTAssertEqual(HTMLText.text("text<!-- never closed"), "text")
        XCTAssertEqual(HTMLText.text("text<div class=\"never closed"), "text")
        XCTAssertEqual(HTMLText.text("text<script>forever"), "text")
        // Deep nesting and a huge attribute: one linear pass.
        let deep = String(repeating: "<div>", count: 200_000) + "deep" + String(repeating: "</div>", count: 200_000)
        let start = Date()
        XCTAssertEqual(HTMLText.text(deep), "deep")
        XCTAssertEqual(HTMLText.text("<p title=\"" + String(repeating: "x", count: 1_000_000) + "\">ok</p>"), "ok")
        // A long run of newlines in <pre>, then many block tags: not quadratic.
        XCTAssertEqual(HTMLText.text("<pre>x" + String(repeating: "\n", count: 1_000_000) + "</pre>" + String(repeating: "<br>", count: 100_000) + "y"),
                       "x" + String(repeating: "\n", count: 1_000_000) + "y")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(HTMLText.text(""), "")
    }
}
