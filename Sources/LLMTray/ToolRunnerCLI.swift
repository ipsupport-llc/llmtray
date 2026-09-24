import Foundation

/// `LLMTray --run-tool <name> '<json args>'` (see LLMTrayApp.init).
enum ToolRunnerCLI {
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
