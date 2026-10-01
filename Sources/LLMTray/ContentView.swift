import SwiftUI
import LLMTrayCore

/// The popover: header, chat and composer. Holds what they share -- the
/// selected model, the draft (ComposerModel) -- and sends turns to ChatClient
/// with the selected model's profile.
struct ContentView: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var presentation: ChatPresentation
    // Chat, tool and server-launch settings live in profiles (see
    // ProfileManager): the selected model's profile, layered on Default.
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var catalog = ModelCatalog.shared
    @ObservedObject private var tabs = ChatTabs.shared
    // Owned by AppDelegate (ChatPresentation), not this view: the popover
    // and the chat window each build their own ContentView, and the draft
    // has to carry over between them.
    @EnvironmentObject private var composer: ComposerModel

    // Persists across launches -- picking up where you left off. Also read
    // by AppDelegate's auto-start and quick menu.
    @AppStorage(Pref.selectedModelID) private var selectedModelID: String?
    @AppStorage(Pref.port) private var port: Int
    @AppStorage(Pref.showReasoning) private var showReasoning: Bool
    @AppStorage(Pref.showToolCalls) private var showToolCalls: Bool
    // Compaction keeps these many messages verbatim at the start and end
    // of a session, replacing everything in between with one
    // model-generated summary (see ChatClient.compactSession).
    @AppStorage(Pref.compactKeepStart) private var compactKeepStart: Int
    @AppStorage(Pref.compactKeepEnd) private var compactKeepEnd: Int

    /// The chats sidebar: over the chat in the popover (closed on each
    /// open), beside it in the window (remembered).
    @State private var showsSidebarOverlay = false
    @AppStorage(Pref.chatWindowSidebar) private var showsWindowSidebar: Bool
    @AppStorage(Pref.chatWindowShowsModelControls) private var windowShowsModelControls: Bool
    @FocusState private var isInputFocused: Bool
    // The selected model's trained context ceiling (max_position_embeddings)
    // caps max_tokens; 32768 only when its config.json doesn't say.
    @State private var modelMaxContext: Int = 32768
    // Starts true: a new view (the chat just moved between the popover and
    // its window) is scrolled to the end on first appearance, below.
    @State private var followChatBottom = true
    /// Following the end before a Tweak draft paused it: restored after.
    @State private var followBeforeDraft: Bool?
    @State private var didScrollOnAppear = false
    @State private var lastChatGeometry = ChatGeometry(bottom: 0, height: 0)
    /// The user's own scrolling (wheel, trackpad, scroller): only it turns
    /// following off -- the chat's own layout changes never do.
    @StateObject private var userScroll = UserScrollWatch()
    /// One retry waits for the user's gesture to end, not one per token.
    @State private var followRetryPending = false
    @State private var chatViewportHeight: CGFloat = 380
    /// What a citation link found: the file changed since, or gone.
    @State private var citationNote: String?

    var body: some View {
        Group {
            if presentation.isDetached { windowLayout } else { popoverLayout }
        }
        .onAppear {
            // Models added or removed in Finder / LM Studio since the last
            // look show up on opening, as they used to.
            // Not on every tab switch (the view is rebuilt per tab): a
            // scan reads the models folder on the main thread.
            if Date().timeIntervalSince(Self.lastRescan) > 5 {
                Self.lastRescan = Date()
                catalog.rescan()
            }
            keepSelectionValid()
            modelDidChange(selectedModelID)
            isInputFocused = true
        }
        .onChange(of: selectedModelID) { modelDidChange($1) }
        .onChange(of: catalog.models) { keepSelectionValid() }
    }

    // MARK: - Layouts

    /// The popover: the header (server, model, tools) above the chat; the
    /// chats sidebar slides in over it. A fixed 420 wide.
    private var popoverLayout: some View {
        VStack(spacing: 0) {
            ChatHeaderView(selectedModelID: $selectedModelID, toggleSidebar: { setSidebarOverlay(!showsSidebarOverlay) })
            // More than one tab (opened from the window, the sidebar or ⌘T):
            // shown here too, or they'd pile up out of sight.
            if tabs.tabs.count > 1 {
                ChatTabStrip().padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            DownloadQueueRow()
            ReviewPromptRow()
            if let id = chat.currentSessionID { ProjectChatFilesRow(sessionID: id) }
            conversation
        }
        .frame(width: 420)
        // The popover is as tall as its content, and an empty chat is short:
        // room for the sidebar while it's shown.
        .frame(minHeight: showsSidebarOverlay ? 560 : nil, alignment: .top)
        .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                if showsSidebarOverlay {
                    Color.black.opacity(0.18)
                        .contentShape(Rectangle())
                        .onTapGesture { setSidebarOverlay(false) }
                        .transition(.opacity)
                    ChatSidebar(close: { setSidebarOverlay(false) }, closesOnOpen: true)
                        .frame(width: 290)
                        .transition(.move(edge: .leading))
                }
            }
        }
    }

    private func setSidebarOverlay(_ shown: Bool) {
        withAnimation(.easeOut(duration: 0.18)) { showsSidebarOverlay = shown }
        // The overlay's search had the focus: typing goes to the chat again.
        if !shown { isInputFocused = true }
    }

    /// The chat's own window: the sidebar beside the chat; the server, model
    /// and tool controls stay in the menu bar's popover unless Settings asks
    /// for them here too.
    private var windowLayout: some View {
        HStack(spacing: 0) {
            if showsWindowSidebar {
                ChatSidebar(close: { withAnimation(.easeOut(duration: 0.18)) { showsWindowSidebar = false } })
                    .frame(width: 250)
                    .transition(.move(edge: .leading))
                Divider()
            }
            VStack(spacing: 0) {
                windowBar
                Divider()
                if windowShowsModelControls {
                    ChatHeaderView(selectedModelID: $selectedModelID, inChatWindow: true)
                    Divider()
                }
                DownloadQueueRow()
                ReviewPromptRow()
                if let id = chat.currentSessionID { ProjectChatFilesRow(sessionID: id) }
                conversation
            }
            .frame(minWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var windowBar: some View {
        HStack(spacing: 10) {
            if !showsWindowSidebar {
                Button { withAnimation(.easeOut(duration: 0.18)) { showsWindowSidebar = true } } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .help("Chats")
                .accessibilityLabel("Chats")
                Button { ChatTabs.shared.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain)
                    .help("New chat (⌘N)")
                    .disabled(chat.currentSessionID != nil && chat.messages.isEmpty)
                Button { ChatTabs.shared.newTemporaryChat() } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.plain)
                    .help("New temporary chat (⌘⇧N) -- nothing about it is ever saved")
                    .accessibilityLabel("New temporary chat")
            }
            ChatTabStrip()
            Spacer(minLength: 8)
            ServerStatusLabel().foregroundColor(.secondary)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The messages and the composer: the same in both.
    private var conversation: some View {
        VStack(spacing: 0) {
            chatArea
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { composer.handleDrop($0) }
            Divider()
            ChatComposer(
                composer: composer, canChat: canChat, canRegenerate: canRegenerate, canCompact: canCompact,
                isFocused: $isInputFocused,
                send: send, regenerate: regenerate, compact: { Task { await presentation.compact(chat) } }
            )
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { composer.handleDrop($0) }
        }
    }

    // MARK: - Model

    /// Keep the selection only while that model is still there, else the
    /// first one -- a stale selection left the picker blank and Play
    /// silently doing nothing.
    private func keepSelectionValid() {
        if catalog.model(id: selectedModelID) == nil {
            selectedModelID = catalog.models.first?.id
        }
    }

    private func modelDidChange(_ modelID: String?) {
        modelMaxContext = ChatSettings.maxContext(forModel: modelID)
        composer.acceptsImages = modelID.map(ModelDiscovery.supportsVision(forModelPath:)) ?? false
    }

    /// The `model` name requests use -- read from the catalog at send time,
    /// so a rename in Settings applies at once.
    private var requestModelName: String {
        guard let id = selectedModelID else { return "default" }
        return catalog.requestName(for: id)
    }

    private var chatSettings: ChatSettings {
        ChatSettings.forModel(selectedModelID, supportsVision: composer.acceptsImages, maxContext: modelMaxContext)
    }

    // MARK: - Chat

    private static let chatBottomID = "chat-bottom"
    @MainActor private static var lastRescan = Date.distantPast

    /// The user's latest own message (not the hidden view_image one).
    private var lastUserMessageID: UUID? {
        chat.messages.last { $0.role == "user" && !$0.isToolContext }?.id
    }

    /// Changes with every piece of the streaming end of the chat: what
    /// follows it, besides the measured height (which changes only when a
    /// line wraps, and whose callbacks coalesce).
    private var chatEndKey: String {
        guard let m = chat.messages.last else { return "" }
        return "\(m.id)|\(m.reasoning.count)|\(m.content.count)|\(m.toolCalls.count)|\(m.images.count)|\(m.audios.count)"
    }

    /// Brings the end into view while following: after the layout the
    /// change causes (one main-queue turn isn't enough -- the scroll landed
    /// against the old content height, a line short each time).
    private func followToEnd(_ proxy: ScrollViewProxy) {
        guard followChatBottom, chat.draft?.anchor == nil else { return }
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard followChatBottom else { return }
                // The user's gesture first; the end once it's over (the last
                // token may have come meanwhile, with nothing after it).
                guard !userScroll.isScrolling else {
                    guard !followRetryPending else { return }
                    followRetryPending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        followRetryPending = false
                        followToEnd(proxy)
                    }
                    return
                }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo(Self.chatBottomID, anchor: .bottom) }
            }
        }
    }

    /// Tool results by call id, for the debug view of tool calls.
    private var toolResults: [String: String] {
        var results: [String: String] = [:]
        for msg in chat.messages where msg.role == "tool" {
            if let id = msg.toolCallID { results[id] = msg.content }
        }
        return results
    }

    /// A citation link (adr/0012): the cited file opens -- the project's
    /// copy, or the linked file -- saying so when it changed since that
    /// answer; one no longer there only says so. A PDF opens in the app's
    /// own viewer at the cited page, the cited text highlighted when it's
    /// still there (PDFCitationViewer); other formats in their app, at
    /// their start (macOS has no page anchor for them), the link naming the
    /// page.
    private func openCitation(_ c: Citation) {
        Task { @MainActor in
            let target: CitationTarget = ChatLibraryStore.shared.library.project(c.project) == nil
                ? .gone : await ProjectIndexer.citationTarget(c)
            let note: String?
            switch target {
            case .gone:
                note = String(format: NSLocalizedString("\"%@\" is no longer in the project.", comment: "citation chip: the cited file was removed"), c.name)
            case .file(let url, let page, let changed):
                note = changed ? String(format: NSLocalizedString("\"%@\" has changed since this answer cited it: page %lld may read differently now.",
                                                                  comment: "citation chip: the cited file was re-indexed"), c.name, page) : nil
                if CitationViewer.opensInViewer(url) {
                    let quote = await ProjectIndexer.citationQuote(c)
                    if await !PDFCitationViewer.show(url, name: c.name, page: page, quote: quote, note: note) { NSWorkspace.shared.open(url) }
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
            citationNote = note
            guard let note else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if citationNote == note { citationNote = nil }
        }
    }

    private var chatArea: some View {
        // Once per evaluation, not per message (it scans the whole history).
        let results = showToolCalls ? toolResults : nil
        // The data credits of each turn's tools, under its answer whether
        // or not the tool calls are shown.
        let sources = ChatMessage.sourcesByAnswer(chat.messages)
        // The project file pages each answer cites.
        let citations = ChatMessage.citationsByAnswer(chat.messages)
        return ScrollViewReader { proxy in
            ScrollView {
                // Not Lazy: a lazy stack estimates the height of rows it
                // hasn't laid out (long markdown answers), and the scroll
                // position jumped whenever the estimate was corrected.
                VStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        VStack(spacing: 2) {
                            Text("No messages yet")
                                .font(.system(size: 12))
                            // A chat started in a project isn't in the sidebar
                            // until its first turn: where it will be.
                            if let id = chat.currentSessionID { EmptyChatProjectNote(sessionID: id) }
                        }
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                    }
                    // "tool" messages are protocol plumbing: the image a
                    // tool produced is attached to the assistant message
                    // that called it.
                    ForEach(chat.messages.filter { $0.role != "tool" && !$0.isToolContext }) { msg in
                        MessageBubble(message: msg, showReasoning: showReasoning, toolResults: results, sources: sources[msg.id] ?? [],
                                      citations: citations[msg.id] ?? [], openCitation: { openCitation($0) },
                                      regenerateMedia: canChat && !chat.isBusy ? { kind, index, action in mediaAction(msg.id, kind, index, action) } : nil,
                                      draft: chat.draft?.anchor?.message == msg.id ? chat.draft : nil)
                            .environment(\.visibleChatHeight, chatViewportHeight)
                            .id(msg.id)
                    }
                    if let draft = chat.draft, draft.anchor == nil {
                        GenerationDraftView(draft: draft).id(draft.id)
                    }
                    // Folder access (adr/0014): the plan waiting for approval
                    // (or its result), and a grant prompt a call waits for.
                    if let plan = chat.folderPlan {
                        FolderPlanCard(model: plan, dismiss: { chat.dismissFolderPlan() }).id(plan.id)
                    }
                    if let prompt = chat.folderPrompt {
                        FolderPromptCard(prompt: prompt).id(prompt.id)
                    }
                    if chat.isGeneratingMedia {
                        if chat.generatingKind == .music {
                            MusicGenerationProgressView()
                        } else {
                            ImageGenerationProgressView().environment(\.visibleChatHeight, chatViewportHeight)
                        }
                    }
                    if chat.isWaitingForModelLoad {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(String(format: NSLocalizedString("Loading %@…", comment: "chat: the picked model is starting"),
                                        catalog.model(id: selectedModelID)?.displayName ?? NSLocalizedString("the model", comment: "")))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let err = chat.errorText {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    if let note = citationNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    // Where the bottom of the content is, relative to the
                    // viewport: tells whether the user is reading the end.
                    Color.clear.frame(height: 1).id(Self.chatBottomID)
                }
                .padding(12)
                // The content's height and where its bottom is in the
                // viewport: the bottom moving with the height unchanged means
                // the user scrolled.
                .background(ChatScrollViewFinder { userScroll.target = $0 })
                .background(GeometryReader { g in
                    let frame = g.frame(in: .named("chatScroll"))
                    Color.clear.preference(key: ChatBottomKey.self, value: ChatGeometry(bottom: frame.maxY, height: frame.height))
                })
            }
            .coordinateSpace(name: "chatScroll")
            // A freshly built view starts at the top of the conversation;
            // it opens at the latest message instead, matching
            // followChatBottom. Once per view: reopening the popover keeps
            // the reader's place, as it always has.
            .onAppear {
                userScroll.start()
                guard !didScrollOnAppear else { return }
                didScrollOnAppear = true
                // After the first layout, or there's nothing to scroll yet.
                DispatchQueue.main.async { proxy.scrollTo(Self.chatBottomID, anchor: .bottom) }
            }
            .background(GeometryReader { g in
                Color.clear.onAppear { chatViewportHeight = g.size.height }
                    .onChange(of: g.size.height) { chatViewportHeight = $1 }
            })
            // Follow new text only while the user is at (or near) the end;
            // scrolled up to read something, they stay where they are.
            .onPreferenceChange(ChatBottomKey.self) { geometry in
                let grew = geometry.height - lastChatGeometry.height
                let moved = abs(geometry.bottom - lastChatGeometry.bottom) > 0.5
                // What the user's scroll moved, beside the content's growth
                // (no programmatic scroll runs meanwhile): > 0 is up, away
                // from the end.
                let scrolledUp = (geometry.bottom - lastChatGeometry.bottom) - grew > 0.5
                lastChatGeometry = geometry
                let atEnd = geometry.bottom <= chatViewportHeight + 40
                // Told by the user's input, not guessed from the geometry:
                // re-rendered Markdown, a folding reasoning block or an
                // image's preview change the height and the offset in ways
                // that looked like a scroll up and stopped following.
                if userScroll.isScrolling {
                    if moved { AnswerInfoPresenter.shared.chatScrolled() }
                    // Up and away from the end: stop. Text arriving while the
                    // user scrolls down to it doesn't count as leaving.
                    // A shrink meanwhile (reasoning folding) moves the offset
                    // without the user: only a pass that didn't shrink counts.
                    if atEnd { followChatBottom = true } else if scrolledUp, grew > -0.5 { followChatBottom = false }
                } else if atEnd {
                    followChatBottom = true
                }
                // Anything that grows the chat at the end -- tokens, an image's
                // progress and preview, the image or song itself -- keeps the
                // end in view while the user follows it.
                // Not while a Tweak draft up the chat is what the user looks at.
                // Never while the user scrolls: that would take the end back from
                // under them before they're 40 pt away.
                if grew > 0.5, geometry.bottom > chatViewportHeight + 1, !userScroll.isScrolling {
                    followToEnd(proxy)
                }
            }
            // Small for an empty chat, capped so a long one scrolls inside
            // a fixed viewport instead of growing the popover. Detached, it
            // takes whatever height the window leaves it.
            .frame(minHeight: 48, maxHeight: presentation.isDetached ? .infinity : (chat.messages.isEmpty ? 48 : 380))
            // A draft wants the user's eyes: brought into view, wherever it is.
            .onChange(of: chat.draft?.id) { _, id in
                guard let id else {
                    if let before = followBeforeDraft {
                        followChatBottom = before
                        followBeforeDraft = nil
                        // Generate: the progress is at the end.
                        if before { DispatchQueue.main.async { proxy.scrollTo(Self.chatBottomID, anchor: .bottom) } }
                    }
                    return
                }
                if chat.draft?.anchor != nil {
                    if followBeforeDraft == nil { followBeforeDraft = followChatBottom }
                    followChatBottom = false
                }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
            // A folder prompt or plan wants the user's eyes too.
            .onChange(of: chat.folderPrompt?.id) { _, id in
                guard let id else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: chat.folderPlan?.id) { _, id in
                guard let id else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: lastUserMessageID) {
                // The user's own new message always brings the end into view
                // (send() appends the reply placeholder right after it).
                followChatBottom = true
                followToEnd(proxy)
            }
            // Every token, reasoning or answer, a tool call, an image or song.
            .onChange(of: chatEndKey) { followToEnd(proxy) }
        }
    }

    /// A model is picked and here: sending starts it if it isn't running
    /// (send), or the proxy reloads an idle-unloaded one. A grey field read
    /// as a broken app.
    private var canChat: Bool {
        catalog.model(id: selectedModelID) != nil
    }

    // Only once a reply has finished -- mid-stream there's nothing to redo.
    private var canRegenerate: Bool {
        // After an error the last message is the user's: retry it.
        canChat && !chat.isBusy && (chat.messages.last?.role == "assistant" || chat.messages.last?.role == "user")
    }

    // Only with a meaningful middle to replace -- compactSession's own guard.
    private var canCompact: Bool {
        // A one-shot summary request: it doesn't wait for a model to start.
        server.canAnswer && !chat.isBusy && chat.messages.count > compactKeepStart + compactKeepEnd + 1
    }

    private func mediaAction(_ messageID: UUID, _ kind: ChatClient.MediaKind, _ index: Int, _ action: ChatClient.MediaAction) {
        switch action {
        case .remove:
            chat.removeMedia(messageID: messageID, kind: kind, index: index)
        case .regenerate, .tweak:
            chat.regenerateMedia(messageID: messageID, kind: kind, index: index, settings: chatSettings, server: server,
                                 tweak: action == .tweak)
        }
    }

    private func send() {
        // The field stays enabled (and focused) while streaming; this is
        // what stops Return from sending a second message mid-stream.
        // Return in an empty field mustn't start loading a model.
        guard canChat, !chat.isBusy, !composer.isEmpty else { return }
        startModelIfStopped()
        let (text, images) = composer.take()
        chat.send(prompt: text, images: images, port: port, modelAlias: requestModelName, settings: chatSettings, server: server)
        isInputFocused = true
    }

    /// Sending is asking for the model: a stopped (or failed) server starts
    /// with the picked one, as the tray's Start does. Only the in-app chat:
    /// an outside client through the API never wakes a server the user
    /// stopped (ServerManager.checkAutoLoadAllowed).
    private func startModelIfStopped() {
        switch server.state {
        case .stopped, .failed: break
        default: return
        }
        guard !server.isIdleUnloaded, let model = catalog.model(id: selectedModelID) else { return }
        server.start(modelPath: model.path, port: port, alias: catalog.alias(for: model.id))
    }

    private func regenerate() {
        // The new answer is what the user asked to see.
        followChatBottom = true
        startModelIfStopped()
        chat.regenerate(port: port, modelAlias: requestModelName, settings: chatSettings, server: server)
    }

}

/// "In project …" under an empty chat that's in one. Its own view: only it
/// is redrawn when the library changes (every save does).
private struct EmptyChatProjectNote: View {
    let sessionID: UUID
    @ObservedObject private var store = ChatLibraryStore.shared

    var body: some View {
        if let project = store.library.projectContext(forChat: sessionID) {
            Label(String(format: NSLocalizedString("In project %@", comment: ""), project.name), systemImage: "folder")
                .font(.system(size: 11))
                .lineLimit(1)
        }
    }
}

/// "Searches N files" above a project chat whose project has searchable
/// files (adr/0012), "· N pinned" with pinned ones; clicking it shows them. Nothing while Project files are
/// off or nothing is searchable yet.
private struct ProjectChatFilesRow: View {
    let sessionID: UUID
    @ObservedObject private var store = ChatLibraryStore.shared
    @ObservedObject private var indexer = ProjectIndexer.shared

    var body: some View {
        if indexer.isEnabled, let project = store.library.projectContext(forChat: sessionID) {
            let searchable = ProjectFileTotals(indexer.documents[project.id] ?? []).searchable
            if searchable > 0 {
                VStack(spacing: 0) {
                    Button { ProjectFilesWindow.show(project.id) } label: {
                        HStack(spacing: 6) {
                            ProjectRingIcon(ring: indexer.ring(for: project.id))
                            Text(project.name).lineLimit(1).truncationMode(.tail)
                            Text(verbatim: "·")
                            Text(String(format: NSLocalizedString("Searches %lld files", comment: "a project chat's header: how many files its tools search"),
                                        Int64(searchable)))
                                .lineLimit(1)
                                // The name truncates first, not the count.
                                .layoutPriority(1)
                            if let pinned = indexer.pins[project.id], !pinned.isEmpty {
                                Text(String(format: NSLocalizedString("· %lld pinned", comment: "a project chat's header: how many files are pinned (whole in its requests)"),
                                            Int64(pinned.count)))
                                    .lineLimit(1)
                                    .layoutPriority(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(indexer.statusText(for: project.id) ?? NSLocalizedString("Show the project's files", comment: ""))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    Divider()
                }
            }
        }
    }
}

/// The chat content's bottom edge (in the scroll view's coordinates) and height.
struct ChatGeometry: Equatable {
    var bottom: CGFloat
    var height: CGFloat
}

/// Whether the user is scrolling the chat now: a scroll-wheel or trackpad
/// event over the chat's own scroll view in the last moments, or a live
/// scroll of it (a drag of its scroller, a trackpad's momentum). Other scroll
/// views (the composer, code blocks elsewhere, other windows) don't count,
/// and programmatic scrolls (following the end) are neither.
@MainActor
final class UserScrollWatch: ObservableObject {
    /// The chat's NSScrollView, found once it's in a window.
    weak var target: NSScrollView?
    private var lastWheel = Date.distantPast
    /// When the chat's live scroll began or last moved; nil when none. Stale
    /// after 2 s: a scroll view rebuilt mid-scroll never sends its end.
    private var liveSince: Date?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    var isScrolling: Bool {
        let now = Date()
        if let since = liveSince, now.timeIntervalSince(since) >= 2 { liveSince = nil }
        return liveSince != nil || now.timeIntervalSince(lastWheel) < 0.35
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.phase != .mayBegin else { return event }
            // Not found (yet): any wheel counts, as before -- better than
            // never letting the user read back.
            guard let target = self.target else {
                self.lastWheel = Date()
                return event
            }
            guard event.window === target.window,
                  // Sideways: a code block's or table's own scroller.
                  abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return event }
            let point = target.convert(event.locationInWindow, from: nil)
            if target.bounds.contains(point) { self.lastWheel = Date() }
            return event
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { if let self, (note.object as? NSScrollView) === self.target { self.liveSince = Date() } }
            },
            center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if let self, (note.object as? NSScrollView) === self.target, self.liveSince != nil { self.liveSince = Date() }
                }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, (note.object as? NSScrollView) === self.target else { return }
                    self.liveSince = nil
                    // Its last movement lands just after the end.
                    self.lastWheel = Date()
                }
            },
        ]
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Reports the NSScrollView around the view it's the background of.
private struct ChatScrollViewFinder: NSViewRepresentable {
    let found: (NSScrollView) -> Void

    init(_ found: @escaping (NSScrollView) -> Void) { self.found = found }

    func makeNSView(context: Context) -> FinderView {
        let v = FinderView()
        v.found = found
        return v
    }

    func updateNSView(_ view: FinderView, context: Context) { view.found = found }

    final class FinderView: NSView {
        var found: ((NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After this pass: the hosting hierarchy is complete by then.
            DispatchQueue.main.async { [weak self] in
                if let scroll = self?.enclosingScrollView { self?.found?(scroll) }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct ChatBottomKey: PreferenceKey {
    static var defaultValue = ChatGeometry(bottom: 0, height: 0)
    static func reduce(value: inout ChatGeometry, nextValue: () -> ChatGeometry) { value = nextValue() }
}
