import XCTest
@testable import LLMTrayCore

final class SharedContextTests: XCTestCase {
    func testTextIsCleanedAndCut() {
        let c = SharedContext(kind: .browserTab, title: "T", source: "https://x.org", text: "  a   b \n\n\n\n c\t d  \n")
        XCTAssertEqual(c.text, "a b\n\nc d")
        XCTAssertFalse(c.truncated)
        let long = SharedContext(kind: .window, title: "", source: "", text: String(repeating: "x", count: SharedContext.maxText + 10))
        XCTAssertEqual(long.text?.count, SharedContext.maxText)
        XCTAssertTrue(long.truncated)
        XCTAssertTrue(long.noteForModel.contains("(cut here"))
        XCTAssertNil(SharedContext(kind: .window, title: "", source: "", text: " \n ").text)
    }

    func testNoteMarksItAsShown() {
        let tab = SharedContext(kind: .browserTab, title: "Account", source: "https://x.org/a", text: "Two-factor: off")
        XCTAssertEqual(tab.noteForModel, """
        [The user is showing you this. Browser tab: Account (https://x.org/a)]
        The page's text:
        Two-factor: off
        [End of what the user is showing]
        """)
        let window = SharedContext(kind: .window, title: "Account settings", source: "Safari")
        XCTAssertEqual(window.heading, "Window: Safari — Account settings")
        XCTAssertEqual(window.noteForModel, "[The user is showing you this. Window: Safari — Account settings]\n[End of what the user is showing]")
        let bare = SharedContext(kind: .browserTab, title: "", source: "https://x.org", titleOnly: true)
        XCTAssertTrue(bare.noteForModel.contains("Only the title and address"))
    }

    func testReadingOrder() {
        // Vision's boxes: origin at the bottom left.
        let pieces = [
            ReadingOrder.Piece(text: "Disabled", x: 0.6, y: 0.495, width: 0.2, height: 0.04),
            ReadingOrder.Piece(text: "Account settings", x: 0.1, y: 0.9, width: 0.4, height: 0.05),
            ReadingOrder.Piece(text: "Two-factor", x: 0.1, y: 0.5, width: 0.3, height: 0.04),
            ReadingOrder.Piece(text: " ", x: 0.1, y: 0.1, width: 0.3, height: 0.04),
        ]
        XCTAssertEqual(ReadingOrder.lines(pieces), "Account settings\nTwo-factor   Disabled")
    }

    func testBrowserScriptsAndAnswers() {
        let chrome = BrowserTab.browser(bundleID: "com.google.Chrome")!
        let script = BrowserTab.script(for: chrome)
        XCTAssertTrue(script.contains("application id \"com.google.Chrome\""))
        XCTAssertTrue(script.contains("execute t javascript \"(function(){"))
        XCTAssertFalse(BrowserTab.script(for: chrome, titleOnly: true).contains("javascript"))
        XCTAssertTrue(BrowserTab.script(for: BrowserTab.browser(bundleID: "com.apple.Safari")!).contains("(text of t)"))
        XCTAssertNil(BrowserTab.browser(bundleID: "com.apple.finder"))

        let tab = BrowserTab.parse("Docs\u{1E}https://x.org/d\u{1E}Hello\u{1E}world", titleOnly: false)
        XCTAssertEqual(tab?.title, "Docs")
        XCTAssertEqual(tab?.source, "https://x.org/d")
        XCTAssertEqual(tab?.text, "Hello\u{1E}world")
        XCTAssertNil(BrowserTab.parse("Docs\u{1E}\u{1E}text", titleOnly: false))
        XCTAssertNil(BrowserTab.parse("no separators", titleOnly: false))
        let bare = BrowserTab.parse("Docs\u{1E}https://x.org\u{1E}", titleOnly: true)
        XCTAssertEqual(bare?.titleOnly, true)
        XCTAssertNil(bare?.text)
    }

    func testSharedTextIsOutsideText() {
        var state = ToolTrust.TurnState()
        XCTAssertTrue(ToolTrust.allows(.guarded, state))
        state.sharedText = true
        XCTAssertFalse(ToolTrust.allows(.guarded, state))
        XCTAssertTrue(ToolTrust.changeIsAfterRead(state))
    }
}
