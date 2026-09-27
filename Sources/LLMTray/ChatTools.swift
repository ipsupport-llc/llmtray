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
}

/// One tool the in-app chat offers the model: its declaration, when it's
/// offered, and running it.
@MainActor
protocol ChatTool: AnyObject {
    var name: String { get }
    var definition: [String: Any] { get }
    func isOffered(_ settings: ChatSettings) -> Bool
    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult
    /// A project tool opts in here: the trust barrier and the budget for
    /// file text then apply to it.
    var projectAccess: ProjectToolAccess { get }
}

extension ChatTool {
    var projectAccess: ProjectToolAccess { .none }
}

/// The chat's tools, by name.
@MainActor
final class ChatToolbox {
    let imageGeneration: ImageToolRunner
    let musicGeneration: MusicToolRunner
    private(set) var tools: [ChatTool] = []
    /// A project tool returned something in this turn: network tools and the
    /// generators are off until the user's next message (ToolTrust).
    private(set) var projectTextThisTurn = false
    /// The request had no room for more file text: search and read aren't
    /// declared for the rest of the turn.
    private(set) var fileTextRoomSpent = false
    /// Ids of the file text pieces sent this turn: not sent again.
    private var sentProjectHits: Set<String> = []

    /// `mflux`, `music`: the app's one image and one music generator, shared
    /// by every chat tab.
    init(mflux: MfluxManager? = nil, music: MusicManager? = nil) {
        imageGeneration = ImageToolRunner(mflux: mflux ?? MfluxManager())
        musicGeneration = MusicToolRunner(music: music ?? MusicManager())
        tools = [imageGeneration, EditImageTool(generator: imageGeneration), ViewImageTool(), musicGeneration]
            + ToolCatalog.makeTools()
    }

    func register(_ tool: ChatTool) {
        tools.append(tool)
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
        // After file text: nothing that reaches out (adr/0012), and no more
        // file text once there's no room for it.
        return tools.filter {
            $0.isOffered(settings) && !spent.contains($0.name)
                && (trustKind($0) != .guarded || ToolTrust.allowsGuarded(projectTextThisTurn: projectTextThisTurn))
                && !(fileTextRoomSpent && $0.projectAccess == .fileText)
        }.map(\.definition)
    }

    /// A real new user turn (per-turn limits reset).
    func startTurn() {
        imageGeneration.startTurn()
        musicGeneration.startTurn()
        projectTextThisTurn = false
        fileTextRoomSpent = false
        sentProjectHits = []
    }

    /// The names of the tools that return project text: their calls and
    /// results are left out of later turns' requests.
    var projectToolNames: Set<String> {
        Set(tools.filter { $0.projectAccess != .none }.map(\.name))
    }

    /// Which side of the trust barrier a tool is on.
    func trustKind(_ tool: ChatTool) -> ToolTrust.Kind {
        if tool.projectAccess != .none { return .project }
        if tool === imageGeneration || tool is EditImageTool || tool === musicGeneration { return .guarded }
        return ToolCatalog.entries.first { $0.name == tool.name }?.usesNetwork == true ? .guarded : .ordinary
    }

    func trustKind(ofCall name: String) -> ToolTrust.Kind {
        tools.first { $0.name == name }.map(trustKind) ?? .ordinary
    }

    /// The calls of a response refused before any of it runs (drafts, the
    /// generator queue, the model's unload): network and generator calls
    /// beside a project call, or after one returned this turn.
    func trustRefusals(_ calls: [ToolCall]) -> Set<String> {
        ToolTrust.refusedUpFront(calls.map { (id: $0.id, kind: trustKind(ofCall: $0.name)) },
                                 projectTextThisTurn: projectTextThisTurn)
    }

    /// A project tool's output as its tool result: at most its share of the
    /// room the next request has (`requestTokens`, the estimate of it so
    /// far), pieces sent earlier in this turn only named. With no safe
    /// room, the tool says so and search/read are no longer declared.
    func fitProjectResult(_ output: ProjectToolOutput, tool name: String, requestTokens: Int,
                          settings: ChatSettings) -> (text: String, returned: [Citation]) {
        guard let tokens = ProjectTextBudget.allowance(contextTokens: settings.maxTokensCap, requestTokens: requestTokens,
                                                       maxTokens: settings.maxTokens) else {
            if tools.first(where: { $0.name == name })?.projectAccess == .fileText { fileTextRoomSpent = true }
            return (ProjectTextBudget.noRoomText, [])
        }
        let fitted = output.rendered(byteBudget: ProjectTextBudget.bytes(forTokens: tokens), alreadySent: sentProjectHits)
        sentProjectHits.formUnion(fitted.returned.map(\.id))
        let returned = fitted.returned.map {
            Citation(project: output.project, doc: $0.doc, rev: $0.rev, page: $0.page, chunk: $0.chunk, name: $0.name)
        }
        return (fitted.text, returned)
    }

    func run(_ call: ToolCall, context: ToolContext) async -> ToolResult {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return .text("Unknown tool: \(call.name)")
        }
        // Checked again right before it runs (the round refused it up front
        // already): an earlier call of this round may have returned file text.
        if trustKind(tool) == .guarded, !ToolTrust.allowsGuarded(projectTextThisTurn: projectTextThisTurn) {
            return .refused(ToolTrust.refusal)
        }
        if tool.projectAccess != .none, tool.isOffered(context.settings) {
            // Whatever it answers -- file names count as file text too.
            defer { projectTextThisTurn = true }
            return await tool.run(Self.parseArguments(call.argumentsJSON), context: context)
        }
        // generate_image, edit_image and generate_music explain their own refusals (the model often keeps
        // calling it from history after it's turned off).
        guard tool.isOffered(context.settings) || tool === imageGeneration || tool is EditImageTool || tool === musicGeneration else {
            return .text("The tool \(call.name) isn't available in this chat. Answer without it.")
        }
        return await tool.run(Self.parseArguments(call.argumentsJSON), context: context)
    }

    static func parseArguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

/// Lets a vision-capable model look at an image it generated in this chat
/// (to check or describe its own result). The image goes to the model in
/// the next request only -- from memory, never a file.
@MainActor
final class ViewImageTool: ChatTool {
    let name = "view_image"

    var definition: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": "Look at an image you generated earlier in this conversation with generate_image, "
                    + "e.g. to check it matches the request or to describe it. Call it only when you need to see "
                    + "the image; you otherwise don't have its pixels.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "index": [
                            "type": "integer",
                            "description": "Which generated image: 1 = the first in this conversation. Omit for the latest.",
                        ],
                    ],
                ],
            ],
        ]
    }

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
