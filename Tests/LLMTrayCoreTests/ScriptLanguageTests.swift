import XCTest
@testable import LLMTrayCore

final class ScriptLanguageTests: XCTestCase {
    func testCandidates() {
        XCTAssertEqual(ScriptLanguage.wikipediaCandidates(for: "Київ").first, "uk")
        XCTAssertEqual(ScriptLanguage.wikipediaCandidates(for: "Їжак"), ["uk", "ru", "en"])
        XCTAssertEqual(ScriptLanguage.wikipediaCandidates(for: "Пётр I").first, "ru")
        XCTAssertEqual(ScriptLanguage.wikipediaCandidates(for: "Москва"), ["ru", "uk", "bg", "sr", "en"])
        XCTAssertEqual(ScriptLanguage.wikipediaCandidates(for: "Мінск ўсё").first, "uk")   // і wins, fine either way
        XCTAssertEqual(ScriptLanguage.wikipediaCandidates(for: "東京"), ["zh", "ja", "en"])
        XCTAssertEqual(ScriptLanguage.wikipediaCandidates(for: "とうきょう"), ["ja", "en"])
        XCTAssertEqual(ScriptLanguage.wikipediaCandidates(for: "서울"), ["ko", "en"])
        XCTAssertEqual(ScriptLanguage.wikipediaCandidates(for: "القاهرة"), ["ar", "en"])
        XCTAssertEqual(ScriptLanguage.wikipediaCandidates(for: "Albert Einstein"), ["en"])
    }
}
