import XCTest
@testable import LLMTrayCore

final class OrphanScanTests: XCTestCase {
    // `ps -E -axww -o pid=,ppid=,rss=,command=`: rss in KiB, the environment
    // after the command.
    private let python = "/opt/homebrew/Cellar/python@3.14/3.14.4/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"

    private func server(pid: Int, ppid: Int, rss: Int = 17_000_000, env: String = "LLMTRAY_SERVER=1") -> String {
        "\(pid) \(ppid) \(rss) \(python) -m mlx_lm.server --model /Users/me/.llmtray/models/roman/gemma-4-E4B-it-mlx --port 18765 --model-alias gemma HOME=/Users/me \(env) PATH=/usr/bin"
    }

    func testOrphanedModelServer() {
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: server(pid: 4312, ppid: 1)), [
            OrphanProcess(kind: .modelServer, pid: 4312, residentBytes: 17_000_000 * 1024, model: "gemma-4-E4B-it-mlx"),
        ])
    }

    func testAnyPort() {
        let line = server(pid: 4312, ppid: 1).replacingOccurrences(of: "--port 18765", with: "--port 19000")
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: line).map(\.pid), [4312])
    }

    func testOrphanedImageRunner() {
        let line = "  977     1 25000000 \(python) /Users/me/Library/Application Support/LLMTray/runtime/llmtray_mflux_runner.py --width 1024 --height 1024 --steps 8 --model /Users/me/.llmtray/image-models/z-image-turbo --base-model z-image-turbo HF_HUB_OFFLINE=1 LLMTRAY_IMAGE_RUNNER=1"
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: line), [
            OrphanProcess(kind: .imageRunner, pid: 977, residentBytes: 25_000_000 * 1024, model: "z-image-turbo"),
        ])
    }

    func testRunningLLMTraysChildIsKept() {
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: server(pid: 4312, ppid: 2592)), [])
    }

    func testUsersOwnServerWithoutMarkerIsKept() {
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: server(pid: 4312, ppid: 1, env: "TERM=xterm")), [])
    }

    func testMarkerMustMatchExactly() {
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: server(pid: 4312, ppid: 1, env: "LLMTRAY_SERVER=10")), [])
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: server(pid: 4312, ppid: 1, env: "XLLMTRAY_SERVER=1")), [])
    }

    func testMarkerOnAnUnrelatedProcessIsIgnored() {
        // Inherited the environment (a shell a tool call started, say), but
        // isn't a model server or image runner.
        let lines = """
        600 1 3000 /bin/zsh -c sleep 600 LLMTRAY_SERVER=1
        601 1 3000 /bin/zsh -c sleep 600 LLMTRAY_IMAGE_RUNNER=1
        """
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: lines), [])
    }

    func testMarkerMustMatchTheKind() {
        // An image runner carrying only the server marker is neither.
        let line = "977 1 100 \(python) /x/llmtray_mflux_runner.py --model /m/z LLMTRAY_SERVER=1"
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: line), [])
    }

    func testMixedOutputAndJunkLines() {
        let lines = [
            "",
            "garbage",
            "    1     0  9000 /sbin/launchd",
            server(pid: 10, ppid: 1),
            server(pid: 11, ppid: 99),
            "  12     1  500 \(python) -m mlx_lm.server --model /m/qwen LLMTRAY_SERVER=1",
        ].joined(separator: "\n")
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: lines).map(\.pid), [10, 12])
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: lines).last?.model, "qwen")
    }

    func testNoModelArgument() {
        let line = "12 1 500 \(python) -m mlx_lm.server LLMTRAY_SERVER=1"
        XCTAssertEqual(OrphanScan.orphans(inPSOutput: line), [
            OrphanProcess(kind: .modelServer, pid: 12, residentBytes: 500 * 1024, model: nil),
        ])
    }
}
