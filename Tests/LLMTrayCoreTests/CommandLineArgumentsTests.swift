import XCTest
@testable import LLMTrayCore

final class CommandLineArgumentsTests: XCTestCase {
    private func parse(_ args: String...) -> CLICommand? {
        try? CommandLineArguments.parse(args).get()
    }

    private func usage(_ args: String...) -> CLIUsageError? {
        guard case .failure(let error) = CommandLineArguments.parse(args) else { return nil }
        return error
    }

    func testNoArgumentsIsTheOverview() {
        XCTAssertEqual(try CommandLineArguments.parse([]).get(), .help(topic: nil))
    }

    func testVersionAndHelp() {
        XCTAssertEqual(parse("--version"), .version)
        XCTAssertEqual(parse("-V"), .version)
        XCTAssertEqual(parse("version"), .version)
        XCTAssertEqual(parse("--help"), .help(topic: nil))
        XCTAssertEqual(parse("help"), .help(topic: nil))
        XCTAssertEqual(parse("help", "chat"), .help(topic: "chat"))
        XCTAssertEqual(parse("chat", "--help"), .help(topic: "chat"))
        XCTAssertEqual(parse("image", "a cat", "-h"), .help(topic: "image"))
        XCTAssertNotNil(usage("help", "frobnicate"))
        // After "--" it's the prompt, not a request for help.
        XCTAssertEqual(parse("chat", "--", "--help"), .chat(.init(prompt: "--help")))
    }

    func testStatusModelsStopApi() {
        XCTAssertEqual(parse("status"), .status(json: false))
        XCTAssertEqual(parse("status", "--json"), .status(json: true))
        XCTAssertEqual(parse("models", "--json"), .models(json: true))
        XCTAssertEqual(parse("stop"), .stop)
        XCTAssertEqual(parse("api"), .api)
        XCTAssertEqual(usage("stop", "now")?.message, "stop: unexpected \"now\"")
        XCTAssertEqual(usage("status", "--json=yes")?.message, "status: --json takes no value")
        XCTAssertEqual(usage("status", "--verbose")?.command, "status")
    }

    func testStart() {
        XCTAssertEqual(parse("start"), .start(model: nil))
        XCTAssertEqual(parse("start", "gemma-4"), .start(model: "gemma-4"))
        XCTAssertEqual(parse("start", "/Users/me/models/org/m"), .start(model: "/Users/me/models/org/m"))
        XCTAssertNotNil(usage("start", "a", "b"))
    }

    func testPullValidatesTheRepo() {
        XCTAssertEqual(parse("pull", "mlx-community/Qwen3-4B-4bit"), .pull(repo: "mlx-community/Qwen3-4B-4bit"))
        XCTAssertEqual(usage("pull")?.command, "pull")
        XCTAssertTrue(usage("pull", "Qwen3")?.message.contains("expected org/name") == true)
        XCTAssertNotNil(usage("pull", "../../etc/x"))
    }

    func testChat() {
        XCTAssertEqual(parse("chat", "Hello there"), .chat(.init(prompt: "Hello there")))
        // Unquoted words are one prompt.
        XCTAssertEqual(parse("chat", "Hello", "there"), .chat(.init(prompt: "Hello there")))
        XCTAssertEqual(parse("chat"), .chat(.init()))
        XCTAssertEqual(parse("chat", "-"), .chat(.init(prompt: "-")))
        XCTAssertEqual(parse("chat", "--model", "n4", "hi", "--system=Be brief", "--show-thinking", "--json"),
                       .chat(.init(prompt: "hi", model: "n4", system: "Be brief", showThinking: true, json: true)))
        XCTAssertEqual(usage("chat", "hi", "--model")?.message, "chat: --model needs a value")
        XCTAssertEqual(usage("chat", "hi", "--temperature", "1")?.message, "chat: unknown option --temperature")
    }

    func testChatReadsStdinOnlyWhenItShould() {
        XCTAssertEqual(CLICommand.ChatOptions(prompt: "-").readsStdin(stdinIsTerminal: true), true)
        XCTAssertEqual(CLICommand.ChatOptions(prompt: "hi").readsStdin(stdinIsTerminal: false), false)
        XCTAssertEqual(CLICommand.ChatOptions().readsStdin(stdinIsTerminal: false), true, "piped in")
        XCTAssertNil(CLICommand.ChatOptions().readsStdin(stdinIsTerminal: true), "nothing to read: a usage error")
    }

    func testImage() {
        XCTAssertEqual(parse("image", "a lighthouse"), .image(.init(prompt: "a lighthouse")))
        XCTAssertEqual(parse("image", "a", "lighthouse", "-o", "out.png", "--width", "512", "--height=768", "--model", "klein4b"),
                       .image(.init(prompt: "a lighthouse", output: "out.png", width: 512, height: 768, model: "klein4b")))
        XCTAssertEqual(parse("image", "x", "--output", "~/a.png"), .image(.init(prompt: "x", output: "~/a.png")))
        XCTAssertEqual(usage("image")?.command, "image")
        XCTAssertEqual(usage("image", "x", "--width", "wide")?.message, "image: --width takes a size in pixels, e.g. 1024")
        XCTAssertNotNil(usage("image", "x", "--height", "0"))
        XCTAssertNotNil(usage("image", "x", "--height", "100000"))
    }

    func testUnknownCommandsAndOptions() {
        XCTAssertEqual(usage("frobnicate")?.message, "unknown command \"frobnicate\"")
        XCTAssertEqual(usage("--frob")?.message, "unknown option --frob")
    }

    func testEveryCommandHasHelp() {
        for command in CommandLineArguments.commands {
            let text = CommandLineArguments.help(command)
            XCTAssertTrue(text.hasPrefix("Usage: llmtray \(command)"), command)
        }
        XCTAssertTrue(CommandLineArguments.help(nil).contains("Commands:"))
        for command in CommandLineArguments.commands where command != "help" {
            XCTAssertTrue(CommandLineArguments.help(nil).contains("  \(command)"), "the overview lists \(command)")
        }
    }
}
