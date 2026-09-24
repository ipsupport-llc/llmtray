import Foundation
import LLMTrayCore

struct ToolCall: Equatable {
    var id: String
    var name: String
    var argumentsJSON: String
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String   // "user" | "assistant" | "tool"
    var content: String = ""
    var reasoning: String = ""
    // Decoded image bytes from an OpenAI-shaped content-array delta
    // (type: "image_url", image_url: {url: "data:image/...;base64,..."})
    // OR appended directly once a generate_image tool call finishes (see
    // ChatClient.executeToolCalls). Held only in memory for as long as
    // this message exists -- never written to disk, so nothing needs
    // cleaning up when the chat is cleared or the app quits.
    var images: [Data] = []
    // Wall-clock seconds each entry in `images` took to generate, same
    // index alignment -- shown as a small caption under the image (a
    // rough per-image benchmark), and persisted alongside it (see
    // PersistedMessage.imageDurations).
    var imageDurations: [Double] = []
    // The generate_image prompt behind each entry in `images`, same index
    // alignment -- used to give the Save panel a filename derived from
    // what was actually asked for instead of a generic "image.png".
    var imagePrompts: [String] = []
    // Present on an assistant message that called one or more tools --
    // resent verbatim in the next request's message history, per the
    // OpenAI tool-calling protocol.
    var toolCalls: [ToolCall] = []
    // Present on a "tool" role message: which call (by id) this is the
    // result of. "tool" messages are protocol plumbing for the model, not
    // shown as their own chat bubble (see ContentView's chatArea).
    var toolCallID: String?
    // True for the single synthetic message compactSession() splices in
    // to replace a run of older messages -- styled distinctly in
    // chatBubble so it reads as "the app summarized this," not something
    // the assistant actually said.
    var isSummary: Bool = false
}

extension Array {
    /// Used for msg.imageDurations[safe: i] in ContentView -- images and
    /// their durations are meant to stay index-aligned, but an old
    /// resumed session predating imageDurations decodes that array as
    /// empty (see PersistedMessage), so a plain subscript would crash.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct ChatSettings {
    var temperature: Double = 0.6
    var topP: Double = 0.95
    /// 0 = top-k off.
    var topK: Int = 0
    var maxTokens: Int = 1024
    var systemPrompt: String = ""
    var enableImageGeneration: Bool = false
    var imageGenModel: ImageGenModel = .gptqMixed
    var unloadModelDuringImageGen: Bool = true
    var imageQuality: ImageQuality = .balanced
    /// Appended to the system prompt whenever tools are offered.
    var toolUsePolicy: String = Profile.defaultToolUsePolicy

    /// The chat settings a model's profile resolves to.
    init(profile p: ResolvedProfile, maxTokensCap: Int) {
        temperature = p.temperature
        topP = p.topP
        topK = p.topK
        maxTokens = min(p.maxTokens, maxTokensCap)
        systemPrompt = p.systemPrompt
        enableImageGeneration = p.enableImageGeneration
        imageGenModel = ImageGenModel(rawValue: p.imageGenModel) ?? .gptqMixed
        unloadModelDuringImageGen = p.unloadModelDuringImageGen
        imageQuality = ImageQuality(rawValue: p.imageQuality) ?? .balanced
        toolUsePolicy = p.toolUsePolicy
    }

    init() {}
}
