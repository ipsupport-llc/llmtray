import XCTest
@testable import LLMTrayCore

final class ProcessRunnerTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testStreamingDeliversEveryLineInOrderBeforeReturning() async throws {
        let lines = Lines()
        // Many small lines, a ~1 MB line (a preview PNG in base64), and a
        // last line without a newline -- all before the call returns.
        let script = """
        for i in $(seq 1 200); do echo "line $i"; done
        head -c 750000 /dev/zero | base64 | tr -d '\\n'; echo
        echo "to stderr" >&2
        printf 'last'
        """
        try await ProcessRunner.runStreaming("/bin/sh", ["-c", script], onLine: { lines.add($0) })
        let got = lines.all
        XCTAssertEqual(got.count, 202, "200 short lines, the long one, and 'last' (no newline)")
        XCTAssertEqual(got.first, "line 1")
        XCTAssertEqual(got[199], "line 200")
        XCTAssertEqual(got[200].count, 1_000_000)
        XCTAssertEqual(got.last, "last")
    }

    func testStreamingFailureCarriesStderrTail() async {
        do {
            try await ProcessRunner.runStreaming("/bin/sh", ["-c", "echo out; echo 'boom' >&2; exit 3"], onLine: { _ in })
            XCTFail("expected a failure")
        } catch let failure as ProcessRunner.Failure {
            XCTAssertEqual(failure.status, 3)
            XCTAssertEqual(failure.outputTail, "boom")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRunnerMessages() {
        XCTAssertEqual(MfluxRunnerMessage(line: "@@LLMTRAY STEP 3 9"), .step(3, 9))
        XCTAssertEqual(MfluxRunnerMessage(line: "@@LLMTRAY IMAGE " + Data([1, 2, 3]).base64EncodedString()), .image(Data([1, 2, 3])))
        XCTAssertNil(MfluxRunnerMessage(line: "100%|██████████| 9/9"))
        XCTAssertNil(MfluxRunnerMessage(line: "@@LLMTRAY PREVIEW not-base64!"))
        XCTAssertNil(MfluxRunnerMessage(line: "@@LLMTRAY STEP x"))
    }
}
