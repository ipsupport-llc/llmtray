import XCTest
@testable import LLMTrayCore

final class ServerLogWatchTests: XCTestCase {
    func testOutOfMemory() {
        var w = ServerLogWatch()
        let line = "ERROR:root:mlx_lm.server generation thread died: [METAL] Command buffer execution failed: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)\n"
        XCTAssertEqual(w.feed(line), [.generationThreadDied(
            reason: "[METAL] Command buffer execution failed: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)",
            outOfMemory: true)])
    }

    func testSplitAcrossChunks() {
        var w = ServerLogWatch()
        XCTAssertEqual(w.feed("INFO ok\nERROR:root:mlx_lm.server gener"), [])
        XCTAssertEqual(w.feed("ation thread died: boom\nTraceback"), [.generationThreadDied(reason: "boom", outOfMemory: false)])
        XCTAssertEqual(w.feed(" (most recent call last):\n"), [])
    }

    func testRealLogFormat() {
        var w = ServerLogWatch()
        let line = "2026-09-24 03:12:44,101 - ERROR - mlx_lm.server generation thread died: [metal::malloc] Attempting to allocate 21474836480 bytes which is greater than the maximum allowed buffer size\n"
        XCTAssertEqual(w.feed(line).first, .generationThreadDied(
            reason: "[metal::malloc] Attempting to allocate 21474836480 bytes which is greater than the maximum allowed buffer size",
            outOfMemory: true))
    }

