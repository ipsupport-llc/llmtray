import Foundation
import LLMTrayCore

/// `LLMTray --run-tool <name> '<json args>'` (see LLMTrayApp.init).
enum ToolRunnerCLI {
    /// Every tool's declaration (all enabled) plus the default tool-use
    /// rule, as JSON -- for tool-calling evals against a model.
    static func dumpDefinitions() -> Never {
        Task { @MainActor in
            var settings = ChatSettings()
            settings.enabledTools = Set(ToolCatalog.entries.map(\.name))
            settings.enableImageGeneration = true
            let out: [String: Any] = ["tools": ChatToolbox().definitions(for: settings), "tool_use_policy": Profile.defaultToolUsePolicy]
            if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    static func run(name: String, json: String) -> Never {
        Task { @MainActor in
            let toolbox = ChatToolbox()
            var settings = ChatSettings()
            settings.enabledTools = Set(ToolCatalog.entries.map(\.name))
            let call = ToolCall(id: "cli", name: name, argumentsJSON: json)
            switch await toolbox.run(call, context: ToolContext(settings: settings, generatedImages: [])) {
            case .text(let text): print(text)
            case .generatedImage(_, _, _, let text), .imageForModel(_, let text): print(text)
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }
}
