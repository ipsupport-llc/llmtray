import XCTest
@testable import LLMTrayCore

final class SpeedJournalTests: XCTestCase {
    func testParse() {
        let s = RequestStats.parse("Request stats: prompt=4096 cached=1024 first_token_s=2.000 tokens=129 decode_s=4.000 drafted=40")
        XCTAssertEqual(s, RequestStats(prompt: 4096, cached: 1024, firstTokenSeconds: 2, tokens: 129, decodeSeconds: 4, drafted: 40))
        XCTAssertEqual(s?.prefillTokensPerSecond, 1536)
        XCTAssertEqual(s?.decodeTokensPerSecond, 32)
        XCTAssertNil(RequestStats.parse("Request stats: prompt=x"))
    }

    func testShortRequestsDontCountForSpeed() {
        let s = RequestStats(prompt: 100, cached: 0, firstTokenSeconds: 1, tokens: 3, decodeSeconds: 0.1, drafted: 0)
        XCTAssertNil(s.prefillTokensPerSecond)
        XCTAssertNil(s.decodeTokensPerSecond)
    }

    func testSummariesPerModelAndSettings() {
        var j = SpeedJournal()
        let t0 = Date(timeIntervalSince1970: 0)
        for (i, decode) in [2.0, 4.0, 8.0].enumerated() {
            j.add(.init(date: t0.addingTimeInterval(Double(i)), model: "frog", settings: "KV 4-bit · MTP",
                        stats: RequestStats(prompt: 2048, cached: 0, firstTokenSeconds: 1, tokens: 101, decodeSeconds: decode, drafted: 50)))
        }
        j.add(.init(date: t0.addingTimeInterval(10), model: "gemma", settings: "KV full",
                    stats: RequestStats(prompt: 50, cached: 0, firstTokenSeconds: 0.2, tokens: 20, decodeSeconds: 1, drafted: 0)))
        let s = j.summaries()
        XCTAssertEqual(s.map(\.model), ["gemma", "frog"])
        XCTAssertEqual(s[1].requests, 3)
        XCTAssertEqual(s[1].decodeTokensPerSecond, 25)   // median of 50, 25, 12.5
        XCTAssertEqual(s[1].prefillTokensPerSecond, 2048)
        XCTAssertEqual(s[1].draftedShare!, 150.0 / 303.0, accuracy: 1e-9)
        XCTAssertNil(s[0].draftedShare)
        XCTAssertNil(s[0].prefillTokensPerSecond)
    }

    func testLimit() {
        var j = SpeedJournal()
        let s = RequestStats(prompt: 1, cached: 0, firstTokenSeconds: 1, tokens: 1, decodeSeconds: 1, drafted: 0)
        for i in 0..<(SpeedJournal.limit + 10) { j.add(.init(date: Date(timeIntervalSince1970: Double(i)), model: "m", settings: "", stats: s)) }
        XCTAssertEqual(j.entries.count, SpeedJournal.limit)
        XCTAssertEqual(j.entries.first?.date, Date(timeIntervalSince1970: 10))
    }

    func testSettingsFromArguments() {
        XCTAssertEqual(SpeedJournal.settings(of: ["--kv-bits", "4", "--num-draft-tokens", "3", "--prefill-step-size", "512"]),
                       "KV 4-bit · MTP · prefill 512")
        XCTAssertEqual(SpeedJournal.settings(of: ["--num-draft-tokens", "0"]), "KV full")
        XCTAssertEqual(SpeedJournal.settings(of: ["--draft-model", "/x"]), "KV full · MTP")
        // As the server reads them: the last one wins, = and _ spellings.
        XCTAssertEqual(SpeedJournal.settings(of: ["--prefill-step-size", "512", "--decode-concurrency", "4",
                                                  "--prefill-step-size=64", "--kv_bits", "8"]),
                       "KV 8-bit · concurrency 4 · prefill 64")
        XCTAssertEqual(SpeedJournal.settings(of: ["--kv-bits", "4", "--num-draft-tokens", "3", "--num-draft-tokens", "0"]),
                       "KV 4-bit")
        // A flag without its value doesn't take the next flag as one.
        XCTAssertEqual(SpeedJournal.settings(of: ["--kv-bits", "--draft-model", "/x"]), "KV full · MTP")
    }
}
