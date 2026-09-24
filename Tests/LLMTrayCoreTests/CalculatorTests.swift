import XCTest
@testable import LLMTrayCore

final class CalculatorTests: XCTestCase {
    private func eval(_ s: String) throws -> Double { try Calculator.evaluate(s) }

    func testArithmeticAndPrecedence() throws {
        XCTAssertEqual(try eval("3847 * 29"), 111_563)
        XCTAssertEqual(try eval("(12345 + 678) / 9"), 1447)
        XCTAssertEqual(try eval("2 + 3 * 4"), 14)
        XCTAssertEqual(try eval("2450 * 15 / 100"), 367.5)
        XCTAssertEqual(try eval("(300 + 50) * 1.08 / 2"), 189, accuracy: 1e-9)
    }

    func testPowersUnaryAndAssociativity() throws {
        XCTAssertEqual(try eval("2 ** 10"), 1024)
        XCTAssertEqual(try eval("2^3^2"), 512)          // right-associative
        XCTAssertEqual(try eval("-2^2"), -4)            // like Python
        XCTAssertEqual(try eval("2^-1"), 0.5)
        XCTAssertEqual(try eval("pi * 2^2"), .pi * 4, accuracy: 1e-12)
    }

    func testIntegerOpsLikePython() throws {
        XCTAssertEqual(try eval("7 // 2"), 3)
        XCTAssertEqual(try eval("-7 // 2"), -4)
        XCTAssertEqual(try eval("-7 % 3"), 2)
        XCTAssertEqual(try eval("7 % 3"), 1)
    }

    func testFunctionsAndConstants() throws {
        XCTAssertEqual(try eval("sqrt(2450)"), 2450.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(try eval("cbrt(27)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try eval("log10(1000)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try eval("log(8, 2)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try eval("math.sqrt(16)"), 4)
        XCTAssertEqual(try eval("round(2.675, 2)"), 2.68, accuracy: 0.011)
        XCTAssertEqual(try eval("max(1, 5, 3)"), 5)
        XCTAssertEqual(try eval("factorial(5)"), 120)
        XCTAssertEqual(try eval("gcd(12, 18) + lcm(4, 6)"), 18)
        XCTAssertEqual(try eval("1e3 + 2.5E-1"), 1000.25)
        XCTAssertEqual(try eval("1_000_000 / 4"), 250_000)
        XCTAssertEqual(try eval("6 × 7 ÷ 2"), 21)
    }

    func testErrors() {
        XCTAssertThrowsError(try eval("1 / 0"))
        XCTAssertThrowsError(try eval("sqrt(-1)"))
        XCTAssertThrowsError(try eval("2 +"))
        XCTAssertThrowsError(try eval("(1 + 2"))
        XCTAssertThrowsError(try eval("__import__('os')"))
        XCTAssertThrowsError(try eval("foo(1)"))
        XCTAssertThrowsError(try eval("1 2"))
        XCTAssertThrowsError(try eval(String(repeating: "(", count: 500) + "1" + String(repeating: ")", count: 500)))
        XCTAssertThrowsError(try eval("10^400"))   // not finite
    }

    func testFormat() {
        XCTAssertEqual(Calculator.format(111_563), "111563")
        XCTAssertEqual(Calculator.format(0.1 + 0.2), "0.3")
        XCTAssertEqual(Calculator.format(-4), "-4")
    }
}
