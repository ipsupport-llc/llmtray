import Foundation
import LLMTrayCore

/// What a tool call produced.
enum ToolResult {
    /// Only a tool result for the model (an answer, a refusal, an error).
    case text(String)
    /// A call refused because this turn already had what it asks for (one
    /// image per request, say): shown to the model in this turn, left out
    /// of later turns' history -- read back there, "it refused" made small
    /// models think the image was never made, and call the tool in a loop.
    case refused(String)
    /// A generated image, shown to the user, plus the tool result.
    case generatedImage(Data, seconds: Double, prompt: String, text: String)
    /// Generated music (.m4a), shown to the user as a player, plus the tool result.
    case generatedAudio(Data, seconds: Double, prompt: String, text: String)
    /// An image put in front of the model (view_image): sent with the next
    /// request, in memory only -- neither shown as a chat bubble nor saved.
    case imageForModel(Data, text: String)
    /// Project file text or names (a project tool): fitted into the
    /// request's room by ChatToolbox.fitProjectResult, its hits kept for
    /// the answer's citations.
    case projectText(ProjectToolOutput)
}

/// What a tool gives the model of the chat's project files (adr/0012).
enum ProjectToolAccess {
    case none
    /// File names and statuses (list): file text for the trust barrier,
    /// but still declared when there's no room for more.
    case listing
    /// File text (search, read): not declared once the request has no
    /// room left for it.
    case fileText
}

/// What a tool may look at besides its arguments.
struct ToolContext {
    var settings: ChatSettings
    /// Images generated earlier in this conversation, oldest first.
    var generatedImages: [(data: Data, prompt: String)]
    /// Every image in this conversation, attached or generated, oldest
    /// first (edit_image).
    var chatImages: [(data: Data, prompt: String)] = []
    /// The chat the call is for (nil: a temporary chat): a project tool
    /// checks it's still in the turn's project.
    var chat: UUID? = nil
    /// Bytes of file text the next request has room for (ProjectTextBudget),
    /// measured before the call: a project tool sizes its answer to it, so
    /// a cut read's cursor points where the text stopped. nil: the hard cap.
    var projectTextBytes: Int? = nil
    /// False once a result found no room this turn: a project tool answers
    /// with its listing only (set by ChatToolbox).
    var fileTextAllowed = true
    /// This one call, unique (a model may repeat call ids): what a `once`
    /// folder grant is for.
    var callKey = UUID().uuidString
    /// Asks the user about a folder in the chat (a folder tool's grant
    /// prompt); nil answers: Stop or another chat.
    var askFolderAccess: FolderToolService.Ask? = nil
}

/// What a tool does in the user's folders (adr/0014).
enum FolderToolAccess {
    case none
    /// `files`: names and bounded contents -- untrusted text.
    case read
    /// `change_files`: proposes a plan, never runs it.
    case change
}

/// One tool the in-app chat offers the model: its declaration, when it's
/// offered, and running it.
@MainActor
protocol ChatTool: AnyObject {
    var name: String { get }
    var definition: [String: Any] { get }
    /// The declaration as data: the call's arguments are read against it
    /// (aliases, types, allowed values) before `run`, and a call that
    /// still can't be understood gets an error saying how to retry. nil:
    /// the JSON is read leniently, the fields as sent.
    var schema: ToolSchema? { get }
    func isOffered(_ settings: ChatSettings) -> Bool
    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult
    /// A project tool opts in here: the trust barrier and the budget for
    /// file text then apply to it.
    var projectAccess: ProjectToolAccess { get }
    /// A folder tool opts in here: the trust barrier (and, for reads, the
    /// budget) apply to it.
    var folderAccess: FolderToolAccess { get }
}

extension ChatTool {
    var projectAccess: ProjectToolAccess { .none }
    var folderAccess: FolderToolAccess { .none }
    var schema: ToolSchema? { nil }
}

/// The chat's tools, by name.
@MainActor
final class ChatToolbox {
    let imageGeneration: ImageToolRunner
    let musicGeneration: MusicToolRunner
    private(set) var tools: [ChatTool] = []
    /// What file text this turn has had back (project files, folder
    /// listings, change proposals): network tools and the generators are off
    /// after any of it, folder changes after a read, until the user's next
    /// message (ToolTrust).
    private(set) var turnTrust = ToolTrust.TurnState()
    var projectTextThisTurn: Bool { turnTrust.projectText }
    /// The request had no room for more file text: search and read aren't
    /// declared for the rest of the turn.
    private(set) var fileTextRoomSpent = false
    /// Ids of the file text pieces sent this turn: not sent again.
    private var sentProjectHits: Set<String> = []
    /// Calls read by `prepare` and not yet run: what their arguments came
    /// to, by call id (for the stats and the error a call gets).
    private var prepared: [String: Prepared] = [:]
    /// Where each call's outcome is counted (Settings > Server).
    var stats: ToolStatsStore = .shared

