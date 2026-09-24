import AppKit
import Combine
import Foundation
import LLMTrayCore

@MainActor
final class ChatClient: ObservableObject {
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
    /// A tool round is running (any tool, not only image generation): the
    /// turn is still in progress -- no second message may interleave.
    @Published private(set) var isRunningTools: Bool = false
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

    /// A compaction summary is being written (see compactSession).
    @Published private(set) var isCompacting: Bool = false
    private var compactionTask: Task<Void, Never>?

    /// A chat turn (streaming + any tool calls) is in progress.
    var isTurnInProgress: Bool { isStreaming || isGeneratingImage || isRunningTools }
    /// Anything that changes `messages` is running: compaction too, so a
    /// second Compact (or a send) can't work on a stale message range.
    var isBusy: Bool { isTurnInProgress || isCompacting }

    private let toolbox = ChatToolbox()
    private var imageTool: ImageToolRunner { toolbox.imageGeneration }
    private var mfluxManager: MfluxManager { imageTool.mflux }
    private var mfluxStatusCancellable: AnyCancellable?
    private var mfluxProgressCancellable: AnyCancellable?
    private var mfluxPreviewCancellable: AnyCancellable?

    private let transport = ChatTransport()
    /// Bumped by cancel(): a tool round scheduled before a Stop doesn't run.
    private var turnToken = 0
    private var decoder = SSEDecoder()
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
    /// The running tool round -- Stop cancels it.
    private var toolTask: Task<Void, Never>?
    private let maxToolCallsPerRound = 8
    // A model that keeps calling a tool after being refused (cap reached,
    // tool off) would otherwise loop request -> refusal -> request forever.
    private var toolRoundsThisTurn = 0
    private let maxToolRoundsPerTurn = 4

