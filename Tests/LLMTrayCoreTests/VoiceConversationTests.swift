import XCTest
@testable import LLMTrayCore

final class VoiceConversationTests: XCTestCase {
    func testBackchannels() {
        for text in ["Угу.", "ага", "Да-да", "мм", "Mm-hmm", "yeah", "OK", "got it", "  "] {
            XCTAssertTrue(VoiceConversationText.isBackchannel(text), text)
        }
        for text in ["Подожди, не то", "нет", "Stop, wait a second", "что?", "да, но я про другое"] {
            XCTAssertFalse(VoiceConversationText.isBackchannel(text), text)
        }
    }

    func testToolKinds() {
        XCTAssertEqual(VoiceConversationText.toolKind("generate_image"), .image)
        XCTAssertEqual(VoiceConversationText.toolKind("search_messages"), .mail)
        XCTAssertEqual(VoiceConversationText.toolKind("list_events"), .calendar)
        XCTAssertEqual(VoiceConversationText.toolKind("project_search"), .search)
        XCTAssertEqual(VoiceConversationText.toolKind("read_file"), .files)
        XCTAssertEqual(VoiceConversationText.toolKind("fetch_url"), .web)
        XCTAssertEqual(VoiceConversationText.toolKind("frobnicate"), .general)
        XCTAssertEqual(VoiceConversationText.tool(.mail, "ru"), "Гляну в почте.")
    }

    func testFillersPerLanguage() {
        XCTAssertFalse(VoiceConversationText.thinking("ru").isEmpty)
        XCTAssertFalse(VoiceConversationText.thinking("xx").isEmpty)   // English fallback
        let all = VoiceConversationText.allFillers("ru")
        XCTAssertEqual(Set(all).count, all.count, "no duplicate filler texts")
    }

    func testModelsPerRecognizer() {
        XCTAssertEqual(VoiceInputFile.needed(for: .parakeet).map(\.repo),
                       ["mlx-community/silero-vad-v6", "mlx-community/smart-turn-v3", "mlx-community/parakeet-tdt-0.6b-v3"])
        XCTAssertEqual(VoiceInputFile.needed(for: .apple).count, 2)
        XCTAssertEqual(VoiceInputFile.whisper.extraRepo, "openai/whisper-large-v3-turbo")
    }

    func testVoicePromptAsksForSpokenStyle() {
        XCTAssertTrue(VoiceConversationText.prompt.contains("read aloud"))
        XCTAssertTrue(VoiceConversationText.prompt.contains("No lists"))
    }
}