    func testRefusedRequestsAndQuotesDontMatch() {
        var w = ServerLogWatch()
        XCTAssertEqual(w.feed("RuntimeError: generation thread died\n"), [])
        // Verbose logging puts whole request bodies on one line.
        XCTAssertEqual(w.feed(#"2026-09-24 03:12:44,101 - DEBUG - Incoming Request Body: {"messages": [{"content": "why 'mlx_lm.server generation thread died'?"}]}"# + "\n"), [])
        XCTAssertEqual(w.feed(#"2026-09-24 03:12:44,101 - DEBUG - Incoming Request Body: {"content": "2026 - ERROR - mlx_lm.server generation thread died: x"}"# + "\n"), [])
        // ... and pretty-printed, one field per line.
        XCTAssertEqual(w.feed("2026-09-24 03:12:44,101 - DEBUG - Incoming Request Body: {\n\t\"content\": \"2026-09-24 03:12:44,101 - ERROR - mlx_lm.server generation thread died: x\"\n}\n"), [])
    }

    func testLongExceptionLineStillDetected() {
        var w = ServerLogWatch()
        XCTAssertEqual(w.feed("2026-09-24 03:12:44,101 - ERROR - mlx_lm.server generation thread died: " + String(repeating: "x", count: 10_000)), [])
        XCTAssertEqual(w.feed(String(repeating: "y", count: 10_000) + "\n").count, 1)
    }

    func testPrefillProgressIsActivity() {
        var w = ServerLogWatch()
        XCTAssertEqual(w.feed("2026-09-27 10:01:02,345 - INFO - Prompt processing progress: 512/20480\n"), [.prefillProgress])
        XCTAssertEqual(w.feed("INFO:root:Prompt processing progress: 1024/20480\n"), [.prefillProgress])
        XCTAssertEqual(w.feed("2026-09-27 10:01:02,345 - INFO - Prefill step 2048 at 0 tokens, 512 at 20480 tokens (--prefill-memory-mb 900)\n"), [.prefillProgress])
        XCTAssertEqual(w.feed("2026-09-27 10:01:02,345 - WARNING - Prefill step down to 64 at 90000 tokens: prefill is slow.\n"), [.prefillProgress])
        // One per chunk, however many lines; split lines count once whole.
        XCTAssertEqual(w.feed("INFO:root:Prompt processing progress: 1/3\nINFO:root:Prompt processing progress: 2/3\nINFO:root:Prompt proc"), [.prefillProgress])
        XCTAssertEqual(w.feed("essing progress: 3/3\n"), [.prefillProgress])
    }

    func testPrefillProgressKeepsDeathEvents() {
        var w = ServerLogWatch()
        XCTAssertEqual(w.feed("INFO:root:Prompt processing progress: 512/1024\nERROR:root:mlx_lm.server generation thread died: boom\n"),
                       [.generationThreadDied(reason: "boom", outOfMemory: false), .prefillProgress])
    }

    func testQuotedProgressIsNotActivity() {
        var w = ServerLogWatch()
        XCTAssertEqual(w.feed(#"2026-09-27 10:01:02,345 - DEBUG - Incoming Request Body: {"content": "INFO:root:Prompt processing progress: 1/2"}"# + "\n"), [])
        XCTAssertEqual(w.feed("2026-09-27 10:01:02,345 - INFO - Prompt processing progress: soon\n"), [])
        XCTAssertEqual(w.feed("Prompt processing progress: 1/2\n"), [], "not a log record")
    }

    func testStallRule() {
        let t = Date(timeIntervalSince1970: 1000)
        // No bytes and no progress for longer than the threshold: stalled.
        XCTAssertTrue(StallRule.isStalled(lastByteAt: t, serverProgressAt: nil, now: t + 61, threshold: 60))
        XCTAssertFalse(StallRule.isStalled(lastByteAt: t, serverProgressAt: nil, now: t + 59, threshold: 60))
        // A slow prefill: no bytes for 74 s, but progress 10 s ago.
        XCTAssertFalse(StallRule.isStalled(lastByteAt: t, serverProgressAt: t + 64, now: t + 74, threshold: 60))
        // Progress that stopped (a wedged prefill) stalls too.
        XCTAssertTrue(StallRule.isStalled(lastByteAt: t, serverProgressAt: t + 5, now: t + 70, threshold: 60))
        // Old progress, from before this request's last byte, changes nothing.
        XCTAssertTrue(StallRule.isStalled(lastByteAt: t, serverProgressAt: t - 100, now: t + 61, threshold: 60))
        // Another request's progress keeps it alive only up to the ceiling.
        XCTAssertFalse(StallRule.isStalled(lastByteAt: t, serverProgressAt: t + 3590, now: t + 3599, threshold: 60, maxWait: 3600))
        XCTAssertTrue(StallRule.isStalled(lastByteAt: t, serverProgressAt: t + 3600, now: t + 3601, threshold: 60, maxWait: 3600))
    }

    func testStallRuleWaiting() {
        let t = Date(timeIntervalSince1970: 1000)
        // Queued behind another chat's long answer: its bytes 5 s ago keep
        // this one waiting, 20 minutes after it was sent.
        XCTAssertFalse(StallRule.isStalledWaiting(sentAt: t, serverActivityAt: t + 1195, now: t + 1200, timeout: 300))
        // Nothing from the server at all since it was sent: stalled.
        XCTAssertTrue(StallRule.isStalledWaiting(sentAt: t, serverActivityAt: nil, now: t + 301, timeout: 300))
        XCTAssertFalse(StallRule.isStalledWaiting(sentAt: t, serverActivityAt: nil, now: t + 299, timeout: 300))
        // Activity from before it was sent doesn't extend it.
        XCTAssertTrue(StallRule.isStalledWaiting(sentAt: t, serverActivityAt: t - 50, now: t + 301, timeout: 300))
        // Activity that stopped: stalled once the timeout passes after it.
        XCTAssertTrue(StallRule.isStalledWaiting(sentAt: t, serverActivityAt: t + 600, now: t + 901, timeout: 300))
        // Past the ceiling, stalled even with the server busy for others.
        XCTAssertTrue(StallRule.isStalledWaiting(sentAt: t, serverActivityAt: t + 3600, now: t + 3601, timeout: 300, maxWait: 3600))
        XCTAssertFalse(StallRule.isStalledWaiting(sentAt: t, serverActivityAt: t + 3590, now: t + 3599, timeout: 300, maxWait: 3600))
        XCTAssertEqual(StallRule.waitTimeout, 300)
        XCTAssertEqual(StallRule.maxWait, 3600)
    }

    func testUTF8SplitAcrossChunks() {
        let d = UTF8StreamDecoder()
        let bytes = Array("привет €𝄞".utf8)
        var out = ""
        for b in bytes { out += d.decode(Data([b])) }
        XCTAssertEqual(out, "привет €𝄞")
        XCTAssertEqual(d.decode(Data("ok".utf8)), "ok")
        XCTAssertEqual(d.decode(Data([0xFF, 0x41])), "\u{FFFD}A", "invalid bytes don't stall the stream")
    }

    func testRestartBudget() {
        var b = RestartBudget(limit: 3, window: 600)
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(b.take(now: t))
        XCTAssertTrue(b.take(now: t + 10))
        XCTAssertTrue(b.take(now: t + 20))
        XCTAssertFalse(b.take(now: t + 30))
        XCTAssertTrue(b.take(now: t + 600), "the first restart left the window")
        XCTAssertFalse(b.take(now: t + 601))
    }

    func testRequestStats() {
        var w = ServerLogWatch()
        let line = "2026-10-07 02:30:00,123 - INFO - Request stats: prompt=10 cached=2 first_token_s=0.500 tokens=4 decode_s=1.000 drafted=1\n"
        XCTAssertEqual(w.feed(line), [.requestStats(RequestStats(prompt: 10, cached: 2, firstTokenSeconds: 0.5, tokens: 4, decodeSeconds: 1, drafted: 1))])
        // Quoted in a logged request body: not a record.
        XCTAssertEqual(w.feed("    \"content\": \"Request stats: prompt=10 cached=2 first_token_s=0.5 tokens=4 decode_s=1 drafted=1\"\n"), [])
    }
}
