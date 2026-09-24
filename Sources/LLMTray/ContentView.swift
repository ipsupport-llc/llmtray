import SwiftUI
import LLMTrayCore

/// The popover: header, chat and composer. Holds what they share -- the
/// selected model, the draft (ComposerModel) -- and sends turns to ChatClient
/// with the selected model's profile.
struct ContentView: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var benchmark: BenchmarkRunner
    // Chat, tool and server-launch settings live in profiles (see
    // ProfileManager): the selected model's profile, layered on Default.
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var catalog = ModelCatalog.shared
    @StateObject private var composer = ComposerModel()

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
    // 0 disables auto-compaction -- otherwise checked after every
    // completed turn.
    @AppStorage(Pref.autoCompactThreshold) private var autoCompactThreshold: Int

    // Backs the History menu -- refreshed on appear and whenever
    // ChatSessionStore posts .sessionsDidChange, not read from disk on
    // every render.
    @State private var sessionHistory: [ChatSessionFile] = []
    @FocusState private var isInputFocused: Bool
    // The selected model's trained context ceiling (max_position_embeddings)
    // caps max_tokens; 32768 only when its config.json doesn't say.
    @State private var modelMaxContext: Int = 32768
    @State private var followChatBottom = true
    @State private var chatViewportHeight: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderView(selectedModelID: $selectedModelID, sessionHistory: sessionHistory)
            Divider()
            chatArea
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { composer.handleDrop($0) }
            Divider()
            ChatComposer(
                composer: composer, canChat: canChat, canRegenerate: canRegenerate, canCompact: canCompact,
                isFocused: $isInputFocused,
                send: send, regenerate: regenerate, compact: { Task { await compact() } }
            )
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { composer.handleDrop($0) }
        }
        .frame(width: 420)
        .onAppear {
            sessionHistory = ChatSessionStore.list()
            // Models added or removed in Finder / LM Studio since the last
            // look show up on opening, as they used to.
            catalog.rescan()
            keepSelectionValid()
            modelDidChange(selectedModelID)
            isInputFocused = true
        }
        .onChange(of: selectedModelID) { modelDidChange($0) }
        .onChange(of: catalog.models) { _ in keepSelectionValid() }
        .onReceive(NotificationCenter.default.publisher(for: .modelsDidChange)) { notification in
            // A Hugging Face download finished: jump to the model that just
            // landed on disk (the catalog rescans on the same notification).
            guard let repoID = notification.object as? String else { return }
            catalog.rescan()
            let downloaded = catalog.root + "/\(repoID)"
            if catalog.model(id: downloaded) != nil { selectedModelID = downloaded }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionsDidChange)) { _ in
            sessionHistory = ChatSessionStore.list()
        }
        .onChange(of: chat.isTurnInProgress) { busy in
            // The one reliable "a turn (streaming + tool calls) just
            // finished" signal: send()/regenerate() don't await the turn.
            if !busy { autoCompactIfNeeded() }
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
        modelMaxContext = max(64, modelID.flatMap(ModelDiscovery.maxContextLength(forModelPath:)) ?? 32768)
        composer.acceptsImages = modelID.map(ModelDiscovery.supportsVision(forModelPath:)) ?? false
    }

    /// The `model` name requests use -- read from the catalog at send time,
    /// so a rename in Settings applies at once.
    private var requestModelName: String {
        guard let id = selectedModelID else { return "default" }
        let alias = catalog.alias(for: id)
        return alias.isEmpty ? (id as NSString).lastPathComponent : alias
    }

    private var chatSettings: ChatSettings {
        var settings = ChatSettings(profile: profiles.resolved(for: selectedModelID), maxTokensCap: modelMaxContext)
        settings.modelSupportsVision = composer.acceptsImages
        settings.modelPath = selectedModelID
        return settings
    }

    // MARK: - Chat

    private static let chatBottomID = "chat-bottom"

    /// Tool results by call id, for the debug view of tool calls.
    private var toolResults: [String: String] {
        var results: [String: String] = [:]
        for msg in chat.messages where msg.role == "tool" {
            if let id = msg.toolCallID { results[id] = msg.content }
        }
        return results
    }

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not Lazy: a lazy stack estimates the height of rows it
                // hasn't laid out (long markdown answers), and the scroll
                // position jumped whenever the estimate was corrected.
                VStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        Text("No messages yet")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                    }
                    // "tool" messages are protocol plumbing: the image a
                    // tool produced is attached to the assistant message
                    // that called it.
                    ForEach(chat.messages.filter { $0.role != "tool" && !$0.isToolContext }) { msg in
                        MessageBubble(message: msg, showReasoning: showReasoning, toolResults: showToolCalls ? toolResults : nil)
                            .id(msg.id)
                    }
                    if chat.isGeneratingImage {
                        ImageGenerationProgressView()
                    }
                    if let err = chat.errorText {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    // Where the bottom of the content is, relative to the
                    // viewport: tells whether the user is reading the end.
                    Color.clear.frame(height: 1).id(Self.chatBottomID)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ChatBottomKey.self, value: g.frame(in: .named("chatScroll")).maxY)
                        })
                }
                .padding(12)
            }
            .coordinateSpace(name: "chatScroll")
            .background(GeometryReader { g in
                Color.clear.onAppear { chatViewportHeight = g.size.height }
                    .onChange(of: g.size.height) { chatViewportHeight = $0 }
            })
            // Follow new text only while the user is at (or near) the end;
            // scrolled up to read something, they stay where they are.
            .onPreferenceChange(ChatBottomKey.self) { bottom in
                followChatBottom = bottom <= chatViewportHeight + 40
            }
            // Small for an empty chat, capped so a long one scrolls inside
            // a fixed viewport instead of growing the window.
            .frame(minHeight: 48, maxHeight: chat.messages.isEmpty ? 48 : 380)
            // Cheap to compare: lengths, not the whole text, per token.
            .onChange(of: (chat.messages.last?.content.count ?? 0) + (chat.messages.last?.reasoning.count ?? 0)) { _ in
                if followChatBottom { proxy.scrollTo(Self.chatBottomID, anchor: .bottom) }
            }
            .onChange(of: chat.messages.count) { _ in
                // The user's own new message always brings the end into view.
                if chat.messages.last?.role == "user" { followChatBottom = true }
                if followChatBottom { proxy.scrollTo(Self.chatBottomID, anchor: .bottom) }
            }
        }
    }

    /// The server is running, or idle-unloaded (the proxy reloads it on
    /// the request).
    private var canChat: Bool {
        if case .running = server.state { return true }
        return server.isIdleUnloaded
    }

    // Only once a reply has finished -- mid-stream there's nothing to redo.
    private var canRegenerate: Bool {
        canChat && !chat.isBusy && chat.messages.last?.role == "assistant"
    }

    // Only with a meaningful middle to replace -- compactSession's own guard.
    private var canCompact: Bool {
        canChat && !chat.isBusy && chat.messages.count > compactKeepStart + compactKeepEnd + 1
    }

    private func send() {
        // The field stays enabled (and focused) while streaming; this is
        // what stops Return from sending a second message mid-stream.
        guard canChat, !chat.isBusy else { return }
        let (text, images) = composer.take()
        chat.send(prompt: text, images: images, port: port, modelAlias: requestModelName, settings: chatSettings, server: server)
        isInputFocused = true
    }

    private func regenerate() {
        chat.regenerate(port: port, modelAlias: requestModelName, settings: chatSettings, server: server)
    }

    private func compact() async {
        await chat.compactSession(
            port: port, modelAlias: requestModelName, settings: chatSettings,
            keepStart: compactKeepStart, keepEnd: compactKeepEnd
        )
    }

    private func autoCompactIfNeeded() {
        guard autoCompactThreshold > 0, chat.messages.count > autoCompactThreshold else { return }
        Task { await compact() }
    }
}

/// The chat content's bottom edge in the scroll view's coordinates.
private struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
