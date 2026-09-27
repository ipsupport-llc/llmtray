import XCTest
@testable import LLMTrayCore

final class AnswerStatsTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func oneRequest() -> AnswerStats {
        AnswerStats(date: Date(timeIntervalSince1970: 1_800_000_000), model: "mlx-community/Qwen3-8B-4bit", modelFolder: "Qwen3-8B-4bit",
                    profile: "Default", contextTokens: 32768,
                    requests: [.init(promptTokens: 2000, cachedTokens: 1500, completionTokens: 300, reasoningTokens: 120,
                                     firstTokenSeconds: 0.5, generationSeconds: 6)],
                    totalSeconds: 6.5)
    }

    func testRatesFromTheLastRequest() throws {
        let stats = oneRequest()
        XCTAssertEqual(try XCTUnwrap(stats.generationTokensPerSecond), 50, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(stats.promptTokensPerSecond), 1000, accuracy: 1e-9, "uncached tokens over time to first token")
        XCTAssertEqual(stats.contextUsed, 2300)
        XCTAssertEqual(try XCTUnwrap(stats.contextFraction), 2300.0 / 32768, accuracy: 1e-9)
    }

    func testUnknownStaysUnknown() {
        var stats = AnswerStats(requests: [.init(completionTokens: 10, firstTokenSeconds: 0.3, generationSeconds: 0.01)])
        XCTAssertNil(stats.generationTokensPerSecond, "a sub-50ms span is noise")
        XCTAssertNil(stats.promptTokensPerSecond, "no prompt tokens reported")
        XCTAssertNil(stats.contextUsed)
        XCTAssertNil(stats.contextFraction)
        stats.requests = [.init(promptTokens: 100, cachedTokens: 100, completionTokens: 5, firstTokenSeconds: 0.2)]
        XCTAssertNil(stats.promptTokensPerSecond, "all cached: nothing processed")
        XCTAssertTrue(AnswerStats().sections().isEmpty)
    }

    func testTotalsAcrossRequestsOnlyWhenEveryOneReported() {
        var stats = AnswerStats(requests: [.init(promptTokens: 900, completionTokens: 40), .init(promptTokens: 1000, completionTokens: 200)],
                                toolCalls: 1)
        XCTAssertEqual(stats.answerTokens, 240)
        XCTAssertEqual(stats.promptTokens, 1000, "the last request's")
        XCTAssertEqual(stats.contextUsed, 1200)
        XCTAssertNil(stats.reasoningTokens)
        stats.requests?[0].completionTokens = nil
        XCTAssertNil(stats.answerTokens, "a partial sum isn't a total")
    }

    func testSections() {
        let sections = oneRequest().sections(locale: en)
        XCTAssertEqual(sections.map(\.kind), [.model, .speed, .tokens, .context, .date])
        XCTAssertEqual(sections[0].rows.map(\.kind), [.model, .folder, .profile])
        XCTAssertEqual(sections[1].rows, [
            .init(kind: .generation, value: "50.0 tok/s"), .init(kind: .promptProcessing, value: "1,000 tok/s"),
            .init(kind: .firstToken, value: "0.50 s"), .init(kind: .totalTime, value: "6.5 s"),
        ])
        XCTAssertEqual(sections[2].rows, [
            .init(kind: .prompt, value: "2,000"), .init(kind: .cached, value: "1,500"),
            .init(kind: .answer, value: "300"), .init(kind: .reasoning, value: "120"),
        ])
        XCTAssertEqual(sections[3].rows, [.init(kind: .context, value: "2,300 / 32,768 (7%)")])
    }

    func testMultiRequestLabels() {
        let stats = AnswerStats(requests: [.init(promptTokens: 900, cachedTokens: 0, completionTokens: 40),
                                           .init(promptTokens: 1000, completionTokens: 200)], toolCalls: 2, totalSeconds: 125)
        let rows = stats.sections(locale: en).flatMap(\.rows)
        XCTAssertEqual(rows.map(\.kind), [.totalTime, .promptLast, .answerTotal, .toolCalls, .context])
        XCTAssertEqual(rows.first?.value, "2:05 min")
    }

    func testPlainText() {
        let text = AnswerStats(profile: "Coding", requests: [.init(promptTokens: 10, completionTokens: 5)])
            .plainText(locale: en, heading: { "\($0)" }, label: { "\($0)" })
        XCTAssertEqual(text, "model\nprofile: Coding\n\ntokens\nprompt: 10\nanswer: 5\n\ncontext\ncontext: 15")
    }

    /// An older chat's message has no stats; one saved without a field (a
    /// server that didn't report it) decodes it as nil.
    func testDecodesWithout() throws {
        struct Message: Codable { var content: String; var answerStats: AnswerStats? }
        let old = try JSONDecoder().decode(Message.self, from: Data(#"{"content":"hi"}"#.utf8))
        XCTAssertNil(old.answerStats)
        let partial = try JSONDecoder().decode(AnswerStats.self, from: Data(#"{"model":"m","requests":[{"completionTokens":3}]}"#.utf8))
        XCTAssertEqual(partial, AnswerStats(model: "m", requests: [.init(completionTokens: 3)]))
        XCTAssertEqual(try JSONDecoder().decode(AnswerStats.self, from: Data("{}".utf8)), AnswerStats())
        let stats = oneRequest()
        XCTAssertEqual(try JSONDecoder().decode(AnswerStats.self, from: JSONEncoder().encode(stats)), stats)
    }

    func testTiming() {
        let sent = Date(timeIntervalSince1970: 100)
        var request = AnswerStats.Request()
        request.time(sent: sent, firstToken: sent.addingTimeInterval(0.8), lastToken: sent.addingTimeInterval(4.8))
        XCTAssertEqual(request.firstTokenSeconds ?? 0, 0.8, accuracy: 1e-6)
        XCTAssertEqual(request.generationSeconds ?? 0, 4, accuracy: 1e-6)
        var none = AnswerStats.Request()
        none.time(sent: sent, firstToken: nil, lastToken: sent)
        XCTAssertNil(none.firstTokenSeconds, "no token came")
        XCTAssertNil(none.generationSeconds)
    }
}