    /// Former tools, now a mode of another: a model that saw them earlier in
    /// the chat (or was tuned on them) still calls them.
    static let formerNames: [String: (tool: String, arguments: [String: String])] = [
        "get_current_date": ("get_current_time", [:]),
        "get_current_time_in_city": ("get_current_time", [:]),
        "news": ("web_search", ["source": "news"]),
        "hackernews": ("web_search", ["source": "hackernews"]),
        "get_wikipedia_summary": ("web_search", ["source": "wikipedia"]),
        "get_hourly_forecast": ("get_weather", ["kind": "hourly"]),
        "get_air_quality": ("get_weather", ["kind": "air"]),
        "get_sunrise_sunset": ("get_weather", ["kind": "sun"]),
        "get_public_holidays": ("get_country_info", ["about": "holidays"]),
        // The three project tools first planned (adr/0012), one tool now.
        "search_project_files": (ProjectFiles.toolName, [:]),
        "read_project_file": (ProjectFiles.toolName, [:]),
        "list_project_files": (ProjectFiles.toolName, [:]),
        // The folder tools first planned (adr/0014), `files` now.
        "list_dir": (FolderTools.filesName, [:]),
        "list_directory": (FolderTools.filesName, [:]),
        "file_info": (FolderTools.filesName, [:]),
    ]

    /// A call as read: the tool it means, its arguments, what was fixed and
    /// what couldn't be understood.
    struct Prepared {
        let tool: ChatTool?
        let arguments: ParsedToolArguments
        /// The call `prepare` handed back: read again, it's this one.
        var output: ToolCall? = nil
        var repairs: [ToolRepair] { arguments.repairs }
    }

    /// `mflux`, `music`: the app's one image and one music generator, shared
    /// by every chat tab.
    init(mflux: MfluxManager? = nil, music: MusicManager? = nil) {
        imageGeneration = ImageToolRunner(mflux: mflux ?? MfluxManager())
        musicGeneration = MusicToolRunner(music: music ?? MusicManager())
        tools = [imageGeneration, EditImageTool(generator: imageGeneration), ViewImageTool(), musicGeneration]
            + ToolCatalog.makeTools() + [ProjectFilesTool(), FilesTool(), ChangeFilesTool()]
    }

    func register(_ tool: ChatTool) {
        tools.append(tool)
    }

    /// The tool a call's name means (another case, a "functions." prefix, a
    /// former name), with the arguments that name implies.
    func resolve(_ called: String) -> (tool: ChatTool, implied: [String: String], repair: ToolRepair?)? {
        guard let resolved = ToolNameResolver.resolve(called, known: tools.map(\.name), former: Self.formerNames),
              let tool = tools.first(where: { $0.name == resolved.name }) else { return nil }
        return (tool, resolved.impliedArguments, resolved.repair)
    }

    /// Reads a call before anything acts on it (ChatClient: the generator
    /// checks, drafts, the saved source; `run`): the declared tool name and
    /// its arguments as the tool expects them, when they could be
    /// understood -- otherwise the call as sent, and `run` explains.
    func prepare(_ call: ToolCall) -> ToolCall {
        guard let (tool, implied, nameRepair) = resolve(call.name) else {
            prepared[call.id] = Prepared(tool: nil, arguments: ParsedToolArguments(values: [:], repairs: [], problems: []))
            return call
        }
        var parsed = ToolArgumentParser.parse(call.argumentsJSON, schema: tool.schema)
        for (key, value) in implied where parsed.values[key] == nil { parsed.values[key] = value }
        if let nameRepair { parsed.repairs.insert(nameRepair, at: 0) }
        // Its own output read again (ChatClient prepared it, then run):
        // what the first reading fixed still counts.
        if let earlier = prepared[call.id], let output = earlier.output, output.name == call.name,
           output.argumentsJSON == call.argumentsJSON {
            parsed.repairs = earlier.repairs + parsed.repairs.filter { !earlier.repairs.contains($0) }
        }
        var out = ToolCall(id: call.id, name: tool.name, argumentsJSON: call.argumentsJSON)
        if parsed.isValid, nameRepair != nil || !parsed.repairs.isEmpty || !implied.isEmpty,
           JSONSerialization.isValidJSONObject(parsed.values),
           let data = try? JSONSerialization.data(withJSONObject: parsed.values, options: [.sortedKeys, .withoutEscapingSlashes]) {
            out.argumentsJSON = String(decoding: data, as: UTF8.self)
        }
        prepared[call.id] = Prepared(tool: tool, arguments: parsed, output: out)
        return out
    }

