import Foundation

/// What a tool call produced.
enum ToolResult {
    /// Only a tool result for the model (an answer, a refusal, an error).
    case text(String)
    /// A generated image, shown to the user, plus the tool result.
    case generatedImage(Data, seconds: Double, prompt: String, text: String)
    /// An image put in front of the model (view_image): sent with the next
    /// request, in memory only -- neither shown as a chat bubble nor saved.
    case imageForModel(Data, text: String)
}

/// What a tool may look at besides its arguments.
struct ToolContext {
    var settings: ChatSettings
    /// Images generated earlier in this conversation, oldest first.
    var generatedImages: [(data: Data, prompt: String)]
}

/// One tool the in-app chat offers the model: its declaration, when it's
/// offered, and running it.
@MainActor
protocol ChatTool: AnyObject {
    var name: String { get }
    var definition: [String: Any] { get }
    func isOffered(_ settings: ChatSettings) -> Bool
    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult
}

/// The chat's tools, by name.
@MainActor
final class ChatToolbox {
    let imageGeneration = ImageToolRunner()
    private(set) var tools: [ChatTool] = []

    init() {
        tools = [imageGeneration, ViewImageTool()] + ToolCatalog.makeTools()
    }

    func register(_ tool: ChatTool) {
        tools.append(tool)
    }

    /// Declarations for the request's `tools`.
    func definitions(for settings: ChatSettings) -> [[String: Any]] {
        tools.filter { $0.isOffered(settings) }.map(\.definition)
    }

    /// A real new user turn (per-turn limits reset).
    func startTurn() {
        imageGeneration.startTurn()
    }

    func run(_ call: ToolCall, context: ToolContext) async -> ToolResult {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return .text("Unknown tool: \(call.name)")
        }
        // generate_image explains its own refusals (the model often keeps
        // calling it from history after it's turned off).
        guard tool.isOffered(context.settings) || tool === imageGeneration else {
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
        let requested = arguments["index"] as? Int
        let index = requested.map { $0 - 1 } ?? images.count - 1
        guard images.indices.contains(index) else {
            return .text("There are \(images.count) generated image(s) in this conversation; index must be 1...\(images.count).")
        }
        let image = images[index]
        return .imageForModel(
            image.data,
            text: "Image \(index + 1) of \(images.count) (prompt: \"\(image.prompt)\") is attached to the next message for you to look at."
        )
    }
}
