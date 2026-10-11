import XCTest
@testable import LLMTrayCore

final class ThinkingTests: XCTestCase {
    func testStyleFromTheTemplate() {
        XCTAssertEqual(Thinking.style(chatTemplate: nil), .none)
        XCTAssertEqual(Thinking.style(chatTemplate: "{{ messages }}"), .none, "Llama, Mistral: nothing to steer")
        XCTAssertEqual(Thinking.style(chatTemplate: "{%- if enable_thinking is false %}<think>\n\n</think>{% endif %}"), .budget, "Qwen 3.5")
        XCTAssertEqual(Thinking.style(chatTemplate: "<|channel>thought"), .budget, "Gemma 4")
        XCTAssertEqual(Thinking.style(chatTemplate: "Reasoning: {{ reasoning_effort }} <think>"), .levels, "gpt-oss: its own levels first")
    }

    func testRequestFields() {
        XCTAssertTrue(Thinking.requestFields(style: .none, effort: .low).isEmpty)
        XCTAssertTrue(Thinking.requestFields(style: .budget, effort: .high).isEmpty, "High: as before, no limit")
        let off = Thinking.requestFields(style: .budget, effort: .off)
        XCTAssertEqual((off["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertEqual(off["thinking_budget"] as? Int, 0, "a template that thinks anyway is closed at once")
        XCTAssertEqual(Thinking.requestFields(style: .budget, effort: .low)["thinking_budget"] as? Int, 512)
        XCTAssertEqual(Thinking.requestFields(style: .budget, effort: .medium)["thinking_budget"] as? Int, 2048)
        XCTAssertEqual((Thinking.requestFields(style: .levels, effort: .medium)["chat_template_kwargs"] as? [String: String])?["reasoning_effort"], "medium")
        XCTAssertEqual((Thinking.requestFields(style: .levels, effort: .off)["chat_template_kwargs"] as? [String: String])?["reasoning_effort"], "low")
        XCTAssertNil(Thinking.requestFields(style: .levels, effort: .high)["thinking_budget"])
    }
}
