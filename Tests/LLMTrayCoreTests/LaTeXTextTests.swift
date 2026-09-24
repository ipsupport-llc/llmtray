import XCTest
@testable import LLMTrayCore

final class LaTeXTextTests: XCTestCase {
    private func u(_ s: String) -> String { LaTeXText.toUnicode(s) }

    func testScreenshotExample() {
        XCTAssertEqual(u(#"\sqrt{144} \times (25 / 5) + 12.5"#), "√144 × (25 / 5) + 12.5")
    }

    func testScripts() {
        XCTAssertEqual(u("x^2 + y^2 = r^2"), "x² + y² = r²")
        XCTAssertEqual(u("a_n = a_{n-1} + 2^{10}"), "aₙ = aₙ₋₁ + 2¹⁰")
        XCTAssertEqual(u("e^{i\\pi} + 1 = 0"), "e^(iπ) + 1 = 0")      // π has no superscript form
        XCTAssertEqual(u("x^{*}"), "x*")
    }

    func testFractionsAndRoots() {
        XCTAssertEqual(u(#"\frac{1}{2}"#), "¹⁄₂")
        XCTAssertEqual(u(#"\frac{a+b}{c}"#), "(a+b)/c")
        XCTAssertEqual(u(#"\sqrt{x^2 + 1}"#), "√(x² + 1)")
        XCTAssertEqual(u(#"\sqrt[3]{27}"#), "³√27")
        XCTAssertEqual(u(#"\frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#), "(-b ± √(b² - 4ac))/(2a)")
    }

    func testSymbolsAndText() {
        XCTAssertEqual(u(#"\alpha + \beta \leq \Omega"#), "α + β ≤ Ω")
        XCTAssertEqual(u(#"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}"#), "∑ᵢ₌₁ⁿ i = (n(n+1))/2")
        XCTAssertEqual(u(#"\int_0^\infty e^{-x} dx"#), "∫₀^∞ e⁻ˣ dx")
        XCTAssertEqual(u(#"\text{speed} = \frac{d}{t}"#), "speed = d/t")
        XCTAssertEqual(u(#"\sin x + \cos x"#), "sin x + cos x")
        XCTAssertEqual(u(#"x \in \mathbb{R}"#), "x ∈ ℝ")
        XCTAssertEqual(u(#"\left( a \right)"#), "( a )")
        XCTAssertEqual(u(#"\unknowncommand{x}"#), "unknowncommandx")
    }

    func testRobustToBrokenInput() {
        XCTAssertEqual(u(#"\frac{1}"#), "1/")
        XCTAssertEqual(u("x^"), "x")
        XCTAssertEqual(u(String(repeating: "{", count: 500) + "x"), "x")
        XCTAssertEqual(u("\\"), "\\")
        // Recursion through commands and \sqrt[...] stays bounded (a model
        // stuck repeating could emit thousands).
        _ = u(String(repeating: #"\sqrt"#, count: 20_000) + "x")
        _ = u(String(repeating: #"\sqrt["#, count: 20_000) + "x")
        _ = u(String(repeating: #"\frac{"#, count: 20_000))
    }

    func testMathSpans() {
        XCTAssertEqual(MathSpans.split(#"Compute $\sqrt{2}$ now"#), [.text("Compute "), .math(#"\sqrt{2}"#, display: false), .text(" now")])
        XCTAssertEqual(MathSpans.split("It costs $5 and $10 total"), [.text("It costs $5 and $10 total")])
        XCTAssertEqual(MathSpans.split(#"$$E = mc^2$$"#), [.math("E = mc^2", display: true)])
        XCTAssertEqual(MathSpans.split(#"a \(x^2\) b"#), [.text("a "), .math("x^2", display: false), .text(" b")])
        XCTAssertEqual(MathSpans.split(#"\[ \int f \]"#), [.math(#" \int f "#, display: true)])
        XCTAssertEqual(MathSpans.split(#"see \[1\] here"#), [.text(#"see \[1\] here"#)])
        XCTAssertEqual(MathSpans.split("for $n$ items"), [.text("for "), .math("n", display: false), .text(" items")])
    }
}
