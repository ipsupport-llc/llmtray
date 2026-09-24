import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import LLMTrayCore

struct ContentView: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var benchmark: BenchmarkRunner
    // Chat, tool and server-launch settings live in profiles (see
    // ProfileManager): the selected model's profile, layered on Default.
    @ObservedObject private var profiles = ProfileManager.shared

    // Where models live -- ~/.llmtray/models by default (this app's own
    // namespace), not ~/.lmstudio/models. Anyone who wants to share models
    // already downloaded via LM Studio can point this there instead.
    @AppStorage(ModelDiscovery.modelsRootDefaultsKey) private var modelsRoot: String = ModelDiscovery.defaultModelsRoot
    @State private var models: [LocalModel] = []
    // Persists across launches -- picking up where you left off instead of
    // defaulting back to the alphabetically-first model every time.
    @AppStorage("selectedModelID") private var selectedModelID: String?
    // Persisted (not just @State) so the right-click quick menu's "Start
    // Server" -- which has no settings panel of its own -- can read the
    // same values back out of UserDefaults from AppDelegate.
    @AppStorage("llmtray.port") private var port: Int = 8765
    // Not @AppStorage -- remembered per selected model via ModelAliasStore
    // instead of one value shared across every model (see onChange(of:
    // selectedModelID) below, which loads/saves it on every switch).
    @State private var alias: String = ""
    @State private var draft: String = ""
    // Backs the History menu -- refreshed on appear and whenever
    // ChatSessionStore posts .sessionsDidChange (save/delete), rather than
    // read fresh from disk on every render (see that notification's own
    // doc comment for why a plain disk read wasn't reliable here).
    @State private var sessionHistory: [ChatSessionFile] = []
    @AppStorage("llmtray.showReasoning") private var showReasoning: Bool = true
    // Compaction keeps these many messages verbatim at the start and end
    // of a session, replacing everything in between with one
    // model-generated summary (see ChatClient.compactSession).
    @AppStorage("llmtray.compactKeepStart") private var compactKeepStart: Int = 4
    @AppStorage("llmtray.compactKeepEnd") private var compactKeepEnd: Int = 6
    // 0 disables auto-compaction -- otherwise, checked after every
    // completed turn (see sendDraft's onChange-driven autoCompactIfNeeded).
    @AppStorage("llmtray.autoCompactThreshold") private var autoCompactThreshold: Int = 0
    @FocusState private var isInputFocused: Bool
    // The selected model's own trained context ceiling (max_position_embeddings),
    // read fresh on every model switch -- see updateModelMaxContext(for:).
    // 32768 is just the fallback for a model whose config.json doesn't
    // expose the field in a shape ModelDiscovery.maxContextLength recognizes,
    // not a real technical limit of anything.
    @State private var modelMaxContext: Int = 32768
    // Whether the *currently selected chat model* (not the image-gen
    // model) accepts image input -- see ModelDiscovery.supportsVision.
    // Gates whether the attach-image button even appears.
    @State private var modelSupportsVision: Bool = false
    // Images the user has attached to the message they're composing, sent
    // alongside it on the next send. Cleared after sendDraft() fires, or
    // immediately if the model changes to one without vision support.
    @State private var pendingAttachments: [Data] = []

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            chatArea
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { handleImageDrop($0) }
            Divider()
            inputBar
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { handleImageDrop($0) }
        }
        .frame(width: 420)
        .onAppear {
            sessionHistory = ChatSessionStore.list()
            models = ModelDiscovery.scanModels(root: modelsRoot)
            // Fall back to the first discovered model if nothing was saved,
            // or if the saved model no longer exists on disk (moved/deleted
            // since last launch).
            if selectedModelID == nil || !models.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = models.first?.id
            }
            if let selectedModelID {
                alias = ModelAliasStore.alias(for: selectedModelID)
            }
            updateModelMaxContext(for: selectedModelID)
            isInputFocused = true
        }
        .onChange(of: selectedModelID) { newID in
            // Swap in that model's own remembered alias instead of leaving
            // whatever was typed for the previous model still in the field.
            alias = newID.map(ModelAliasStore.alias(for:)) ?? ""
            updateModelMaxContext(for: newID)
        }
        .onChange(of: modelsRoot) { newRoot in
            // Covers every way modelsRoot can change (typing, Browse…, the
            // "Use LM Studio" shortcut) with one rescan instead of needing
            // an explicit call at each call site -- previously this only
            // happened on the specific buttons, so editing the text field
            // directly and not hitting Return left the picker stale until
            // the app was restarted.
            rescanModels(root: newRoot)
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelsDidChange)) { notification in
            // Fires after a Hugging Face download finishes -- rescan and
            // jump straight to the model that just landed on disk instead
            // of leaving the picker on whatever was selected before.
            rescanModels()
            if let repoID = notification.object as? String {
                let downloadedPath = modelsRoot + "/\(repoID)"
                if models.contains(where: { $0.id == downloadedPath }) {
                    selectedModelID = downloadedPath
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionsDidChange)) { _ in
            sessionHistory = ChatSessionStore.list()
        }
        .onChange(of: chat.isBusy) { busy in
            // Fires once a turn (streaming + any tool calls) fully settles,
            // not right when it starts -- send()/regenerate() themselves
            // don't await that, so this is the one reliable "a turn just
            // finished" signal available here.
            if !busy {
                autoCompactIfNeeded()
            }
        }
    }


    // MARK: - Profile-backed settings

    /// Binding to a field of the selected model's profile. Writes go to
    /// that profile (its overlay, or Default for models on Default).
    private func pb<T>(_ keyPath: WritableKeyPath<Profile, T?>) -> Binding<T> {
        Binding(
            get: { profiles.value(keyPath, for: selectedModelID) },
            set: { profiles.set(keyPath, $0, for: selectedModelID) }
        )
    }

    private var activeProfile: Profile { profiles.profile(for: selectedModelID) }

    /// After any rescan: keep the selection only if that model is still
    /// there, else fall back to the first one -- a stale selection left the
    /// picker blank, Play enabled but silently doing nothing, and the
    /// settings editing a model that no longer exists.
    private func rescanModels(root: String? = nil) {
        models = ModelDiscovery.scanModels(root: root ?? modelsRoot)
        if selectedModelID == nil || !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = models.first?.id
        }
    }
    private var resolvedProfile: ResolvedProfile { profiles.resolved(for: selectedModelID) }

    private var temperature: Double { resolvedProfile.temperature }
    private var chatSettings: ChatSettings {
        ChatSettings(profile: resolvedProfile, maxTokensCap: modelMaxContext)
    }

    // MARK: - Profiles UI

    private var profilePickerBinding: Binding<String> {
        Binding(
            get: { profiles.profileID(for: selectedModelID) },
            set: { switchProfile(to: $0) }
        )
    }

    private var profilePicker: some View {
        Menu {
            Picker("Profile", selection: profilePickerBinding) {
                ForEach(profiles.profiles) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(!canSwitchProfile)
            Divider()
            Button("Edit Profile…") { openSettings(.profiles, profileID: profiles.profileID(for: selectedModelID)) }
            Button("New Profile…") {
                let p = profiles.create(name: NSLocalizedString("New profile", comment: ""))
                switchProfile(to: p.id)
                openSettings(.profiles, profileID: p.id)
            }
            .disabled(!canSwitchProfile)
        } label: {
            Text(profiles.profile(for: selectedModelID).name)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text(canSwitchProfile ? "Settings profile for this model" : "Can't switch profiles while a request or the auto-tune is running"))
    }

    /// The one sampling knob kept in the popover; edits the model's profile.
    private var temperatureRow: some View {
        HStack(spacing: 6) {
            Text("Temperature").font(.system(size: 11)).foregroundColor(.secondary)
            Slider(value: pb(\.request.temperature), in: 0...2, step: 0.05).controlSize(.mini)
            Text(String(format: "%.2f", temperature)).font(.system(size: 11)).monospacedDigit().frame(width: 32, alignment: .trailing)
        }
        .help(Text("Randomness of the answers (part of the model's profile). Lower is more focused, higher more varied."))
    }

    /// Switching can restart the server, which would kill an in-flight
    /// request (in-app or external -- both go through the proxy, counted
    /// by server.isBusy) or race the auto-tune sweep's own restarts and
    /// make it write its candidates into the newly assigned profile.
    private var canSwitchProfile: Bool {
        selectedModelID != nil && !isBusy && !server.isBusy && !chat.isBusy && !benchmark.isRunning
    }

    /// Assigns a profile to the selected model. Launch-setting differences
    /// are applied by the "Restart Server" prompt, not by restarting here
    /// (that would cut off in-flight requests).
    private func switchProfile(to id: String) {
        guard canSwitchProfile, let modelID = selectedModelID else { return }
        profiles.assign(profileID: id, to: modelID)
    }

    private func openSettings(_ pane: SettingsPane? = nil, profileID: String? = nil) {
        var info: [String: String] = [:]
        if let pane { info["pane"] = pane.rawValue }
        if let profileID { info["profileID"] = profileID }
        NotificationCenter.default.post(name: .showSettings, object: nil, userInfo: info)
    }

    // MARK: - Status header

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    chat.newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New chat (saved)")
                // Only disabled when there's truly nothing to start fresh
                // from -- an empty *persistent* session. In temporary mode
                // (currentSessionID == nil) messages is empty too, but this
                // button is the only way back to a saved session, so it
                // must stay enabled there regardless of message count.
                .disabled(chat.currentSessionID != nil && chat.messages.isEmpty)
                Menu {
                    if sessionHistory.isEmpty {
                        Text("No saved sessions")
                    }
                    ForEach(sessionHistory) { session in
                        Menu(session.title.isEmpty ? "New chat" : session.title) {
                            Button("Open") {
                                chat.loadSession(session)
                            }
                            Button("Delete", role: .destructive) {
                                deleteSession(session)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 16)
                .help("Past chats")
                Button {
                    chat.newTemporaryChat()
                } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.plain)
                .help("New temporary chat -- nothing about it is ever saved")
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(models) { m in
                        Text(m.displayName).tag(m.id as String?)
                    }
                }
                .labelsHidden()
                .disabled(isBusy || benchmark.isRunning)
                .help(Text(benchmark.isRunning ? "Can't change models while auto-tune is running" : "Model"))

                Menu {
                    Button("Rescan Models") { rescanModels() }
                    Button("Browse Hugging Face…") { NotificationCenter.default.post(name: .showHFBrowser, object: nil) }
                    Button("Manage Models…") { openSettings(.models) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(Text("Rescan, download or manage models"))
                .accessibilityLabel(Text("Model actions"))

                serverToggleButton
            }

            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3").foregroundColor(.secondary).font(.system(size: 11))
                profilePicker
                temperatureRow
            }

            RestartBanner()
        }
        .padding(12)
    }

    /// Small icon instead of a full-width "Start Server"/"Stop Server"
    /// button -- the server now starts on its own at launch (see
    /// AppDelegate's quickStart() call in applicationDidFinishLaunching),
    /// so this is for the "I changed the model, unload/reload" case, not
    /// the everyday path.
    private var serverToggleButton: some View {
        Group {
            switch server.state {
            case .stopped, .failed:
                Button {
                    startServer()
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(selectedModelID == nil)
                .help("Start server")
            case .starting:
                ProgressView().controlSize(.small)
                    .help("Starting…")
            case .running:
                Button {
                    server.stop()
                } label: {
                    Image(systemName: "eject.fill")
                }
                .help("Stop server (unload model)")
            }
        }
        .buttonStyle(.plain)
        // Explicit Start/Stop regardless of which icon is currently shown --
        // e.g. right-clicking while stopped still offers "Stop Server" as a
        // clearly-disabled no-op rather than nothing at all.
        .contextMenu {
            Button("Start Server") { startServer() }
                .disabled(!isStoppedOrFailed || selectedModelID == nil)
            Button("Stop Server") { server.stop() }
                .disabled(!isRunning)
        }
    }

    private func startServer() {
        guard let id = selectedModelID, let model = models.first(where: { $0.id == id }) else { return }
        server.start(modelPath: model.path, port: port, alias: alias)
    }

    /// Re-reads the newly-selected model's own context ceiling so the "Max
    /// tokens" slider reflects what this specific model actually supports,
    /// instead of one fixed number applied to every model regardless of its
    /// real trained limit. Also pulls maxTokens back down if it's currently
    /// set higher than the new model's ceiling allows.
    private func updateModelMaxContext(for modelID: String?) {
        let fallback = 32768
        // max(64, ...) keeps the slider's range valid (lowerBound is a fixed
        // 64) even in the unlikely case a config.json reports something
        // smaller than that.
        modelMaxContext = max(64, modelID.flatMap(ModelDiscovery.maxContextLength(forModelPath:)) ?? fallback)
        modelSupportsVision = modelID.map(ModelDiscovery.supportsVision(forModelPath:)) ?? false
        if !modelSupportsVision {
            pendingAttachments.removeAll()
        }
    }

    private var isStoppedOrFailed: Bool {
        switch server.state {
        case .stopped, .failed: return true
        default: return false
        }
    }

    private var isBusy: Bool {
        if case .starting = server.state { return true }
        return false
    }

    private var statusColor: Color {
        switch server.state {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch server.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running(let port, let model): return "Running — \(model) on :\(port)"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    private var isRunning: Bool {
        if case .running = server.state { return true }
        return false
    }

    /// The chat can send: the server is running, or it was idle-unloaded
    /// and the proxy will reload it on the request (the setting's own text
    /// promises that; the chat used to stay disabled until Play).
    private var canChat: Bool {
        isRunning || server.isIdleUnloaded
    }

    // MARK: - Chat

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        Text("No messages yet")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                    }
                    // "tool" messages are protocol plumbing for the
                    // generate_image round-trip (see ChatClient) -- the
                    // image they produced is already attached to the
                    // assistant message that called the tool, so there's
                    // nothing left worth showing as its own bubble.
                    ForEach(chat.messages.filter { $0.role != "tool" }) { msg in
                        chatBubble(msg)
                            .id(msg.id)
                    }
                    if chat.isGeneratingImage {
                        imageGenerationProgressView
                    }
                    if let err = chat.errorText {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                }
                .padding(12)
            }
            // Collapses toward minHeight for an empty chat instead of
            // always reserving the full 560px popover for nothing, but
            // caps out at maxHeight so a long conversation scrolls within
            // a fixed viewport rather than growing the window unbounded.
            .frame(minHeight: 48, maxHeight: chat.messages.isEmpty ? 48 : 380)
            .onChange(of: (chat.messages.last?.content ?? "") + (chat.messages.last?.reasoning ?? "")) { _ in
                if let last = chat.messages.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    // Split out for the same type-checker reason as the other extracted
    // sections -- a conditional ProgressView + Image + Text stack inside
    // the already-large chat ScrollView body.
    private var imageGenerationProgressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let progress = chat.mfluxStepProgress, progress.total > 0 {
                    ProgressView(value: Double(progress.step), total: Double(progress.total))
                        .frame(width: 100)
                    Text("Step \(progress.step)/\(progress.total)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(chat.mfluxStatusText.isEmpty ? "Generating image…" : chat.mfluxStatusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            if let preview = chat.mfluxPreviewImage {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 320)
                    .cornerRadius(8)
                    .opacity(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chatBubble(_ msg: ChatMessage) -> some View {
        Group {
            if msg.isSummary {
                summaryBubble(msg)
            } else {
                normalChatBubble(msg)
            }
        }
    }

    /// The synthetic message compactSession() splices in -- styled
    /// distinctly (icon + italic + dimmed) so it plainly reads as "the app
    /// compacted some history here," not something anyone actually said.
    private func summaryBubble(_ msg: ChatMessage) -> some View {
        Label(msg.content, systemImage: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 11).italic())
            .foregroundColor(.secondary)
            .padding(8)
            .background(Color.gray.opacity(0.06))
            .cornerRadius(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func normalChatBubble(_ msg: ChatMessage) -> some View {
        VStack(alignment: msg.role == "user" ? .trailing : .leading, spacing: 2) {
            Text(msg.role == "user" ? "You" : "Assistant")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            if showReasoning && !msg.reasoning.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label(
                        msg.content.isEmpty ? "Thinking…" : "Thought process",
                        systemImage: "brain"
                    )
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    Text(ChatMarkdown.render(msg.reasoning, baseSize: 11))
                        .font(.system(size: 11).italic())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color.gray.opacity(0.06))
                .cornerRadius(8)
            }

            if !msg.content.isEmpty || msg.reasoning.isEmpty {
                // Assistant output is markdown (see ChatMarkdown); the
                // user's own text is shown exactly as typed.
                Group {
                    if msg.role == "user" || msg.content.isEmpty {
                        Text(msg.content.isEmpty ? "…" : msg.content)
                    } else {
                        Text(ChatMarkdown.render(msg.content, baseSize: 13))
                    }
                }
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(msg.role == "user" ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
                    .cornerRadius(8)
            }

            // Rendered straight from the in-memory bytes the model sent
            // this turn -- never written to disk (except mflux's own
            // transient temp file, deleted immediately after this Data is
            // read -- see MfluxManager.generate), so nothing to clean up
            // when the chat is cleared or the app quits. Save button is the
            // one deliberate escape hatch for a user who wants to keep one.
            ForEach(Array(msg.images.enumerated()), id: \.offset) { i, data in
                if let nsImage = NSImage(data: data) {
                    VStack(alignment: .leading, spacing: 2) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 320, maxHeight: 320)
                            .cornerRadius(8)
                            .onTapGesture {
                                openImagePreview(data, title: msg.imagePrompts[safe: i] ?? "Image")
                            }
                            .pointingHandCursor()
                            .contextMenu {
                                Button("Copy") { copyImageToClipboard(data) }
                                Button("Save…") { saveImage(data, prompt: msg.imagePrompts[safe: i] ?? "") }
                            }
                        HStack(spacing: 8) {
                            Button {
                                saveImage(data, prompt: msg.imagePrompts[safe: i] ?? "")
                            } label: {
                                Label("Save…", systemImage: "square.and.arrow.down")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            Button {
                                copyImageToClipboard(data)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            if let seconds = msg.imageDurations[safe: i] {
                                Text(String(format: "Generated in %.1fs", seconds))
                                    .font(.system(size: 10))
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == "user" ? .trailing : .leading)
    }

    /// Opens a full-size, resizable preview window for a tapped thumbnail --
    /// entirely in-memory (NSHostingView over the same NSImage already
    /// decoded for the thumbnail), no disk write, unlike Save. Windows are
    /// retained in a static array (not @State) since they're meant to
    /// outlive this View struct's own lifecycle -- the popover can close
    /// without closing a preview the user opened from it.
    private func openImagePreview(_ data: Data, title: String) {
        guard let nsImage = NSImage(data: data) else { return }
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let maxSize = NSSize(width: screenSize.width * 0.9, height: screenSize.height * 0.9)
        let scale = min(1, min(maxSize.width / nsImage.size.width, maxSize.height / nsImage.size.height))
        let windowSize = NSSize(width: nsImage.size.width * scale, height: nsImage.size.height * scale)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = title
        window.contentView = NSHostingView(
            rootView: Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
        )
        window.center()
        window.isReleasedWhenClosed = false
        Self.imagePreviewWindows.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var imagePreviewWindows: [NSWindow] = []

    /// The one deliberate way a generated image reaches disk -- an explicit
    /// per-image save, not automatic (see chatBubble's images ForEach).
    private func saveImage(_ data: Data, prompt: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.slugify(prompt) + ".png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    /// Puts the image on the system pasteboard -- still no disk write,
    /// unlike Save; the fastest path for "paste this into another app."
    private func copyImageToClipboard(_ data: Data) {
        guard let nsImage = NSImage(data: data) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    /// Derives a save-panel filename straight from the prompt that made
    /// the image, instead of a generic "image.png" every time -- no extra
    /// model round-trip needed for this, the prompt text is already
    /// exactly what the picture is of.
    private static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        let slug = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = String(collapsed.prefix(48))
        return trimmed.isEmpty ? "image" : trimmed
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 4) {
            if canRegenerate || chat.lastTokensPerSecond != nil || canCompact || chat.currentSessionID == nil {
                HStack {
                    if chat.currentSessionID == nil {
                        Label("Temporary — not saved", systemImage: "eye.slash")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    if canRegenerate {
                        Button {
                            regenerate()
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                    if canCompact {
                        Button {
                            Task { await compact() }
                        } label: {
                            Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .disabled(chat.isBusy)
                    }
                    Spacer()
                    if let tps = chat.lastTokensPerSecond {
                        Text(String(format: "%.1f tok/s", tps))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
            }
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { i, data in
                            if let nsImage = NSImage(data: data) {
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .onTapGesture {
                                            openImagePreview(data, title: "Attachment")
                                        }
                                        .pointingHandCursor()
                                        .contextMenu {
                                            Button("Copy") { copyImageToClipboard(data) }
                                            Button("Save…") { saveImage(data, prompt: "attachment") }
                                        }
                                    Button {
                                        pendingAttachments.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(.white)
                                            .background(Circle().fill(Color.black.opacity(0.5)))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 4, y: -4)
                                    .help("Remove attachment")
                                    .accessibilityLabel("Remove attachment")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                if modelSupportsVision {
                    Button {
                        attachImages()
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .buttonStyle(.plain)
                    .help("Attach image(s) for the model to see")
                }
                // Not disabled during streaming: a disabled NSTextField
                // resigns first responder, which is what was actually
                // kicking focus out of the input field every time a
                // response started -- sendDraft()'s own guard already
                // stops a second send from firing, so disabling here too
                // only cost focus retention for no added safety.
                TextField("Message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(sendDraft)
                    .onChange(of: draft) { convertDroppedImagePaths(in: $0) }
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { handleImageDrop($0) }
                    .focused($isInputFocused)
                    .disabled(!canChat)

                if chat.isBusy {
                    Button {
                        chat.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop generating")
                    .accessibilityLabel("Stop generating")
                    // Cancelling mid-image-generation only stops the network
                    // side of the tool round-trip; the mflux subprocess
                    // itself isn't interruptible yet, so the button is
                    // disabled rather than implying a generation already
                    // running on the GPU can be stopped instantly.
                    .disabled(chat.isGeneratingImage)
                } else {
                    Button {
                        sendDraft()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .help("Send")
                    .accessibilityLabel("Send")
                    .disabled(!canChat || (draft.trimmingCharacters(in: .whitespaces).isEmpty && pendingAttachments.isEmpty))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func sendDraft() {
        // The input field stays enabled (and focused) through streaming --
        // this guard is what actually stops Return from firing a second
        // send() mid-stream and stomping ChatClient's in-flight
        // assistantMessageIndex, without having to disable the field
        // itself (which would kick focus out of it every time).
        guard canChat, !chat.isBusy else { return }
        let text = draft
        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []
        let settings = chatSettings
        chat.send(prompt: text, images: attachments, port: port, modelAlias: alias.isEmpty ? "default" : alias, settings: settings, server: server)
        isInputFocused = true
    }

    /// Lets the user pick one or more image files to send to a
    /// vision-capable model (see modelSupportsVision). Always normalized
    /// to PNG here -- ChatClient.serialize() assumes that MIME type for
    /// every attachment rather than sniffing each file's real format.
    private func attachImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            attachImage(NSImage(contentsOf: url))
        }
    }

    @discardableResult
    private func attachImage(_ nsImage: NSImage?) -> Bool {
        guard let nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        pendingAttachments.append(png)
        return true
    }

    /// Images dropped on the chat or the input bar: files (incl. the
    /// floating screenshot thumbnail, which hands over a file URL) or raw
    /// image data. Only for vision-capable models.
    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard modelSupportsVision else { return false }
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let image = NSImage(contentsOf: url)
                    DispatchQueue.main.async { attachImage(image) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    let image = obj as? NSImage
                    DispatchQueue.main.async { attachImage(image) }
                }
            }
        }
        return handled
    }

    /// Dropping a file onto the text field itself makes AppKit's field
    /// editor insert its *path* as text before any SwiftUI drop handler
    /// sees it -- which is how a dragged screenshot ended up sent as
    /// "/var/folders/.../Screenshot ....png" and the model replied it can't
    /// open local files. So a path to an existing image file appearing in
    /// the draft is turned into an attachment instead.
    private func convertDroppedImagePaths(in text: String) {
        guard modelSupportsVision, text.contains("/") else { return }
        var remaining = text
        var converted = false
        for line in text.components(separatedBy: .newlines) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("/") || candidate.hasPrefix("file://") else { continue }
            let url = candidate.hasPrefix("file://") ? URL(string: candidate) : URL(fileURLWithPath: candidate)
            guard let url, url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  FileManager.default.fileExists(atPath: url.path),
                  attachImage(NSImage(contentsOf: url)) else { continue }
            remaining = remaining.replacingOccurrences(of: candidate, with: "")
            converted = true
        }
        if converted {
            draft = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // Only offered once a reply has actually finished -- mid-stream there's
    // nothing settled yet to redo.
    private var canRegenerate: Bool {
        canChat && !chat.isBusy && chat.messages.last?.role == "assistant"
    }

    private func regenerate() {
        let settings = chatSettings
        chat.regenerate(port: port, modelAlias: alias.isEmpty ? "default" : alias, settings: settings, server: server)
    }

    // Only worth offering once there's actually a meaningful middle to
    // replace -- matches compactSession()'s own no-op guard.
    private var canCompact: Bool {
        canChat && !chat.isBusy && chat.messages.count > compactKeepStart + compactKeepEnd + 1
    }

    private func compact() async {
        let settings = chatSettings
        await chat.compactSession(
            port: port, modelAlias: alias.isEmpty ? "default" : alias, settings: settings,
            keepStart: compactKeepStart, keepEnd: compactKeepEnd
        )
    }

    // Checked once a turn fully settles (see body's onChange(of: chat.isBusy))
    // rather than right after sendDraft() fires it, since send() itself
    // doesn't await the turn's completion.
    private func autoCompactIfNeeded() {
        guard autoCompactThreshold > 0, chat.messages.count > autoCompactThreshold else { return }
        Task { await compact() }
    }

    private func deleteSession(_ session: ChatSessionFile) {
        ChatSessionStore.delete(id: session.id)
        // Deleting the session currently on screen would otherwise leave
        // the chat showing a conversation whose log no longer exists --
        // start a fresh one instead of leaving that dangling state.
        if chat.currentSessionID == session.id {
            chat.newSession()
        }
    }
}

/// Pointing-hand cursor while hovered. Balances its own push on disappear:
/// a view removed while hovered (an attachment's remove button sits on top
/// of it; a chat image scrolled away) never gets the hover-exit, so a bare
/// push/pop in onHover left the cursor stuck as a hand.
private struct PointingHandCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !hovering, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}
