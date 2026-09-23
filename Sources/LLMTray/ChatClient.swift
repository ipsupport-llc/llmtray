import AppKit
import Combine
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
    /// 0 = not sent (top-k off).
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

@MainActor
final class ChatClient: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var lastTokensPerSecond: Double?
    @Published var errorText: String?
    // True while a generate_image tool call is actually running (mflux
    // bootstrap + generation) -- distinct from isStreaming since this
    // spans the gap between the tool-call-carrying response finishing and
    // the follow-up request (with the tool's result) starting. isBusy
    // covers both for UI gating.
    @Published private(set) var isGeneratingImage: Bool = false
    @Published private(set) var mfluxStatusText: String = ""
    // Mirrored from MfluxManager (see its stepProgress/previewImage docs)
    // for the same reason mfluxStatusText is -- ContentView only imports
    // this file's types, not MfluxManager's directly.
    @Published private(set) var mfluxStepProgress: (step: Int, total: Int)?
    @Published private(set) var mfluxPreviewImage: NSImage?
    // True only during the explicit, Settings-initiated warm-up download
    // (see downloadImageModel) -- distinct from isGeneratingImage (a real
    // chat-triggered generation) and NOT included in isBusy, since it's
    // driven from Settings, not the chat input, and shouldn't block
    // sending an unrelated message while it runs in the background.
    @Published private(set) var isDownloadingModel: Bool = false

    // nil means "temporary chat" (see newTemporaryChat()) -- nothing about
    // this conversation is ever written to ChatSessionStore. Non-nil means
    // persistCurrentSession() writes a session file after every completed
    // turn, keyed by this id.
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var currentSessionTitle: String = ""
    private var sessionCreatedAt: Date?

    var isBusy: Bool { isStreaming || isGeneratingImage }

    private let mfluxManager = MfluxManager()
    private var mfluxStatusCancellable: AnyCancellable?
    private var mfluxProgressCancellable: AnyCancellable?
    private var mfluxPreviewCancellable: AnyCancellable?

    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var sseBuffer: String = ""
    // Set directly in the nonisolated URLSession delegate callback below, at
    // the real moment the first byte arrives on the network -- not inside
    // the `Task { @MainActor in ... }` that processes it. That dispatched
    // Task can lag behind the actual network event when the main thread is
    // busy (e.g. re-rendering the chat bubble on every streamed delta), and
    // measuring from a delayed dispatch point silently compresses the
    // apparent elapsed time toward zero, which is what was inflating tok/s
    // to nonsense values.
    nonisolated(unsafe) private var firstByteDate: Date?
    // HTTP status of the in-flight chat response, and its body when that
    // status isn't 2xx. mlx_lm.server reports request errors (e.g. an image
    // sent to a model without vision) as a plain JSON `{"error": ...}` body,
    // not SSE -- previously those bytes went into the SSE parser, matched no
    // `data:` line, and the turn silently ended with an empty assistant
    // bubble and no error shown. Set in the nonisolated delegate callbacks,
    // same as firstByteDate (URLSession serializes those per task).
    nonisolated(unsafe) private var responseStatusCode: Int?
    nonisolated(unsafe) private var errorResponseBody = Data()
    // See resetConversationState(): async continuations capture this and
    // drop their result if the conversation was replaced meanwhile.
    private var conversationEpoch = 0
    private var approxCompletionTokens: Int = 0
    private var usageCompletionTokens: Int?
    private var assistantMessageIndex: Int?

    private struct RequestContext {
        var port: Int
        var modelAlias: String
        var settings: ChatSettings
        var server: ServerManager
    }
    private var pendingRequestContext: RequestContext?
    // Small tool-calling models (this feature was built against a 4B one)
    // can fail to treat a successful tool result as "done" and just call
    // generate_image again unprompted -- confirmed live. This caps actual
    // generations per user turn regardless of how many times the model
    // tries, resetting whenever a real new turn starts (send/regenerate).
    private var imagesGeneratedThisTurn = 0
    private let maxImagesPerTurn = 1

    private static let generateImageTool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "generate_image",
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

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        mfluxStatusCancellable = mfluxManager.$statusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.mfluxStatusText = $0 }
        mfluxProgressCancellable = mfluxManager.$stepProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.mfluxStepProgress = $0 }
        mfluxPreviewCancellable = mfluxManager.$previewImage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.mfluxPreviewImage = $0 }
        // Every launch starts a fresh persistent session by default (see
        // ChatSessionStore) -- picking up an older one is an explicit
        // History action (ContentView), and newTemporaryChat() is the
        // opt-out for a one-off that shouldn't be logged at all.
        newSession()
    }

    // MARK: - Sessions

    /// Starts a brand-new persistent session -- nothing is written to disk
    /// until the first completed turn (see persistCurrentSession()), so an
    /// abandoned empty session never litters the sessions directory.
    func newSession() {
        resetConversationState()
        messages.removeAll()
        currentSessionID = UUID()
        currentSessionTitle = ""
        sessionCreatedAt = Date()
    }

    /// Nothing typed or generated in this chat is ever written anywhere --
    /// currentSessionID stays nil, so persistCurrentSession() is a no-op
    /// for the whole lifetime of this conversation.
    func newTemporaryChat() {
        resetConversationState()
        messages.removeAll()
        currentSessionID = nil
        currentSessionTitle = ""
        sessionCreatedAt = nil
    }

    /// Everything that must not survive a switch to a different
    /// conversation. The New chat / History controls stay enabled while a
    /// turn is still running (by design -- so you can leave a slow one), and
    /// several steps of a turn are async (mflux image generation takes tens
    /// of seconds and can't be cancelled; compaction awaits its own
    /// request). Those continuations used to resume into whatever
    /// `messages` held by then: a generated image + tool result appended
    /// into the NEW session and a follow-up request sent from it (the model
    /// continued the old conversation there), or an old session's
    /// compaction summary spliced into the new one and saved into its file
    /// -- the "context leaks between chat sessions" a tester reported.
    /// Bumping `conversationEpoch` makes every such continuation discard its
    /// result; dropping `task` makes late SSE callbacks from the cancelled
    /// stream ignorable (see the taskIdentifier checks in the delegate).
    private func resetConversationState() {
        cancel()
        task = nil
        conversationEpoch += 1
        assistantMessageIndex = nil
        pendingRequestContext = nil
        sseBuffer = ""
        errorText = nil
        lastTokensPerSecond = nil
        imagesGeneratedThisTurn = 0
    }

    func loadSession(_ file: ChatSessionFile) {
        resetConversationState()
        let imagesDir = ChatSessionStore.imagesDir(for: file.id)
        messages = file.messages.map { pm in
            let images = pm.imageFilenames.compactMap { FileManager.default.contents(atPath: imagesDir + "/" + $0) }
            return ChatMessage(
                role: pm.role, content: pm.content, reasoning: pm.reasoning, images: images,
                imageDurations: pm.imageDurations, imagePrompts: pm.imagePrompts, isSummary: pm.isSummary
            )
        }
        currentSessionID = file.id
        currentSessionTitle = file.title
        sessionCreatedAt = file.createdAt
    }

    /// Called after every turn that ends with no pending tool call (see
    /// continueWithPendingToolCalls) -- a no-op for a temporary chat
    /// (currentSessionID == nil). "tool" role messages are dropped; a
    /// content-less assistant message is only dropped if it also carries
    /// no image (an image-only tool-call-carrier message is real content
    /// now that images are persisted, not plumbing to discard).
    private func persistCurrentSession() {
        guard let sessionID = currentSessionID else { return }
        let imagesDir = ChatSessionStore.imagesDir(for: sessionID)
        var pendingImageWrites: [(path: String, data: Data)] = []

        let persisted = messages.compactMap { msg -> PersistedMessage? in
            guard msg.role != "tool" else { return nil }
            if msg.role == "assistant", msg.content.isEmpty, msg.reasoning.isEmpty, msg.images.isEmpty { return nil }
            // Keyed by this message's own (stable for its lifetime) id, so
            // re-persisting the same session after a later turn doesn't
            // re-derive different filenames for images already on disk.
            let filenames = msg.images.enumerated().map { i, _ in "\(msg.id.uuidString)-\(i).png" }
            for (i, data) in msg.images.enumerated() {
                pendingImageWrites.append((imagesDir + "/" + filenames[i], data))
            }
            return PersistedMessage(
                role: msg.role, content: msg.content, reasoning: msg.reasoning, isSummary: msg.isSummary,
                imageFilenames: filenames, imageDurations: msg.imageDurations, imagePrompts: msg.imagePrompts
            )
        }
        guard !persisted.isEmpty else { return }

        if !pendingImageWrites.isEmpty {
            try? FileManager.default.createDirectory(atPath: imagesDir, withIntermediateDirectories: true)
            for (path, data) in pendingImageWrites where !FileManager.default.fileExists(atPath: path) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }

        if currentSessionTitle.isEmpty, let firstUser = messages.first(where: { $0.role == "user" }) {
            currentSessionTitle = String(firstUser.content.prefix(48))
        }
        let file = ChatSessionFile(
            id: sessionID,
            title: currentSessionTitle.isEmpty ? "New chat" : currentSessionTitle,
            createdAt: sessionCreatedAt ?? Date(),
            updatedAt: Date(),
            messages: persisted
        )
        ChatSessionStore.save(file)
    }

    private static let compactionSystemPrompt = """
        You are compacting an ongoing chat conversation to save context space. You'll be shown a \
        chunk of earlier turns from the middle of the conversation (a beginning and an end are \
        being kept as-is around it). Write a single concise paragraph -- not a list, not \
        commentary addressed to anyone -- that preserves: what the user asked for or wanted; what \
        was concluded, established as fact, or decided; concrete details a later turn might depend \
        on again (names, numbers, file paths, chosen options, preferences); and the state of \
        anything left unresolved. Write it as compressed background information for whoever \
        continues this conversation next, not as a message to the user.
        """

    /// Replaces messages[keepStart..<(count-keepEnd)] with one synthetic
    /// summary message generated by the model itself, cutting overall
    /// message/token count without losing the substance of what happened
    /// in between. No-op if there isn't enough in the middle to bother
    /// compacting. See ContentView for the keepStart/keepEnd Settings.
    func compactSession(port: Int, modelAlias: String, settings: ChatSettings, keepStart: Int, keepEnd: Int) async {
        guard !isBusy else { return }
        guard messages.count > keepStart + keepEnd + 1 else { return }
        let middleRange = keepStart..<(messages.count - keepEnd)
        let middle = Array(messages[middleRange])
        guard !middle.isEmpty else { return }

        let transcript = middle.map { msg -> String in
            let speaker = msg.role == "user" ? "User" : (msg.role == "tool" ? "Tool result" : "Assistant")
            let text = msg.content.isEmpty ? msg.reasoning : msg.content
            return "\(speaker): \(text)"
        }.joined(separator: "\n\n")

        let requestMessages: [[String: Any]] = [
            ["role": "system", "content": Self.compactionSystemPrompt],
            ["role": "user", "content": transcript],
        ]

        let epoch = conversationEpoch
        do {
            let summary = try await requestCompletion(port: port, modelAlias: modelAlias, messages: requestMessages)
            // Switched to another session while the summary was being
            // written: middleRange indexes the OLD message list -- splicing
            // it into the new one would inject (and persist) the old
            // conversation's summary there.
            guard epoch == conversationEpoch else { return }
            messages.replaceSubrange(middleRange, with: [ChatMessage(role: "assistant", content: summary, isSummary: true)])
            persistCurrentSession()
        } catch {
            guard epoch == conversationEpoch else { return }
            errorText = "Compaction failed: \(error.localizedDescription)"
        }
    }

    /// One-shot (non-streaming) completion, fully decoupled from the SSE
    /// delegate machinery send()/regenerate() use -- compactSession() only
    /// ever runs while !isBusy, so there's no risk of clobbering an
    /// in-flight stream's `task`/`sseBuffer` state by using a separate
    /// ad-hoc URLSession call instead.
    private func requestCompletion(port: Int, modelAlias: String, messages: [[String: Any]]) async throws -> String {
        guard let url = URL(string: "http://localhost:\(port)/v1/chat/completions") else {
            throw URLError(.badURL)
        }
        let body: [String: Any] = [
            "model": modelAlias,
            "messages": messages,
            "stream": false,
            "temperature": 0.3,
            "max_tokens": 512,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
            throw NSError(
                domain: "ChatClient", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected response shape from the chat completion endpoint."]
            )
        }
        return content
    }

    func send(
        prompt: String, images: [Data] = [], port: Int, modelAlias: String, settings: ChatSettings,
        server: ServerManager
    ) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        imagesGeneratedThisTurn = 0
        messages.append(ChatMessage(role: "user", content: prompt, images: images))
        startAssistantResponse(port: port, modelAlias: modelAlias, settings: settings, server: server)
    }

    /// Re-runs the last user turn with a fresh generation -- drops the
    /// previous assistant reply (if any) so the retry doesn't just pile up
    /// underneath a garbled/unhelpful one, then asks again with the exact
    /// same prompt.
    func regenerate(port: Int, modelAlias: String, settings: ChatSettings, server: ServerManager) {
        guard !isBusy else { return }
        imagesGeneratedThisTurn = 0
        if messages.last?.role == "assistant" {
            messages.removeLast()
        }
        guard messages.last?.role == "user" else { return }
        startAssistantResponse(port: port, modelAlias: modelAlias, settings: settings, server: server)
    }

    /// Explicit, Settings-initiated warm-up download for the given image
    /// model -- called before enabling the "Enable image generation"
    /// toggle so the (potentially tens-of-GB) download happens visibly,
    /// up front, not silently the first time a chat message happens to
    /// trigger generate_image. Returns the error on failure (the toggle
    /// stays off in that case) or nil on success.
    func downloadImageModel(_ model: ImageGenModel) async -> Error? {
        isDownloadingModel = true
        defer { isDownloadingModel = false }
        do {
            try await mfluxManager.downloadModel(model)
            return nil
        } catch {
            return error
        }
    }

    private func startAssistantResponse(port: Int, modelAlias: String, settings: ChatSettings, server: ServerManager) {
        errorText = nil
        pendingRequestContext = RequestContext(port: port, modelAlias: modelAlias, settings: settings, server: server)
        messages.append(ChatMessage(role: "assistant"))
        assistantMessageIndex = messages.count - 1

        var payloadMessages: [[String: Any]] = messages.dropLast(1).map(Self.serialize(message:))
        let userSystemPrompt = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = [userSystemPrompt, settings.enableImageGeneration ? settings.toolUsePolicy : ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !systemPrompt.isEmpty {
            payloadMessages.insert(["role": "system", "content": systemPrompt], at: 0)
        }

        var body: [String: Any] = [
            "model": modelAlias,
            "messages": payloadMessages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "max_tokens": settings.maxTokens,
        ]
        if settings.topK > 0 {
            body["top_k"] = settings.topK
        }
        if settings.enableImageGeneration {
            body["tools"] = [Self.generateImageTool]
        }

        guard let url = URL(string: "http://localhost:\(port)/v1/chat/completions"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            errorText = "failed to build request"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 300

        sseBuffer = ""
        approxCompletionTokens = 0
        usageCompletionTokens = nil
        firstByteDate = nil
        responseStatusCode = nil
        errorResponseBody = Data()
        isStreaming = true

        task = session.dataTask(with: request)
        task?.resume()
    }

    /// Serializes one message for the request body, matching whichever of
    /// the three shapes OpenAI's tool-calling protocol expects: a plain
    /// user/system/assistant turn, an assistant turn that called tool(s)
    /// (tool_calls attached, content omitted if the model produced none),
    /// or a "tool" role result keyed by tool_call_id.
    private static func serialize(message: ChatMessage) -> [String: Any] {
        if message.role == "tool" {
            return ["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.content]
        }
        if message.role == "assistant", !message.toolCalls.isEmpty {
            var dict: [String: Any] = ["role": "assistant"]
            if !message.content.isEmpty {
                dict["content"] = message.content
            }
            dict["tool_calls"] = message.toolCalls.map { call in
                ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.argumentsJSON]]
            }
            return dict
        }
        if message.role == "user", !message.images.isEmpty {
            // Attachments are always normalized to PNG before landing in
            // ChatMessage.images (see ContentView's attach-file handling),
            // so the MIME half of this data URI is never a guess.
            var parts: [[String: Any]] = []
            if !message.content.isEmpty {
                parts.append(["type": "text", "text": message.content])
            }
            for data in message.images {
                let url = "data:image/png;base64,\(data.base64EncodedString())"
                parts.append(["type": "image_url", "image_url": ["url": url]])
            }
            return ["role": "user", "content": parts]
        }
        return ["role": message.role, "content": message.content]
    }

    func cancel() {
        task?.cancel()
        isStreaming = false
    }

    // MARK: - URLSessionDataDelegate (incremental SSE parsing)

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        responseStatusCode = (response as? HTTPURLResponse)?.statusCode
        completionHandler(.allow)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let code = responseStatusCode, !(200..<300).contains(code) {
            errorResponseBody.append(data)
            return
        }
        if firstByteDate == nil {
            firstByteDate = Date()
        }
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        let taskID = dataTask.taskIdentifier
        Task { @MainActor in
            // A cancelled stream from a conversation that was since replaced
            // can still have chunks queued -- they must not land in the new
            // one (see resetConversationState).
            guard self.task?.taskIdentifier == taskID else { return }
            self.handleChunk(chunk)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Captured here, synchronously in the real delegate callback, for
        // the same reason as firstByteDate above -- not inside the
        // dispatched Task, which could run late.
        let completionDate = Date()
        let statusCode = responseStatusCode
        let errorBody = errorResponseBody
        let taskID = task.taskIdentifier
        Task { @MainActor in
            // Completion of a stream abandoned by switching conversations:
            // nothing of it (error text, tool-call continuation, persisting)
            // belongs to the conversation now on screen.
            guard self.task?.taskIdentifier == taskID else { return }
            self.isStreaming = false
            if let statusCode, !(200..<300).contains(statusCode) {
                self.errorText = Self.serverErrorMessage(statusCode: statusCode, body: errorBody)
                self.dropEmptyAssistantPlaceholder()
                self.persistCurrentSession()
                return
            }
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.errorText = error.localizedDescription
            }
            self.finalizeTokensPerSecond(endDate: completionDate)
            if error == nil {
                await self.continueWithPendingToolCalls()
            }
        }
    }

    /// mlx_lm.server's error bodies are `{"error": "<message>"}`; fall back
    /// to the raw body (or just the status) for anything else.
    private static func serverErrorMessage(statusCode: Int, body: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = obj["error"] as? String, !message.isEmpty {
            return "Server error (\(statusCode)): \(message)"
        }
        let raw = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Server error (\(statusCode))" : "Server error (\(statusCode)): \(raw)"
    }

    /// A failed request leaves the assistant message that was appended up
    /// front with nothing in it -- remove it rather than leaving a blank
    /// bubble that looks like a hung response.
    private func dropEmptyAssistantPlaceholder() {
        guard let idx = assistantMessageIndex, idx < messages.count else { return }
        let msg = messages[idx]
        if msg.role == "assistant", msg.content.isEmpty, msg.reasoning.isEmpty,
           msg.toolCalls.isEmpty, msg.images.isEmpty {
            messages.remove(at: idx)
            assistantMessageIndex = nil
        }
    }

    /// If the response that just finished streaming carried one or more
    /// tool calls, runs them and sends their results back as a follow-up
    /// request so the model can react -- otherwise this turn is done.
    private func continueWithPendingToolCalls() async {
        guard let idx = assistantMessageIndex, idx < messages.count else {
            persistCurrentSession()
            return
        }
        let toolCalls = messages[idx].toolCalls
        guard !toolCalls.isEmpty, let context = pendingRequestContext else {
            persistCurrentSession()
            return
        }
        await executeToolCalls(toolCalls, sourceIndex: idx, context: context)
    }

    private func executeToolCalls(_ toolCalls: [ToolCall], sourceIndex: Int, context: RequestContext) async {
        // Whether unloading/reloading the chat model is worth doing at all
        // this round -- skip it entirely if every call here is already
        // going to be refused by the per-turn cap below, so a model stuck
        // repeating the tool call doesn't also repeatedly stop/reload the
        // chat server for nothing.
        let willActuallyGenerate = toolCalls.contains { $0.name == "generate_image" }
            && imagesGeneratedThisTurn < maxImagesPerTurn
            && context.settings.enableImageGeneration

        // Only when mflux will actually run -- a refused call (toggle off,
        // per-turn cap) shouldn't flash the "Generating image…" UI / pulse.
        isGeneratingImage = willActuallyGenerate
        defer { isGeneratingImage = false }

        // A diffusion model's own peak memory can rival or exceed a loaded
        // chat model's (confirmed live: Z-Image Turbo alone peaked near
        // 25GB on a 24GB Mac) -- mlx_lm.server has no notion of "make room,
        // something else needs the GPU right now," so the chat model is
        // stopped first and reloaded after, unless the user has said their
        // Mac comfortably fits both at once. Reuses ServerManager's own
        // idle-unload/reload pair (stop() + ensureModelLoaded()), which
        // already remembers the last-loaded model/alias for exactly this
        // "stopped, but not forgotten" case.
        let shouldUnload = context.settings.unloadModelDuringImageGen && willActuallyGenerate
        if shouldUnload {
            context.server.stop()
        }

        // Session switched mid-call (see resetConversationState): stop
        // touching `messages` -- it now belongs to another conversation.
        let epoch = conversationEpoch

        callLoop: for call in toolCalls {
            guard epoch == conversationEpoch else { break callLoop }
            guard call.name == "generate_image" else {
                messages.append(ChatMessage(role: "tool", content: "Unknown tool: \(call.name)", toolCallID: call.id))
                continue
            }
            // The tool is only *declared* when image generation is enabled,
            // but a model that saw generate_image calls earlier in the same
            // session keeps emitting them from history after the toggle is
            // turned off (reported by a tester, confirmed in code: nothing
            // here checked the toggle) -- and the server still parses that
            // text as a tool call. Refuse instead of silently running mflux.
            guard context.settings.enableImageGeneration else {
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: "Image generation is turned off in LLMTray's settings, so no image was "
                            + "generated. Do not call generate_image; answer in text, and if the user wants "
                            + "an image, tell them to enable image generation in settings first.",
                        toolCallID: call.id
                    )
                )
                continue
            }
            // Small tool-calling models can fail to treat a successful
            // result as "done" and just call the tool again unprompted
            // (confirmed live against a 4B model) -- refuse rather than
            // burn another real generation, and say so plainly enough that
            // even a small model should stop trying.
            guard imagesGeneratedThisTurn < maxImagesPerTurn else {
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: "Not generating another image -- one was already generated for this request "
                            + "and shown to the user. Do not call generate_image again unless the user sends a "
                            + "new message explicitly asking for a new or different image.",
                        toolCallID: call.id
                    )
                )
                continue
            }
            let arguments = Self.parseArguments(call.argumentsJSON)
            let prompt = (arguments["prompt"] as? String) ?? ""
            let requestedWidth = (arguments["width"] as? Int) ?? 1024
            let requestedHeight = (arguments["height"] as? Int) ?? 1024
            // Scales whatever the model asked for rather than replacing it
            // outright, so a deliberately non-square request from the model
            // keeps its aspect ratio -- MfluxManager.generate rounds the
            // result to a multiple of 16 regardless.
            let scale = context.settings.imageQuality.scale
            let width = Int(Double(requestedWidth) * scale)
            let height = Int(Double(requestedHeight) * scale)
            do {
                let start = Date()
                let imageData = try await mfluxManager.generate(
                    prompt: prompt, width: width, height: height, model: context.settings.imageGenModel
                )
                guard epoch == conversationEpoch else { break callLoop }
                let elapsed = Date().timeIntervalSince(start)
                if sourceIndex < messages.count {
                    messages[sourceIndex].images.append(imageData)
                    messages[sourceIndex].imageDurations.append(elapsed)
                    messages[sourceIndex].imagePrompts.append(prompt)
                }
                imagesGeneratedThisTurn += 1
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: "Image generated and already displayed to the user directly above your reply "
                            + "-- you do not have the image data and cannot embed, link, or preview it yourself. "
                            + "Do not write markdown image syntax (![...](...)) or any placeholder/fake URL for "
                            + "it. Just reply in plain text (e.g. briefly describe what you asked for), or say "
                            + "nothing else. Do not call generate_image again for this request unless the user "
                            + "explicitly asks for a new or different image.",
                        toolCallID: call.id
                    )
                )
            } catch {
                guard epoch == conversationEpoch else { break callLoop }
                messages.append(
                    ChatMessage(
                        role: "tool", content: "Image generation failed: \(error.localizedDescription)",
                        toolCallID: call.id
                    )
                )
            }
        }

        // Reload even if the conversation was switched meanwhile -- the new
        // one needs the chat model too.
        if shouldUnload {
            do {
                try await context.server.ensureModelLoaded()
            } catch {
                errorText = "Failed to reload the chat model after image generation: \(error.localizedDescription)"
                return
            }
        }

        // ...but never send the old conversation's follow-up request from
        // the new one.
        guard epoch == conversationEpoch else { return }

        startAssistantResponse(
            port: context.port, modelAlias: context.modelAlias, settings: context.settings, server: context.server
        )
    }

    private static func parseArguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func finalizeTokensPerSecond(endDate: Date) {
        guard let start = firstByteDate else { return }
        let elapsed = endDate.timeIntervalSince(start)
        // Sub-50ms is measurement noise (SSE framing, a one-word reply),
        // not a real generation rate -- dividing by it is what produced
        // the nonsense "cosmos" numbers.
        guard elapsed > 0.05 else { return }
        // Prefer the server's real completion_tokens (from the final
        // stream_options.include_usage chunk) over the word-count proxy --
        // this is only an approximation when the server doesn't send usage.
        let tokenCount = usageCompletionTokens ?? approxCompletionTokens
        guard tokenCount > 0 else { return }
        lastTokensPerSecond = Double(tokenCount) / elapsed
    }

    private func handleChunk(_ chunk: String) {
        sseBuffer += chunk
        let lines = sseBuffer.components(separatedBy: "\n")
        // Keep the last (possibly incomplete) line in the buffer for next time.
        sseBuffer = lines.last ?? ""
        for line in lines.dropLast() {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // The final stream_options.include_usage chunk has an empty (or
            // absent) choices array and a top-level "usage" object -- this is
            // the accurate completion_tokens count for tok/s, when present.
            if let usage = obj["usage"] as? [String: Any],
               let completionTokens = usage["completion_tokens"] as? Int {
                usageCompletionTokens = completionTokens
            }

            guard let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any] else { continue }

            // mlx_lm.server puts this under the key "reasoning", not the
            // "reasoning_content" name some other OpenAI-compatible servers
            // use -- checking both means this doesn't silently break again
            // if a future server build changes it back.
            let reasoningValue = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String)
            if let reasoning = reasoningValue, !reasoning.isEmpty {
                appendToAssistant(reasoning: reasoning)
                approxCompletionTokens += max(1, reasoning.split(whereSeparator: { $0.isWhitespace }).count)
            }
            // Most servers/deltas send plain string content. A model that
            // emits image output uses OpenAI's multimodal content-array
            // shape instead -- [{type: "text", text: "..."}, {type:
            // "image_url", image_url: {url: "data:image/...;base64,..."}}]
            // -- handle both.
            if let content = delta["content"] as? String, !content.isEmpty {
                appendToAssistant(content: content)
                // Word-count proxy, used only if the server never sends a
                // real usage.completion_tokens (see finalizeTokensPerSecond).
                approxCompletionTokens += max(1, content.split(whereSeparator: { $0.isWhitespace }).count)
            } else if let parts = delta["content"] as? [[String: Any]] {
                for part in parts {
                    guard let type = part["type"] as? String else { continue }
                    if type == "text", let text = part["text"] as? String, !text.isEmpty {
                        appendToAssistant(content: text)
                        approxCompletionTokens += max(1, text.split(whereSeparator: { $0.isWhitespace }).count)
                    } else if type == "image_url",
                              let imageURL = part["image_url"] as? [String: Any],
                              let urlString = imageURL["url"] as? String,
                              let data = Self.decodeDataURI(urlString) {
                        appendToAssistant(image: data)
                    }
                }
            }

            // mlx_lm.server only ever emits a complete tool call here --
            // it accumulates the model's raw <tool_call>...</tool_call>
            // text server-side and only appends to its own tool_calls list
            // once that block closes (see server.py's generation loop), so
            // by the time this delta is visible, "arguments" is already a
            // complete, parseable JSON string -- no incremental/fragmented
            // merging by index needed, unlike OpenAI's own real streaming
            // protocol.
            if let toolCallParts = delta["tool_calls"] as? [[String: Any]] {
                for part in toolCallParts {
                    guard let function = part["function"] as? [String: Any],
                          let name = function["name"] as? String else { continue }
                    let id = (part["id"] as? String) ?? UUID().uuidString
                    let argumentsJSON = (function["arguments"] as? String) ?? "{}"
                    appendToAssistant(toolCall: ToolCall(id: id, name: name, argumentsJSON: argumentsJSON))
                }
            }
        }
    }

    /// Parses a "data:image/png;base64,...."-style URI. Returns nil for a
    /// remote http(s) URL -- rendering those would mean fetching and
    /// (however briefly) holding third-party content this app didn't
    /// generate; only inline data URIs are treated as "the model's own
    /// generated image."
    private static func decodeDataURI(_ uriString: String) -> Data? {
        guard uriString.hasPrefix("data:"),
              let commaIndex = uriString.firstIndex(of: ",") else { return nil }
        let base64Part = uriString[uriString.index(after: commaIndex)...]
        return Data(base64Encoded: String(base64Part))
    }

    private func appendToAssistant(content: String) {
        guard let idx = assistantMessageIndex, idx < messages.count else { return }
        messages[idx].content += content
    }

    private func appendToAssistant(reasoning: String) {
        guard let idx = assistantMessageIndex, idx < messages.count else { return }
        messages[idx].reasoning += reasoning
    }

    private func appendToAssistant(image: Data) {
        guard let idx = assistantMessageIndex, idx < messages.count else { return }
        messages[idx].images.append(image)
    }

    private func appendToAssistant(toolCall: ToolCall) {
        guard let idx = assistantMessageIndex, idx < messages.count else { return }
        messages[idx].toolCalls.append(toolCall)
    }
}
