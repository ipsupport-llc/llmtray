import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

enum SettingsTab {
    case general
    case chat
    case benchmark
    case advanced
}

struct ContentView: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @StateObject private var runtime = RuntimeManager()
    @StateObject private var benchmark = BenchmarkRunner()

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
    @AppStorage("llmtray.kvBits") private var kvBits: Int = 4
    @AppStorage("llmtray.kvGroupSize") private var kvGroupSize: Int = 64
    @AppStorage("llmtray.quantizedKVStart") private var quantizedKVStart: Int = 0
    // Not @AppStorage -- remembered per selected model via ModelAliasStore
    // instead of one value shared across every model (see onChange(of:
    // selectedModelID) below, which loads/saves it on every switch).
    @State private var alias: String = ""
    @State private var aliasConflict: Bool = false
    @State private var draft: String = ""
    @State private var showSettings: Bool = false
    @State private var settingsTab: SettingsTab = .general
    // Backs the History menu -- refreshed on appear and whenever
    // ChatSessionStore posts .sessionsDidChange (save/delete), rather than
    // read fresh from disk on every render (see that notification's own
    // doc comment for why a plain disk read wasn't reliable here).
    @State private var sessionHistory: [ChatSessionFile] = []
    @AppStorage("llmtray.autoRestartStallThreshold") private var autoRestartStallThreshold: Int = 3
    @AppStorage("llmtray.autoStartOnLaunch") private var autoStartOnLaunch: Bool = true
    // Reuses Sparkle's own UserDefaults key directly -- SPUUpdater reads
    // this key itself on every access rather than caching it, so binding a
    // Toggle straight to it controls Sparkle without needing a reference
    // to the updater instance (which lives in AppDelegate, not here).
    @AppStorage("SUEnableAutomaticChecks") private var autoCheckForUpdates: Bool = true
    @AppStorage("llmtray.showReasoning") private var showReasoning: Bool = true
    @AppStorage("llmtray.autoStopIdleMinutes") private var autoStopIdleMinutes: Int = 0
    @AppStorage("llmtray.promptCacheMB") private var promptCacheMB: Int = 1024
    @AppStorage("llmtray.stallThresholdSeconds") private var stallThresholdSeconds: Int = 60
    @AppStorage("llmtray.allowLAN") private var allowLAN: Bool = false
    @AppStorage("llmtray.verboseServerLogging") private var verboseServerLogging: Bool = false
    @AppStorage("llmtray.extraServerArgs") private var extraServerArgs: String = ""
    @AppStorage("llmtray.decodeConcurrency") private var decodeConcurrency: Int = 1
    @AppStorage("llmtray.enableImageGeneration") private var enableImageGeneration: Bool = false
    @AppStorage("llmtray.imageGenModel") private var imageGenModel: ImageGenModel = .gptqMixed
    // On by default -- a diffusion model's own peak memory can rival or
    // exceed a loaded chat model's, and mlx_lm.server has no notion of
    // "share the GPU with something else right now." Off is there for
    // whoever has enough unified memory to comfortably hold both at once.
    @AppStorage("llmtray.unloadModelDuringImageGen") private var unloadModelDuringImageGen: Bool = true
    @AppStorage("llmtray.imageQuality") private var imageQuality: ImageQuality = .balanced
    // Compaction keeps these many messages verbatim at the start and end
    // of a session, replacing everything in between with one
    // model-generated summary (see ChatClient.compactSession).
    @AppStorage("llmtray.compactKeepStart") private var compactKeepStart: Int = 4
    @AppStorage("llmtray.compactKeepEnd") private var compactKeepEnd: Int = 6
    // 0 disables auto-compaction -- otherwise, checked after every
    // completed turn (see sendDraft's onChange-driven autoCompactIfNeeded).
    @AppStorage("llmtray.autoCompactThreshold") private var autoCompactThreshold: Int = 0
    @State private var imageModelDownloadError: String?
    // SMAppService.mainApp.status is the actual source of truth (the user
    // could also flip this from System Settings > General > Login Items
    // directly) -- not persisted separately in UserDefaults, just read
    // fresh on appear and updated locally after a successful toggle.
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @FocusState private var isInputFocused: Bool
    @AppStorage("llmtray.temperature") private var temperature: Double = 0.6
    @AppStorage("llmtray.topP") private var topP: Double = 0.95
    @AppStorage("llmtray.maxTokens") private var maxTokens: Double = 1024
    @AppStorage("llmtray.systemPrompt") private var systemPrompt: String = ""
    // The selected model's own trained context ceiling (max_position_embeddings),
    // read fresh on every model switch -- see updateModelMaxContext(for:).
    // 32768 is just the fallback for a model whose config.json doesn't
    // expose the field in a shape ModelDiscovery.maxContextLength recognizes,
    // not a real technical limit of anything.
    @State private var modelMaxContext: Int = 32768

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            if showSettings {
                // Plain (unwrapped) settingsPanel relied on the popover's
                // own preferredContentSize sizing to grow to fit -- fine
                // when Settings was short, but confirmed live once enough
                // toggles piled up in General: NSPopover has nowhere to
                // grow past screen bounds, so the excess just got clipped
                // with no way to scroll to it (couldn't reach the top of
                // the panel, or the chat below it, at all). Capping the
                // height and scrolling internally here -- same pattern
                // chatArea already uses -- keeps the whole popover on
                // screen regardless of how many settings end up in either tab.
                ScrollView {
                    settingsPanel
                }
                .frame(maxHeight: 380)
                Divider()
            }
            chatArea
            Divider()
            inputBar
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
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isInputFocused = true
        }
        .onChange(of: selectedModelID) { newID in
            // Swap in that model's own remembered alias instead of leaving
            // whatever was typed for the previous model still in the field.
            alias = newID.map(ModelAliasStore.alias(for:)) ?? ""
            aliasConflict = false
            updateModelMaxContext(for: newID)
        }
        .onChange(of: modelsRoot) { newRoot in
            // Covers every way modelsRoot can change (typing, Browse…, the
            // "Use LM Studio" shortcut) with one rescan instead of needing
            // an explicit call at each call site -- previously this only
            // happened on the specific buttons, so editing the text field
            // directly and not hitting Return left the picker stale until
            // the app was restarted.
            models = ModelDiscovery.scanModels(root: newRoot)
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelsDidChange)) { notification in
            // Fires after a Hugging Face download finishes -- rescan and
            // jump straight to the model that just landed on disk instead
            // of leaving the picker on whatever was selected before.
            models = ModelDiscovery.scanModels(root: modelsRoot)
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
                    NotificationCenter.default.post(name: .showServerLog, object: nil)
                } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(.plain)
                .help("View server log")
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                Button {
                    models = ModelDiscovery.scanModels(root: modelsRoot)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Rescan \(modelsRoot)")
                Button {
                    NotificationCenter.default.post(name: .showHFBrowser, object: nil)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help("Browse & download models from Hugging Face")
            }

            HStack(spacing: 6) {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(models) { m in
                        Text(m.displayName).tag(m.id as String?)
                    }
                }
                .labelsHidden()
                .disabled(isBusy)

                serverToggleButton
            }
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
        server.start(modelPath: model.path, port: port, kvBits: kvBits, kvGroupSize: kvGroupSize, alias: alias)
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
        maxTokens = min(maxTokens, Double(modelMaxContext))
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

    // MARK: - Settings

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $settingsTab) {
                Text("General").tag(SettingsTab.general)
                Text("Chat").tag(SettingsTab.chat)
                Text("Benchmark").tag(SettingsTab.benchmark)
                Text("Advanced").tag(SettingsTab.advanced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 4)

            switch settingsTab {
            case .general:
                generalSettingsContent
            case .chat:
                chatTabContent
            case .benchmark:
                BenchmarkView(benchmark: benchmark, port: port, modelAlias: alias.isEmpty ? "default" : alias)
            case .advanced:
                advancedSettingsContent
            }
        }
        .font(.system(size: 12))
        .padding(12)
    }

    private var generalSettingsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }
            Toggle("Start server automatically on launch", isOn: $autoStartOnLaunch)
            Toggle("Automatically check for updates", isOn: $autoCheckForUpdates)
            Toggle("Show reasoning / thinking", isOn: $showReasoning)
            Stepper(
                autoStopIdleMinutes == 0
                    ? "Unload model when idle: off"
                    : "Unload model after \(autoStopIdleMinutes) min idle",
                value: $autoStopIdleMinutes, in: 0...180, step: 5
            )
            if autoStopIdleMinutes > 0 {
                Text("Frees the memory a loaded model holds; reloads automatically on the next request (with the usual startup delay).")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 4)

            modelsRootSection

            Divider().padding(.vertical, 4)

            Group {
                Stepper("Port: \(port)", value: $port, in: 1024...65535)
                Stepper("KV bits: \(kvBits == 0 ? "off" : String(kvBits))", value: $kvBits, in: 0...8)
                Stepper("KV group size: \(kvGroupSize)", value: $kvGroupSize, in: 16...128, step: 16)
                if kvBits > 0 {
                    Stepper(
                        quantizedKVStart == 0
                            ? "Start quantizing KV cache: from the first token"
                            : "Start quantizing KV cache: after \(quantizedKVStart) tokens",
                        value: $quantizedKVStart, in: 0...20000, step: 500
                    )
                    Text("Keeps the first N tokens of context at full precision before switching to quantized KV -- higher values trade some of the memory savings for accuracy on long prompts.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Model alias:")
                        TextField("alias", text: $alias)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: alias) { newAlias in
                                guard let selectedModelID else { return }
                                aliasConflict = ModelAliasStore.isAliasTaken(
                                    newAlias, excluding: selectedModelID, among: models.map(\.id)
                                )
                                // Still saved even when it conflicts -- the
                                // warning is informational (whichever model
                                // a client's `model` field matches first
                                // wins), not a hard block, since the user
                                // might be mid-edit toward some other value.
                                ModelAliasStore.setAlias(newAlias, for: selectedModelID)
                            }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(alias, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy alias — this is the `model` value other tools should send")
                    }
                    if aliasConflict {
                        Text("Another model already uses this alias.")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
            }
            .disabled(isBusy || isRunning)

            Divider().padding(.vertical, 4)
            runtimeUpdateRow
        }
    }

    // Split into one computed property per section (rather than one giant
    // VStack) -- SwiftUI's ViewBuilder type-checking is worse than linear
    // in the number of sibling views/modifiers in a single block, and this
    // section had grown large enough that a release/optimized build (which
    // type-checks more strictly than a debug build) started timing out
    // with "unable to type-check this expression in reasonable time" on
    // the enclosing VStack, even though `swift build` (debug) compiled it
    // fine locally.
    private var advancedSettingsContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            serverRecoverySection
            Divider().padding(.vertical, 4)
            memorySection
            Divider().padding(.vertical, 4)
            concurrencySection
            Divider().padding(.vertical, 4)
            networkSection
            Divider().padding(.vertical, 4)
            diagnosticsSection
        }
        .disabled(isBusy || isRunning)
    }

    private var serverRecoverySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Server recovery").foregroundColor(.secondary)
            Stepper("Stall timeout: \(stallThresholdSeconds)s", value: $stallThresholdSeconds, in: 10...300, step: 10)
            Stepper(
                autoRestartStallThreshold == 0
                    ? "Auto-restart on repeated stalls: off"
                    : "Auto-restart after \(autoRestartStallThreshold) consecutive stalled requests",
                value: $autoRestartStallThreshold, in: 0...10
            )
            // A single multi-line literal, not `+`-joined string literals --
            // each `+` on String forces the type-checker to consider every
            // visible `+` overload (numeric types, arrays, ...) at every
            // join point, which is the single most common trigger for
            // "unable to type-check this expression in reasonable time"
            // inside a ViewBuilder (see experimentalSection's fix).
            Text(
                """
                A request can stall if mlx_lm.server's worker thread dies without crashing the whole \
                process (e.g. a METAL out-of-memory error) -- every request after that hangs until \
                its own timeout above, forever, since the process itself looks alive. Auto-restart \
                kicks in after that many stalls in a row instead of leaving it wedged. 0 disables it.
                """
            )
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Memory").foregroundColor(.secondary)
            Stepper("Prompt cache limit: \(promptCacheMB) MB", value: $promptCacheMB, in: 128...8192, step: 128)
            Text("Caps mlx_lm.server's cross-conversation KV cache -- without a limit it grows forever and can crash the process on a long session.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private var concurrencySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Concurrency").foregroundColor(.secondary)
            Stepper(
                decodeConcurrency <= 1
                    ? "Max concurrent predictions: 1 (requests queue)"
                    : "Max concurrent predictions: \(decodeConcurrency)",
                value: $decodeConcurrency, in: 1...16
            )
            Text("How many separate requests mlx_lm.server batches into one GPU step. Only helps when multiple clients/chats hit the server at the same time -- a single conversation isn't sped up by this. Higher values use more memory per loaded model.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Network").foregroundColor(.secondary)
            Toggle("Allow connections from local network", isOn: $allowLAN)
            Text(
                allowLAN
                    ? "The server is reachable from other devices on your network, not just this Mac."
                    : "Loopback only (127.0.0.1) -- nothing outside this Mac can reach the server."
            )
            .font(.system(size: 10))
            .foregroundColor(allowLAN ? .orange : .secondary)
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Diagnostics").foregroundColor(.secondary)
            Toggle("Verbose server logging (DEBUG)", isOn: $verboseServerLogging)
            VStack(alignment: .leading, spacing: 2) {
                Text("Extra mlx_lm.server arguments:").font(.system(size: 11))
                TextField("e.g. --draft-model /path/to/model", text: $extraServerArgs)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private var modelsRootSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models folder").foregroundColor(.secondary)
            HStack {
                // No .onSubmit rescan needed here -- the .onChange(of: modelsRoot)
                // on the root view already rescans on every edit, live.
                TextField("models folder", text: $modelsRoot)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("Browse…") {
                    chooseModelsRootFolder()
                }
            }
            Button("Use LM Studio's folder (~/.lmstudio/models)") {
                modelsRoot = NSString(string: "~/.lmstudio/models").expandingTildeInPath
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .font(.system(size: 10))
        }
    }

    /// SMAppService.mainApp -- the modern (macOS 13+, matching this app's
    /// own minimum) way to register a login item, requiring no separate
    /// helper binary the way the older SMLoginItemSetEnabled API did.
    /// Registration can fail (e.g. running from a bare, unsigned dev build
    /// rather than a properly installed .app), so this surfaces the error
    /// inline instead of silently leaving the toggle in the wrong state.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }

    private func chooseModelsRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: modelsRoot)
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelsRoot = url.path
    }

    private var chatTabContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt").foregroundColor(.secondary)
                TextEditor(text: $systemPrompt)
                    .font(.system(size: 12))
                    .frame(height: 90)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Text("Sent as the first message on every new chat. Leave empty for none.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 4)
            chatSettingsSection
        }
    }

    private var chatSettingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Chat sampling").foregroundColor(.secondary)
            HStack {
                Text("Temperature").frame(width: 90, alignment: .leading)
                Slider(value: $temperature, in: 0...2, step: 0.05)
                Text(String(format: "%.2f", temperature)).frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text("Top-p").frame(width: 90, alignment: .leading)
                Slider(value: $topP, in: 0...1, step: 0.01)
                Text(String(format: "%.2f", topP)).frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text("Max tokens").frame(width: 90, alignment: .leading)
                Slider(value: $maxTokens, in: 64...Double(modelMaxContext), step: 256)
                Text(String(Int(maxTokens))).frame(width: 52, alignment: .trailing)
            }

            Divider().padding(.vertical, 4)
            sessionSettingsSection

            Divider().padding(.vertical, 4)
            imageGenerationSection
        }
    }

    private var sessionSettingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sessions").foregroundColor(.secondary)
            Stepper("Keep first \(compactKeepStart) messages", value: $compactKeepStart, in: 1...20)
            Stepper("Keep last \(compactKeepEnd) messages", value: $compactKeepEnd, in: 1...20)
            Stepper(
                "Auto-compact past: \(autoCompactThreshold == 0 ? "off" : "\(autoCompactThreshold) messages")",
                value: $autoCompactThreshold, in: 0...200, step: 10
            )
            Text(
                """
                Compacting replaces older messages in the middle of a long chat with one \
                model-written summary, keeping the first/last few intact -- shrinks context \
                without losing the gist. Manual "Compact" button always available once a chat is \
                long enough; auto-compact (off by default) triggers it for you past the threshold.
                """
            )
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
    }

    // Split out of chatSettingsSection -- same SwiftUI type-checker
    // complexity reasoning as advancedSettingsContent's own split (see its
    // comment): this section alone has a custom Binding, a Picker, and
    // several Text/conditional views, easily enough to trip the same
    // "unable to type-check this expression in reasonable time" seen there.
    private var imageGenerationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tools").foregroundColor(.secondary)
            Picker("Model", selection: $imageGenModel) {
                ForEach(ImageGenModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            Text("\(imageGenModel.summary) Download: \(imageGenModel.approximateDownloadDescription).")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Toggle("Enable image generation", isOn: enableImageGenerationBinding)
            if enableImageGeneration {
                Picker("Canvas size", selection: $imageQuality) {
                    ForEach(ImageQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text("Scales whatever width/height the model asks for -- Balanced is a 1024x1024 no-op.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Toggle("Unload chat model during generation", isOn: $unloadModelDuringImageGen)
                Text(
                    """
                    Both models resident at once can easily exceed unified memory (a diffusion \
                    model's own peak can rival or exceed a loaded chat model's) -- on, the chat \
                    model stops before generating and reloads right after, adding reload time \
                    per image. Turn off only if this Mac comfortably fits both at once.
                    """
                )
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
            if chat.isDownloadingModel {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(chat.mfluxStatusText.isEmpty ? "Downloading…" : chat.mfluxStatusText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            if let imageModelDownloadError {
                Text(imageModelDownloadError)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
            Text(
                """
                Exposes a generate_image tool to the model (needs a tool-calling-capable model \
                to actually use it) -- when called, runs the selected model locally and shows \
                the result inline.
                """
            )
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
    }

    // Extracted with an explicit `Binding<Bool>` type -- see
    // mtpRuntimeToggleBinding's old comment (now removed along with that
    // toggle) for why an inline Binding(get:set:) in a ViewBuilder is a
    // type-checker trap regardless of the surrounding block's own size.
    private var enableImageGenerationBinding: Binding<Bool> {
        Binding<Bool>(
            get: { enableImageGeneration },
            set: { newValue in
                if newValue {
                    confirmAndDownloadImageModel()
                } else {
                    enableImageGeneration = false
                }
            }
        )
    }

    /// Downloads (if not already cached) before actually flipping the
    /// toggle on -- a diffusion model is tens of GB; doing this eagerly,
    /// with a visible progress row, beats silently stalling the first chat
    /// message that happens to trigger generate_image.
    private func confirmAndDownloadImageModel() {
        let model = imageGenModel
        let alert = NSAlert()
        alert.messageText = "Enable image generation?"
        alert.informativeText = "The first time, this downloads \(model.displayName) "
            + "(\(model.approximateDownloadDescription)) to this Mac. Downloading now, before "
            + "enabling, so it doesn't stall a later chat message."
        alert.addButton(withTitle: "Download and Enable")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        imageModelDownloadError = nil
        Task {
            if let error = await chat.downloadImageModel(model) {
                imageModelDownloadError = error.localizedDescription
            } else {
                enableImageGeneration = true
            }
        }
    }

    // The pin is a full git commit SHA now (our own fork, not a PyPI
    // semver) -- shorten it for display the way GitHub itself does; the
    // "mtp-runtime" branch-tip marker is already short and passes through.
    private func shortRef(_ ref: String) -> String {
        ref.count > 12 ? String(ref.prefix(7)) : ref
    }

    private var runtimeUpdateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("mlx-lm runtime:")
                    .foregroundColor(.secondary)
                Text(runtime.pinnedVersion().map(shortRef) ?? "unknown")
                Spacer()
                switch runtime.checkState {
                case .checking, .updating:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check for Updates") {
                        runtime.checkForUpdate()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .disabled(isRunning)
                }
            }
            switch runtime.checkState {
            case .upToDate:
                Text("Up to date.").foregroundColor(.secondary)
            case .updateAvailable(let current, let latest):
                HStack {
                    Text("\(shortRef(current)) → \(shortRef(latest)) available")
                    Button("Update") {
                        runtime.applyUpdate(to: latest)
                    }
                    .disabled(isRunning)
                }
            case .failed(let msg):
                Text(msg).foregroundColor(.red).lineLimit(2)
            case .idle, .checking, .updating:
                EmptyView()
            }
            if isRunning {
                Text("Stop the server before updating the runtime.")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
            }
        }
        .font(.system(size: 11))
    }

    private var isRunning: Bool {
        if case .running = server.state { return true }
        return false
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
                    Text(msg.reasoning)
                        .font(.system(size: 11).italic())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color.gray.opacity(0.06))
                .cornerRadius(8)
            }

            if !msg.content.isEmpty || msg.reasoning.isEmpty {
                Text(msg.content.isEmpty ? "…" : msg.content)
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
                        HStack(spacing: 8) {
                            Button {
                                saveImage(data, prompt: msg.imagePrompts[safe: i] ?? "")
                            } label: {
                                Label("Save…", systemImage: "square.and.arrow.down")
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

    /// The one deliberate way a generated image reaches disk -- an explicit
    /// per-image save, not automatic (see chatBubble's images ForEach).
    private func saveImage(_ data: Data, prompt: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.slugify(prompt) + ".png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
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
            HStack(spacing: 8) {
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
                    .focused($isInputFocused)
                    .disabled(!isRunning)

                if chat.isBusy {
                    Button {
                        chat.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
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
                    .disabled(!isRunning || draft.trimmingCharacters(in: .whitespaces).isEmpty)
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
        guard isRunning, !chat.isBusy else { return }
        let text = draft
        draft = ""
        let settings = ChatSettings(temperature: temperature, topP: topP, maxTokens: Int(maxTokens), systemPrompt: systemPrompt, enableImageGeneration: enableImageGeneration, imageGenModel: imageGenModel, unloadModelDuringImageGen: unloadModelDuringImageGen, imageQuality: imageQuality)
        chat.send(prompt: text, port: port, modelAlias: alias.isEmpty ? "default" : alias, settings: settings, server: server)
        isInputFocused = true
    }

    // Only offered once a reply has actually finished -- mid-stream there's
    // nothing settled yet to redo.
    private var canRegenerate: Bool {
        isRunning && !chat.isBusy && chat.messages.last?.role == "assistant"
    }

    private func regenerate() {
        let settings = ChatSettings(temperature: temperature, topP: topP, maxTokens: Int(maxTokens), systemPrompt: systemPrompt, enableImageGeneration: enableImageGeneration, imageGenModel: imageGenModel, unloadModelDuringImageGen: unloadModelDuringImageGen, imageQuality: imageQuality)
        chat.regenerate(port: port, modelAlias: alias.isEmpty ? "default" : alias, settings: settings, server: server)
    }

    // Only worth offering once there's actually a meaningful middle to
    // replace -- matches compactSession()'s own no-op guard.
    private var canCompact: Bool {
        isRunning && !chat.isBusy && chat.messages.count > compactKeepStart + compactKeepEnd + 1
    }

    private func compact() async {
        let settings = ChatSettings(temperature: temperature, topP: topP, maxTokens: Int(maxTokens), systemPrompt: systemPrompt, enableImageGeneration: enableImageGeneration, imageGenModel: imageGenModel, unloadModelDuringImageGen: unloadModelDuringImageGen, imageQuality: imageQuality)
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
