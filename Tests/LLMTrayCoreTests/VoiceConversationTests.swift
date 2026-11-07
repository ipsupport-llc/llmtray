import XCTest
@testable import LLMTrayCore

final class VoiceConversationTests: XCTestCase {
    func testBackchannels() {
        XCTAssertFalse(VoiceConversationText.isBackchannel("  "), "nothing heard isn't a backchannel")
        for text in ["Угу.", "ага", "Да-да", "мм", "Mm-hmm", "yeah", "OK", "got it"] {
            XCTAssertTrue(VoiceConversationText.isBackchannel(text), text)
        }
        for text in ["Подожди, не то", "нет", "Stop, wait a second", "что?", "да, но я про другое"] {
            XCTAssertFalse(VoiceConversationText.isBackchannel(text), text)
        }
    }

    func testEcho() {
        let spoken = ["Хм, что ты имеешь в виду?", "Готов описать LLMTray, чтобы я написал пост?"]
        XCTAssertTrue(VoiceConversationText.isEcho("что ты имеешь в виду", of: spoken))
        XCTAssertTrue(VoiceConversationText.isEcho("Хм.", of: ["Хм…"]))
        XCTAssertTrue(VoiceConversationText.isEcho("готова описать ллмтрей чтобы я написал", of: spoken), "a word or two misheard")
        XCTAssertFalse(VoiceConversationText.isEcho("а чем бы ты мог помочь", of: spoken))
        XCTAssertFalse(VoiceConversationText.isEcho("нет, подожди", of: spoken))
        XCTAssertFalse(VoiceConversationText.isEcho("что", of: []), "nothing played, nothing echoes")
        XCTAssertFalse(VoiceConversationText.isEcho("  ", of: spoken))
        XCTAssertTrue(VoiceConversationText.isEcho("what do you mean", of: ["Hmm, what do you mean by that?"]))
        XCTAssertFalse(VoiceConversationText.isEcho("what can you help me with", of: ["Hmm, what do you mean by that?"]))
        XCTAssertFalse(VoiceConversationText.isEcho("Do not delete the file", of: ["I can delete the file."]), "a correction isn't echo")
        XCTAssertFalse(VoiceConversationText.isEcho("file delete", of: ["I can delete the file."]), "the words, not the order")
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