    /// Whether `prepare` understood a call's arguments: one it didn't gets
    /// only `run`'s error -- no draft, no queue ticket, no unload.
    /// Read from the call itself, not the cache by id: a model may repeat ids.
    func understood(_ call: ToolCall) -> Bool {
        guard let tool = resolve(call.name)?.tool else { return true }   // unknown: runs nothing
        return ToolArgumentParser.parse(call.argumentsJSON, schema: tool.schema).isValid
    }

    /// A call refused before it could run (the per-response cap, the trust
    /// barrier, the turn's round limit, the user's skip): counted.
    func recordRefusal(_ call: ToolCall) {
        let entry = prepared.removeValue(forKey: call.id)
        let tool = entry?.tool ?? resolve(call.name)?.tool
        stats.record(tool: tool?.name, known: tool != nil, repairs: entry?.repairs ?? [], outcome: .refused)
    }

    /// Declarations for the request's `tools`: not the generators this turn
    /// has used up (a small model otherwise calls one again after its
    /// result, in a loop, until the round limit).
    func definitions(for settings: ChatSettings) -> [[String: Any]] {
        var spent: Set<String> = []
        if imageGeneration.imagesThisTurn >= imageGeneration.maxImagesPerTurn {
            spent.formUnion([ImageToolRunner.toolName, EditImageTool.toolName])
        }
        if musicGeneration.songsThisTurn >= musicGeneration.maxSongsPerTurn { spent.insert(MusicToolRunner.toolName) }
        // After file text: nothing that reaches out (adr/0012), no folder
        // change after a read (adr/0014), and no more file text once there's
        // no room for it.
        let allowGuarded = ToolTrust.allowsGuarded(turnTrust)
        let folderTools = Set(FolderTools.declared(featureOn: settings.folders != nil, temporaryChat: settings.folders?.temporary ?? true,
                                                   turn: turnTrust, fileTextRoomSpent: fileTextRoomSpent))
        return tools.compactMap { tool -> [String: Any]? in
            guard tool.isOffered(settings), !spent.contains(tool.name) else { return nil }
            // project_files by its mode (none once there's no room for file text).
            if let files = tool as? ProjectFilesTool { return files.definition(for: settings, fileTextAllowed: !fileTextRoomSpent) }
            if tool.folderAccess != .none { return folderTools.contains(tool.name) ? tool.definition : nil }
            guard !(fileTextRoomSpent && tool.projectAccess == .fileText) else { return nil }
            // A tool of several switches: its modes that may run now (the
            // local time stays after file text, the city lookup doesn't).
            if let selectable = tool as? SelectableTool { return selectable.definition(for: settings, allowGuarded: allowGuarded) }
            return trustKind(tool) != .guarded || allowGuarded ? tool.definition : nil
        }
    }

    /// A real new user turn (per-turn limits reset).
    func startTurn() {
        imageGeneration.startTurn()
        musicGeneration.startTurn()
        turnTrust = ToolTrust.TurnState()
        fileTextRoomSpent = false
        sentProjectHits = []
        prepared = [:]
    }

    /// The turn's request carries pinned file text (adr/0012, "Pinned
    /// files"): the barrier is down from its start, as after a project
    /// tool's result.
    func notePinnedText() {
        turnTrust.record(.project)
    }

    /// The names of the tools that return project or folder text: their
    /// calls and results are left out of later turns' requests.
    var projectToolNames: Set<String> {
        Set(tools.filter { $0.projectAccess != .none || $0.folderAccess != .none }.map(\.name))
    }

    /// The tools whose answer is sized to the request's room for file text.
    var budgetedToolNames: Set<String> {
        Set(tools.filter { $0.projectAccess != .none || $0.folderAccess == .read }.map(\.name))
    }

    /// Which side of the trust barrier a tool is on.
    func trustKind(_ tool: ChatTool) -> ToolTrust.Kind {
        if tool.projectAccess != .none { return .project }
        switch tool.folderAccess {
        case .read: return .folderRead
        case .change: return .folderChange
        case .none: break
        }
        if tool === imageGeneration || tool is EditImageTool || tool === musicGeneration { return .guarded }
        return ToolCatalog.entries.first { $0.name == tool.name }?.usesNetwork == true ? .guarded : .ordinary
    }

