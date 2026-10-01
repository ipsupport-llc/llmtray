import AppKit
import Combine
import Foundation
import LLMTrayCore

@MainActor
final class ChatClient: ObservableObject {
    /// Stable for this client's lifetime: its tab's identity.
    let tabID = UUID()
    @Published var messages: [ChatMessage] = [] {
        didSet { hasUnsavedChanges = true }
    }
    /// The answer waits for a model being loaded (shown as such).
    @Published private(set) var isWaitingForModelLoad = false
    @Published var isStreaming: Bool = false
    @Published var lastTokensPerSecond: Double?
    @Published var errorText: String?
    // True while a generate_image tool call is actually running (mflux
    // bootstrap + generation) -- distinct from isStreaming since this
    // spans the gap between the tool-call-carrying response finishing and
    // the follow-up request (with the tool's result) starting. isBusy
    // covers both for UI gating.
    @Published private(set) var isGeneratingMedia: Bool = false
    /// A tool round is running (any tool, not only image generation): the
    /// turn is still in progress -- no second message may interleave.
    @Published private(set) var isRunningTools: Bool = false
    @Published private(set) var mfluxStatusText: String = ""
    // Mirrored from MfluxManager (see its stepProgress/previewImage docs)
    // for the same reason mfluxStatusText is -- ContentView only imports
    // this file's types, not MfluxManager's directly.
    @Published private(set) var mfluxStepProgress: (step: Int, total: Int)?
    @Published private(set) var mfluxPreviewImage: NSImage?
    /// Mirrored from MusicManager, like the mflux ones.
    @Published private(set) var musicStatusText: String = ""
    @Published private(set) var musicProgress: Int?
    enum MediaKind { case image, music }
    /// What a generated image's or song's buttons do.
    enum MediaAction { case regenerate, tweak, remove }
    /// Creator mode's draft on screen, waiting for the user or its countdown.
    @Published var draft: GenerationDraft?
    /// A folder grant prompt on screen (adr/0014): a folder tool's call
    /// waits for it, or the user opened it (Allow Folder…).
    @Published var folderPrompt: FolderAccessPrompt?
    /// The chat's pending folder plan, or the last one's result.
    @Published var folderPlan: FolderPlanModel?
    /// The chat as the folder grants know it, per visit: a saved chat's
    /// session id plus the visit's, a temporary chat's own. Never reused, so
    /// a call that outlived a visit can't write for the next one; its grants
    /// and plan end with the visit.
    private(set) var folderChatID = UUID().uuidString

    static func folderChatID(_ session: UUID?) -> String {
        let visit = UUID().uuidString
        return session.map { "\($0.uuidString)#\(visit)" } ?? visit
    }
    /// Waiting in the app-wide generator queue: how many are ahead (the
    /// running one included); nil once it runs.
    @Published private(set) var mediaQueuePosition: Int?
    /// What isGeneratingMedia is making (the progress view shown).
    @Published private(set) var generatingKind: MediaKind?
    // True only during the explicit, Settings-initiated warm-up download
    // (see downloadImageModel) -- distinct from isGeneratingMedia (a real
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
    /// The title is the user's or the model's already: no auto-title.
    private var titleIsFinal = false
    /// Bumped by a rename: a title request still running then drops its
    /// answer.
    private var titleRevision = 0
    private var titleTask: Task<Void, Never>?
    /// The chat changed since it was loaded or last written. An unchanged
    /// chat isn't written again: that bumped its updatedAt, so merely
    /// opening another chat moved it to the top of the list.
    private var hasUnsavedChanges = false

    /// A compaction summary is being written (see compactSession).
    @Published private(set) var isCompacting: Bool = false
    private var compactionTask: Task<Void, Never>?

    /// A chat turn (streaming + any tool calls) is in progress.
    var isTurnInProgress: Bool { isStreaming || isGeneratingMedia || isRunningTools }
    /// Anything that changes `messages` is running: compaction too, so a
    /// second Compact (or a send) can't work on a stale message range.
    var isBusy: Bool { isTurnInProgress || isCompacting }

    private let toolbox: ChatToolbox
    /// Another tab is unloading the model for an image, or has it unloaded
    /// (ChatTabs): an answer waits for it to come back.
    var isAnotherChatUnloadingModel: () -> Bool = { false }
    /// This chat unloads the model for an image and reloads it after:
    /// announced before the unload, so other tabs wait from the start.
    @Published private(set) var isUnloadingModelForMedia = false
    private var imageTool: ImageToolRunner { toolbox.imageGeneration }
    private var mfluxManager: MfluxManager { imageTool.mflux }
    private var mfluxStatusCancellable: AnyCancellable?
    private var mfluxProgressCancellable: AnyCancellable?
    private var mfluxPreviewCancellable: AnyCancellable?
    private var musicTool: MusicToolRunner { toolbox.musicGeneration }
    private var musicManager: MusicManager { musicTool.music }
    private var musicStatusCancellable: AnyCancellable?
    private var musicProgressCancellable: AnyCancellable?

    private let transport = ChatTransport()
    /// Bumped by cancel(): a tool round scheduled before a Stop doesn't run.
    private var turnToken = 0
    private var decoder = SSEDecoder()
    // See resetConversationState(): async continuations capture this and
    // drop their result if the conversation was replaced meanwhile.
    private(set) var conversationEpoch = 0
    private var approxCompletionTokens: Int = 0
    private var usageCompletionTokens: Int?
    /// The turn's answer details so far: one request per round, set on its
    /// answer when the turn ends (AnswerStats). nil between turns.
    private var turnStats: AnswerStats?
    private var turnStartDate: Date?
    /// The running request's usage, as the server reports it.
    private var requestStats = AnswerStats.Request()
    /// This chat's prompt-token estimate (adr/0012), calibrated by each
    /// response's usage against the request it answered.
    private var tokenEstimator = PromptTokenEstimator()
    /// A request's shape for the estimate: its size, how many messages of
    /// the history it sent, and the rest serialized -- the system prompt
    /// and parameters, and each tool declaration by name; and its model
    /// (whose pinned-file ratio its count teaches), its pinned block's
    /// bytes and its framing without that block.
    private struct SentRequest {
        var measure: PromptTokenEstimator.Measure
        var historyCount: Int
        var framing: Framing
        var modelPath: String?
        var pinnedBytes: Int
        var unpinnedFraming: Framing
        var carriesPins: Bool
    }
    private struct Framing: Equatable {
        var base: Data
        var tools: [String: Data]

        /// The same rest, or only fewer declarations (tools no longer
        /// offered: their tokens counted anyway).
        func isCovered(by counted: Framing) -> Bool {
            base == counted.base && tools.allSatisfy { counted.tools[$0.key] == $0.value }
        }
    }
    /// The last request sent, and the last one the server counted (what
    /// tokenEstimator's calibration is of).
    private var lastRequest: SentRequest?
    private var countedRequest: SentRequest?
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

