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

    func testEntriesGroupWhatHappened() {
        let log = """
        --- runtime ready ---
        /Users/x/site-packages/mlx_lm/server.py:3156: UserWarning: mlx_lm.server is not recommended for production
          warnings.warn(
        127.0.0.1 - - [17/Oct/2026 06:22:11] "POST /v1/chat/completions HTTP/1.1" 200 -
        2026-10-17 06:22:11,984 - INFO - Prompt Cache: 0 sequences, 0.00 GB
        2026-10-17 06:22:11,986 - INFO - Prompt processing progress: 256/521
        2026-10-17 06:22:12,795 - INFO - Request stats: prompt=521 cached=0 first_token_s=0.658 tokens=19 decode_s=0.153 drafted=0
        2026-10-17 06:22:13,000 - WARNING - Prompt cache: checkpoint skipped: no memory room
        2026-10-17 06:22:13,100 - WARNING - Prompt cache: checkpoint skipped: no memory room
        2026-10-17 06:22:14,000 - ERROR - Generation failed; the requests in work get the error: boom
        Traceback (most recent call last):
          File "/x/server.py", line 1, in <module>
            main()
        RuntimeError: boom
        127.0.0.1 - - [17/Oct/2026 06:22:15] "GET /v1/models HTTP/1.1" 200 -
        2026-10-17 06:22:16,000 - INFO - Starting httpd
        """
        let entries = ServerLogGrouping.entries(ServerLogParser.parse(log))
        XCTAssertEqual(entries.map(\.kind), [.event, .warning, .request, .warning, .error, .request, .line])
        XCTAssertEqual(entries[1].children.map(\.text), ["  warnings.warn("])
        XCTAssertEqual(entries[1].summary, "UserWarning: mlx_lm.server is not recommended for production")
        let request = entries[2]
        XCTAssertEqual(request.children.count, 3)
        XCTAssertEqual(request.stats?.prompt, 521)
        // Read: its progress is done with.
        XCTAssertNil(request.progress)
        XCTAssertEqual(entries[3].repeats, 2)
        XCTAssertEqual(entries[4].summary, "RuntimeError: boom")
        XCTAssertEqual(entries[4].context, "Generation failed; the requests in work get the error: boom")
        XCTAssertEqual(entries[4].children.count, 4)
        XCTAssertTrue(entries[5].children.isEmpty)
        XCTAssertEqual(entries.map(\.id), entries.map(\.head.id))
    }

    func testStatsWithSeveralOpenRequestsStayApart() {
        let log = """
        127.0.0.1 - - [17/Oct/2026 06:22:11] "POST /v1/chat/completions HTTP/1.1" 200 -
        127.0.0.1 - - [17/Oct/2026 06:22:11] "POST /v1/messages HTTP/1.1" 200 -
        2026-10-17 06:22:12,795 - INFO - Request stats: prompt=5 cached=0 first_token_s=0.1 tokens=2 decode_s=0.1 drafted=0
        """
        let entries = ServerLogGrouping.entries(ServerLogParser.parse(log))
        XCTAssertEqual(entries.map(\.kind), [.request, .request, .line])
        XCTAssertNil(entries[0].stats)
    }

    func testReviewedGroupingCases() {
        func kinds(_ log: String) -> [ServerLogEntry] { ServerLogGrouping.entries(ServerLogParser.parse(log)) }
        // Python's own warning shape repeated: one entry, ×2, one source line.
        let warn = kinds("""
        /x/server.py:1: UserWarning: careful
          warnings.warn(
        /x/server.py:1: UserWarning: careful
          warnings.warn(
        """)
        XCTAssertEqual(warn.count, 1)
        XCTAssertEqual(warn[0].repeats, 2)
        XCTAssertEqual(warn[0].children.count, 1)

        // Chained tracebacks: one error, the final cause as its summary.
        let chained = kinds("""
        2026-10-17 06:22:14,000 - ERROR - Generation failed: boom
        Traceback (most recent call last):
          File "a.py", line 1
        ValueError: first

        During handling of the above exception, another exception occurred:

        Traceback (most recent call last):
          File "b.py", line 2
        RuntimeError: second
        """)
        XCTAssertEqual(chained.map(\.kind), [.error])
        XCTAssertEqual(chained[0].summary, "RuntimeError: second")

        // A traceback cut off: the next ordinary line isn't its exception.
        let cut = kinds("""
        Traceback (most recent call last):
          File "a.py", line 1
        some unrelated output
        """)
        XCTAssertEqual(cut.map(\.kind), [.error, .line])

        // Overlapping requests don't stop later ones from getting their stats.
        let overlap = kinds("""
        127.0.0.1 - - [17/Oct/2026 06:22:11] "POST /v1/chat/completions HTTP/1.1" 200 -
        127.0.0.1 - - [17/Oct/2026 06:22:11] "POST /v1/messages HTTP/1.1" 200 -
        2026-10-17 06:22:12,000 - INFO - Request stats: prompt=5 cached=0 first_token_s=0.1 tokens=2 decode_s=0.1 drafted=0
        2026-10-17 06:22:12,500 - INFO - Request stats: prompt=6 cached=0 first_token_s=0.1 tokens=2 decode_s=0.1 drafted=0
        127.0.0.1 - - [17/Oct/2026 06:22:20] "POST /v1/chat/completions HTTP/1.1" 200 -
        2026-10-17 06:22:21,000 - INFO - Request stats: prompt=7 cached=0 first_token_s=0.1 tokens=2 decode_s=0.1 drafted=0
        """)
        XCTAssertEqual(overlap.last?.stats?.prompt, 7)

        // The server dying ends the request it was serving.
        let died = kinds("""
        127.0.0.1 - - [17/Oct/2026 06:22:11] "POST /v1/chat/completions HTTP/1.1" 200 -
        --- mlx_lm.server exited unexpectedly (code 9) ---
        2026-10-17 06:22:30,000 - INFO - Request stats: prompt=5 cached=0 first_token_s=0.1 tokens=2 decode_s=0.1 drafted=0
        """)
        XCTAssertNil(died[0].stats)
    }
}
