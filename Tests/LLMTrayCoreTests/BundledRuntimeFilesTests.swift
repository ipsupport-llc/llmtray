import XCTest

/// Every runner script in runtime/ ships in the app: scripts/build_app.sh
/// copies runtime files by name, and a runner left off that list fails only
/// in a built app (v0.9.3-beta.4 shipped without the spoken-answers runner).
final class BundledRuntimeFilesTests: XCTestCase {
    func testEveryRunnerScriptIsCopiedIntoTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build_app.sh"), encoding: .utf8)
        let runtime = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("runtime").path)
        let scripts = runtime.filter { $0.hasPrefix("llmtray_") && $0.hasSuffix(".py") }
        XCTAssertFalse(scripts.isEmpty)
        for name in scripts {
            XCTAssertTrue(script.contains("$REPO_ROOT/runtime/\(name)"), "\(name) isn't copied by scripts/build_app.sh")
        }
    }
}
