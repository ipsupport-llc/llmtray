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
    // Generated music (16-bit WAV bytes), shown as players: in memory, and
    // persisted like images (a temporary chat's never touch disk). Same
    // index alignment for the three arrays after it.
    var audios: [Data] = []
    var audioPrompts: [String] = []
    // Wall-clock seconds each took to generate.
    var audioDurations: [Double] = []
    var audioFilenames: [String] = []
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
    // A message the app adds for the model only -- an image view_image put
    // in front of it. Not shown as a bubble, not saved with the session.
    var isToolContext: Bool = false
    // Credits of the data an answer's tools used (their results' "source",
    // e.g. ExchangeRate-API's required one). Saved with the session, where
    // the tool messages they come from aren't.
    var sources: [String] = []
    // The files a loaded session's images came from, same order: saved
    // again under these names (not the message's new id).
    var imageFilenames: [String] = []
}

extension ChatMessage {
    /// Each answer's credits: the "source" of the tool results of its turn
    /// (collected up to the answer that ends it), plus any it was saved with.
    static func sourcesByAnswer(_ messages: [ChatMessage]) -> [UUID: [String]] {
        var pending: [String] = []
        var out: [UUID: [String]] = [:]
        for msg in messages {
            switch msg.role {
            case "user" where !msg.isToolContext:
                pending = []
            case "tool" where msg.content.contains("\"source\""):
                if let obj = (try? JSONSerialization.jsonObject(with: Data(msg.content.utf8))) as? [String: Any],
                   let source = obj["source"] as? String, !pending.contains(source) {
                    pending.append(source)
                }
            case "assistant" where msg.toolCalls.isEmpty && !msg.content.isEmpty:
                let all = msg.sources + pending.filter { !msg.sources.contains($0) }
                if !all.isEmpty { out[msg.id] = all }
                pending = []
            default:
                break
            }
        }
        return out
    }
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
    var enableMusicGeneration: Bool = false
    var enabledTools: Set<String> = Set(Profile.defaultEnabledTools)
    var imageGenModel: ImageGenModel = .gptqMixed
    /// The model edit_image uses; nil = no editing.
    var imageEditModel: ImageGenModel?
    var unloadModelDuringImageGen: Bool = true
    var imageQuality: ImageQuality = .balanced
    /// The model the turn is for, and its max-tokens cap -- so the settings
    /// can be re-resolved mid-turn (a tool switched off stops at once).
    var modelPath: String?
    var maxTokensCap: Int = 32768
    /// The chat model accepts images (view_image is offered only then).
    var modelSupportsVision: Bool = false
    /// Appended to the system prompt whenever tools are offered.
    var toolUsePolicy: String = Profile.defaultToolUsePolicy

    /// The chat settings a model's profile resolves to.
    init(profile p: ResolvedProfile, maxTokensCap: Int) {
        temperature = p.temperature
        topP = p.topP
        topK = p.topK
        maxTokens = min(p.maxTokens, maxTokensCap)
        self.maxTokensCap = maxTokensCap
        systemPrompt = p.systemPrompt
        enableImageGeneration = p.enableImageGeneration
        enableMusicGeneration = p.enableMusicGeneration
        enabledTools = Set(p.enabledTools)
        imageGenModel = ImageGenModel(rawValue: p.imageGenModel) ?? .gptqMixed
        imageEditModel = ImageGenModel(rawValue: p.imageEditModel).flatMap { $0.supportsEditing ? $0 : nil }
        unloadModelDuringImageGen = p.unloadModelDuringImageGen
        imageQuality = ImageQuality(rawValue: p.imageQuality) ?? .balanced
        toolUsePolicy = p.toolUsePolicy
    }

    init() {}
}

extension ChatSettings {
    /// What a request for `modelID` is sent with: its profile (layered on
    /// Default), max tokens capped at the model's trained context. Shared by
    /// the chat view and compaction, which also runs with no view on screen.
    @MainActor
    static func forModel(_ modelID: String?, supportsVision: Bool, maxContext: Int? = nil) -> ChatSettings {
        let cap = maxContext ?? Self.maxContext(forModel: modelID)
        var settings = ChatSettings(profile: ProfileManager.shared.resolved(for: modelID), maxTokensCap: cap)
        settings.modelSupportsVision = supportsVision
        settings.modelPath = modelID
        return settings
    }

    /// The model's trained context ceiling (max_position_embeddings);
    /// 32768 only when its config.json doesn't say.
    static func maxContext(forModel modelID: String?) -> Int {
        max(64, modelID.flatMap(ModelDiscovery.maxContextLength(forModelPath:)) ?? 32768)
    }
}
