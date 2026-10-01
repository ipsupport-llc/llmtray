import Foundation

/// `llmtray`'s command line (adr/0019 §4), parsed without a dependency:
/// a command, then its arguments and options in any order. `--opt value`
/// and `--opt=value` both work, `--` ends the options, and a lone `-` is an
/// argument (stdin). Pure, so every rule is a unit test.
public enum CLICommand: Equatable, Sendable {
    case status(json: Bool)
    case models(json: Bool)
    case start(model: String?)
    case stop
    case chat(ChatOptions)
    case pull(repo: String)
    case image(ImageOptions)
    case api
    case version
    /// `topic`: a command's name, nil for the overview.
    case help(topic: String?)

    public struct ChatOptions: Equatable, Sendable {
        /// The prompt's words joined; "-" or nil: read stdin (see readsStdin).
        public var prompt: String?
        public var model: String?
        public var system: String?
        public var showThinking = false
        /// Each streamed event as a JSON line instead of plain text.
        public var json = false

        public init(prompt: String? = nil, model: String? = nil, system: String? = nil, showThinking: Bool = false, json: Bool = false) {
            self.prompt = prompt
            self.model = model
            self.system = system
            self.showThinking = showThinking
            self.json = json
        }

        /// Whether the prompt comes from stdin: asked for with "-", or none
        /// given while something is piped in. nil: there's no prompt at all
        /// (none given, stdin a terminal) -- a usage error.
        public func readsStdin(stdinIsTerminal: Bool) -> Bool? {
            if prompt == "-" { return true }
            if prompt != nil { return false }
            return stdinIsTerminal ? nil : true
        }
    }

    public struct ImageOptions: Equatable, Sendable {
        public var prompt: String
        /// nil: ./llmtray-<timestamp>.png.
        public var output: String?
        public var width: Int?
        public var height: Int?
        public var model: String?

        public init(prompt: String, output: String? = nil, width: Int? = nil, height: Int? = nil, model: String? = nil) {
            self.prompt = prompt
            self.output = output
            self.width = width
            self.height = height
            self.model = model
        }
    }
}

public struct CLIUsageError: Error, Equatable, Sendable {
    public var message: String
    /// The command it's about, for its help.
    public var command: String?

    public init(_ message: String, command: String? = nil) {
        self.message = message
        self.command = command
    }
}

public enum CommandLineArguments {
    /// The commands `help` knows, in the order the overview lists them.
    public static let commands = ["status", "models", "start", "stop", "chat", "pull", "image", "api", "help"]

    /// `arguments`: without the program name.
    public static func parse(_ arguments: [String]) -> Result<CLICommand, CLIUsageError> {
        guard let first = arguments.first else { return .success(.help(topic: nil)) }
        switch first {
        case "--version", "-V", "version": return .success(.version)
        case "--help", "-h": return .success(.help(topic: nil))
        default: break
        }
        if first.hasPrefix("-") { return .failure(CLIUsageError("unknown option \(first)")) }
        let rest = Array(arguments.dropFirst())
        // `llmtray chat --help` is help, not a prompt.
        let beforeDashes = rest.firstIndex(of: "--").map { Array(rest[..<$0]) } ?? rest
        if beforeDashes.contains(where: { $0 == "--help" || $0 == "-h" }) {
            return .success(.help(topic: commands.contains(first) ? first : nil))
        }
        switch first {
        case "status": return simple(first, rest, flags: ["--json"]).map { .status(json: $0.flags.contains("--json")) }
        case "models": return simple(first, rest, flags: ["--json"]).map { .models(json: $0.flags.contains("--json")) }
        case "stop": return simple(first, rest).map { _ in .stop }
        case "api": return simple(first, rest).map { _ in .api }
        case "start":
            return simple(first, rest, maxArguments: 1).map { .start(model: $0.arguments.first) }
        case "pull":
            return simple(first, rest, maxArguments: 1).flatMap { parsed in
                guard let repo = parsed.arguments.first else { return .failure(CLIUsageError("pull: which model? e.g. llmtray pull mlx-community/Qwen3-4B-4bit", command: first)) }
                guard HubRepoName.isValid(repo) else {
                    return .failure(CLIUsageError("pull: \"\(repo)\" isn't a Hugging Face repo -- expected org/name", command: first))
                }
                return .success(.pull(repo: repo))
            }
        case "chat":
            return scan(first, rest, flags: ["--show-thinking", "--json"], options: ["--model", "--system"]).map { parsed in
                .chat(.init(prompt: parsed.arguments.isEmpty ? nil : parsed.arguments.joined(separator: " "),
                            model: parsed.options["--model"], system: parsed.options["--system"],
                            showThinking: parsed.flags.contains("--show-thinking"), json: parsed.flags.contains("--json")))
            }
        case "image":
            return scan(first, rest, options: ["-o", "--output", "--width", "--height", "--model"]).flatMap { parsed in
                let prompt = parsed.arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else { return .failure(CLIUsageError("image: what to draw? e.g. llmtray image \"a lighthouse at dusk\"", command: first)) }
                var options = CLICommand.ImageOptions(prompt: prompt, output: parsed.options["-o"] ?? parsed.options["--output"],
                                                      model: parsed.options["--model"])
                for (key, path) in [("--width", \CLICommand.ImageOptions.width), ("--height", \.height)] {
                    guard let text = parsed.options[key] else { continue }
                    guard let value = Int(text), (64...8192).contains(value) else {
                        return .failure(CLIUsageError("image: \(key) takes a size in pixels, e.g. 1024", command: first))
                    }
                    options[keyPath: path] = value
                }
                return .success(.image(options))
            }
        case "help":
            return simple(first, rest, maxArguments: 1).flatMap { parsed in
                guard let topic = parsed.arguments.first else { return .success(.help(topic: nil)) }
                guard commands.contains(topic) else { return .failure(CLIUsageError("help: no command \"\(topic)\"")) }
                return .success(.help(topic: topic))
            }
        default:
            return .failure(CLIUsageError("unknown command \"\(first)\""))
        }
    }

