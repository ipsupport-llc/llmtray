import XCTest
@testable import LLMTrayCore

final class DocumentMathTests: XCTestCase {
    private func math(_ tex: String, display: Bool = false) -> String { DocumentMath.mathML(tex, display: display) ?? "nil" }

    func testCommonForms() {
        XCTAssertEqual(math("x^2"), "<math><mrow><msup><mi>x</mi><mn>2</mn></msup></mrow></math>")
        XCTAssertTrue(math(#"\frac12"#).contains("<mfrac><mn>1</mn><mn>2</mn></mfrac>"))
        XCTAssertTrue(math(#"\sqrt[3]{8}"#).contains("<mroot><mrow><mn>8</mn></mrow><mrow><mn>3</mn></mrow></mroot>"))
        XCTAssertTrue(math(#"x_{i}^{2}"#).contains("<msubsup><mi>x</mi>"))
        XCTAssertTrue(math("3.14 - x").contains("<mn>3.14</mn><mo>−</mo>"))
        XCTAssertTrue(math(#"\mathbb{R}"#).contains("<mi>ℝ</mi>"))
        XCTAssertTrue(math(#"\sqrt[x^2]{y}"#).contains("<mroot><mrow><mi>y</mi></mrow><mrow><msup><mi>x</mi><mn>2</mn></msup></mrow></mroot>"))
        XCTAssertTrue(math(#"a \& b"#).contains("<mi mathvariant=\"normal\">&amp;</mi>"))
        XCTAssertTrue(math("a & b").contains("<mi>a</mi><mo>&amp;</mo><mi>b</mi>"), "a bare & is kept")
        XCTAssertTrue(math(#"\text{if } x"#).contains("<mtext>if </mtext>"))
        XCTAssertTrue(math(#"\Delta \alpha"#).contains("<mi mathvariant=\"normal\">Δ</mi><mi>α</mi>"))
        XCTAssertTrue(math(#"\hat{x}"#).contains("<mover accent=\"true\"><mrow><mi>x</mi></mrow><mo>ˆ</mo></mover>"))
    }

    /// A sum's scripts are limits, an integral's stay scripts; a function
    /// name is upright and applied, spaced unless brackets follow.
    func testOperatorsAndFunctions() {
        XCTAssertTrue(math(#"\sum_{i=1}^n i"#).contains("<munderover><mo>∑</mo>"))
        XCTAssertTrue(math(#"\int_0^1 f"#).contains("<msubsup><mo>∫</mo>"))
        XCTAssertTrue(math(#"\sum\limits_{i=1}^{n} i"#).contains("<munderover><mo>∑</mo><mrow><mi>i</mi>"))
        XCTAssertTrue(math(#"\int\limits_0^1 f"#).contains("<munderover><mo>∫</mo>"))
        XCTAssertTrue(math(#"\displaystyle^2"#).contains("<msup><mrow></mrow><mn>2</mn></msup>"))
        XCTAssertTrue(math(#"\lim_{x \to 0} x"#).contains("<munder><mi>lim</mi>"))
        XCTAssertTrue(math(#"\sin x"#).contains("<mi>sin</mi><mo>\u{2061}</mo><mtext>\u{2009}</mtext><mi>x</mi>"))
        XCTAssertTrue(math(#"\sin(x)"#).contains("<mi>sin</mi><mo>\u{2061}</mo><mo stretchy=\"false\">(</mo>"))
        XCTAssertTrue(math(#"\sin^2 x"#).contains("<msup><mi>sin</mi><mn>2</mn></msup><mo>\u{2061}</mo>"))
    }

    /// Plain brackets keep their size; \left and \right wrap what's
    /// between them and stretch to it.
    func testBrackets() {
        XCTAssertTrue(math("(a)").contains("<mo stretchy=\"false\">(</mo>"))
        XCTAssertTrue(math(#"\left( \frac{a}{b} \right)"#).contains("<mrow><mo>(</mo><mrow><mfrac>"))
        XCTAssertTrue(math(#"\left\{ x \right."#).contains("<mrow><mo>{</mo><mrow><mi>x</mi></mrow></mrow>"))
        XCTAssertTrue(math(#"\begin{cases} 1 & x > 0 \\ 0 & \text{else} \end{cases}"#).contains("<mrow><mo>{</mo><mtable><mtr>"))
        XCTAssertEqual(math(#"\begin{bmatrix} 1 \\ 2 \\ \end{bmatrix}"#).components(separatedBy: "<mtr>").count - 1, 2, "a last \\\\ adds no row")
    }

    func testWhatCantBeReadIsNil() {
        for bad in [#"\frac{1}{"#, "{x", "x}", #"\left( x"#, #"\begin{matrix} 1"#, "  ", "x^"] {
            XCTAssertNil(DocumentMath.mathML(bad, display: false), bad)
        }
        XCTAssertNil(DocumentMath.mathML(String(repeating: "x", count: DocumentMath.maxScalars + 1), display: false))
        // An unknown command shows as written; markup is text.
        XCTAssertTrue(math(#"\foo"#).contains(#"<mtext>\foo</mtext>"#))
        XCTAssertFalse(math(#"\text{<b>}"#).contains("<b>"))
    }
}
