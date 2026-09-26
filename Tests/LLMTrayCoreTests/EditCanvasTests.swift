import XCTest
@testable import LLMTrayCore

final class EditCanvasTests: XCTestCase {
    func testSquareStaysSquare() {
        let size = EditCanvas.size(sourceWidth: 3000, sourceHeight: 3000, scale: 1)
        XCTAssertEqual(size.width, 1024)
        XCTAssertEqual(size.height, 1024)
    }

    func testKeepsAspectAndMultipleOf16() {
        let size = EditCanvas.size(sourceWidth: 4032, sourceHeight: 3024, scale: 1)
        XCTAssertEqual(size.width % 16, 0)
        XCTAssertEqual(size.height % 16, 0)
        XCTAssertEqual(Double(size.width) / Double(size.height), 4.0 / 3, accuracy: 0.03)
        XCTAssertEqual(Double(size.width * size.height), 1024 * 1024, accuracy: 1024 * 1024 * 0.05)
    }

    func testScaleAndLimits() {
        let fast = EditCanvas.size(sourceWidth: 1000, sourceHeight: 1000, scale: 0.5)
        XCTAssertEqual(fast.width, 512)
        let strip = EditCanvas.size(sourceWidth: 10000, sourceHeight: 10, scale: 1.5)
        XCTAssertLessThanOrEqual(strip.width, 2048)
        XCTAssertGreaterThanOrEqual(strip.height, 256)
        let wide = EditCanvas.size(sourceWidth: 2048, sourceHeight: 512, scale: 1.5)
        XCTAssertEqual(Double(wide.width) / Double(wide.height), 4, accuracy: 0.1)
        let empty = EditCanvas.size(sourceWidth: 0, sourceHeight: 0, scale: 1)
        XCTAssertEqual(empty.width, 1024)
    }
}
