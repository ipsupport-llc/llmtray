import AppKit
import Foundation
import LLMTrayCore

/// The in-app chat's one tool, `generate_image`: its declaration, the
/// per-turn limit, and running it through mflux. What each call returns to
/// the model is decided here; ChatClient only places the results in the
/// conversation (and unloads/reloads the chat model around generation).
@MainActor
final class ImageToolRunner: ChatTool {
    static let toolName = "generate_image"
    let name = ImageToolRunner.toolName
    var definition: [String: Any] { Self.declaration }

    static let declaration: [String: Any] = [
        "type": "function",
        "function": [
            "name": toolName,
            "description": "Generate an image from a text description using a local diffusion "
                + "model running on this Mac. Call this only when the user's latest message explicitly "
                + "asks for an image (draw, create, generate, sketch, or make a picture, illustration, "
                + "artwork, or photo). Never call it for greetings, small talk or questions.",
            "parameters": [
                "type": "object",
                "properties": [
                    "prompt": [
                        "type": "string",
                        "description": "A detailed visual description of the image to generate.",
                    ],
                    "width": [
                        "type": "integer",
                        "description": "Image width in pixels. Defaults to 1024.",
                    ],
                    "height": [
                        "type": "integer",
                        "description": "Image height in pixels. Defaults to 1024.",
                    ],
                ],
                "required": ["prompt"],
            ],
        ],
    ]

    let mflux: MfluxManager

    init(mflux: MfluxManager) {
        self.mflux = mflux
    }

    // Small tool-calling models (this feature was built against a 4B one)
    // can fail to treat a successful tool result as "done" and call
    // generate_image again unprompted -- confirmed live. This caps actual
    // generations per user turn, however often the model tries.
    private(set) var imagesThisTurn = 0
    let maxImagesPerTurn = 1

    /// A real new user turn (send / regenerate).
    func startTurn() {
        imagesThisTurn = 0
    }

    /// Whether this round will actually run mflux rather than only refuse
    /// -- so a model stuck repeating the call doesn't make the chat model
    /// unload/reload (or the "Generating image…" UI flash) for nothing.
    /// `chatImages`: an edit_image call that will only be refused (no
    /// image, a bad index) doesn't count.
    func willGenerate(_ calls: [ToolCall], settings: ChatSettings, chatImages: [(data: Data, prompt: String)] = []) -> Bool {
        calls.contains { call in
            Self.runsGenerator(call.name, settings) && (call.name != EditImageTool.toolName
                || EditImageTool.source(ChatToolbox.parseArguments(call.argumentsJSON), in: chatImages).image != nil)
        } && imagesThisTurn < maxImagesPerTurn && settings.enableImageGeneration
    }

    /// generate_image, and edit_image with an edit model set: the calls
    /// that run mflux.
    static func runsGenerator(_ name: String, _ settings: ChatSettings) -> Bool {
        name == toolName || name == EditImageTool.toolName && settings.imageEditModel != nil
    }

    static func clampedSide(_ value: Any?) -> Int {
        min(max((value as? Int) ?? 1024, 256), 2048)
    }

    func isOffered(_ settings: ChatSettings) -> Bool {
        settings.enableImageGeneration
    }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let settings = context.settings
        // Only *declared* while image generation is enabled, but a model
        // that saw generate_image calls earlier in the session keeps
        // emitting them from history after the toggle is turned off
        // (reported by a tester), and the server still parses them.
        guard settings.enableImageGeneration else {
            return .text(
                "Image generation is turned off in LLMTray's settings, so no image was "
                    + "generated. Do not call generate_image; answer in text, and if the user wants "
                    + "an image, tell them to enable image generation in settings first."
            )
        }
        guard imagesThisTurn < maxImagesPerTurn else {
            return .text(
                "Not generating another image -- one was already generated for this request "
                    + "and shown to the user. Do not call generate_image again unless the user sends a "
                    + "new message explicitly asking for a new or different image."
            )
        }
        let prompt = String(((arguments["prompt"] as? String) ?? "").prefix(4000))
        // Scales what the model asked for rather than replacing it, so a
        // deliberately non-square request keeps its aspect ratio --
        // MfluxManager.generate rounds to a multiple of 16 regardless.
        let scale = settings.imageQuality.scale
        // Model-supplied: clamped before any arithmetic (Int.max would trap
        // in the conversion; 20000 px would run the Mac out of memory).
        let width = Int(Double(Self.clampedSide(arguments["width"])) * scale)
        let height = Int(Double(Self.clampedSide(arguments["height"])) * scale)
        return await produce(prompt: prompt, width: width, height: height, model: settings.imageGenModel, images: [],
                             settings: settings, toolName: Self.toolName)
    }

    /// Runs mflux for generate_image or edit_image (the per-turn limit
    /// counts both) and words the result for the model.
    /// `note`: said first in the result (which image was edited).
    func produce(prompt: String, width: Int, height: Int, model: ImageGenModel, images: [Data],
                 settings: ChatSettings, toolName: String, note: String = "") async -> ToolResult {
        do {
            let start = Date()
            let image = try await mflux.generate(prompt: prompt, width: width, height: height, model: model, images: images)
            imagesThisTurn += 1
            return .generatedImage(
                image, seconds: Date().timeIntervalSince(start), prompt: prompt,
                text: note + "Image generated and already displayed to the user directly above your reply "
                    + (settings.modelSupportsVision
                        ? "-- you can't embed or link it; call view_image if you need to see it. "
                        : "-- you do not have the image data and cannot embed, link, or preview it yourself. ")
                    + "Do not write markdown image syntax (![...](...)) or any placeholder/fake URL for "
                    + "it. Just reply in plain text (e.g. briefly describe what you asked for), or say "
                    + "nothing else. Do not call \(toolName) again for this request unless the user "
                    + "explicitly asks for a new or different image."
            )
        } catch {
            return .text("Image generation failed: \(error.localizedDescription)")
        }
    }
}

