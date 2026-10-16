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
            // The folder tools as a saved chat with the feature on declares
            // them (adr/0014; a Settings switch, not a profile's).
            if !defaultToolsOnly { tools += [FolderTools.filesDefinition, FolderTools.changeDefinition] }
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
            // A document goes into the current folder (no chat to keep it).
            if name == MakeDocumentTool.toolName {
                let parsed = ToolArgumentParser.parse(json, schema: DocumentSpec.schema)
                if let schema = parsed.isValid ? nil : Optional(DocumentSpec.schema), let error = parsed.errorMessage(tool: schema) {
                    print(error)
                    exit(1)
                }
                // `--base <file>`: an earlier call (JSON) that `changes` change.
                let args = CommandLine.arguments
                let base = args.firstIndex(of: "--base").flatMap { j in j + 1 < args.count ? try? String(contentsOfFile: args[j + 1], encoding: .utf8) : nil }
                let values: [String: Any]
                var changed: [String] = []
                var earlier: String?
                switch DocumentEdit.resolve(parsed.values, documents: base.map { [(title: "", arguments: $0)] } ?? []) {
                case .success(let (v, notes, base)): values = v; changed = notes; earlier = base?.content
                case .failure(let problem): print(problem.text); exit(1)
                }
                switch DocumentSpec.read(values, earlier: earlier) {
                case .failure(let e): print(e.text); exit(1)
                case .success(var spec):
                    spec.adjusted = changed + spec.adjusted
                    let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    switch await DocumentRenderer.render(spec, source: DocumentSource(arguments: MakeDocumentTool.argumentsJSON(values), project: nil)) {
                    case .success(var made):
                        made.thumbnail = nil
                        guard let document = try? DocumentRenderer.install(made, in: here) else { print("couldn't write the PDF here"); exit(1) }
                        print(here.appendingPathComponent(document.filename).path + " (\(document.pages) pages)")
                        for note in spec.adjusted + spec.notes + made.notes { print("note: " + note) }
                        exit(0)
                    case .failure(let e): print(e.text); exit(1)
                    }
                }
            }
            let toolbox = ChatToolbox()
            toolbox.stats = .inMemory()
            var settings = ChatSettings()
            settings.enabledTools = Set(ToolCatalog.entries.map(\.name))
            let call = ToolCall(id: "cli", name: name, argumentsJSON: json)
            switch await toolbox.run(call, context: ToolContext(settings: settings, generatedImages: [])) {
            case .text(let text), .refused(let text): print(text)
            case .generatedImage(_, _, _, let text), .generatedAudio(_, _, _, let text), .imageForModel(_, let text): print(text)
            case .projectText(let output): print(output.rendered(byteBudget: 1 << 30).text)
            case .generatedDocument(_, let text), .loadedTools(_, _, let text), .mcp(_, let text, _): print(text)
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }
}
