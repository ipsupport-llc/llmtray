import XCTest
@testable import LLMTrayCore

final class SupervisedProcessTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func sh(_ script: String, _ supervision: ProcessRunner.Supervision, lines: Lines = Lines(),
                    onLine: (@Sendable (String) -> Bool)? = nil) async throws -> ProcessRunner.SupervisedExit {
        try await ProcessRunner.runSupervised("/bin/sh", ["-c", script], supervision: supervision,
                                              onLine: onLine ?? { lines.add($0); return true })
    }

    private let roomy = ProcessRunner.Supervision(timeout: 20, maxStdoutBytes: 10 << 20)

    func testDeliversLinesAndExitStatus() async throws {
        let lines = Lines()
        let exit = try await sh("for i in 1 2 3; do echo \"line $i\"; done; echo oops >&2; printf last; exit 3", roomy, lines: lines)
        XCTAssertEqual(lines.all, ["line 1", "line 2", "line 3", "last"])
        XCTAssertEqual(exit.status, 3)
        XCTAssertNil(exit.signal)
        XCTAssertNil(exit.limit)
        XCTAssertEqual(exit.stderrTail, "oops")
        XCTAssertEqual(exit.stdoutBytes, 25)
    }

    func testEnvironmentIsPassed() async throws {
        let lines = Lines()
        _ = try await ProcessRunner.runSupervised("/bin/sh", ["-c", "echo $LLMTRAY_TEST_VALUE"], environment: ["LLMTRAY_TEST_VALUE": "42"],
                                                  supervision: roomy, onLine: { lines.add($0); return true })
        XCTAssertEqual(lines.all, ["42"])
    }

    func testOnlyStandardDescriptorsReachTheChild() async throws {
        // An inherited descriptor would keep the app's files and pipes open in
        // a hostile child. The ones here are inheritable (no FD_CLOEXEC).
        let open = (0..<8).map { _ in Darwin.open("/dev/null", O_RDONLY) }
        defer { open.forEach { close($0) } }
        let lines = Lines()
        _ = try await ProcessRunner.runSupervised("/bin/ls", ["/dev/fd"], supervision: roomy, onLine: { lines.add($0); return true })
        XCTAssertTrue(Set(["0", "1", "2"]).isSubset(of: Set(lines.all)))
        // ls opens a couple of its own, at the lowest numbers free.
        XCTAssertTrue(Set(lines.all).isDisjoint(with: Set(open.suffix(4).map(String.init))), "\(lines.all) vs \(open)")
    }

    func testTimeoutKillsTheWholeGroup() async throws {
        let lines = Lines()
        let start = Date()
        var s = roomy
        s.timeout = 0.5
        // A grandchild that would outlive its parent.
        let exit = try await sh("sleep 30 & echo $!; sleep 30", s, lines: lines)
        XCTAssertEqual(exit.limit, .timeout)
        XCTAssertEqual(exit.signal, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let grandchild = try XCTUnwrap(Int32(lines.all.first ?? ""))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(kill(grandchild, 0), -1, "the grandchild survived")
    }

    func testStdoutCap() async throws {
        var s = roomy
        s.maxStdoutBytes = 1 << 20
        let exit = try await sh("yes", s)
        XCTAssertEqual(exit.limit, .stdout)
        XCTAssertGreaterThan(exit.stdoutBytes, 1 << 20)
    }

    func testCallerCanStopIt() async throws {
        let count = Lines()
        let exit = try await sh("while true; do echo tick; done", roomy, onLine: { line in
            count.add(line)
            return count.all.count < 5
        })
        XCTAssertEqual(exit.limit, .stoppedByCaller)
        XCTAssertEqual(count.all.count, 5, "nothing is delivered after a stop")
    }

    func testCPULimitIsReported() async throws {
        let exit = try await sh("ulimit -t 1; while :; do :; done", roomy)
        XCTAssertEqual(exit.signal, SIGXCPU)
        XCTAssertEqual(exit.limit, .cpu)
    }

    /// A child that allocates ~800 MB and holds it (perl ships with macOS).
    private let hog = "/usr/bin/perl"
    private let hogArguments = ["-e", "my $x = 'a' x (800 * 1024 * 1024); sleep 10;"]

    func testFootprintPollingKillsAtTheLimit() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: hog))
        let s = ProcessRunner.Supervision(timeout: 20, maxStdoutBytes: 1 << 20, maxFootprintBytes: 200 << 20)
        let exit = try await ProcessRunner.runSupervised(hog, hogArguments, supervision: s, onLine: { _ in true })
        XCTAssertEqual(exit.limit, .memory)
        XCTAssertFalse(exit.jetsamApplied)
        XCTAssertGreaterThan(exit.peakFootprint, 200 << 20)
    }

    func testJetsamLimitWhenAvailable() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: hog))
        // No polling: only the kernel can stop it.
        let s = ProcessRunner.Supervision(timeout: 20, maxStdoutBytes: 1 << 20, jetsamLimitBytes: 200 << 20)
        let exit = try await ProcessRunner.runSupervised(hog, hogArguments, supervision: s, onLine: { _ in true })
        try XCTSkipUnless(exit.jetsamApplied, "posix_spawnattr_setjetsam_ext is not available here")
        XCTAssertEqual(exit.signal, SIGKILL)
        XCTAssertEqual(exit.limit, .memory)
        XCTAssertLessThan(exit.wallTime, 10)
    }

    func testCancellationKillsTheChild() async throws {
        let task = Task { try await self.sh("sleep 30", self.roomy) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }

    func testSpawnFailureThrows() async {
        do {
            _ = try await ProcessRunner.runSupervised("/nonexistent/binary", [], supervision: roomy, onLine: { _ in true })
            XCTFail("expected a spawn failure")
        } catch {
            XCTAssertTrue(error is POSIXError, "\(error)")
        }
    }
}
