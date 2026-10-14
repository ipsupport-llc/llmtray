import XCTest
@testable import LLMTrayCore

final class AppleSystemModelTests: XCTestCase {
    func testAConversationFromAChatRequest() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "Be brief."],
            ["role": "system", "content": "Memory: answers in Russian."],
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "1", "function": ["name": "web_search", "arguments": "{}"]]]],
            ["role": "tool", "content": "{\"results\": []}"],
            ["role": "assistant", "content": ""],
            ["role": "user", "content": [["type": "text", "text": "what now?"], ["type": "image_url", "image_url": ["url": "data:..."]]]],
        ]
        let conversation = try XCTUnwrap(AppleConversation(messages: messages))
        XCTAssertEqual(conversation.instructions, "Be brief.\n\nMemory: answers in Russian.")
        XCTAssertEqual(conversation.prompt, "what now?", "the last user message, its text only")
        XCTAssertEqual(conversation.turns.map(\.role), [.user, .assistant, .user], "an empty assistant turn goes")
        XCTAssertEqual(conversation.turns[1].text, "[called: web_search]")
        XCTAssertEqual(conversation.turns[2].text, "[tool result: {\"results\": []}]")
        XCTAssertNil(AppleConversation(messages: [["role": "system", "content": "x"]]), "nothing to answer")
    }

    func testARequestsKnobs() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "apple-system", "stream": true, "stream_options": ["include_usage": true],
            "max_tokens": 32768, "temperature": 0.7, "messages": [["role": "user", "content": "hi"]],
        ] as [String: Any])
        let request = try XCTUnwrap(AppleChatWire.Request(body: body, contextSize: 8192))
        XCTAssertTrue(request.stream)
        XCTAssertTrue(request.includeUsage)
        XCTAssertEqual(request.maxTokens, 4096, "at most half the context for the answer")
        XCTAssertEqual(request.temperature, 0.7)
        XCTAssertNil(AppleChatWire.Request(body: Data("{\"model\":\"x\"}".utf8), contextSize: 8192))
    }

    func testTheStreamReadsAsTheChatReadsMLX() {
        let wire = AppleChatWire(id: "chatcmpl-1", created: 1, model: AppleSystemModel.id)
        var decoder = SSEDecoder()
        let stream = AppleChatWire.event(wire.roleChunk()) + AppleChatWire.event(wire.textChunk("При"))
            + AppleChatWire.event(wire.textChunk("вет")) + AppleChatWire.event(wire.finishChunk())
            + AppleChatWire.event(wire.usageChunk(.init(prompt: 12, completion: 3))) + AppleChatWire.done
        let events = decoder.feed(stream)
        XCTAssertEqual(events, [.content("При"), .content("вет"), .usage(completionTokens: 3, promptTokens: 12)])
        XCTAssertEqual(SSEDecoder.events(fromLine: "data: " + AppleChatWire.errorChunk("too long", code: "context_length_exceeded")),
                       [.error("too long")])
        let completion = try? JSONSerialization.jsonObject(with: Data(wire.completion("ok", usage: nil).utf8)) as? [String: Any]
        let message = ((completion?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        XCTAssertEqual(message, "ok")
    }

    func testFailuresAsHTTP() {
        XCTAssertEqual(AppleChatWire.status(of: .contextExceeded).code, "context_length_exceeded")
        XCTAssertTrue(AppleChatWire.status(of: .unavailable("off")).status.hasPrefix("503"))
        XCTAssertEqual(AppleSystemModel.classify(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "y"])),
                       .failed("Error Domain=x Code=1 \"y\" UserInfo={NSLocalizedDescription=y}"))
    }

    /// Opt-in (APPLE_MODEL_LIVE=1, a Mac with Apple Intelligence on): the
    /// real model streams an answer whose pieces add up to it.
    func testLiveStreaming() async throws {
        guard ProcessInfo.processInfo.environment["APPLE_MODEL_LIVE"] == "1" else { throw XCTSkip("APPLE_MODEL_LIVE not set") }
        guard AppleSystemModel.isAvailable else { throw XCTSkip("Apple's model isn't available here") }
        let pieces = Pieces()
        let result = try await AppleSystemModel.stream(
            messages: [["role": "system", "content": "Answer in one short sentence."],
                       ["role": "user", "content": "Как называется столица Франции?"]],
            maxTokens: 100, temperature: 0.2) { await pieces.add($0) }
        let joined = await pieces.text
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertEqual(joined, result.text)
        print("Apple: \(result.text) usage: \(String(describing: result.usage))")
    }

    actor Pieces {
        var text = ""
        func add(_ piece: String) { text += piece }
    }
}
