import XCTest
@testable import LLMTrayCore

final class MusicRunnerMessageTests: XCTestCase {
    func testParsesEachKind() {
        XCTAssertEqual(MusicRunnerMessage(line: "@@LLMTRAY STAGE Writing the song"), .stage("Writing the song"))
        XCTAssertEqual(MusicRunnerMessage(line: "@@LLMTRAY STEP 65 100"), .step(65, 100))
        XCTAssertEqual(MusicRunnerMessage(line: "@@LLMTRAY SEED 123456"), .seed(123456))
        XCTAssertNil(MusicRunnerMessage(line: "@@LLMTRAY SEED x"))
        XCTAssertEqual(MusicRunnerMessage(line: "@@LLMTRAY AUDIO " + Data("RIFF".utf8).base64EncodedString()), .audio(Data("RIFF".utf8)))
    }

    func testIgnoresOtherLines() {
        XCTAssertNil(MusicRunnerMessage(line: "Loading 5Hz LM..."))
        XCTAssertNil(MusicRunnerMessage(line: "@@LLMTRAY STEP x"))
        XCTAssertNil(MusicRunnerMessage(line: "@@LLMTRAY AUDIO !!!"))
        XCTAssertNil(MusicRunnerMessage(line: "@@LLMTRAY IMAGE abc"))
    }
}
