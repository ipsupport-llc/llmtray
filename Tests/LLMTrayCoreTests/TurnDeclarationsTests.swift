import XCTest
@testable import LLMTrayCore

final class TurnDeclarationsTests: XCTestCase {
    private func tool(_ name: String) -> [String: Any] {
        ["type": "function", "function": ["name": name, "parameters": ["type": "object"]]]
    }

    func testKeepsOnlyALongTurnsFirstList() {
        XCTAssertFalse(TurnDeclarations.shouldKeep(alreadyKept: false, declared: 3, promptTokens: 2_999))
        XCTAssertTrue(TurnDeclarations.shouldKeep(alreadyKept: false, declared: 3, promptTokens: 3_000))
        // Kept once: a later, narrower list doesn't replace it.
        XCTAssertFalse(TurnDeclarations.shouldKeep(alreadyKept: true, declared: 2, promptTokens: 40_000))
        // A request without tools (the last round of a short turn) keeps nothing.
        XCTAssertFalse(TurnDeclarations.shouldKeep(alreadyKept: false, declared: 0, promptTokens: 40_000))
    }

    func testRepeatsTheListInOrderWithoutToolsSwitchedOff() {
        let kept = [tool("web_search"), tool("project_files"), tool("generate_image")]
        let names = TurnDeclarations.repeated(kept, offered: ["generate_image", "project_files", "web_search"]).compactMap(TurnDeclarations.name)
        XCTAssertEqual(names, ["web_search", "project_files", "generate_image"])
        let fewer = TurnDeclarations.repeated(kept, offered: ["project_files", "generate_image"]).compactMap(TurnDeclarations.name)
        XCTAssertEqual(fewer, ["project_files", "generate_image"])
        XCTAssertTrue(TurnDeclarations.repeated([["type": "function"]], offered: ["x"]).isEmpty)
    }
}
