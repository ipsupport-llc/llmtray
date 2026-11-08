import XCTest
@testable import LLMTrayCore

final class RecurrentLoopsTests: XCTestCase {
    func testOnlyForALoopedModel() {
        XCTAssertNil(RecurrentLoops.requestValue(modelLoops: nil, picked: 3))
    }

    func testPickOrServerDefault() {
        XCTAssertNil(RecurrentLoops.requestValue(modelLoops: 2, picked: 0), "default: the server's")
        XCTAssertEqual(RecurrentLoops.requestValue(modelLoops: 2, picked: 4), 4)
        XCTAssertNil(RecurrentLoops.requestValue(modelLoops: 2, picked: 9))
    }
}
