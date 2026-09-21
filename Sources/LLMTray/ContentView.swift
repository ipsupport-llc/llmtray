import SwiftUI
import AppKit
import ServiceManagement

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
                    chat.clear()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New chat")
                .disabled(chat.messages.isEmpty)
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
                    ForEach(chat.messages) { msg in
                        chatBubble(msg)
                            .id(msg.id)
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

    private func chatBubble(_ msg: ChatMessage) -> some View {
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
            // this turn -- never written to disk, so nothing to clean up
            // when the chat is cleared or the app quits.
            ForEach(Array(msg.images.enumerated()), id: \.offset) { _, data in
                if let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 320)
                        .cornerRadius(8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == "user" ? .trailing : .leading)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 4) {
            if canRegenerate || chat.lastTokensPerSecond != nil {
                HStack {
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

                if chat.isStreaming {
                    Button {
                        chat.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
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
        guard isRunning, !chat.isStreaming else { return }
        let text = draft
        draft = ""
        let settings = ChatSettings(temperature: temperature, topP: topP, maxTokens: Int(maxTokens), systemPrompt: systemPrompt)
        chat.send(prompt: text, port: port, modelAlias: alias.isEmpty ? "default" : alias, settings: settings)
        isInputFocused = true
    }

    // Only offered once a reply has actually finished -- mid-stream there's
    // nothing settled yet to redo.
    private var canRegenerate: Bool {
        isRunning && !chat.isStreaming && chat.messages.last?.role == "assistant"
    }

    private func regenerate() {
        let settings = ChatSettings(temperature: temperature, topP: topP, maxTokens: Int(maxTokens), systemPrompt: systemPrompt)
        chat.regenerate(port: port, modelAlias: alias.isEmpty ? "default" : alias, settings: settings)
    }
}
