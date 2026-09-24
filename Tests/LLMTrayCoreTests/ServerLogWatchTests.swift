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
}
