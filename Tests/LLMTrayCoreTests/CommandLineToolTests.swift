import XCTest
@testable import LLMTrayCore

final class CommandLineToolTests: XCTestCase {
    private let target = "/Applications/LLMTray.app/Contents/Helpers/llmtray"

    func testInstallPlan() {
        XCTAssertEqual(CommandLineTool.installPlan(existing: .nothing, target: target), .create)
        XCTAssertEqual(CommandLineTool.installPlan(existing: .symlink(destination: target), target: target), .alreadyInstalled)
        // Our own link to a copy that moved, or an older one.
        XCTAssertEqual(CommandLineTool.installPlan(existing: .symlink(destination: "/Users/me/Downloads/LLMTray.app/Contents/Helpers/llmtray"),
                                                   target: target), .replace)
        // Someone else's llmtray stays.
        XCTAssertEqual(CommandLineTool.installPlan(existing: .symlink(destination: "/opt/homebrew/bin/llmtray"), target: target),
                       .refuseForeignLink("/opt/homebrew/bin/llmtray"))
        XCTAssertEqual(CommandLineTool.installPlan(existing: .other, target: target), .refuseFile)
    }

    func testUninstallPlan() {
        XCTAssertEqual(CommandLineTool.uninstallPlan(existing: .symlink(destination: target)), .remove)
        XCTAssertEqual(CommandLineTool.uninstallPlan(existing: .nothing), .nothingInstalled)
        XCTAssertEqual(CommandLineTool.uninstallPlan(existing: .symlink(destination: "/usr/local/bin/other")), .refuseForeign)
        XCTAssertEqual(CommandLineTool.uninstallPlan(existing: .other), .refuseForeign)
    }

    func testExistingOnDisk() throws {
        let dir = NSTemporaryDirectory() + "llmtray-link-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let link = dir + "/llmtray"
        XCTAssertEqual(CommandLineTool.existing(at: link), .nothing)
        // A dangling link (the app was deleted) is still a link.
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertEqual(CommandLineTool.existing(at: link), .symlink(destination: target))
        try FileManager.default.removeItem(atPath: link)
        FileManager.default.createFile(atPath: link, contents: Data("#!/bin/sh\n".utf8))
        XCTAssertEqual(CommandLineTool.existing(at: link), .other)
    }

    func testIsOnPath() {
        let home = "/Users/me"
        let dir = "/Users/me/.local/bin"
        XCTAssertTrue(CommandLineTool.isOnPath(dir, path: "/usr/bin:/Users/me/.local/bin:/bin", home: home))
        XCTAssertTrue(CommandLineTool.isOnPath(dir, path: "/usr/bin:/Users/me/.local/bin/", home: home))
        XCTAssertTrue(CommandLineTool.isOnPath(dir, path: "~/.local/bin:/usr/bin", home: home))
        XCTAssertTrue(CommandLineTool.isOnPath(dir, path: "$HOME/.local/bin", home: home))
        XCTAssertFalse(CommandLineTool.isOnPath(dir, path: "/usr/bin:/bin:/Users/me/.local/bin2", home: home))
        XCTAssertFalse(CommandLineTool.isOnPath(dir, path: "", home: home))
    }

    func testPathHintFollowsTheShell() {
        XCTAssertEqual(CommandLineTool.pathHint(shell: "/bin/zsh").file, "~/.zprofile")
        XCTAssertEqual(CommandLineTool.pathHint(shell: "/bin/bash").file, "~/.bash_profile")
        XCTAssertEqual(CommandLineTool.pathHint(shell: "/opt/homebrew/bin/fish").line, "fish_add_path $HOME/.local/bin")
        XCTAssertEqual(CommandLineTool.pathHint(shell: "/bin/ksh").file, "~/.profile")
        XCTAssertEqual(CommandLineTool.pathHint(shell: "/bin/zsh").line, "export PATH=\"$HOME/.local/bin:$PATH\"")
    }

    func testPathProbeSurvivesShellNoise() {
        let marker = CommandLineTool.pathProbeMarker
        XCTAssertEqual(CommandLineTool.parsePathProbe("Last login: today\n\(marker)/usr/bin:/bin\(marker)\n% "), "/usr/bin:/bin")
        XCTAssertNil(CommandLineTool.parsePathProbe("zsh: command not found"))
        XCTAssertTrue(CommandLineTool.pathProbeCommand.contains("$PATH"))
    }

    func testTheProbeCommandRunsInARealShell() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CommandLineTool.pathProbeCommand]
        process.environment = ["PATH": "/a:/b"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(CommandLineTool.parsePathProbe(output), "/a:/b")
    }

    func testAppBundleOfTheBinary() {
        XCTAssertEqual(CommandLineTool.appBundle(containing: target), "/Applications/LLMTray.app")
        XCTAssertEqual(CommandLineTool.appBundle(containing: "/Users/me/Downloads/LLMTray 2.app/Contents/Helpers/llmtray"),
                       "/Users/me/Downloads/LLMTray 2.app")
        XCTAssertNil(CommandLineTool.appBundle(containing: "/Users/me/llmtray/.build/debug/LLMTrayCLI"))
        XCTAssertNil(CommandLineTool.appBundle(containing: "/x/Contents/Helpers/llmtray"), "not inside an .app")
    }
}

