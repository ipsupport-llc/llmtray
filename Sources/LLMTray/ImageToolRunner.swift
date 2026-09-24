import Foundation

/// The in-app chat's one tool, `generate_image`: its declaration, the
/// per-turn limit, and running it through mflux. What each call returns to
/// the model is decided here; ChatClient only places the results in the
/// conversation (and unloads/reloads the chat model around generation).
@MainActor
final class ImageToolRunner {
    static let name = "generate_image"

    static let definition: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
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

    enum Result {
        /// Only a tool result for the model (a refusal, an error...).
        case message(String)
        /// A generated image, shown to the user, plus the tool result.
        case image(Data, seconds: Double, prompt: String, message: String)
    }

    let mflux = MfluxManager()

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
    func willGenerate(_ calls: [ToolCall], settings: ChatSettings) -> Bool {
        calls.contains { $0.name == Self.name } && imagesThisTurn < maxImagesPerTurn && settings.enableImageGeneration
    }

    func run(_ call: ToolCall, settings: ChatSettings) async -> Result {
        guard call.name == Self.name else {
            return .message("Unknown tool: \(call.name)")
        }
        // Only *declared* while image generation is enabled, but a model
        // that saw generate_image calls earlier in the session keeps
        // emitting them from history after the toggle is turned off
        // (reported by a tester), and the server still parses them.
        guard settings.enableImageGeneration else {
            return .message(
                "Image generation is turned off in LLMTray's settings, so no image was "
                    + "generated. Do not call generate_image; answer in text, and if the user wants "
                    + "an image, tell them to enable image generation in settings first."
            )
        }
        guard imagesThisTurn < maxImagesPerTurn else {
            return .message(
                "Not generating another image -- one was already generated for this request "
                    + "and shown to the user. Do not call generate_image again unless the user sends a "
                    + "new message explicitly asking for a new or different image."
            )
        }
        let arguments = Self.parseArguments(call.argumentsJSON)
        let prompt = (arguments["prompt"] as? String) ?? ""
        // Scales what the model asked for rather than replacing it, so a
        // deliberately non-square request keeps its aspect ratio --
        // MfluxManager.generate rounds to a multiple of 16 regardless.
        let scale = settings.imageQuality.scale
        let width = Int(Double((arguments["width"] as? Int) ?? 1024) * scale)
        let height = Int(Double((arguments["height"] as? Int) ?? 1024) * scale)
        do {
            let start = Date()
            let image = try await mflux.generate(prompt: prompt, width: width, height: height, model: settings.imageGenModel)
            imagesThisTurn += 1
            return .image(
                image, seconds: Date().timeIntervalSince(start), prompt: prompt,
                message: "Image generated and already displayed to the user directly above your reply "
                    + "-- you do not have the image data and cannot embed, link, or preview it yourself. "
                    + "Do not write markdown image syntax (![...](...)) or any placeholder/fake URL for "
                    + "it. Just reply in plain text (e.g. briefly describe what you asked for), or say "
                    + "nothing else. Do not call generate_image again for this request unless the user "
                    + "explicitly asks for a new or different image."
            )
        } catch {
            return .message("Image generation failed: \(error.localizedDescription)")
        }
    }

    private static func parseArguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}
