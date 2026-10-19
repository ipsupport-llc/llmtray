import XCTest
@testable import LLMTrayCore

final class UsageLedgerTests: XCTestCase {
    func testClientNames() {
        XCTAssertEqual(UsageClient.name(userAgent: "x", fromApp: true, background: false), "LLMTray")
        XCTAssertEqual(UsageClient.name(userAgent: nil, fromApp: true, background: true), "LLMTray (background)")
        XCTAssertEqual(UsageClient.name(userAgent: "codex_cli_rs/0.47.0 (Mac OS 26.0.0; arm64)", fromApp: false, background: false), "Codex")
        XCTAssertEqual(UsageClient.name(userAgent: "claude-cli/2.1.3 (external, cli)", fromApp: false, background: false), "Claude Code")
        XCTAssertEqual(UsageClient.name(userAgent: "curl/8.7.1", fromApp: false, background: false), "curl")
        XCTAssertEqual(UsageClient.name(userAgent: "OpenAI/Python 1.99.0", fromApp: false, background: false), "OpenAI SDK (Python)")
        XCTAssertEqual(UsageClient.name(userAgent: "MyTool/3.1 (whatever)", fromApp: false, background: false), "MyTool")
        XCTAssertEqual(UsageClient.name(userAgent: "  ", fromApp: false, background: false), "Other")
        XCTAssertEqual(UsageClient.name(userAgent: nil, fromApp: false, background: false), "Other")
        XCTAssertEqual(UsageClient.name(userAgent: "(((", fromApp: false, background: false), "Other")
        XCTAssertEqual(UsageClient.name(userAgent: "customized-agent/1.0", fromApp: false, background: false), "customized-agent")
        XCTAssertEqual(UsageClient.name(userAgent: "ツール/1.0", fromApp: false, background: false), "Other")
        XCTAssertEqual(UsageClient.name(userAgent: "Zed/0.200", fromApp: false, background: false), "Zed")
    }

    func testStatsLineWithClient() {
        let line = "Request stats: prompt=10 cached=4 first_token_s=0.5 tokens=20 decode_s=1.0 drafted=0 client=Claude Code"
        XCTAssertEqual(RequestStats.parse(line)?.client, "Claude Code")
        XCTAssertNil(RequestStats.parse("Request stats: prompt=10 cached=4 first_token_s=0.5 tokens=20 decode_s=1.0 drafted=0")?.client)
        XCTAssertEqual(RequestStats.parse(line)?.tokens, 20)
        // Text after the numbers or the name doesn't lose the line.
        let base = "Request stats: prompt=10 cached=4 first_token_s=0.5 tokens=20 decode_s=1.0 drafted=0"
        XCTAssertEqual(RequestStats.parse(base + " ")?.tokens, 20)
        XCTAssertEqual(RequestStats.parse(base + " peak_mb=5")?.tokens, 20)
        XCTAssertNil(RequestStats.parse(base + " client=")?.client)
        XCTAssertEqual(RequestStats.parse(base + " client=Codex extra=1")?.client, "Codex extra")
    }

    func testSumsAndPeriods() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15
        var ledger = UsageLedger()
        func stats(_ client: String, prompt: Int = 1000, cached: Int = 500, tokens: Int = 101) -> RequestStats {
            RequestStats(prompt: prompt, cached: cached, firstTokenSeconds: 1, tokens: tokens, decodeSeconds: 2, drafted: 0, client: client)
        }
        ledger.record(stats("Codex"), model: "gemma", at: now, calendar: calendar)
        ledger.record(stats("Codex"), model: "gemma", at: now, calendar: calendar)
        ledger.record(stats("curl", prompt: 10, cached: 0, tokens: 3), model: "lfm", at: now.addingTimeInterval(-3 * 86400), calendar: calendar)
        ledger.record(stats("curl"), model: "gemma", at: now.addingTimeInterval(-30 * 86400), calendar: calendar)
        XCTAssertEqual(ledger.rows.count, 3)

        let today = ledger.lines(.today, by: .client, now: now, calendar: calendar)
        XCTAssertEqual(today.map(\.name), ["Codex"])
        XCTAssertEqual(today[0].counts.requests, 2)
        XCTAssertEqual(today[0].counts.cachedShare, 0.5)
        XCTAssertEqual(today[0].counts.decodeTokensPerSecond, 50)   // (101 - 1) / 2
        XCTAssertEqual(today[0].counts.prefillTokensPerSecond, 500)  // 500 uncached / 1 s

        let week = ledger.lines(.week, by: .model, now: now, calendar: calendar)
        XCTAssertEqual(week.map(\.name), ["gemma", "lfm"])
        // A short answer and prompt count, but not toward the speeds.
        XCTAssertNil(week[1].counts.decodeTokensPerSecond)
        XCTAssertNil(week[1].counts.prefillTokensPerSecond)

        XCTAssertEqual(UsageLedger.total(ledger.lines(.all, by: .model, now: now, calendar: calendar)).requests, 4)
        // A day after today (the clock moved back) isn't in Today.
        XCTAssertTrue(ledger.lines(.today, by: .day, now: now.addingTimeInterval(-86400), calendar: calendar).isEmpty)
        XCTAssertEqual(ledger.lines(.all, by: .day, now: now, calendar: calendar).map(\.name),
                       ["2027-01-15", "2027-01-12", "2026-12-16"])

        let round = try? JSONDecoder().decode(UsageLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(round, ledger)
        ledger.clear()
        XCTAssertTrue(ledger.rows.isEmpty)
    }
}
