import XCTest
@testable import LLMTrayCore

final class SSEDecoderTests: XCTestCase {
    private func chunk(_ delta: [String: Any]) -> String {
        let obj: [String: Any] = ["choices": [["delta": delta]]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return "data: " + String(decoding: data, as: UTF8.self) + "\n"
    }

    func testContentAndReasoning() {
        var d = SSEDecoder()
        let events = d.feed(chunk(["reasoning": "think"]) + chunk(["content": "Hi"]))
        XCTAssertEqual(events, [.reasoning("think"), .content("Hi")])
    }

    func testReasoningContentKeyVariant() {
        var d = SSEDecoder()
        XCTAssertEqual(d.feed(chunk(["reasoning_content": "r"])), [.reasoning("r")])
    }

    func testLineSplitAcrossFeeds() {
        var d = SSEDecoder()
        let line = chunk(["content": "Привет"])
        let cut = line.index(line.startIndex, offsetBy: 20)
        XCTAssertEqual(d.feed(String(line[..<cut])), [])
        XCTAssertEqual(d.feed(String(line[cut...])), [.content("Привет")])
    }

    func testLastLineWithoutNewline() {
        var d = SSEDecoder()
        var line = chunk(["content": "end"])
        line.removeLast()
        XCTAssertEqual(d.feed(line), [])
        XCTAssertEqual(d.finish(), [.content("end")])
    }

    func testDoneCRLFAndNonDataLinesIgnored() {
        var d = SSEDecoder()
        let crlf = chunk(["content": "a"]).replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(d.feed(": keep-alive\n\n" + crlf + "data: [DONE]\n"), [.content("a")])
    }

    func testUsageChunk() {
        var d = SSEDecoder()
        let events = d.feed(#"data: {"choices":[],"usage":{"completion_tokens":42}}"# + "\n")
        XCTAssertEqual(events, [.usage(completionTokens: 42)])
    }

    func testContentArrayWithInlineImageOnly() {
        var d = SSEDecoder()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let events = d.feed(chunk(["content": [
            ["type": "text", "text": "here"],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]],
            ["type": "image_url", "image_url": ["url": "https://example.com/x.png"]],
        ]]))
        XCTAssertEqual(events, [.content("here"), .image(png)])
    }

    func testToolCall() {
        var d = SSEDecoder()
        let events = d.feed(chunk(["tool_calls": [
            ["id": "c1", "function": ["name": "generate_image", "arguments": #"{"prompt":"cat"}"#]],
        ]]))
        XCTAssertEqual(events, [.toolCall(id: "c1", name: "generate_image", argumentsJSON: #"{"prompt":"cat"}"#)])
    }

    func testMalformedJSONSkipped() {
        var d = SSEDecoder()
        XCTAssertEqual(d.feed("data: {not json\n" + chunk(["content": "ok"])), [.content("ok")])
    }
}
