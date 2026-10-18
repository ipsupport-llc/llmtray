import XCTest
@testable import LLMTrayCore

final class ServerLogParserTests: XCTestCase {
    func testKindsOfARealLog() {
        let log = """
        --- first run: setting up mlx-lm runtime (this can take a minute) ---
        /Users/x/site-packages/mlx_lm/server.py:3156: UserWarning: mlx_lm.server is not recommended for production
          warnings.warn(
        2026-10-17 06:21:55,047 - INFO - Starting httpd at 127.0.0.1 on port 18765...
        127.0.0.1 - - [17/Oct/2026 06:22:11] "POST /v1/chat/completions HTTP/1.1" 200 -
        2026-10-17 06:22:11,984 - INFO - Prompt Cache: 0 sequences, 0.00 GB
        2026-10-17 06:22:11,985 - INFO - - assistant: 0 sequences, 0.00 GB
        2026-10-17 06:22:11,986 - INFO - Prompt processing progress: 0/521
        2026-10-17 06:22:12,795 - INFO - Request stats: prompt=521 cached=0 first_token_s=0.658 tokens=19
        2026-10-17 06:22:13,000 - WARNING - Prompt cache: checkpoint skipped: no memory room
        2026-10-17 06:22:14,000 - ERROR - Generation failed; the requests in work get the error: boom
        Traceback (most recent call last):
          File "/x/server.py", line 1, in <module>
            main()
        RuntimeError: boom
        --- memory: a part of a chat couldn't be read (unreadable reply); given up after 3 tries ---
        127.0.0.1 - - [17/Oct/2026 06:22:15] "GET /v1/models HTTP/1.1" 404 -
        """
        let lines = ServerLogParser.parse(log)
        XCTAssertEqual(lines.map(\.kind), [
            .event, .warning, .warning, .info, .request, .cache, .cache, .progress, .stats,
            .warning, .error, .error, .error, .error, .error, .warning, .request,
        ])
        XCTAssertEqual(lines[3].time, "06:21:55")
        XCTAssertEqual(lines[3].message, "Starting httpd at 127.0.0.1 on port 18765...")
        XCTAssertEqual(lines[4].method, "POST")
        XCTAssertEqual(lines[4].path, "/v1/chat/completions")
        XCTAssertEqual(lines[4].status, 200)
        XCTAssertEqual(lines[16].status, 404)
        XCTAssertEqual(lines[0].message, "first run: setting up mlx-lm runtime (this can take a minute)")
        XCTAssertEqual(lines.map(\.id), Array(0..<lines.count))
    }

    func testReviewCases() {
        let log = """
        WARNING:root:Prompt cache: checkpoint skipped
        INFO:root:Request stats: prompt=3
        127.0.0.1 - - [17/Oct/2026 06:22:15] "POST /v1/chat/completions HTTP/1.1" 500 -
        --- mlx_lm.server exited unexpectedly (code 9) ---
        DEBUG body: {"error": "the warning was quoted"}
        --- a rule --- in model text
        Traceback (most recent call last):
          File "x.py", line 1
        2026-10-17 06:22:16,000 - INFO - Starting httpd
        """
        let lines = ServerLogParser.parse(log, firstID: 100)
        XCTAssertEqual(lines.map(\.kind), [.warning, .stats, .request, .warning, .info, .info, .error, .error, .info])
        XCTAssertTrue(lines[2].isError)
        XCTAssertEqual(lines.first?.id, 100)
        XCTAssertEqual(lines[3].message, "mlx_lm.server exited unexpectedly (code 9)")
        XCTAssertTrue(ServerLogParser.matches("Café ready", "cafe"))
    }

    func testEmptyAndPartialLines() {
        XCTAssertTrue(ServerLogParser.parse("").isEmpty)
        XCTAssertEqual(ServerLogParser.parse("half a line").first?.kind, .info)
    }
}