    /// A call's side of the barrier: for a tool of several switches, the
    /// mode it's for (the local time is ordinary, a city's lookup isn't).
    func trustKind(of call: ToolCall, settings: ChatSettings) -> ToolTrust.Kind {
        guard let tool = resolve(call.name)?.tool else { return .ordinary }
        if let selectable = tool as? SelectableTool {
            // From the call itself, never a cache by id: a response can
            // repeat an id, and the barrier mustn't read another call's mode.
            let arguments = ToolArgumentParser.parse(call.argumentsJSON, schema: tool.schema).values
            return ToolCatalog.usesNetwork(selectable.mode(for: arguments, settings)) ? .guarded : .ordinary
        }
        return trustKind(tool)
    }

    /// The calls of a response refused before any of it runs (drafts, the
    /// generator queue, the model's unload): network and generator calls
    /// beside a project or folder call, or after one returned this turn;
    /// folder changes beside a read, or after one.
    func trustRefusals(_ calls: [ToolCall], settings: ChatSettings) -> Set<String> {
        let batch = calls.map { (id: $0.id, kind: trustKind(of: $0, settings: settings)) }
        batchTrust = turnTrust
        for call in batch { batchTrust.record(call.kind) }
        return ToolTrust.refusedUpFront(batch, state: turnTrust)
    }

    /// What the batch `trustRefusals` read would leave: what its refused
    /// calls are told.
    private var batchTrust = ToolTrust.TurnState()

    /// What a call refused up front by the barrier is told.
    func trustRefusalText(_ call: ToolCall, settings: ChatSettings) -> String {
        ToolTrust.refusalText(for: trustKind(of: call, settings: settings), batchTrust)
    }

    /// A project tool's output as its tool result: at most its share of the
    /// room the next request has (`requestTokens`, the estimate of it so
    /// far), pieces sent earlier in this turn only named. With no safe
    /// room, the tool says so and file-text tools (project_files) are no longer declared.
    func fitProjectResult(_ output: ProjectToolOutput, tool name: String, requestTokens: Int,
                          settings: ChatSettings) -> (text: String, returned: [Citation]) {
        guard let tokens = ProjectTextBudget.allowance(contextTokens: settings.maxTokensCap, requestTokens: requestTokens,
                                                       maxTokens: settings.maxTokens) else {
            if tools.first(where: { $0.name == name })?.projectAccess == .fileText { fileTextRoomSpent = true }
            return (ProjectTextBudget.noRoomText, [])
        }
        let fitted = output.rendered(byteBudget: ProjectTextBudget.bytes(forTokens: tokens), alreadySent: sentProjectHits)
        sentProjectHits.formUnion(fitted.whole)
        let returned = fitted.returned.map {
            Citation(project: output.project, doc: $0.doc, rev: $0.rev, page: $0.page, chunk: $0.chunk, name: $0.name)
        }
        return (fitted.text, returned)
    }

    func run(_ call: ToolCall, context: ToolContext) async -> ToolResult {
        let call = prepare(call)
        let entry = prepared.removeValue(forKey: call.id)
        let repairs = entry?.repairs ?? []
        guard let tool = entry?.tool else {
            stats.record(tool: nil, known: false, repairs: [], outcome: .error("unknown_tool"))
            let available = definitions(for: context.settings).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            return .text(available.isEmpty ? "No tool named \(call.name), and no tools are available in this chat. Answer without one."
                         : "No tool named \(call.name). Available: \(available.joined(separator: ", ")).")
        }
        func finish(_ result: ToolResult, _ outcome: ToolCallStats.Outcome? = nil) -> ToolResult {
            stats.record(tool: tool.name, known: true, repairs: repairs, outcome: outcome ?? Self.outcome(of: result))
            return result
        }
        let arguments = entry?.arguments ?? ParsedToolArguments(values: [:], repairs: [], problems: [])
        // Checked again right before it runs (the round refused it up front
        // already): an earlier call of this round may have returned file text.
        let kind = trustKind(of: call, settings: context.settings)
        if !ToolTrust.allows(kind, turnTrust) {
            return finish(.refused(ToolTrust.refusalText(for: kind, turnTrust)))
        }
        if tool.projectAccess != .none || tool.folderAccess != .none, tool.isOffered(context.settings) {
            // Whatever it answers -- file names count as file text too.
            defer { turnTrust.record(kind) }
            if let problem = Self.argumentError(arguments, tool) { return finish(problem.result, .error(problem.kind)) }
            var context = context
            context.fileTextAllowed = !fileTextRoomSpent
            let result = await tool.run(arguments.values, context: context)
            // A folder read that found no room: no file text for the rest of the turn.
            if tool.folderAccess == .read, case .text(let text) = result, text == ProjectTextBudget.noRoomText { fileTextRoomSpent = true }
            return finish(result)
        }
        // generate_image, edit_image and generate_music explain their own refusals (the model often keeps
        // calling it from history after it's turned off).
        let generator = tool === imageGeneration || tool is EditImageTool || tool === musicGeneration
        guard tool.isOffered(context.settings) || generator else {
            return finish(.text("The tool \(call.name) isn't available in this chat. Answer without it."), .error("unavailable"))
        }
        guard tool.isOffered(context.settings) else {
            return finish(await tool.run(arguments.values, context: context), .error("unavailable"))
        }
        if let problem = Self.argumentError(arguments, tool) { return finish(problem.result, .error(problem.kind)) }
        // A mode switched off (web_search's news while only the web is on).
        if let selectable = tool as? SelectableTool {
            let mode = selectable.mode(for: arguments.values, context.settings)
            if !selectable.isModeOn(mode, context.settings) {
                let on = selectable.offeredEntries(context.settings).map(selectable.modeLabel)
                return finish(SelectableTool.error("\(tool.name): \(selectable.modeLabel(mode)) isn't switched on in this chat; "
                                                   + "available: \(on.joined(separator: ", "))"), .error("unavailable"))
            }
        }
        let result = await tool.run(arguments.values, context: context)
        // A web (or generator) result: no folder change is prompted by it this turn.
        if kind == .guarded { turnTrust.record(kind) }
        return finish(result)
    }

