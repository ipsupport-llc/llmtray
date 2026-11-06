import XCTest
@testable import LLMTrayCore

final class SpeakableTextTests: XCTestCase {
    let code = "Code in the chat."

    func testMarkdownBecomesSpeakable() {
        let md = """
        ## Setup

        Run **this** and see [the docs](https://example.com) or https://x.y/z.
        - first *item*
        1. `brew` step [1]

        ```swift
        let x = 1
        ```
        > quoted
        | Name | Size |
        |------|-----:|
        | a | 2 |
        <br>---
        """
        let plain = SpeakableText.plain(fromMarkdown: md, codeBlock: code)
        XCTAssertEqual(plain, """
        Setup

        Run this and see the docs or
        first item
        brew step

        Code in the chat.
        quoted
        Name, Size

        a, 2
        """)
    }

    func testSnakeCaseIsNotItalic() {
        XCTAssertEqual(SpeakableText.speakableLine("set max_tokens_cap to _ten_"), "set max_tokens_cap to ten")
    }

    func testStreamEmitsCompleteSentencesOnly() {
        var s = SentenceStream(codeBlock: code)
        XCTAssertEqual(s.feed("Hello there. How"), ["Hello there."])
        XCTAssertEqual(s.feed(" are you"), [])
        XCTAssertEqual(s.feed("? Fine"), ["How are you?"])
        XCTAssertEqual(s.finish(), ["Fine"])
        XCTAssertEqual(s.finish(), [])
    }

    func testDecimalsAndNewlines() {
        var s = SentenceStream(codeBlock: code)
        XCTAssertEqual(s.feed("It costs 3.5 dollars"), [])
        XCTAssertEqual(s.feed("\n- next"), ["It costs 3.5 dollars"])
        XCTAssertEqual(s.finish(), ["next"])
    }

    func testAnOpenFenceIsHeldUntilItCloses() {
        var s = SentenceStream(codeBlock: code)
        XCTAssertEqual(s.feed("Try this.\n```py\nprint(1)\nx = 2. y\n"), ["Try this."])
        XCTAssertEqual(s.feed("```\nDone. "), ["Code in the chat.", "Done."])
        XCTAssertEqual(s.finish(), [])
    }

    func testAFenceStartingInTheLastLineIsHeld() {
        var s = SentenceStream(codeBlock: code)
        XCTAssertEqual(s.feed("Look.\n``"), ["Look."])
        XCTAssertEqual(s.feed("`\nlet a = 1. b\n```\n"), ["Code in the chat."])
    }

    func testRussianSentences() {
        var s = SentenceStream(codeBlock: code)
        XCTAssertEqual(s.feed("Привет! Чем могу помочь? Т"), ["Привет!", "Чем могу помочь?"])
        XCTAssertEqual(s.feed("ак и есть."), [])
        XCTAssertEqual(s.finish(), ["Так и есть."])
    }

    func testLongSentencesAreCut() {
        let long = Array(repeating: "word", count: 40).joined(separator: " ") + ", " + Array(repeating: "tail", count: 10).joined(separator: " ")
        let parts = SentenceStream.split(long, maxLength: 120)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 120 }, "\(parts.map(\.count))")
        XCTAssertEqual(parts.joined(separator: " ").replacingOccurrences(of: "  ", with: " "), long)
    }

    func testPunctuationAloneIsSkipped() {
        var s = SentenceStream(codeBlock: code)
        XCTAssertEqual(s.feed("---\n...\nOk.\n"), ["Ok."])
    }

    func testLanguage() {
        XCTAssertEqual(SpeechLanguage.detect("Это предложение написано по-русски, вне всяких сомнений.", fallback: "en"), "ru")
        XCTAssertEqual(SpeechLanguage.detect("This sentence is clearly written in English.", fallback: "ru"), "en")
        XCTAssertEqual(SpeechLanguage.detect("OK", fallback: "ru"), "ru")
        XCTAssertEqual(SpeechLanguage.code(.simplifiedChinese), "zh")
        XCTAssertEqual(SpeechLanguage.code(.norwegian), "no")
        XCTAssertEqual(SpeechLanguage.code(.portuguese), "pt")
        XCTAssertNil(SpeechLanguage.code(.undetermined))
    }
}