    private struct Parsed {
        var arguments: [String] = []
        var flags: Set<String> = []
        var options: [String: String] = [:]
    }

    private static func simple(_ command: String, _ rest: [String], flags: Set<String> = [], maxArguments: Int = 0) -> Result<Parsed, CLIUsageError> {
        scan(command, rest, flags: flags).flatMap { parsed in
            guard parsed.arguments.count <= maxArguments else {
                return .failure(CLIUsageError("\(command): unexpected \"\(parsed.arguments[maxArguments])\"", command: command))
            }
            return .success(parsed)
        }
    }

    private static func scan(_ command: String, _ rest: [String], flags: Set<String> = [], options: Set<String> = []) -> Result<Parsed, CLIUsageError> {
        var parsed = Parsed()
        var i = 0
        var optionsEnded = false
        while i < rest.count {
            let arg = rest[i]
            i += 1
            // "-" is stdin; a negative number isn't expected anywhere.
            guard !optionsEnded, arg.hasPrefix("-"), arg != "-" else {
                parsed.arguments.append(arg)
                continue
            }
            if arg == "--" {
                optionsEnded = true
                continue
            }
            let (name, inline): (String, String?) = {
                guard arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") else { return (arg, nil) }
                return (String(arg[..<eq]), String(arg[arg.index(after: eq)...]))
            }()
            if flags.contains(name) {
                guard inline == nil else { return .failure(CLIUsageError("\(command): \(name) takes no value", command: command)) }
                parsed.flags.insert(name)
            } else if options.contains(name) {
                if let inline {
                    parsed.options[name] = inline
                } else {
                    guard i < rest.count else { return .failure(CLIUsageError("\(command): \(name) needs a value", command: command)) }
                    parsed.options[name] = rest[i]
                    i += 1
                }
            } else {
                return .failure(CLIUsageError("\(command): unknown option \(name)", command: command))
            }
        }
        return .success(parsed)
    }

    // MARK: - Help

    /// The overview (`llmtray help`), or one command's (`llmtray help chat`).
    public static func help(_ topic: String?) -> String {
        guard let topic, let text = commandHelp[topic] else { return overview }
        return text
    }

    static let overview = """
        llmtray -- control LLMTray from the terminal

        Usage: llmtray <command> [options]

        Commands:
          status [--json]          The server's state, the loaded model, the API address
          models [--json]          The chat models in your models folder
          start [model]            Start the server (with this model, by name or path)
          stop                     Stop the server
          chat "prompt"            Ask the model; the answer streams as it's written
          pull <org/name>          Download a chat model from Hugging Face
          image "prompt"           Generate an image, saved as a PNG
          api                      The OpenAI-compatible endpoint, for other apps
          help [command]           This help, or a command's

          --version                LLMTray's version

        LLMTray is started in the background when it isn't running.
        Exit status: 0 ok, 1 error, 2 usage.
        """

    static let commandHelp: [String: String] = [
        "status": """
            Usage: llmtray status [--json]

            The server's state (stopped, starting, running, failed), the loaded and
            the selected model, and the OpenAI-compatible endpoint.

              --json    The status as JSON.
            """,
        "models": """
            Usage: llmtray models [--json]

            The chat models in LLMTray's models folder: the name to request each by,
            its size, and which is selected (*) and loaded.

              --json    The list as JSON.
            """,
        "start": """
            Usage: llmtray start [model]

            Starts the server, as Start in the menu bar does -- with this model when
            one is named (by its name in `llmtray models`, its folder name or its
            path; it becomes the selected one), else with the selected one. A
            running server switches to the named model. Waits until it's loaded.
            """,
        "stop": """
            Usage: llmtray stop

            Stops the server, as Stop in the menu bar does.
            """,
        "chat": """
            Usage: llmtray chat "prompt" [--model M] [--system S] [--show-thinking] [--json]
                   echo "prompt" | llmtray chat [options]

            Sends one message to the model and prints the answer as it streams. The
            server is started first when it's stopped. With "-" or no prompt and
            something piped in, the prompt is read from stdin.

              --model M          This model (by name or path) instead of the loaded one
              --system S         A system prompt
              --show-thinking    Also print the model's reasoning (to stderr)
              --json             Each event as a JSON line: {"content":...}, {"reasoning":...}
            """,
        "pull": """
            Usage: llmtray pull <org/name>

            Downloads a chat model from Hugging Face into the models folder, through
            LLMTray's download queue (the same as its Hugging Face browser). Ctrl-C
            stops watching; the download goes on in LLMTray.
            """,
        "image": """
            Usage: llmtray image "prompt" [-o out.png] [--width N] [--height N] [--model M]

            Generates an image with the image model set up in LLMTray's Settings,
            queued with the chat's own generations (and with the chat model unloaded
            meanwhile when Settings says so). Prints where the PNG was saved.

              -o, --output FILE  Where to save it (default: ./llmtray-<time>.png)
              --width N          Pixels (default 1024, scaled by the image quality setting)
              --height N         Pixels (default 1024, likewise)
              --model M          An image model: gptqMixed, gptq8bit, gptq4bit, klein4b
            """,
        "api": """
            Usage: llmtray api

            The OpenAI-compatible endpoint LLMTray serves, and how to point a client
            (an SDK, an agent, curl) at it.
            """,
        "help": """
            Usage: llmtray help [command]
            """,
    ]
}
