import XCTest
@testable import LLMTrayCore

final class BackgroundAdmissionTests: XCTestCase {
    func testOneBackgroundRequestOnlyWhileNoForeground() {
        var a = BackgroundAdmission()
        let first = a.admitBackground()
        XCTAssertNotNil(first)
        XCTAssertNil(a.admitBackground(), "one at a time")
        a.backgroundEnded(first!)
        _ = a.foregroundBegan()
        XCTAssertNil(a.admitBackground(), "not while a foreground request is at the model")
        a.foregroundEnded()
        XCTAssertNotNil(a.admitBackground())
    }

    func testAForegroundRequestNamesTheBackgroundOneToPreempt() {
        var a = BackgroundAdmission()
        let id = a.admitBackground()!
        XCTAssertEqual(a.foregroundBegan(), id)
        XCTAssertEqual(a.foregroundBegan(), id, "a second one waits for it too")
        a.backgroundEnded(id)
        XCTAssertNil(a.background)
        XCTAssertNil(a.foregroundBegan())
        XCTAssertEqual(a.foreground, 3)
    }

    func testAStaleEndDoesntFreeANewerRequest() {
        var a = BackgroundAdmission()
        let old = a.admitBackground()!
        a.backgroundEnded(old)
        let new = a.admitBackground()!
        a.backgroundEnded(old)
        XCTAssertEqual(a.background, new)
    }

    func testForegroundCountNeverGoesNegative() {
        var a = BackgroundAdmission()
        a.foregroundEnded()
        XCTAssertEqual(a.foreground, 0)
        XCTAssertNotNil(a.admitBackground())
    }

    func testOutcomesFromTheProxysRefusals() {
        func body(_ code: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["error": ["message": "m", "code": code]])
        }
        XCTAssertEqual(BackgroundRequest.outcome(status: 503, body: body(BackgroundRequest.busyCode)), .busy)
        XCTAssertEqual(BackgroundRequest.outcome(status: 409, body: body(BackgroundRequest.notLoadedCode)), .notLoaded)
        XCTAssertEqual(BackgroundRequest.outcome(status: 503, body: body(BackgroundRequest.preemptedCode)), .preempted)
        XCTAssertEqual(BackgroundRequest.outcome(status: 400, body: body("other")), .failed("m"))
        XCTAssertEqual(BackgroundRequest.outcome(status: 502, body: Data("{\"error\":\"upstream stalled\"}".utf8)), .failed("upstream stalled"))
        XCTAssertEqual(BackgroundRequest.outcome(status: 500, body: Data()), .failed("HTTP 500"))
        XCTAssertTrue(BackgroundRequest.Outcome.preempted.isTransient)
        XCTAssertFalse(BackgroundRequest.Outcome.failed("x").isTransient)
    }

    func testStreamedContentReadsDeltasToTheEnd() {
        var s = StreamedContent()
        s.read(line: ": keep-alive")
        s.read(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#)
        s.read(line: #"data: {"choices":[{"delta":{"reasoning":"hmm"}}]}"#)
        s.read(line: #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#)
        s.read(line: #"data:{"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#)
        XCTAssertEqual(s.text, "Hello")
        XCTAssertEqual(s.finishReason, "stop")
        XCTAssertFalse(s.done)
        s.read(line: "data: [DONE]")
        XCTAssertTrue(s.done)
    }
}
