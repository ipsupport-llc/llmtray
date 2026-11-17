import XCTest
@testable import LLMTrayCore

final class LinkNoteTests: XCTestCase {
    private let pageTool: [String: Any] = ["type": "function", "function": [
        "name": "web_search", "parameters": ["type": "object", "properties": ["query": ["type": "string"], "url": ["type": "string"]]]]]
    private let searchOnly: [String: Any] = ["type": "function", "function": [
        "name": "web_search", "parameters": ["type": "object", "properties": ["query": ["type": "string"]]]]]

    func testLinks() {
        XCTAssertEqual(LinkNote.links(in: "https://chatgpt.com/s/t_6afb о чем это"), ["https://chatgpt.com/s/t_6afb"])
        XCTAssertEqual(LinkNote.links(in: "see example.com and https://a.org/x, https://a.org/x"), ["https://example.com", "https://a.org/x"])
        XCTAssertTrue(LinkNote.links(in: "mail me at a@b.com, ftp://x.org/f").isEmpty)
        XCTAssertTrue(LinkNote.links(in: "no links here").isEmpty)
    }

    func testNote() {
        let note = LinkNote.text(for: "https://chatgpt.com/s/t_6afb разберем", canReadPages: true)
        XCTAssertEqual(note, "[App note, not the user's words: the message has a link. To read it, call web_search with source=page and url set to the link.]")
        XCTAssertNil(LinkNote.text(for: "https://chatgpt.com/s/t_6afb", canReadPages: false), "no page tool: nothing")
        XCTAssertNil(LinkNote.text(for: "привет", canReadPages: true))
    }

    func testDeclares() {
        XCTAssertTrue(LinkNote.declaresPageReading([searchOnly, pageTool]))
        XCTAssertFalse(LinkNote.declaresPageReading([searchOnly]))
        XCTAssertFalse(LinkNote.declaresPageReading([]))
    }
}
