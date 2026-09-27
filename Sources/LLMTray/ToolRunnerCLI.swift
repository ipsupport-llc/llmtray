import Foundation
import LLMTrayCore

/// `LLMTray --run-tool <name> '<json args>'` (see LLMTrayApp.init).
enum ToolRunnerCLI {
    /// Every tool's declaration (all enabled, or with `defaultToolsOnly`
    /// the Default profile's) plus the default tool-use rule, as JSON --
    /// for tool-calling evals against a model (scripts/eval_tool_choice.py).
    static func dumpDefinitions(defaultToolsOnly: Bool = false) -> Never {
        Task { @MainActor in
            var settings = ChatSettings()
            if !defaultToolsOnly {
                settings.enabledTools = Set(ToolCatalog.entries.map(\.name))
                settings.enableImageGeneration = true
                settings.enableMusicGeneration = true
                settings.imageEditModel = .klein4b
                settings.modelSupportsVision = true
            }
            let toolbox = ChatToolbox()
            toolbox.stats = .inMemory()
            var tools = toolbox.definitions(for: settings)
            // project_files as a project with searchable files declares it
            // (it isn't a switch: it follows the chat's project).
            if !defaultToolsOnly, let files = ProjectFiles.definition(for: .all) { tools.append(files) }
            let modes = ["all": ProjectFiles.definition(for: .all) ?? [:], "listing": ProjectFiles.definition(for: .listing) ?? [:]]
            let out: [String: Any] = ["tools": tools, "tool_use_policy": Profile.defaultToolUsePolicy, "project_files_modes": modes]
            if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// How a call reads: `{"ok", "tool", "arguments", "repairs", "error"}`.
    static func check(name: String, json: String) -> Never {
        Task { @MainActor in
            let toolbox = ChatToolbox()
            toolbox.stats = .inMemory()
            var out: [String: Any] = ["ok": false]
            if let (tool, implied, nameRepair) = toolbox.resolve(name) {
                var parsed = ToolArgumentParser.parse(json, schema: tool.schema)
                for (key, value) in implied where parsed.values[key] == nil { parsed.values[key] = value }
                out["tool"] = tool.name
                out["arguments"] = parsed.values
                out["repairs"] = ((nameRepair.map { [$0] } ?? []) + parsed.repairs).map(\.rawValue)
                out["ok"] = parsed.isValid
                if let schema = tool.schema, let error = parsed.errorMessage(tool: schema) { out["error"] = error }
            } else {
                out["error"] = "no tool named \(name)"
            }
            if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
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
            toolbox.stats = .inMemory()
            var settings = ChatSettings()
            settings.enabledTools = Set(ToolCatalog.entries.map(\.name))
            let call = ToolCall(id: "cli", name: name, argumentsJSON: json)
            switch await toolbox.run(call, context: ToolContext(settings: settings, generatedImages: [])) {
            case .text(let text), .refused(let text): print(text)
            case .generatedImage(_, _, _, let text), .generatedAudio(_, _, _, let text), .imageForModel(_, let text): print(text)
            case .projectText(let output): print(output.rendered(byteBudget: 1 << 30).text)
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }
}