    init() {
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

    /// Everything that must not survive a switch to another conversation.
    /// Async turn steps (image generation, compaction) outlive the switch;
    /// bumping `conversationEpoch` makes them drop their result instead of
    /// landing in the new chat (adr/0003), and cancelling the transport
    /// drops the abandoned stream's late callbacks.
    private func resetConversationState() {
        cancel()
        conversationEpoch += 1
        assistantMessageIndex = nil
        pendingRequestContext = nil
        decoder = SSEDecoder()
        errorText = nil
        lastTokensPerSecond = nil
        toolbox.startTurn()
        toolRoundsThisTurn = 0
    }

    func loadSession(_ file: ChatSessionFile) {
        resetConversationState()
        let imagesDir = ChatSessionStore.imagesDir(for: file.id)
        messages = file.messages.map { pm in
            let images = pm.imageFilenames.compactMap { FileManager.default.contents(atPath: imagesDir + "/" + $0) }
            return ChatMessage(
                role: pm.role, content: pm.content, reasoning: pm.reasoning, images: images,
                imageDurations: pm.imageDurations, imagePrompts: pm.imagePrompts, isSummary: pm.isSummary,
                sources: pm.sources
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

        // Before the tool messages they come from are dropped.
        let sources = ChatMessage.sourcesByAnswer(messages)
        let persisted = messages.compactMap { msg -> PersistedMessage? in
            guard msg.role != "tool", !msg.isToolContext else { return nil }
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
                imageFilenames: filenames, imageDurations: msg.imageDurations, imagePrompts: msg.imagePrompts,
                sources: sources[msg.id] ?? []
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
        isCompacting = true
        let work = Task { @MainActor in
            await self.runCompaction(port: port, modelAlias: modelAlias, keepStart: keepStart, keepEnd: keepEnd)
        }
        compactionTask = work
        await work.value
        compactionTask = nil
        isCompacting = false
    }

    private func runCompaction(port: Int, modelAlias: String, keepStart: Int, keepEnd: Int) async {
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
            guard let request = ChatRequestBuilder.completion(port: port, modelAlias: modelAlias, messages: requestMessages) else {
                throw URLError(.badURL)
            }
            let summary = try await ChatTransport.completion(request)
            // Switched to another session while the summary was being
            // written: middleRange indexes the OLD message list -- splicing
            // it into the new one would inject (and persist) the old
            // conversation's summary there.
            guard epoch == conversationEpoch, !Task.isCancelled, middleRange.upperBound <= messages.count else { return }
            messages.replaceSubrange(middleRange, with: [ChatMessage(role: "assistant", content: summary, isSummary: true)])
            persistCurrentSession()
        } catch {
            guard epoch == conversationEpoch, !Task.isCancelled else { return }
            errorText = "Compaction failed: \(error.localizedDescription)"
        }
    }

    func send(
        prompt: String, images: [Data] = [], port: Int, modelAlias: String, settings: ChatSettings,
        server: ServerManager
    ) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        toolbox.startTurn()
        toolRoundsThisTurn = 0
        messages.append(ChatMessage(role: "user", content: prompt, images: images))
        startAssistantResponse(port: port, modelAlias: modelAlias, settings: settings, server: server)
    }

    /// Re-runs the last user turn with a fresh generation -- drops the
    /// previous assistant reply (if any) so the retry doesn't just pile up
    /// underneath a garbled/unhelpful one, then asks again with the exact
    /// same prompt.
    func regenerate(port: Int, modelAlias: String, settings: ChatSettings, server: ServerManager) {
        guard !isBusy else { return }
        toolbox.startTurn()
        toolRoundsThisTurn = 0
        // The whole last response: assistant turns, tool results and the
        // hidden view_image message, back to the user's own message.
        while let last = messages.last, !(last.role == "user" && !last.isToolContext) {
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

    /// `offerTools: false` for the answer after the last allowed tool round.
    private func startAssistantResponse(port: Int, modelAlias: String, settings: ChatSettings, server: ServerManager, offerTools: Bool = true) {
        errorText = nil
        pendingRequestContext = RequestContext(port: port, modelAlias: modelAlias, settings: settings, server: server)
        messages.append(ChatMessage(role: "assistant"))
        assistantMessageIndex = messages.count - 1

        guard let request = ChatRequestBuilder.streaming(
            port: port, modelAlias: modelAlias, settings: settings,
            history: Array(messages.dropLast(1)),
            tools: offerTools ? toolbox.definitions(for: settings) : []
        ) else {
            errorText = "failed to build request"
            return
        }

        decoder = SSEDecoder()
        approxCompletionTokens = 0
        usageCompletionTokens = nil
        lastTokensPerSecond = nil
        isStreaming = true
        transport.stream(request, onText: { [weak self] text in
            self?.handle(self?.decoder.feed(text) ?? [])
        }, onComplete: { [weak self] completion in
            self?.streamDidComplete(completion)
        })
    }

    func cancel() {
        transport.cancel()
        turnToken += 1
        isStreaming = false
        toolTask?.cancel()
        toolTask = nil
        isRunningTools = false
        compactionTask?.cancel()
        closeDanglingToolCalls()
    }

    /// Every tool call in the history must be answered by a tool result
    /// (OpenAI protocol): a Stop between a tool-calling response and its
    /// results would otherwise leave the next request malformed.
    private func closeDanglingToolCalls() {
        guard let idx = messages.lastIndex(where: { $0.role == "assistant" && !$0.toolCalls.isEmpty }) else { return }
        let answered = Set(messages[(idx + 1)...].compactMap(\.toolCallID))
        var insertAt = idx + 1
        while insertAt < messages.count, messages[insertAt].role == "tool" { insertAt += 1 }
        for call in messages[idx].toolCalls where !answered.contains(call.id) {
            messages.insert(ChatMessage(role: "tool", content: "Cancelled by the user.", toolCallID: call.id), at: insertAt)
            insertAt += 1
        }
    }

    /// The settings as they are *now* (a tool switched off mid-turn stops
    /// at once), for the model the turn started with.
    private func currentSettings(_ start: ChatSettings) -> ChatSettings {
        guard let modelPath = start.modelPath else { return start }
        var now = ChatSettings(profile: ProfileManager.shared.resolved(for: modelPath), maxTokensCap: start.maxTokensCap)
        now.modelPath = modelPath
        now.modelSupportsVision = start.modelSupportsVision
        return now
    }

    private func streamDidComplete(_ completion: ChatTransport.Completion) {
        if let statusCode = completion.statusCode, completion.isHTTPError {
            isStreaming = false
            errorText = ChatTransport.serverErrorMessage(statusCode: statusCode, body: completion.errorBody)
            dropEmptyAssistantPlaceholder()
            closeDanglingToolCalls()
            persistCurrentSession()
            return
        }
        handle(decoder.finish())
        if let error = completion.error, (error as NSError).code != NSURLErrorCancelled {
            errorText = error.localizedDescription
        }
        finalizeTokensPerSecond(firstByte: completion.firstByteDate, endDate: completion.endDate)
        if completion.error != nil { closeDanglingToolCalls() }   // no follow-up: keep the history valid
        continueWithPendingToolCalls(afterError: completion.error != nil)
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
    /// Decided synchronously, in the same main-actor turn the stream ended
    /// in: the turn stays "in progress" (isStreaming) until the tool round
    /// has taken over, so Send/Stop don't flicker between rounds and a Stop
    /// in that gap (see cancel(), turnToken) stops the round.
    private func continueWithPendingToolCalls(afterError: Bool) {
        guard !afterError, let idx = assistantMessageIndex, idx < messages.count,
              !messages[idx].toolCalls.isEmpty, let context = pendingRequestContext else {
            isStreaming = false
            if !afterError { persistCurrentSession() }
            return
        }
        let toolCalls = messages[idx].toolCalls
        let token = turnToken
        isRunningTools = true   // set before isStreaming drops: never an idle gap
        toolTask = Task {
            defer { if token == self.turnToken { self.isRunningTools = false } }
            guard token == self.turnToken else { return }
            await self.executeToolCalls(toolCalls, sourceIndex: idx, context: context, token: token)
        }
    }

    /// Images generated in this conversation, oldest first (view_image).
    private var generatedImages: [(data: Data, prompt: String)] {
        messages.filter { $0.role == "assistant" }.flatMap { msg in
            msg.images.enumerated().map { (data: $1, prompt: msg.imagePrompts[safe: $0] ?? "") }
        }
    }

    private func executeToolCalls(_ toolCalls: [ToolCall], sourceIndex: Int, context: RequestContext, token: Int) async {
        // Captured before the first suspension: a conversation switch or a
        // Stop during any await below ends this round.
        let epoch = conversationEpoch
        func stillCurrent() -> Bool { epoch == conversationEpoch && token == turnToken && !Task.isCancelled }

        // Tool calls in the answer that was requested *without* tools (the
        // model repeating them from history): refused, the turn ends.
        if toolRoundsThisTurn >= maxToolRoundsPerTurn {
            for call in toolCalls {
                messages.append(ChatMessage(role: "tool", content: "Not run: tool limit for this message reached.", toolCallID: call.id))
            }
            errorText = "Stopped: the model kept calling tools (\(maxToolRoundsPerTurn) rounds in one turn)."
            isRunningTools = false
            isStreaming = false
            persistCurrentSession()
            return
        }

        var settings = currentSettings(context.settings)
        let willActuallyGenerate = imageTool.willGenerate(toolCalls, settings: settings)
        // Only when mflux will actually run -- a refused call shouldn't
        // flash the "Generating image…" UI / pulse.
        isGeneratingImage = willActuallyGenerate
        isStreaming = false
        defer { isGeneratingImage = false }

        // A diffusion model's own peak memory can rival or exceed a loaded
        // chat model's (Z-Image Turbo alone peaked near 25 GB on a 24 GB
        // Mac), so the chat model is unloaded first and reloaded after,
        // unless the user has said their Mac fits both.
        let shouldUnload = settings.unloadModelDuringImageGen && willActuallyGenerate
        if shouldUnload {
            await context.server.unloadModel()
        }

        var pendingModelImages: [Data] = []
        for (i, call) in toolCalls.enumerated() {
            guard stillCurrent() else { break }
            guard i < maxToolCallsPerRound else {
                messages.append(ChatMessage(
                    role: "tool", content: "Not run: at most \(maxToolCallsPerRound) tool calls per response.",
                    toolCallID: call.id
                ))
                continue
            }
            settings = currentSettings(context.settings)
            let result = await toolbox.run(call, context: ToolContext(settings: settings, generatedImages: generatedImages))
            guard stillCurrent() else { break }
            switch result {
            case .text(let text):
                messages.append(ChatMessage(role: "tool", content: text, toolCallID: call.id))
            case .imageForModel(let data, let text):
                messages.append(ChatMessage(role: "tool", content: text, toolCallID: call.id))
                pendingModelImages.append(data)
            case .generatedImage(let data, let seconds, let prompt, let text):
                if sourceIndex < messages.count {
                    messages[sourceIndex].images.append(data)
                    messages[sourceIndex].imageDurations.append(seconds)
                    messages[sourceIndex].imagePrompts.append(prompt)
                }
                messages.append(ChatMessage(role: "tool", content: text, toolCallID: call.id))
            }
        }

        // Images a tool put in front of the model (view_image) follow the
        // tool results as one hidden user message: tool results are text.
        if stillCurrent(), !pendingModelImages.isEmpty {
            messages.append(ChatMessage(
                role: "user", content: "(The image(s) you asked to look at.)",
                images: pendingModelImages, isToolContext: true
            ))
        }

        // Reload even after a Stop or a conversation switch -- the chat
        // model is needed either way.
        if shouldUnload {
            do {
                try await context.server.ensureModelLoaded()
            } catch {
                errorText = "Failed to reload the chat model after image generation: \(error.localizedDescription)"
                return
            }
        }

        // ...but never send the old conversation's (or a stopped turn's)
        // follow-up request.
        guard stillCurrent() else { return }
        toolRoundsThisTurn += 1
        // The last allowed round's answer is requested without tools, so the
        // turn ends with a reply instead of an error.
        let offerTools = toolRoundsThisTurn < maxToolRoundsPerTurn
        isRunningTools = false
        startAssistantResponse(
            port: context.port, modelAlias: context.modelAlias, settings: currentSettings(context.settings),
            server: context.server, offerTools: offerTools
        )
    }

    private func finalizeTokensPerSecond(firstByte: Date?, endDate: Date) {
        guard let start = firstByte else { return }
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

    private func handle(_ events: [SSEEvent]) {
        for event in events {
            switch event {
            case .reasoning(let text):
                appendToAssistant(reasoning: text)
                approxCompletionTokens += Self.approxTokens(text)
            case .content(let text):
                appendToAssistant(content: text)
                approxCompletionTokens += Self.approxTokens(text)
            case .image(let data):
                appendToAssistant(image: data)
            case .toolCall(let id, let name, let argumentsJSON):
                appendToAssistant(toolCall: ToolCall(id: id, name: name, argumentsJSON: argumentsJSON))
            case .usage(let completionTokens):
                usageCompletionTokens = completionTokens
            }
        }
    }

    /// Word-count proxy for tok/s, used only if the server never sends a
    /// real usage.completion_tokens (see finalizeTokensPerSecond).
    private static func approxTokens(_ text: String) -> Int {
        max(1, text.split(whereSeparator: { $0.isWhitespace }).count)
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