/// `edit_image`: changes an image from this chat -- one the user attached
/// or one generated here -- following an instruction, with the profile's
/// edit model (FLUX.2 klein), which is separate from the one generating
/// new images. The result is a new image; the source stays.
@MainActor
final class EditImageTool: ChatTool {
    static let toolName = "edit_image"
    let name = EditImageTool.toolName
    let generator: ImageToolRunner

    init(generator: ImageToolRunner) {
        self.generator = generator
    }

    var definition: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": "Edit an image from this conversation (one the user attached or one generated here) "
                    + "with a local diffusion model: change, add or remove something, restyle it, change the "
                    + "background, and so on. Call this only when the user's latest message explicitly asks to "
                    + "change an existing image; to make a new image from scratch use generate_image.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "prompt": [
                            "type": "string",
                            "description": "What to change, as a clear instruction (e.g. \"make it night, keep everything else\").",
                        ],
                        "index": [
                            "type": "integer",
                            "description": "Which image of this conversation: 1 = the first one, counting attached and generated images. Omit for the latest.",
                        ],
                    ],
                    "required": ["prompt"],
                ],
            ],
        ]
    }

    func isOffered(_ settings: ChatSettings) -> Bool {
        settings.enableImageGeneration && settings.imageEditModel != nil
    }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let settings = context.settings
        guard settings.enableImageGeneration else {
            return .text(
                "Image generation is turned off in LLMTray's settings, so the image wasn't edited. Do not call "
                    + "edit_image; answer in text, and if the user wants an edit, tell them to enable image generation in settings first."
            )
        }
        guard let model = settings.imageEditModel else {
            return .text(
                "Image editing is turned off in LLMTray's settings. Do not call edit_image; tell the user "
                    + "to choose an image editing model in settings to edit images."
            )
        }
        guard generator.imagesThisTurn < generator.maxImagesPerTurn else {
            return .text(
                "Not editing -- an image was already made for this request and shown to the user. Do not call "
                    + "edit_image again unless the user sends a new message asking for another change."
            )
        }
        let (picked, refusal) = Self.source(arguments, in: context.chatImages)
        guard let source = picked else { return .text(refusal) }
        let instruction = String(((arguments["prompt"] as? String) ?? "").prefix(4000))
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .text("Say what to change in `prompt`.")
        }
        let pixels = NSBitmapImageRep(data: source.data).map { ($0.pixelsWide, $0.pixelsHigh) } ?? (1024, 1024)
        let size = EditCanvas.size(sourceWidth: pixels.0, sourceHeight: pixels.1, scale: settings.imageQuality.scale)
        let note = "Edited image \(source.index) of \(context.chatImages.count) (\(source.prompt.isEmpty ? "generated" : source.prompt)). "
        return await generator.produce(prompt: instruction, width: size.width, height: size.height, model: model,
                                       images: [source.data], settings: settings, toolName: name, note: note)
    }

    /// The image an edit_image call picks (1-based `index` over every image
    /// in the chat, the latest when omitted), or why there's none.
    static func source(_ arguments: [String: Any], in images: [(data: Data, prompt: String)])
        -> (image: (data: Data, prompt: String, index: Int)?, refusal: String) {
        guard !images.isEmpty else {
            return (nil, "There's no image in this conversation to edit. Ask the user to attach one, or use generate_image to make a new one.")
        }
        // Model-supplied: compared, never subtracted from (Int.min - 1 traps).
        // A string or a fraction isn't silently taken as "the latest".
        let requested = arguments["index"] as? Int
        guard arguments["index"] == nil || requested != nil, requested.map({ (1...images.count).contains($0) }) ?? true else {
            return (nil, "There are \(images.count) image(s) in this conversation, attached and generated; index must be an integer 1...\(images.count).")
        }
        let index = requested ?? images.count
        return ((images[index - 1].data, images[index - 1].prompt, index), "")
    }
}