    init(mflux: MfluxManager? = nil, music: MusicManager? = nil) {
        toolbox = ChatToolbox(mflux: mflux, music: music)
        musicStatusCancellable = musicTool.music.$statusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.musicStatusText = $0 }
        musicProgressCancellable = musicTool.music.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.musicProgress = $0 }
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
        let id = UUID()
        currentSessionID = id
        folderChatID = Self.folderChatID(id)
        currentSessionTitle = ""
        sessionCreatedAt = Date()
        titleIsFinal = false
    }

    /// Nothing typed or generated in this chat is ever written anywhere --
    /// currentSessionID stays nil, so persistCurrentSession() is a no-op
    /// for the whole lifetime of this conversation.
    func newTemporaryChat() {
        resetConversationState()
        messages.removeAll()
        currentSessionID = nil
        folderChatID = Self.folderChatID(nil)
        currentSessionTitle = ""
        sessionCreatedAt = nil
    }

    /// Everything that must not survive a switch to another conversation.
    /// Async turn steps (image generation, compaction) outlive the switch;
    /// bumping `conversationEpoch` makes them drop their result instead of
    /// landing in the new chat (adr/0003), and cancelling the transport
    /// drops the abandoned stream's late callbacks.
    private func resetConversationState() {
        AudioPlayback.shared.stop(ifAnyOf: messages)   // this chat's song leaves the screen
        cancel()
        titleTask?.cancel()
        titleTask = nil
        conversationEpoch += 1
        endFolderChat()
        assistantMessageIndex = nil
        pendingRequestContext = nil
        decoder = SSEDecoder()
        errorText = nil
        lastTokensPerSecond = nil
        toolbox.startTurn()
        toolRoundsThisTurn = 0
        turnStats = nil
        tokenEstimator = PromptTokenEstimator()
        lastRequest = nil
        countedRequest = nil
    }

    func loadSession(_ file: ChatSessionFile) {
        resetConversationState()
        let imagesDir = ChatSessionStore.imagesDir(for: file.id)
        messages = file.messages.map { pm in
            let images = pm.imageFilenames.compactMap { FileManager.default.contents(atPath: imagesDir + "/" + $0) }
            var message = ChatMessage(
                role: pm.role, content: pm.content, reasoning: pm.reasoning, images: images,
                imageDurations: pm.imageDurations, imagePrompts: pm.imagePrompts, isSummary: pm.isSummary,
                sources: pm.sources
            )
            // The files they came from: saved again under the same names.
            message.imageFilenames = images.count == pm.imageFilenames.count ? pm.imageFilenames : []
            message.citations = pm.citations ?? []
            message.answerStats = pm.answerStats
            if pm.imageSources.count == images.count { message.imageSources = pm.imageSources }
            let audios = pm.audioFilenames.compactMap { FileManager.default.contents(atPath: imagesDir + "/" + $0) }
            if audios.count == pm.audioFilenames.count {
                message.audios = audios
                message.audioFilenames = pm.audioFilenames
                message.audioPrompts = pm.audioPrompts
                message.audioDurations = pm.audioDurations
                if pm.audioSources.count == audios.count { message.audioSources = pm.audioSources }
            }
            return message
        }
        currentSessionID = file.id
        folderChatID = Self.folderChatID(file.id)
        currentSessionTitle = file.title
        sessionCreatedAt = file.createdAt
        titleIsFinal = true
        hasUnsavedChanges = false
    }

    /// Renames the chat on screen: through here, not the session file --
    /// the next turn rewrites that file with this title.
    func renameCurrentSession(_ title: String) {
        currentSessionTitle = title
        titleIsFinal = true
        titleRevision += 1
        titleTask?.cancel()
        hasUnsavedChanges = true
        persistCurrentSession()
    }

    private static let titleSystemPrompt = """
        Write a short title for this conversation: at most six words, in the language the user \
        wrote in, no quotes, no trailing period. Reply with the title only.
        """

    /// After a new chat's first answer: the model names the chat, as the
    /// first 48 characters of the question often don't say much. Once per
    /// chat; a rename (or a failure) leaves it at that.
    /// Cancelled by a rename and by leaving the chat (resetConversationState),
    /// so it doesn't keep the one server busy for nothing.
    func generateTitleIfNeeded(port: Int, modelAlias: String) {
        guard currentSessionID != nil, !titleIsFinal,
              let question = messages.first(where: { $0.role == "user" && !$0.isToolContext }),
              let answer = messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty && !$0.isSummary })
        else { return }
        let epoch = conversationEpoch
        let revision = titleRevision
        let requestMessages: [[String: Any]] = [
            ["role": "system", "content": Self.titleSystemPrompt],
            ["role": "user", "content": "User: \(question.content.prefix(1500))\n\nAssistant: \(answer.content.prefix(1500))"],
        ]
        guard let request = ChatRequestBuilder.completion(port: port, modelAlias: modelAlias, messages: requestMessages) else { return }
        titleIsFinal = true
        titleTask = Task { [weak self] in
            guard let raw = try? await ChatTransport.completion(request), !Task.isCancelled,
                  let title = cleanedChatTitle(raw),
                  let self, epoch == self.conversationEpoch, revision == self.titleRevision else { return }
            self.currentSessionTitle = title
            self.hasUnsavedChanges = true
            self.persistCurrentSession()
        }
    }

    /// Called after every turn that ends with no pending tool call (see
    /// continueWithPendingToolCalls) -- a no-op for a temporary chat
    /// (currentSessionID == nil). "tool" role messages are dropped; a
    /// content-less assistant message is only dropped if it also carries
    /// no image (an image-only tool-call-carrier message is real content
    /// now that images are persisted, not plumbing to discard).
    private func persistCurrentSession() {
        guard let sessionID = currentSessionID, hasUnsavedChanges else { return }
        let imagesDir = ChatSessionStore.imagesDir(for: sessionID)
        var pendingImageWrites: [(path: String, data: Data)] = []

        // Before the tool messages they come from are dropped.
        let sources = ChatMessage.sourcesByAnswer(messages)
        let citations = ChatMessage.citationsByAnswer(messages)
        var persisted = messages.compactMap { msg -> PersistedMessage? in
            guard msg.role != "tool", !msg.isToolContext else { return nil }
            if msg.role == "assistant", msg.content.isEmpty, msg.reasoning.isEmpty, msg.images.isEmpty, msg.audios.isEmpty { return nil }
            // Keyed by this message's own (stable for its lifetime) id, so
            // re-persisting the same session after a later turn doesn't
            // re-derive different filenames for images already on disk.
            let filenames = msg.images.enumerated().map { i, _ in
                i < msg.imageFilenames.count ? msg.imageFilenames[i] : "\(msg.id.uuidString)-\(i).png"
            }
            for (i, data) in msg.images.enumerated() {
                pendingImageWrites.append((imagesDir + "/" + filenames[i], data))
            }
            // Music beside the images (.m4a; songs from before are .wav).
            let audioNames = msg.audios.enumerated().map { i, data in
                i < msg.audioFilenames.count ? msg.audioFilenames[i] : Self.audioFilename(msg.id, i, data)
            }
            for (i, data) in msg.audios.enumerated() {
                pendingImageWrites.append((imagesDir + "/" + audioNames[i], data))
            }
            var persisted = PersistedMessage(
                role: msg.role, content: msg.content, reasoning: msg.reasoning, isSummary: msg.isSummary,
                imageFilenames: filenames, imageDurations: msg.imageDurations, imagePrompts: msg.imagePrompts,
                sources: sources[msg.id] ?? []
            )
            persisted.audioFilenames = audioNames
            persisted.audioPrompts = msg.audioPrompts
            persisted.audioDurations = msg.audioDurations
            persisted.imageSources = msg.imageSources.count == msg.images.count ? msg.imageSources : []
            persisted.audioSources = msg.audioSources.count == msg.audios.count ? msg.audioSources : []
            persisted.citations = citations[msg.id]
            persisted.answerStats = msg.answerStats
            return persisted
        }
        guard !persisted.isEmpty else { return }

        var mediaMissing = false
        if !pendingImageWrites.isEmpty {
            try? FileManager.default.createDirectory(atPath: imagesDir, withIntermediateDirectories: true)
            for (path, data) in pendingImageWrites where !FileManager.default.fileExists(atPath: path) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            // A file that couldn't be written (a full disk): the chat is saved
            // without it rather than listing what isn't there (the text still
            // is); the next save tries the file again.
            let missing = Set(pendingImageWrites.filter { !FileManager.default.fileExists(atPath: $0.path) }
                .map { ($0.path as NSString).lastPathComponent })
            if !missing.isEmpty {
                persisted = persisted.map { $0.withoutFiles(missing) }
                mediaMissing = true
            }
        }
        let referenced = Set(pendingImageWrites.map { ($0.path as NSString).lastPathComponent })

        if currentSessionTitle.isEmpty, let firstUser = messages.first(where: { $0.role == "user" }) {
            currentSessionTitle = String(firstUser.content.prefix(48))
        }
        let title = currentSessionTitle.isEmpty ? "New chat" : currentSessionTitle
        let file = ChatSessionFile(
            id: sessionID,
            title: title,
            createdAt: sessionCreatedAt ?? Date(),
            updatedAt: Date(),
            messages: persisted
        )
        // Images no message refers to any more (compacted, regenerated):
        // only once the chat that no longer lists them is on disk.
        guard ChatSessionStore.save(file) else { return }
        // Still to write: the next save (a later turn, leaving the chat)
        // tries the media again.
        hasUnsavedChanges = mediaMissing
        for name in (try? FileManager.default.contentsOfDirectory(atPath: imagesDir)) ?? [] where !referenced.contains(name) {
            try? FileManager.default.removeItem(atPath: imagesDir + "/" + name)
        }
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

    /// The part compaction replaces: from the first user turn at or after
    /// `keepStart` to the last one starting at or before `count - keepEnd`
    /// -- whole turns only (a tool round split across the cut would leave
    /// a tool result without its call, or a call without results), and
    /// only up to the first turn with an image or music (it would be gone
    /// from the chat, and its file deleted). Nil when there's nothing worth it.
    static func compactionRange(_ messages: [ChatMessage], keepStart: Int, keepEnd: Int) -> Range<Int>? {
        func isTurnStart(_ i: Int) -> Bool { messages[i].role == "user" && !messages[i].isToolContext }
        guard messages.count > keepStart + keepEnd + 1 else { return nil }
        // An earlier summary is compacted again with the rest (else every
        // compaction would leave its summary behind for good).
        guard let start = (keepStart..<messages.count).first(where: { isTurnStart($0) || messages[$0].isSummary }) else { return nil }
        var end = messages.count - keepEnd
        if let media = messages.indices.first(where: { $0 >= start && (!messages[$0].images.isEmpty || !messages[$0].audios.isEmpty) }) {
            end = min(end, media)
        }
        while end > start, end < messages.count, !isTurnStart(end) { end -= 1 }
        guard end > start + 1, end < messages.count else { return nil }
        return start..<end
    }

    private func runCompaction(port: Int, modelAlias: String, keepStart: Int, keepEnd: Int) async {
        guard let middleRange = Self.compactionRange(messages, keepStart: keepStart, keepEnd: keepEnd) else { return }
        let middle = Array(messages[middleRange])

        // Without tool results: file (or web) text must not come back as a
        // trusted summary (adr/0012). Citation markers stay in the answers' text as they are.
        let transcript = CompactionTranscript.make(middle.map {
            CompactionTranscript.Line(role: $0.role, content: $0.content, reasoning: $0.reasoning, isToolContext: $0.isToolContext)
        })

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
            errorText = String(format: NSLocalizedString("Compaction failed: %@", comment: ""), error.localizedDescription)
        }
    }

    func send(
        prompt: String, images: [Data] = [], port: Int, modelAlias: String, settings: ChatSettings,
        server: ServerManager
    ) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        toolbox.startTurn()
        toolRoundsThisTurn = 0
        turnStats = nil
        messages.append(ChatMessage(role: "user", content: prompt, images: images))
        startTurn(port: port, modelAlias: modelAlias, settings: settings, server: server)
    }

    /// The chat's project as the library has it now (adr/0012): read as a
    /// turn starts, so a move, an edit of its instructions or its deletion
    /// applies from the next message. A temporary chat has none.
    private func withProject(_ settings: ChatSettings) -> ChatSettings {
        var settings = settings
        settings.project = currentSessionID.flatMap { ChatLibraryStore.shared.library.projectContext(forChat: $0) }
        settings.folders = folderChat
        return settings
    }

    // MARK: - Folder access (adr/0014)

    /// The chat for the folder tools; nil while the feature is off.
    var folderChat: FolderChat? {
        FolderAccessManager.shared.isEnabled ? FolderChat(id: folderChatID, temporary: currentSessionID == nil) : nil
    }

    /// The chat is left (another one, a closed tab): its folder grants for
    /// the chat, denies and pending plan end, and their cards go.
    private func endFolderChat() {
        folderPrompt?.resolve(nil)
        folderPrompt = nil
        folderPlan = nil
        FolderAccessManager.shared.endChat(folderChatID)
    }

    /// A folder tool's call asks the user about a folder: the card shows in
    /// the chat and the call waits for it (nil: Stop, another chat).
    /// `chatID` and `token`: the call's chat and turn -- a call that outlived
    /// a switch or a Stop never asks in the chat on screen now.
    func askFolderAccess(_ request: FolderGrantRequest, chatID: String, token: Int) async -> GrantChoice? {
        guard let chat = folderChat, chat.id == chatID, token == turnToken else { return nil }
        let prompt = FolderAccessPrompt(request: request, choices: GrantChoice.offered(temporaryChat: chat.temporary), forCall: true)
        folderPrompt?.resolve(nil)
        folderPrompt = prompt
        let answer = await prompt.decide()
        if folderPrompt === prompt { folderPrompt = nil }
        FolderAccessManager.shared.refresh()
        return answer
    }

    /// Allow Folder… in the chat's menu: the user picks a folder, then how
    /// long (a card in the chat); the model may ask again after a deny.
    func allowFolder(level: FolderAccessLevel) {
        guard let chat = folderChat, !(chat.temporary && level > .read) else { return }
        // A call is waiting on its own question: that one first.
        guard folderPrompt?.forCall != true else { return }
        let message = level == .change
            ? NSLocalizedString("Choose a folder the chat may propose changes in. You approve every change.", comment: "")
            : NSLocalizedString("Choose a folder the chat may look in.", comment: "")
        guard let picked = FolderAccessManager.shared.pickFolder(message: message) else { return }
        switch picked {
        case .failure(let error):
            errorText = String(format: NSLocalizedString("That folder can't be shared with the chat: %@", comment: ""), FolderAccessManager.message(error))
        case .success(let root):
            let prompt = FolderAccessPrompt(request: FolderGrantRequest(root: root, level: level),
                                            choices: GrantChoice.offered(temporaryChat: chat.temporary, forCall: false), forCall: false)
            prompt.onAnswer = { [weak prompt] choice in
                do {
                    try FolderAccessManager.shared.userGrant(root, level: level, choice: choice, chat: chat)
                } catch {
                    prompt?.error = FolderAccessManager.message(error)
                }
            }
            prompt.onDone = { [weak self, weak prompt] in
                if let self, self.folderPrompt === prompt { self.folderPrompt = nil }
            }
            folderPrompt = prompt
        }
    }

    /// The folders this chat may use now, for its menu.
    var accessibleFolders: [FolderGrant] {
        guard let chat = folderChat else { return [] }
        return FolderAccessManager.shared.service.accessibleFolders(chat)
    }

    /// The pending plan as the store has it now: a new card, or the card's
    /// newer revision; none once it's gone (a result card stays).
    func refreshFolderPlan() {
        guard let plan = FolderAccessManager.shared.service.plans.pending(chatID: folderChatID) else {
            if folderPlan?.isReviewing == true { folderPlan = nil }
            return
        }
        if let card = folderPlan, card.isReviewing, card.review.plan.id == plan.id {
            card.update(plan)
        } else if folderPlan?.isBusy != true {
            // A new plan: in place of the last one's result.
            let card = FolderPlanModel(review: PlanReview(plan: plan), chatID: folderChatID)
            // A plan proposed while this one ran shows once it's done.
            card.onSettled = { [weak self] in self?.refreshFolderPlan() }
            folderPlan = card
        }
    }

    /// The plan card's Close (or Cancel): a plan waiting behind it shows.
    func dismissFolderPlan() {
        folderPlan = nil
        refreshFolderPlan()
    }

    /// Settings turned folder access off: the plan waiting for approval and
    /// any open prompt go (a running plan finishes; its result stays).
    func folderAccessTurnedOff() {
        folderPrompt?.resolve(nil)
        folderPrompt = nil
        FolderAccessManager.shared.service.plans.cancel(chatID: folderChatID)
        if folderPlan?.isReviewing == true { folderPlan = nil }
    }

    /// The turn's first request, with its project, that project's file
    /// counts (which project_files modes it declares) and its pinned files
    /// -- read first, off the main thread, while the turn already shows as
    /// busy. A Stop or another chat meanwhile drops it.
    private func startTurn(port: Int, modelAlias: String, settings: ChatSettings, server: ServerManager) {
        let base = withProject(settings)
        guard let project = base.project, ProjectIndexer.shared.isEnabled else {
            return startAssistantResponse(port: port, modelAlias: modelAlias, settings: base, server: server)
        }
        isStreaming = true
        let token = turnToken, epoch = conversationEpoch
        Task { [weak self] in
            let files = await ProjectIndexer.shared.summary(for: project.id)
            let pinned = await ProjectIndexer.shared.pinnedFiles(for: project.id)
            guard let self, token == self.turnToken, epoch == self.conversationEpoch else { return }
            var settings = base
            settings.project?.files = files
            settings = self.withPinnedFiles(pinned, settings, port: port, modelAlias: modelAlias, server: server)
            self.startAssistantResponse(port: port, modelAlias: modelAlias, settings: settings, server: server)
        }
    }

    /// The pinned files the turn's requests carry (adr/0012, "Pinned
    /// files"), fixed for the turn: in pin order, each while it fits what's
    /// left of the model's limit and the request's room (the conversation
    /// counted, the answer and the margin kept free); a line for the rest.
    /// Their pages are what the turn's answers may cite, and file text in
    /// the request drops the trust barrier from the turn's start.
    private func withPinnedFiles(_ pinned: (files: [PinnedFileText], notes: [PinnedFileNote]), _ base: ChatSettings,
                                 port: Int, modelAlias: String, server: ServerManager) -> ChatSettings {
        guard var project = base.project, !pinned.files.isEmpty || !pinned.notes.isEmpty else { return base }
        toolbox.notePinnedText()
        let context = RequestContext(port: port, modelAlias: modelAlias, settings: base, server: server)
        let margin = Int((Double(base.maxTokensCap) * ProjectTextBudget.margin).rounded(.up))
        func settings(_ files: [PinnedFileText], _ left: [PinnedFileNote]) -> ChatSettings {
            var s = base
            project.pinned = files
            project.pinnedLeftOut = pinned.notes + left
            s.project = project
            return s
        }
        // Sized at the model's learned ratio, in the pin limit and in the
        // request's room alike: the request without the files (counted when
        // it was) plus their block at that ratio -- unless this very prefix
        // was counted. At 2 bytes a token a book that fits was left out.
        // The last count, when its request differed only in its pins, is
        // used less nothing of its pinned block (the growth alone added):
        // taking it off at a ratio that may be too low could undercount.
        let ratio = ProjectIndexer.pinBytesPerToken(model: base.modelPath)
        let bare = Self.unpinned(base)
        let unpinnedCount = countedTokenEstimate(context, bare, unpinned: true)
        let rest = unpinnedCount ?? requestTokenEstimate(context, bare)
        let countedPinned = unpinnedCount == nil ? 0 : countedRequest?.pinnedBytes ?? 0
        let chosen = PinnedFiles.select(pinned.files, limitTokens: ProjectIndexer.pinLimit(for: base).tokens,
                                        bytesPerToken: ratio) { files in
            let withFiles = settings(files, [])
            let block = Self.pinnedBlockBytes(withFiles)
            let estimate = countedTokenEstimate(context, withFiles)
                ?? rest + PinTokenRatio.tokens(bytes: max(0, block - countedPinned), bytesPerToken: ratio)
            return estimate + base.maxTokens + margin <= base.maxTokensCap
        }
        if let user = messages.lastIndex(where: { $0.role == "user" && !$0.isToolContext }) {
            messages[user].returnedCitations = PinnedFiles.citations(chosen.files, project: project.id)
        }
        return settings(chosen.files, chosen.left)
    }

    /// Re-runs the last user turn with a fresh generation -- drops the
    /// previous assistant reply (if any) so the retry doesn't just pile up
    /// underneath a garbled/unhelpful one, then asks again with the exact
    /// same prompt.
    /// Saves what's there now (app quit).
    func saveNow() { persistCurrentSession() }

    /// The open session is being deleted: nothing of it is saved again.
    func forgetCurrentSession() { currentSessionID = nil }

    /// Its tab was closed: the turn stops (saved as it is), and nothing
    /// still running -- a title request, a tool round's tail -- may write
    /// this chat again (the chat may be open in another tab by then).
    func close() {
        cancel()
        titleTask?.cancel()
        titleTask = nil
        conversationEpoch += 1
        endFolderChat()
        forgetCurrentSession()
    }

    func regenerate(port: Int, modelAlias: String, settings: ChatSettings, server: ServerManager) {
        guard !isBusy else { return }
        AudioPlayback.shared.stop(ifAnyOf: messages)   // the song being played may be the one replaced
        toolbox.startTurn()
        toolRoundsThisTurn = 0
        turnStats = nil
        // The whole last response: assistant turns, tool results and the
        // hidden view_image message, back to the user's own message.
        while let last = messages.last, !(last.role == "user" && !last.isToolContext) {
            messages.removeLast()
        }
        guard messages.last?.role == "user" else { return }
        startTurn(port: port, modelAlias: modelAlias, settings: settings, server: server)
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

    /// The same for music generation: mlx-audio and ACE-Step 1.5's
    /// checkpoints, before the toggle turns on.
    func downloadMusicModel(_ model: MusicModel) async -> Error? {
        isDownloadingModel = true
        defer { isDownloadingModel = false }
        do {
            try await musicManager.download(model)
            return nil
        } catch {
            return error
        }
    }

    func isMusicModelReady(_ model: MusicModel) -> Bool { musicManager.isReady(model) }

    /// A model download from Settings (not in the queue) holds the image or
    /// music generator: a granted turn waits for it rather than unloading
    /// the chat model for a "busy" error.
    private func waitWhileGeneratorsBusy(_ stillCurrent: () -> Bool) async {
        while (mfluxManager.isBusy || musicManager.isBusy), stillCurrent() {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// This turn (since the user's last message) has shown something: an
    /// answer, an image, a song.
    private var turnProducedSomething: Bool {
        guard let start = messages.lastIndex(where: { $0.role == "user" && !$0.isToolContext }) else { return false }
        return messages[(start + 1)...].contains {
            $0.role == "assistant" && (!$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.images.isEmpty || !$0.audios.isEmpty)
        }
    }

    /// A call's arguments as Regenerate should run them again: edit_image's
    /// "latest image" pinned to the image it meant then (the result itself
    /// is the latest one afterwards).
    static func pinnedArguments(_ call: ToolCall, chatImageCount: Int) -> String {
        guard call.name == EditImageTool.toolName else { return call.argumentsJSON }
        var arguments = ChatToolbox.parseArguments(call.argumentsJSON)
        if arguments["index"] == nil { arguments["index"] = chatImageCount }
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else { return call.argumentsJSON }
        return String(decoding: data, as: UTF8.self)
    }

    /// A song's name on disk when the message has none yet: by its index,
    /// with its format's extension.
    static func audioFilename(_ messageID: UUID, _ index: Int, _ data: Data) -> String {
        "\(messageID.uuidString)-audio-\(index).\(AudioCodec.format(of: data).fileExtension)"
    }

    /// An image put in (`by` 1) at, or taken out (`by` -1) from before,
    /// message `j`'s image `image`: the edit_image calls pinned to an image
    /// after it (by its place among the chat's images) follow it there.
    private func shiftPinnedEditIndices(message j: Int, image: Int, by delta: Int) {
        func counts(_ m: ChatMessage) -> Bool { (m.role == "assistant" || m.role == "user") && !m.isToolContext }
        guard counts(messages[j]) else { return }
        // 1-based place of the first image that moves.
        let first = messages[..<j].filter(counts).reduce(0) { $0 + $1.images.count } + image + 1
        for m in messages.indices {
            for k in messages[m].imageSources.indices where messages[m].imageSources[k].tool == EditImageTool.toolName {
                let arguments = ChatToolbox.parseArguments(messages[m].imageSources[k].arguments)
                guard let pinned = arguments["index"] as? Int, pinned >= first || delta < 0 && pinned == first - 1,
                      // The removed image itself: 0, nothing to edit any more (not made again).
                      let data = try? JSONSerialization.data(withJSONObject: arguments.merging(["index": pinned >= first ? pinned + delta : 0]) { $1 },
                                                             options: [.sortedKeys])
                else { continue }
                messages[m].imageSources[k].arguments = String(decoding: data, as: UTF8.self)
            }
        }
    }

    /// The image or piece of music can be made again (it has its source).
    func canRegenerateMedia(_ message: ChatMessage, _ kind: MediaKind, _ index: Int) -> Bool {
        switch kind {
        case .image:
            guard message.imageSources.count == message.images.count, message.imageSources.indices.contains(index) else { return false }
            let source = message.imageSources[index]
            // An edit of an image since removed.
            return source.tool != EditImageTool.toolName || ChatToolbox.parseArguments(source.arguments)["index"] as? Int != 0
        case .music: return message.audioSources.count == message.audios.count && message.audioSources.indices.contains(index)
        }
    }

    /// Makes one image or piece of music again -- the same tool call, a new
    /// seed -- and puts it in place of the old one. No chat model request:
    /// only the generator runs (with the chat model unloaded around it, as
    /// in a turn, when that's set).
    /// Makes another image or piece of music from the same tool call (a new
    /// seed) and puts it right after the one it came from: a variant, so
    /// the one that was there isn't lost (Remove takes either away).
    /// `tweak`: first the Creator mode draft, prefilled, to change the
    /// prompt, the model or the knobs. No chat model request: only the
    /// generator runs (the chat model unloaded around it, as in a turn).
    func regenerateMedia(messageID: UUID, kind: MediaKind, index: Int, settings baseSettings: ChatSettings,
                         server: ServerManager, tweak: Bool = false) {
        guard !isBusy, let i = messages.firstIndex(where: { $0.id == messageID }),
              canRegenerateMedia(messages[i], kind, index) else { return }
        let source = kind == .image ? messages[i].imageSources[index] : messages[i].audioSources[index]
        let baseline = currentSettings(baseSettings)
        AudioPlayback.shared.stop(ifAnyOf: [messages[i]])
        errorText = nil
        let epoch = conversationEpoch
        let token = turnToken
        // Stop (cancel bumps turnToken and cancels the task) or another
        // chat opened meanwhile: the result is dropped, errors too.
        func stillCurrent() -> Bool { epoch == conversationEpoch && token == turnToken && !Task.isCancelled }
        isRunningTools = true
        toolTask = Task {
            var call = ToolCall(id: "regenerate", name: source.tool, argumentsJSON: source.arguments)
            var settings = GenerationDraft.pinning(source.model, for: call, baseline)
            var model = source.model
            if tweak, let draftKind = GenerationDraft.kind(of: call, settings) {
                guard stillCurrent() else { return }   // Stop before it started: no draft to wait on
                let draft = GenerationDraft(kind: draftKind, call: call, settings: settings)
                draft.anchor = (messageID, index)
                self.draft = draft
                let outcome = await draft.decide(countdown: 0)   // asked for: waits for Generate
                if self.draft === draft { self.draft = nil }
                guard stillCurrent(), outcome == .run else {
                    if token == turnToken { isRunningTools = false }
                    return
                }
                call = draft.editedCall
                // Read again: the draft may have waited long, settings may have changed.
                settings = draft.apply(to: GenerationDraft.pinning(source.model, for: call, currentSettings(baseSettings)))
                model = draft.modelID
            }
            // The per-turn limits don't apply: nothing else is made meanwhile.
            toolbox.startTurn()
            // Only if the generator will really run (it may have been turned
            // off since): a refusal needs no unload, nor the "Generating…" UI.
            let runs = kind == .image
                ? imageTool.willGenerate([call], settings: settings, chatImages: chatImages)
                : musicTool.willGenerate([call], settings: settings) && musicManager.isReady(settings.musicModel)
            isGeneratingMedia = runs
            generatingKind = runs ? kind : nil
            defer {
                // Only what this run set: a turn started after a Stop keeps its own.
                if runs {
                    isGeneratingMedia = false
                    generatingKind = nil
                    mediaQueuePosition = nil
                }
                isUnloadingModelForMedia = false
                if token == turnToken { isRunningTools = false }
            }
            // Its turn in the app-wide queue, like a chat's own generation.
            var ticket: GenerationQueue.Ticket?
            if runs {
                do {
                    ticket = try await GenerationQueue.shared.acquire(
                        isCancelled: { !stillCurrent() },
                        onPosition: { [weak self] in self?.mediaQueuePosition = $0 }
                    )
                    await waitWhileGeneratorsBusy(stillCurrent)
                } catch {
                    return
                }
            }
            defer { ticket?.release() }
            guard stillCurrent() else { return }
            // Only a model that's up comes back after: a stopped server stays
            // stopped (a reload would fail with "the server isn't running").
            let unload = runs && settings.unloadModelDuringImageGen && server.canAnswer
            if unload {
                isUnloadingModelForMedia = true
                await server.unloadModel()
            }
            let variantSource = MediaSource(tool: call.name, arguments: call.argumentsJSON, model: model)
            let result = await toolbox.run(call, context: ToolContext(settings: settings, generatedImages: generatedImages, chatImages: chatImages))
            if unload {
                do { try await server.ensureModelLoaded() } catch {
                    if stillCurrent() {
                        errorText = String(format: NSLocalizedString("Failed to reload the chat model after image generation: %@", comment: ""), error.localizedDescription)
                    }
                }
            }
            guard stillCurrent(), let j = messages.firstIndex(where: { $0.id == messageID }) else { return }
            recordToolUsage(call, result, settings: settings, chatModel: nil, asToolCall: false)   // the user's, not the model's
            let at = index + 1
            let id = messages[j].id.uuidString
            switch result {
            case .generatedImage(let data, let seconds, let prompt, _) where kind == .image && messages[j].images.count >= at:
                // The names the others were saved under first (a message never
                // loaded from disk has none yet), then the variant's own.
                if messages[j].imageFilenames.count != messages[j].images.count {
                    messages[j].imageFilenames = messages[j].images.indices.map { "\(id)-\($0).png" }
                }
                shiftPinnedEditIndices(message: j, image: at, by: 1)
                messages[j].images.insert(data, at: at)
                messages[j].imageFilenames.insert("\(UUID().uuidString).png", at: at)
                if messages[j].imageDurations.count >= at { messages[j].imageDurations.insert(seconds, at: at) }
                if messages[j].imagePrompts.count >= at { messages[j].imagePrompts.insert(prompt, at: at) }
                if messages[j].imageSources.count >= at { messages[j].imageSources.insert(variantSource, at: at) }
            case .generatedAudio(let data, let seconds, let prompt, _) where kind == .music && messages[j].audios.count >= at:
                if messages[j].audioFilenames.count != messages[j].audios.count {
                    messages[j].audioFilenames = messages[j].audios.enumerated().map { Self.audioFilename(messages[j].id, $0, $1) }
                }
                // A clip's id is its index: one playing now would take the variant's.
                AudioPlayback.shared.stop(ifAnyOf: [messages[j]])
                messages[j].audios.insert(data, at: at)
                messages[j].audioFilenames.insert("\(UUID().uuidString).\(AudioCodec.format(of: data).fileExtension)", at: at)
                if messages[j].audioDurations.count >= at { messages[j].audioDurations.insert(seconds, at: at) }
                if messages[j].audioPrompts.count >= at { messages[j].audioPrompts.insert(prompt, at: at) }
                if messages[j].audioSources.count >= at { messages[j].audioSources.insert(variantSource, at: at) }
            case .text(let text), .refused(let text):
                // The tool's words to the model, without its instructions.
                errorText = text.components(separatedBy: " Do not ").first ?? text
                return
            default:
                return
            }
            hasUnsavedChanges = true
            persistCurrentSession()
        }
    }

    /// Takes one generated image or piece of music out of a message (its
    /// file goes with the next save).
    func removeMedia(messageID: UUID, kind: MediaKind, index: Int) {
        guard !isBusy, let j = messages.firstIndex(where: { $0.id == messageID }) else { return }
        func drop<T>(_ array: inout [T]) { if array.indices.contains(index) { array.remove(at: index) } }
        // The names the rest were saved under, first: a message never loaded
        // from disk derives them from the index, which is about to shift.
        let id = messages[j].id.uuidString
        switch kind {
        case .image:
            guard messages[j].images.indices.contains(index) else { return }
            if messages[j].imageFilenames.count != messages[j].images.count {
                messages[j].imageFilenames = messages[j].images.indices.map { "\(id)-\($0).png" }
            }
            shiftPinnedEditIndices(message: j, image: index + 1, by: -1)
            drop(&messages[j].images); drop(&messages[j].imageFilenames); drop(&messages[j].imageDurations)
            drop(&messages[j].imagePrompts); drop(&messages[j].imageSources)
        case .music:
            guard messages[j].audios.indices.contains(index) else { return }
            AudioPlayback.shared.stop(ifAnyOf: [messages[j]])
            if messages[j].audioFilenames.count != messages[j].audios.count {
                messages[j].audioFilenames = messages[j].audios.enumerated().map { Self.audioFilename(messages[j].id, $0, $1) }
            }
            drop(&messages[j].audios); drop(&messages[j].audioFilenames); drop(&messages[j].audioDurations)
            drop(&messages[j].audioPrompts); drop(&messages[j].audioSources)
        }
        hasUnsavedChanges = true
        persistCurrentSession()
    }

    /// `offerTools: false` for the answer after the last allowed tool round.
    private func startAssistantResponse(port: Int, modelAlias: String, settings: ChatSettings, server: ServerManager, offerTools: Bool = true) {
        errorText = nil
        pendingRequestContext = RequestContext(port: port, modelAlias: modelAlias, settings: settings, server: server)
        messages.append(ChatMessage(role: "assistant"))
        assistantMessageIndex = messages.count - 1

        let body = ChatRequestBuilder.streamingBody(
            modelAlias: modelAlias, settings: settings,
            history: Array(messages.dropLast(1)),
            tools: offerTools ? toolbox.definitions(for: settings) : [],
            projectTools: toolbox.projectToolNames
        )
        guard let request = ChatRequestBuilder.streaming(port: port, body: body) else {
            errorText = NSLocalizedString("failed to build request", comment: "")
            return
        }
        // What the response's usage calibrates the estimate against; until
        // it comes, nothing is counted (an older count may be of a history
        // compaction or a new turn has changed since).
        countedRequest = nil
        let sentTools = offerTools ? toolbox.definitions(for: settings) : []
        lastRequest = SentRequest(measure: ChatRequestBuilder.measure(body), historyCount: messages.count - 1,
                                  framing: framing(modelAlias: modelAlias, settings: settings, tools: sentTools),
                                  modelPath: settings.modelPath, pinnedBytes: Self.pinnedBlockBytes(settings),
                                  unpinnedFraming: framing(modelAlias: modelAlias, settings: Self.unpinned(settings), tools: sentTools),
                                  carriesPins: !(settings.project?.pinned.isEmpty ?? true))

        decoder = SSEDecoder()
        approxCompletionTokens = 0
        usageCompletionTokens = nil
        lastTokensPerSecond = nil
        requestStats = AnswerStats.Request()
        if turnStats == nil {
            let path = settings.modelPath
            turnStats = AnswerStats(model: path.flatMap { ModelCatalog.shared.model(id: $0)?.displayName } ?? modelAlias,
                                    modelFolder: path.map { ($0 as NSString).lastPathComponent },
                                    profile: settings.profileName, contextTokens: settings.maxTokensCap)
            turnStartDate = nil
        }
        isStreaming = true
        // Another tab unloaded the model for an image: this answer waits for
        // it to come back (the server refuses requests meanwhile) instead
        // of failing. Stop / leaving the chat ends the wait.
        // Also a model the chat's own send just started (ContentView.send):
        // the message is in, the answer comes once it's loaded.
        func modelAway() -> Bool { server.suspendedForImageGeneration || isAnotherChatUnloadingModel() || server.isStarting }
        guard modelAway() else { return startStreamIfModelUp(request, server: server) }
        let token = turnToken, epoch = conversationEpoch
        Task { [weak self] in
            while let self, modelAway(), token == self.turnToken, epoch == self.conversationEpoch {
                self.isWaitingForModelLoad = server.isStarting
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            self?.isWaitingForModelLoad = false
            guard let self, token == self.turnToken, epoch == self.conversationEpoch else { return }
            self.startStreamIfModelUp(request, server: server)
        }
    }

    /// Streams the request, or -- the model failed to start, or nothing
    /// will start it -- ends the turn with why: a request to a port nobody
    /// listens on only said "Could not connect to the server".
    private func startStreamIfModelUp(_ request: URLRequest, server: ServerManager) {
        if server.canAnswer { return startStream(request) }
        isStreaming = false
        if case .failed(let reason) = server.state {
            errorText = String(format: NSLocalizedString("The model didn't start: %@", comment: "chat: the auto-start failed"), reason)
        } else {
            errorText = NSLocalizedString("The model isn't running. Send again to start it.", comment: "chat")
        }
        dropEmptyAssistantPlaceholder()
        closeDanglingToolCalls()
        persistCurrentSession()
    }

    private func startStream(_ request: URLRequest) {
        transport.stream(request, onText: { [weak self] text in
            self?.handle(self?.decoder.feed(text) ?? [])
        }, onComplete: { [weak self] completion in
            self?.streamDidComplete(completion)
        })
    }

    func cancel() {
        isWaitingForModelLoad = false
        draft?.resolve(nil)
        draft = nil
        // A call waiting on a folder prompt stops; one the user opened stays.
        if folderPrompt?.forCall == true {
            folderPrompt?.resolve(nil)
            folderPrompt = nil
        }
        transport.cancel()
        turnToken += 1
        isStreaming = false
        toolTask?.cancel()
        toolTask = nil
        isRunningTools = false
        compactionTask?.cancel()
        closeDanglingToolCalls()
        // What there is so far (the user's message, a partial answer) is
        // kept: Stop, a switch to another chat and quitting all come here.
        dropEmptyAssistantPlaceholder()
        persistCurrentSession()
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
    /// at once), for the model and the project the turn started with.
    private func currentSettings(_ start: ChatSettings) -> ChatSettings {
        guard let modelPath = start.modelPath else { return start }
        var now = ChatSettings(profile: ProfileManager.shared.resolved(for: modelPath), maxTokensCap: start.maxTokensCap)
        now.modelPath = modelPath
        now.modelSupportsVision = start.modelSupportsVision
        now.project = start.project
        // Turned off mid-turn: stops at once.
        now.folders = FolderAccessManager.shared.isEnabled ? start.folders : nil
        return now
    }

    private func streamDidComplete(_ completion: ChatTransport.Completion) {
        if let statusCode = completion.statusCode, completion.isHTTPError {
            pinnedRequestFailed()
            isStreaming = false
            errorText = ChatTransport.serverErrorMessage(statusCode: statusCode, body: completion.errorBody)
            dropEmptyAssistantPlaceholder()
            closeDanglingToolCalls()
            persistCurrentSession()
            return
        }
        handle(decoder.finish())
        if completion.error == nil { recordRequestStats(completion) }
        if let error = completion.error, (error as NSError).code != NSURLErrorCancelled {
            if requestStats.promptTokens == nil { pinnedRequestFailed() }
            errorText = error.localizedDescription
            dropEmptyAssistantPlaceholder()
        }
        finalizeTokensPerSecond(firstToken: completion.firstDataDate, endDate: completion.endDate)
        if completion.error != nil { closeDanglingToolCalls() }   // no follow-up: keep the history valid
        continueWithPendingToolCalls(afterError: completion.error != nil)
    }

    /// The request failed without a count (refused, or the server gone):
    /// when it carried pinned text, likely past the context with pins sized
    /// too small, and no count comes back to correct the ratio -- the
    /// failure does (PinTokenRatios.recordFailure). Nothing is shown.
    private func pinnedRequestFailed() {
        guard let request = lastRequest, request.carriesPins else { return }
        ProjectIndexer.shared.recordPinnedRequestFailed(model: request.modelPath)
    }

    /// The request that just ended, in the turn's answer details.
    private func recordRequestStats(_ completion: ChatTransport.Completion) {
        guard var stats = turnStats else { return }
        var request = requestStats
        request.time(sent: completion.startDate, firstToken: completion.firstDataDate, lastToken: completion.endDate)
        stats.requests = (stats.requests ?? []) + [request]
        if turnStartDate == nil { turnStartDate = completion.startDate }
        stats.totalSeconds = turnStartDate.map { completion.endDate.timeIntervalSince($0) }
        stats.date = completion.endDate
        turnStats = stats
    }

    // MARK: - Usage statistics

    /// One use for the opted-in statistics (adr/0015), with the model's
    /// family. A temporary chat counts nothing, not even a number.
    private func recordUsage(_ feature: TelemetryFeature, model: String?) {
        guard currentSessionID != nil else { return }
        UsageTelemetry.shared.record(feature, model: model)
    }

    /// A tool that ran (not a refusal, an unknown tool or one this chat
    /// doesn't offer, which answer in text): a tool call, when the model
    /// made it, and the image or song it made.
    private func recordToolUsage(_ call: ToolCall, _ result: ToolResult, settings: ChatSettings, chatModel: String?, asToolCall: Bool) {
        if case .refused = result { return }
        guard toolbox.tools.contains(where: { $0.name == call.name && $0.isOffered(settings) }) else { return }
        if asToolCall { recordUsage(.toolCalls, model: chatModel) }
        switch result {
        case .generatedImage:
            let edit = call.name == EditImageTool.toolName
            let model = edit ? settings.imageEditModel : settings.imageGenModel
            recordUsage(edit ? .imageEdit : .imageGenerate, model: model?.hfRepo)
        case .generatedAudio:
            recordUsage(.music, model: settings.musicModel.hfRepo)
        default:
            break
        }
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
            if !afterError, errorText == nil, let idx = assistantMessageIndex, idx < messages.count,
               messages[idx].role == "assistant", !messages[idx].content.isEmpty || !messages[idx].images.isEmpty {
                // An LLM text answer: how it was made, for its info popover.
                if !messages[idx].content.isEmpty, messages[idx].toolCalls.isEmpty, let stats = turnStats {
                    messages[idx].answerStats = stats
                }
                // An answer that came through: what the review prompt counts.
                ReviewPrompter.shared.recordAnswer()
                recordUsage(.chat, model: pendingRequestContext?.settings.modelPath)
            }
            // After an error too: the history is valid (dangling tool calls
            // closed), and the user's message must not be lost.
            turnStats = nil
            persistCurrentSession()
            return
        }
        let toolCalls = messages[idx].toolCalls
        if var stats = turnStats {
            stats.toolCalls = (stats.toolCalls ?? 0) + toolCalls.count
            turnStats = stats
        }
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

    /// Every image in this conversation, attached or generated, oldest
    /// first (edit_image). Not the copies view_image put in front of the
    /// model.
    private var chatImages: [(data: Data, prompt: String)] {
        messages.filter { ($0.role == "assistant" || $0.role == "user") && !$0.isToolContext }.flatMap { msg in
            msg.images.enumerated().map { (data: $1, prompt: msg.role == "user" ? "attached by the user" : msg.imagePrompts[safe: $0] ?? "") }
        }
    }

    private func executeToolCalls(_ calls: [ToolCall], sourceIndex: Int, context: RequestContext, token: Int) async {
        // Read once, before anything acts on them: the declared tool names
        // and the arguments as the tools expect them (a fenced or
        // single-quoted object, an alias, "5" for 5...), so the generator
        // checks, drafts and saved sources see what will run.
        var toolCalls = calls.map(toolbox.prepare)
        // Captured before the first suspension: a conversation switch or a
        // Stop during any await below ends this round.
        let epoch = conversationEpoch
        func stillCurrent() -> Bool { epoch == conversationEpoch && token == turnToken && !Task.isCancelled }

        // Tool calls in the answer that was requested *without* tools (the
        // model repeating them from history): refused, the turn ends.
        if toolRoundsThisTurn >= maxToolRoundsPerTurn {
            for call in toolCalls {
                toolbox.recordRefusal(call)
                var refusal = ChatMessage(role: "tool", content: "Not run: tool limit for this message reached.", toolCallID: call.id)
                refusal.isRefusal = true
                messages.append(refusal)
            }
            // Only when the turn gave the user nothing: calls repeated after
            // the image, song or answer was already there are just dropped.
            if !turnProducedSomething {
                errorText = String(format: NSLocalizedString("Stopped: the model kept calling tools (%lld rounds in one turn).", comment: ""), maxToolRoundsPerTurn)
            }
            isRunningTools = false
            isStreaming = false
            persistCurrentSession()
            return
        }

        var settings = currentSettings(context.settings)
        // The trust barrier (adr/0012), per call and before anything below:
        // beside a project call, or after file text came back this turn, the
        // network and generator calls are refused -- no draft, no queue
        // ticket, no unload for them.
        let untrusted = toolbox.trustRefusals(Array(toolCalls.prefix(maxToolCallsPerRound)), settings: settings)
        // Arguments that couldn't be read (toolbox.understood, below): run
        // answers with the error; no generator gets ready for them. Asked of
        // each call, not by id: a repeated id mustn't take a readable
        // generator call's preflight away while it still runs.

        // Creator mode: each image or song asked for is first an editable
        // draft (prompt, model, knobs), going ahead by itself after the
        // countdown unless the user touches it -- before the queue and the
        // chat model's unload, which the user's editing mustn't hold.
        var drafts: [String: GenerationDraft] = [:]
        var skipped: Set<String> = []
        if settings.creatorMode {
            isStreaming = false
            for (i, call) in toolCalls.enumerated() {
                guard i < maxToolCallsPerRound, !untrusted.contains(call.id), toolbox.understood(call), let kind = GenerationDraft.kind(of: call, settings),
                      kind == .music ? musicTool.willGenerate([call], settings: settings) && musicManager.isReady(settings.musicModel)
                                     : imageTool.willGenerate([call], settings: settings, chatImages: chatImages)
                else { continue }
                let draft = GenerationDraft(kind: kind, call: call, settings: settings)
                self.draft = draft
                let outcome = await draft.decide(countdown: settings.creatorCountdown)
                if self.draft === draft { self.draft = nil }
                guard stillCurrent(), let outcome else { return }   // Stop / another chat: cancel() tidied up
                if outcome == .skip {
                    skipped.insert(call.id)
                } else {
                    toolCalls[i] = draft.editedCall
                    drafts[call.id] = draft
                }
            }
        }
        // Read again: a draft may have waited long, settings may have changed.
        settings = currentSettings(context.settings)
        /// A call's settings: the models its draft chose.
        func settingsFor(_ call: ToolCall, _ base: ChatSettings) -> ChatSettings {
            drafts[call.id].map { $0.apply(to: base) } ?? base
        }

        // Images and music alike: either generator takes most of this
        // Mac's memory, so neither runs beside the other.
        let images = chatImages
        // Past the per-response cap a call isn't run: it mustn't queue or unload either.
        let running = toolCalls.prefix(maxToolCallsPerRound).filter { !skipped.contains($0.id) && !untrusted.contains($0.id) && toolbox.understood($0) }
        let wantsImage = running.contains { imageTool.willGenerate([$0], settings: settingsFor($0, settings), chatImages: images) }
        let wantsMusic = running.contains {
            let s = settingsFor($0, settings)
            return musicTool.willGenerate([$0], settings: s) && musicManager.isReady(s.musicModel)
        }
        let willActuallyGenerate = wantsImage || wantsMusic
        // Only when a generator will actually run -- a refused call
        // shouldn't flash the "Generating…" UI / pulse.
        isGeneratingMedia = willActuallyGenerate
        generatingKind = willActuallyGenerate ? (wantsMusic && !wantsImage ? .music : .image) : nil
        isStreaming = false
        defer { isGeneratingMedia = false; generatingKind = nil; mediaQueuePosition = nil }

        // One generator at a time, app-wide: another chat's image or song
        // first, then this one (waiting shows in the chat), rather than a
        // refusal. Stop or leaving the chat takes it out of the queue.
        var ticket: GenerationQueue.Ticket?
        if willActuallyGenerate {
            do {
                ticket = try await GenerationQueue.shared.acquire(
                    isCancelled: { !stillCurrent() },
                    onPosition: { [weak self] in self?.mediaQueuePosition = $0 }
                )
                // A Settings download holds a generator too: its turn waits for that.
                await waitWhileGeneratorsBusy(stillCurrent)
            } catch {
                return   // Stop / another chat: cancel() and the reset tidy up
            }
            // Before the release's defer below: handed back here, or the
            // queue would stay taken for good.
            guard stillCurrent() else {
                ticket?.release()
                return
            }
        }
        // After the model's reload below (defers run last-in first-out, and
        // this one is declared before the reload's code runs): the next in
        // line starts from a loaded model, as it expects.
        defer { ticket?.release() }

        // A diffusion model's own peak memory can rival or exceed a loaded
        // chat model's (Z-Image Turbo alone peaked near 25 GB on a 24 GB
        // Mac), so the chat model is unloaded first and reloaded after,
        // unless the user has said their Mac fits both.
        let shouldUnload = settings.unloadModelDuringImageGen && willActuallyGenerate
        if shouldUnload {
            isUnloadingModelForMedia = true
            await context.server.unloadModel()
        }
        defer { isUnloadingModelForMedia = false }

        var pendingModelImages: [Data] = []
        for (i, call) in toolCalls.enumerated() {
            guard stillCurrent() else { break }
            guard i < maxToolCallsPerRound else {
                toolbox.recordRefusal(call)
                messages.append(ChatMessage(
                    role: "tool", content: "Not run: at most \(maxToolCallsPerRound) tool calls per response.",
                    toolCallID: call.id
                ))
                continue
            }
            if skipped.contains(call.id) {
                toolbox.recordRefusal(call)
                var note = ChatMessage(role: "tool", content: "Not run: the user chose not to make this. Don't call it again "
                                       + "for this request; answer in text.", toolCallID: call.id)
                note.isRefusal = true
                messages.append(note)
                continue
            }
            if untrusted.contains(call.id) {
                let text = toolbox.trustRefusalText(call, settings: settings)
                toolbox.recordRefusal(call)
                var refusal = ChatMessage(role: "tool", content: text, toolCallID: call.id)
                refusal.isRefusal = true
                messages.append(refusal)
                continue
            }
            settings = settingsFor(call, currentSettings(context.settings))
            if willActuallyGenerate, call.name == MusicToolRunner.toolName {
                generatingKind = .music
            } else if willActuallyGenerate, ImageToolRunner.runsGenerator(call.name, settings) {
                generatingKind = .image
            }
            let source = MediaSource(tool: call.name, arguments: Self.pinnedArguments(call, chatImageCount: chatImages.count),
                                     model: drafts[call.id]?.modelID)
            var toolContext = ToolContext(settings: settings, generatedImages: generatedImages, chatImages: chatImages, chat: currentSessionID)
            let chatID = folderChatID
            toolContext.askFolderAccess = { [weak self] request in await self?.askFolderAccess(request, chatID: chatID, token: token) }
            if toolbox.budgetedToolNames.contains(call.name) {
                // What the next request has room for now, the results before
                // this one counted: the tool sizes its answer to it.
                toolContext.projectTextBytes = ProjectTextBudget.allowance(
                    contextTokens: settings.maxTokensCap, requestTokens: requestTokenEstimate(context, settings),
                    maxTokens: settings.maxTokens).map(ProjectTextBudget.bytes(forTokens:)) ?? 0
            }
            let result = await toolbox.run(call, context: toolContext)
            guard stillCurrent() else { break }
            // A proposal went to the chat's plan: its card shows it.
            if call.name == FolderTools.changeName { refreshFolderPlan() }
            recordToolUsage(call, result, settings: settings, chatModel: context.settings.modelPath, asToolCall: true)
            switch result {
            case .text(let text):
                messages.append(ChatMessage(role: "tool", content: text, toolCallID: call.id))
            case .refused(let text):
                var refusal = ChatMessage(role: "tool", content: text, toolCallID: call.id)
                refusal.isRefusal = true
                messages.append(refusal)
            case .imageForModel(let data, let text):
                messages.append(ChatMessage(role: "tool", content: text, toolCallID: call.id))
                pendingModelImages.append(data)
            case .projectText(let output):
                // Fitted into what the next request has room for, measured
                // with the results before it.
                let fitted = toolbox.fitProjectResult(output, tool: call.name, requestTokens: requestTokenEstimate(context, settings),
                                                      settings: settings)
                var result = ChatMessage(role: "tool", content: fitted.text, toolCallID: call.id)
                result.returnedCitations = fitted.returned
                messages.append(result)
            case .generatedImage(let data, let seconds, let prompt, let text):
                if sourceIndex < messages.count {
                    messages[sourceIndex].images.append(data)
                    messages[sourceIndex].imageDurations.append(seconds)
                    messages[sourceIndex].imagePrompts.append(prompt)
                    // Aligned, or none: an older message's images have no source.
                    if messages[sourceIndex].imageSources.count == messages[sourceIndex].images.count - 1 {
                        messages[sourceIndex].imageSources.append(source)
                    }
                }
                messages.append(ChatMessage(role: "tool", content: text, toolCallID: call.id))
            case .generatedAudio(let data, let seconds, let prompt, let text):
                if sourceIndex < messages.count {
                    messages[sourceIndex].audios.append(data)
                    messages[sourceIndex].audioDurations.append(seconds)
                    messages[sourceIndex].audioPrompts.append(prompt)
                    if messages[sourceIndex].audioSources.count == messages[sourceIndex].audios.count - 1 {
                        messages[sourceIndex].audioSources.append(source)
                    }
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
                errorText = String(format: NSLocalizedString("Failed to reload the chat model after image generation: %@", comment: ""), error.localizedDescription)
                persistCurrentSession()   // the generated image is kept
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

    /// The next request's prompt tokens as it would be sent now: the whole
    /// history so far, with the tools it would declare. In a tool round it
    /// grew from the request the server just counted: that count, plus the
    /// messages since (the call, the results so far) and any growth of the
    /// rest, at the estimator's conservative ratio.
    private func requestTokenEstimate(_ context: RequestContext, _ settings: ChatSettings) -> Int {
        if let counted = countedTokenEstimate(context, settings) { return counted }
        let body = ChatRequestBuilder.streamingBody(modelAlias: context.modelAlias, settings: settings, history: messages,
                                                    tools: toolbox.definitions(for: settings), projectTools: toolbox.projectToolNames)
        return tokenEstimator.estimate(ChatRequestBuilder.measure(body))
    }

    /// The estimate from the server's count of the last request, when it
    /// covers this one (the same framing, the history only grown); nil
    /// otherwise. A changed system prompt or profile (read again mid-turn)
    /// or a new declaration isn't covered.
    /// `unpinned`: `settings` has no pinned block, matched against the
    /// counted request's framing without its own.
    private func countedTokenEstimate(_ context: RequestContext, _ settings: ChatSettings, unpinned: Bool = false) -> Int? {
        guard let counted = countedRequest, counted.historyCount <= messages.count else { return nil }
        let framing = framing(modelAlias: context.modelAlias, settings: settings, tools: toolbox.definitions(for: settings))
        guard framing.isCovered(by: unpinned ? counted.unpinnedFraming : counted.framing) else { return nil }
        let added = ChatRequestBuilder.measure(["messages": messages[counted.historyCount...].map(ChatRequestBuilder.serialize)])
        return tokenEstimator.estimate(countedPlus: added)
    }

    /// The settings without pinned files or their notes.
    private static func unpinned(_ settings: ChatSettings) -> ChatSettings {
        var s = settings
        s.project?.pinned = []
        s.project?.pinnedLeftOut = []
        return s
    }

    /// The bytes of the pinned block the system prompt carries (its files
    /// and notes), as `measure` counts them.
    private static func pinnedBlockBytes(_ settings: ChatSettings) -> Int {
        guard let p = settings.project else { return 0 }
        return PinnedFiles.jsonBytes(PinnedFiles.block(p.pinned, notes: p.pinnedLeftOut))
    }

    /// A request without its history's messages, serialized. The system
    /// prompt as with tools declared (the tool-use rule then joins it).
    private func framing(modelAlias: String, settings: ChatSettings, tools: [[String: Any]]) -> Framing {
        func data(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data() }
        var base = ChatRequestBuilder.streamingBody(modelAlias: modelAlias, settings: settings, history: [], tools: tools)
        base["tools"] = nil
        var byName: [String: Data] = [:]
        for tool in tools {
            byName[(tool["function"] as? [String: Any])?["name"] as? String ?? ""] = data(tool)
        }
        return Framing(base: data(base), tools: byName)
    }

    /// From the first token (the first "data:" line, not a prefill
    /// keepalive), as the answer's details measure it.
    private func finalizeTokensPerSecond(firstToken: Date?, endDate: Date) {
        guard let start = firstToken else { return }
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
            case .usage(let completionTokens, let promptTokens, let cachedTokens, let reasoningTokens):
                usageCompletionTokens = completionTokens
                requestStats.completionTokens = completionTokens
                requestStats.promptTokens = promptTokens
                requestStats.cachedTokens = cachedTokens
                requestStats.reasoningTokens = reasoningTokens
                if let promptTokens, let request = lastRequest {
                    countedRequest = tokenEstimator.calibrate(request.measure, promptTokens: promptTokens) ? request : nil
                    ProjectIndexer.shared.recordPromptTokens(model: request.modelPath, request.measure, promptTokens: promptTokens,
                                                             carriedPins: request.carriesPins)
                }
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
