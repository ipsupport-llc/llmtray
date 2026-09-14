import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @StateObject private var runtime = RuntimeManager()

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
    @AppStorage("llmtray.alias") private var alias: String = "n"
    @State private var draft: String = ""
    @State private var showSettings: Bool = false
    @AppStorage("llmtray.temperature") private var temperature: Double = 0.6
    @AppStorage("llmtray.topP") private var topP: Double = 0.95
    @AppStorage("llmtray.maxTokens") private var maxTokens: Double = 1024

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            if showSettings {
                settingsPanel
                Divider()
            }
            chatArea
            Divider()
            inputBar
        }
        .frame(width: 420, height: 560)
        .onAppear {
            models = ModelDiscovery.scanModels(root: modelsRoot)
            // Fall back to the first discovered model if nothing was saved,
            // or if the saved model no longer exists on disk (moved/deleted
            // since last launch).
            if selectedModelID == nil || !models.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = models.first?.id
            }
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

            Picker("Model", selection: $selectedModelID) {
                ForEach(models) { m in
                    Text(m.displayName).tag(m.id as String?)
                }
            }
            .labelsHidden()
            .disabled(isBusy)

            HStack {
                startStopButton
                Spacer()
            }
        }
        .padding(12)
    }

    private var startStopButton: some View {
        Group {
            switch server.state {
            case .stopped, .failed:
                Button("Start Server") {
                    guard let id = selectedModelID, let model = models.first(where: { $0.id == id }) else { return }
                    server.start(modelPath: model.path, port: port, kvBits: kvBits, kvGroupSize: kvGroupSize, alias: alias)
                }
                .disabled(selectedModelID == nil)
            case .starting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Starting…")
                }
            case .running:
                Button("Stop Server", role: .destructive) {
                    server.stop()
                }
            }
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
            modelsRootSection

            Divider().padding(.vertical, 4)

            Group {
                Stepper("Port: \(port)", value: $port, in: 1024...65535)
                Stepper("KV bits: \(kvBits == 0 ? "off" : String(kvBits))", value: $kvBits, in: 0...8)
                Stepper("KV group size: \(kvGroupSize)", value: $kvGroupSize, in: 16...128, step: 16)
                HStack {
                    Text("Model alias:")
                    TextField("alias", text: $alias)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .disabled(isBusy || isRunning)

            Divider().padding(.vertical, 4)
            chatSettingsSection
            Divider().padding(.vertical, 4)
            runtimeUpdateRow
        }
        .font(.system(size: 12))
        .padding(12)
    }

    private var modelsRootSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models folder").foregroundColor(.secondary)
            HStack {
                TextField("models folder", text: $modelsRoot)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { models = ModelDiscovery.scanModels(root: modelsRoot) }
                Button("Browse…") {
                    chooseModelsRootFolder()
                }
            }
            Button("Use LM Studio's folder (~/.lmstudio/models)") {
                modelsRoot = NSString(string: "~/.lmstudio/models").expandingTildeInPath
                models = ModelDiscovery.scanModels(root: modelsRoot)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .font(.system(size: 10))
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
        models = ModelDiscovery.scanModels(root: modelsRoot)
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
                Slider(value: $maxTokens, in: 64...32768, step: 64)
                Text(String(Int(maxTokens))).frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var runtimeUpdateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("mlx-lm runtime:")
                    .foregroundColor(.secondary)
                Text(runtime.pinnedVersion() ?? "unknown")
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
                    Text("\(current) → \(latest) available")
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

            if !msg.reasoning.isEmpty {
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
                TextField("Message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(sendDraft)
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
        guard isRunning else { return }
        let text = draft
        draft = ""
        let settings = ChatSettings(temperature: temperature, topP: topP, maxTokens: Int(maxTokens))
        chat.send(prompt: text, port: port, modelAlias: alias.isEmpty ? "default" : alias, settings: settings)
    }

    // Only offered once a reply has actually finished -- mid-stream there's
    // nothing settled yet to redo.
    private var canRegenerate: Bool {
        isRunning && !chat.isStreaming && chat.messages.last?.role == "assistant"
    }

    private func regenerate() {
        let settings = ChatSettings(temperature: temperature, topP: topP, maxTokens: Int(maxTokens))
        chat.regenerate(port: port, modelAlias: alias.isEmpty ? "default" : alias, settings: settings)
    }
}