final class CommandLineOutputTests: XCTestCase {
    private func status(_ state: String, model: String? = nil, selected: String? = nil, idle: Bool = false, message: String? = nil) -> ControlStatus {
        ControlStatus(state: state, message: message, model: model, modelPath: model.map { "/m/\($0)" }, selectedModel: selected,
                      port: 8765, idleUnloaded: idle, appVersion: "0.9.0", baseURL: ControlStatus.baseURL(port: 8765),
                      appTokenHeader: "X-LLMTray-App", appToken: "t")
    }

    func testStatusText() {
        let running = CommandLineOutput.status(status(ControlStatus.running, model: "gemma", selected: "gemma"))
        XCTAssertEqual(running, """
            LLMTray 0.9.0 -- server running
              model     gemma  (/m/gemma)
              API       http://127.0.0.1:8765/v1
            """)
        let stopped = CommandLineOutput.status(status(ControlStatus.stopped, selected: "n4"))
        XCTAssertTrue(stopped.contains("server stopped"))
        XCTAssertTrue(stopped.contains("selected  n4"))
        XCTAssertTrue(stopped.contains("llmtray start"), "says why the API doesn't answer")
        XCTAssertTrue(CommandLineOutput.status(status(ControlStatus.stopped, model: "g", idle: true)).contains("idle"))
        XCTAssertTrue(CommandLineOutput.status(status(ControlStatus.failed, message: "out of memory")).contains("failed: out of memory"))
    }

    func testModelsTable() {
        let text = CommandLineOutput.models([
            ControlModel(path: "/m/a", name: "gemma-4", displayName: "org/gemma-4", sizeBytes: 15_000_000_000, selected: true, loaded: true),
            ControlModel(path: "/m/b", name: "n4", displayName: "org/n4", sizeBytes: nil, selected: false, loaded: false),
        ])
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("* gemma-4"))
        XCTAssertTrue(lines[0].hasSuffix("loaded"))
        XCTAssertTrue(lines[1].hasPrefix("  n4     "), "names in one column")
        XCTAssertTrue(lines[1].contains("?"), "size not measured yet")
        XCTAssertTrue(CommandLineOutput.models([]).contains("llmtray pull"))
    }

    func testProgressLine() {
        XCTAssertEqual(CommandLineOutput.progress(0.5, "1 GB of 2"), "[##########----------]   50%  1 GB of 2")
        XCTAssertEqual(CommandLineOutput.progress(nil, "waiting"), "waiting")
        XCTAssertEqual(CommandLineOutput.progress(1.7, nil), "[####################]  100%")
    }

    func testDefaultImageName() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(CommandLineOutput.defaultImageName(at: date, timeZone: TimeZone(identifier: "UTC")!), "llmtray-20260921-141320.png")
    }

    func testApiText() {
        let text = CommandLineOutput.api(status(ControlStatus.running, model: "gemma"), exampleModel: "gemma")
        XCTAssertTrue(text.contains("export OPENAI_BASE_URL=http://127.0.0.1:8765/v1"))
        XCTAssertTrue(text.contains("\"model\": \"gemma\""))
        XCTAssertFalse(text.contains("isn't running"))
        XCTAssertTrue(CommandLineOutput.api(status(ControlStatus.stopped), exampleModel: nil).contains("llmtray start"))
    }

    func testApiErrors() {
        XCTAssertEqual(CommandLineOutput.apiError(status: 404, body: Data(#"{"error":{"message":"The model 'x' is not here"}}"#.utf8)),
                       "HTTP 404: The model 'x' is not here")
        XCTAssertEqual(CommandLineOutput.apiError(status: 503, body: Data(#"{"error":"busy"}"#.utf8)), "HTTP 503: busy")
        XCTAssertEqual(CommandLineOutput.apiError(status: 500, body: Data("oops\n".utf8)), "HTTP 500: oops")
        XCTAssertEqual(CommandLineOutput.apiError(status: 502, body: Data()), "HTTP 502")
    }

    func testChatRequestBody() throws {
        let plain = CLICommand.ChatOptions(prompt: "hi").requestBody(prompt: "hi")
        XCTAssertNil(plain["model"], "without --model the loaded model answers")
        XCTAssertEqual(plain["stream"] as? Bool, true)
        XCTAssertEqual((plain["messages"] as? [[String: Any]])?.count, 1)
        let full = CLICommand.ChatOptions(prompt: "hi", model: "n4", system: "Be brief").requestBody(prompt: "hi")
        XCTAssertEqual(full["model"] as? String, "n4")
        let messages = try XCTUnwrap(full["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: full))
    }
}