    /// The error for arguments that couldn't be understood, as the tool's
    /// results read (JSON for the selectable tools, text for the others).
    private static func argumentError(_ arguments: ParsedToolArguments, _ tool: ChatTool) -> (result: ToolResult, kind: String)? {
        guard let first = arguments.problems.first else { return nil }
        let message = tool.schema.flatMap { arguments.errorMessage(tool: $0) }
            ?? "\(tool.name): arguments must be one JSON object."
        return (tool is SelectableTool ? SelectableTool.error(message) : .text(message), first.statsKind)
    }

    /// How a result counts.
    static func outcome(of result: ToolResult) -> ToolCallStats.Outcome {
        switch result {
        case .refused: return .refused
        case .text(let text):
            if SelectableTool.isError(text) || text.hasPrefix(ProjectFiles.toolName + ":")
                || text.hasPrefix(FolderTools.filesName + ":") || text.hasPrefix(FolderTools.changeName + ":") { return .error("failed") }
            // The generators' and view_image's plain-text failures.
            let failed = ["failed", "There's no image", "No image has been", "index must be", "Say what to change", "Describe the style"]
            return failed.contains { text.contains($0) } ? .error("failed") : .success
        case .generatedImage, .generatedAudio, .imageForModel, .projectText: return .success
        }
    }

    /// A call's arguments, read leniently (a fence, single quotes, a
    /// trailing comma...); `{}` when they aren't an object at all.
    static func parseArguments(_ json: String) -> [String: Any] {
        guard case .success(let parsed) = LenientJSON.parse(json), let obj = parsed.value as? [String: Any] else { return [:] }
        return obj
    }
}

/// Lets a vision-capable model look at an image it generated in this chat
/// (to check or describe its own result). The image goes to the model in
/// the next request only -- from memory, never a file.
@MainActor
final class ViewImageTool: ChatTool {
    let name = "view_image"

    static let schema = ToolSchema("view_image", "Look at an image you generated in this chat, to check or describe it.", [
        .init("index", .integer, "1 = the first; omit for the latest.", aliases: ["image", "image_index", "n", "number"]),
    ])
    var schema: ToolSchema? { Self.schema }
    var definition: [String: Any] { Self.schema.definition }

    func isOffered(_ settings: ChatSettings) -> Bool {
        settings.enableImageGeneration && settings.modelSupportsVision
    }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let images = context.generatedImages
        guard !images.isEmpty else {
            return .text("No image has been generated in this conversation yet.")
        }
        // Model-supplied: compared, never subtracted from (Int.min - 1 traps).
        let requested = arguments["index"] as? Int
        guard requested.map({ (1...images.count).contains($0) }) ?? true else {
            return .text("There are \(images.count) generated image(s) in this conversation; index must be 1...\(images.count).")
        }
        let index = (requested ?? images.count) - 1
        let image = images[index]
        return .imageForModel(
            image.data,
            text: "Image \(index + 1) of \(images.count) (prompt: \"\(image.prompt)\") is attached to the next message for you to look at."
        )
    }
}
