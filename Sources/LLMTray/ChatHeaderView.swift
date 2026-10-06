import LLMTrayCore
import SwiftUI

/// The popover's header: server status, chat session controls, the model
/// picker with Start/Stop, the model's profile and temperature, and the
/// restart prompt.
struct ChatHeaderView: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var presentation: ChatPresentation
    @ObservedObject private var profiles = ProfileManager.shared
    @ObservedObject private var catalog = ModelCatalog.shared
    @AppStorage(Pref.port) private var port: Int
    // A turn in any tab holds back model switches / restarts.
    @ObservedObject private var tabs = ChatTabs.shared
    @ObservedObject private var switchPrompter = ModelSwitchPrompter.shared
    /// A switch the picker or Load started, until the server reports it.
    @State private var switchingTo: String?

    @Binding var selectedModelID: String?
    /// Shows the chats sidebar over the popover's chat. nil: the tray's
    /// controls while the chat has its own window -- no chat controls.
    var toggleSidebar: (() -> Void)?
    /// Inside the chat window (Settings > General > Show model controls in
    /// the chat window): the window's own bar has the status and chat
    /// controls, so only the model, profile, tools and temperature rows.
    var inChatWindow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !inChatWindow {
                HStack {
                    // While the chat has its own window, clicking the status
                    // brings it up. In the popover it's the chat already.
                    if presentation.isDetached {
                        Button { NotificationCenter.default.post(name: .detachChat, object: nil) } label: {
                            ServerStatusLabel().contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show Chat Window")
                        .accessibilityHint(Text("Shows the chat window"))
                        .pointingHandCursor()
                    } else {
                        ServerStatusLabel()
                    }
                    Spacer()
                    sessionControls
                }
            }
            HStack(spacing: 6) {
                modelCard

                Button { NotificationCenter.default.post(name: .showHFBrowser, object: nil) } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help(Text("Download models from Hugging Face"))
                .accessibilityLabel(Text("Download models"))

                Menu {
                    Button("Rescan Models") { catalog.rescan() }
                    Button("Manage Models…") { openSettings(.models) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(Text("Rescan or manage models"))
                .accessibilityLabel(Text("Model actions"))

                serverToggleButton
            }
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3").foregroundColor(.secondary).font(.subheadline)
                profilePicker
                toolsMenu
                temperatureRow
            }
            modelSwitchRow
            RestartBanner()
            if let fit = catalog.fit(for: fitModelID) {
                GPUFitNotice(fit: fit)
            }
        }
        .padding(12)
    }

    /// The model the "barely fits" notice is about: the loaded one while
    /// it runs, else the picked one (what Start would load).
    private var fitModelID: String? {
        if case .running = server.state, let loaded = server.loadedModelPath { return loaded }
        return selectedModelID
    }

    // MARK: Model card

    /// The model picker in a small card: its size on disk and what it can
    /// do under the name -- small grey symbols with their names on hover
    /// (a big leading one read as a button, an eye as "hide"). The picker
    /// itself is unchanged.
    private var modelCard: some View {
        let capabilities = selectedModelID.map(ModelCapabilities.of) ?? []
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Picker("Model", selection: Binding(get: { selectedModelID }, set: { pickModel($0) })) {
                    ForEach(catalog.models) { m in
                        Text(m.displayName).tag(m.id as String?)
                    }
                }
                .labelsHidden()
                .disabled(!ops.canSwitchModel)
                .help(Text(benchmark.isRunning ? "Can't change models while auto-tune is running" : "Model"))
                if let details = modelDetails(capabilities) {
                    HStack(spacing: 4) {
                        Text(verbatim: details.size).lineLimit(1)
                        ForEach(capabilities, id: \.self) { c in
                            Image(systemName: ModelCapabilities.symbol(c)).help(ModelCapabilities.name(c))
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: details.spoken))
                }
            }
        }
        .padding(.leading, 6).padding(.trailing, 2).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    /// The size line, once the catalog has measured the folder.
    private func modelDetails(_ capabilities: [RecommendedModel.Capability]) -> (size: String, spoken: String)? {
        guard let id = selectedModelID, let bytes = catalog.sizes[id] else { return nil }
        let size = ModelCatalog.format(bytes)
        return (size, ([size] + capabilities.map(ModelCapabilities.name)).joined(separator: ", "))
    }

    // MARK: Model switching

    /// Picking another model while one is running loads it now (as LM
    /// Studio does); stopped or idle-unloaded, nothing loads until a
    /// message or Start, as before (ModelSelection).
    private func pickModel(_ id: String?) {
        selectedModelID = id
        if let model = ModelSelection.modelToLoad(afterPicking: id, server: server, benchmark: benchmark) { loadModel(model) }
    }

    private func loadModel(_ model: LocalModel) {
        switchingTo = model.path
        Task {
            // A failure shows in the server status (the launch reports it).
            try? await server.switchLoadedModel(to: model.path, alias: catalog.alias(for: model.id))
            if switchingTo == model.path { switchingTo = nil }
        }
    }

    private func shortName(_ path: String) -> String {
        let name = catalog.model(id: path)?.displayName ?? (path as NSString).lastPathComponent
        return name.split(separator: "/").last.map(String.init) ?? name
    }

    /// An outside client's pending "Ask first" request; otherwise, while the
    /// loaded model isn't the selected one (a client switched it, a switch
    /// failed), the way back.
    @ViewBuilder
    private var modelSwitchRow: some View {
        if let ask = switchPrompter.pending {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right").foregroundColor(.orange)
                Text(String(format: NSLocalizedString("%1$@ asks for %2$@", comment: "model switch prompt: client, model"),
                            ask.client, shortName(ask.target)))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Keep") { switchPrompter.answer(false) }
                    .help(server.loadedModelPath.map { Text(String(format: NSLocalizedString("Keep %@ loaded", comment: "model switch prompt"), shortName($0))) }
                          ?? Text("Keep the loaded model"))
                Button("Switch") { switchPrompter.answer(true) }
            }
            .font(.subheadline)
            .controlSize(.small)
        } else if case .running = server.state, switchingTo == nil, let loaded = server.loadedModelPath,
                  let selected = catalog.model(id: selectedModelID), loaded != selected.path {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundColor(.secondary)
                Text(String(format: NSLocalizedString("Loaded: %1$@ · selected: %2$@", comment: "model mismatch: loaded, selected"),
                            shortName(loaded), shortName(selected.path)))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundColor(.secondary)
                Spacer(minLength: 4)
                Button(String(format: NSLocalizedString("Load %@", comment: "load the selected model"), shortName(selected.path))) {
                    loadModel(selected)
                }
                .lineLimit(1)
                .disabled(!ops.canSwitchModel || tabs.isAnyBusy)
            }
            .font(.subheadline)
            .controlSize(.small)
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionControls: some View {
        if let toggleSidebar {
            HStack {
                Button { toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.plain)
                    .help("Chats")
                    .accessibilityLabel("Chats")
                Button { ChatTabs.shared.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain)
                    .help("New chat (⌘N)")
                    // Only disabled when there's truly nothing to start fresh
                    // from -- an empty *persistent* session. A temporary chat is
                    // empty too, but this is the way back to a saved one.
                    .disabled(chat.currentSessionID != nil && chat.messages.isEmpty)
                Button { ChatTabs.shared.newTemporaryChat() } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.plain)
                    .help("New temporary chat (⌘⇧N) -- nothing about it is ever saved")
                Button { NotificationCenter.default.post(name: .detachChat, object: nil) } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .buttonStyle(.plain)
                .help("Open in Window -- closing the window puts the chat back in the menu bar")
                .accessibilityLabel("Open in Window")
                settingsButton
            }
        } else {
            HStack {
                // The chat has its own window: this raises it.
                Button { NotificationCenter.default.post(name: .detachChat, object: nil) } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.plain)
                .help("Show Chat Window")
                .accessibilityLabel("Show Chat Window")
                settingsButton
            }
        }
    }

    private var settingsButton: some View {
        Button { openSettings() } label: { Image(systemName: "gearshape") }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            .buttonStyle(.plain)
    }

    // MARK: Server

    /// Small icon, not a full-width button: the server starts on its own at
    /// launch, so this is for "unload / reload", not the everyday path.
    private var serverToggleButton: some View {
        Group {
            switch server.state {
            case .stopped, .failed:
                Button(action: startServer) { Image(systemName: "play.fill") }
                    // Not beside a generator: it reloads by itself after.
                    .disabled(selectedModelID == nil || server.suspendedForImageGeneration)
                    .help(server.suspendedForVoice ? Text("The model reloads when Voice Lab stops")
                          : server.suspendedForImageGeneration ? Text("The model reloads when the image or song is done") : Text("Start server"))
            case .starting:
                ProgressView().controlSize(.small).help("Starting…")
            case .running:
                Button { server.stop() } label: { Image(systemName: "eject.fill") }
                    .help("Stop server (unload model)")
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Start Server", action: startServer)
                .disabled(!isStoppedOrFailed || selectedModelID == nil || server.suspendedForImageGeneration)
            Button("Stop Server") { server.stop() }
                .disabled(!isRunning)
        }
    }

    private func startServer() {
        guard let model = catalog.model(id: selectedModelID) else { return }
        server.start(modelPath: model.path, port: port, alias: catalog.alias(for: model.id))
    }

    private var isRunning: Bool {
        if case .running = server.state { return true }
        return false
    }

    private var isStoppedOrFailed: Bool {
        switch server.state {
        case .stopped, .failed: return true
        default: return false
        }
    }


    // MARK: Profile

    private var ops: OperationAvailability { OperationAvailability(server: server, benchmark: benchmark) }

    /// For the loaded model a switch can change launch arguments -- not
    /// while a request or the auto-tune could be cut off.
    private var canSwitchProfile: Bool {
        ModelSelection.canAssignProfile(to: selectedModelID, server: server, benchmark: benchmark)
    }

    private var profilePicker: some View {
        Menu {
            Picker("Profile", selection: Binding(
                get: { profiles.profileID(for: selectedModelID) },
                set: { switchProfile(to: $0) }
            )) {
                ForEach(profiles.profiles) { p in Text(p.name).tag(p.id) }
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

    private func switchProfile(to id: String) {
        ModelSelection.assignProfile(id, to: selectedModelID, server: server, benchmark: benchmark)
    }

    /// Quick on/off for the model's chat tools; edits its profile.
    private var toolsMenu: some View {
        let enabled = Set(profiles.value(\.tools.enabledTools, for: selectedModelID))
        return Menu {
            ForEach(ToolCatalog.entries) { tool in
                Toggle(tool.usesNetwork ? "\(tool.title) 🌐" : tool.title, isOn: Binding(
                    get: { enabled.contains(tool.name) },
                    set: { on in
                        var tools = profiles.value(\.tools.enabledTools, for: selectedModelID).filter { $0 != tool.name }
                        if on { tools.append(tool.name) }
                        profiles.set(\.tools.enabledTools, tools, for: selectedModelID)
                    }
                ))
            }
            Divider()
            Button("Tool Settings…") { openSettings(.profiles, profileID: profiles.profileID(for: selectedModelID)) }
        } label: {
            Image(systemName: "wrench.and.screwdriver")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(selectedModelID == nil)
        .help(Text(String(format: NSLocalizedString("Chat tools of the profile \u{201C}%@\u{201D} (%lld on) -- applies to every model using it", comment: "wrench menu tooltip"), profiles.profile(for: selectedModelID).name, enabled.count)))
        .accessibilityLabel(Text("Chat tools"))
    }

    /// The one sampling knob kept in the popover; edits the model's profile.
    private var temperatureRow: some View {
        HStack(spacing: 6) {
            Text("Temperature").font(.subheadline).foregroundColor(.secondary)
            Slider(value: Binding(
                get: { profiles.value(\.request.temperature, for: selectedModelID) },
                set: { profiles.set(\.request.temperature, $0, for: selectedModelID) }
            ), in: 0...2, step: 0.05).controlSize(.mini)
            Text(String(format: "%.2f", profiles.resolved(for: selectedModelID).temperature))
                .font(.subheadline).monospacedDigit().frame(width: 32, alignment: .trailing)
        }
        .help(Text("Randomness of the answers (part of the model's profile). Lower is more focused, higher more varied."))
    }

    private func openSettings(_ pane: SettingsPane? = nil, profileID: String? = nil) {
        var info: [String: String] = [:]
        if let pane { info["pane"] = pane.rawValue }
        if let profileID { info["profileID"] = profileID }
        NotificationCenter.default.post(name: .showSettings, object: nil, userInfo: info)
    }
}

/// The server's state as a dot and a line: the popover's header, and the
/// chat window's title bar.
struct ServerStatusLabel: View {
    @EnvironmentObject var server: ServerManager

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }
    }

    private var statusColor: Color {
        switch server.state {
        case .stopped: return server.suspendedForImageGeneration ? .blue : .gray
        case .starting: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch server.state {
        case .stopped:
            // Unloaded for an image or a song (ChatClient): not idle, and
            // it comes back by itself when that's done.
            if server.suspendedForVoice {
                return NSLocalizedString("Paused while Voice Lab is on -- the model reloads after", comment: "server status")
            }
            if server.suspendedForImageGeneration {
                return NSLocalizedString("Paused while an image or song is made -- the model reloads after", comment: "server status")
            }
            return server.isIdleUnloaded
                ? NSLocalizedString("Idle -- the model reloads on the next message", comment: "server status")
                : NSLocalizedString("Stopped", comment: "server status")
        case .starting:
            return NSLocalizedString("Starting…", comment: "server status")
        case .running(let port, let model):
            return String(format: NSLocalizedString("Running — %@ on :%lld", comment: "server status: model name, port"), model, port)
        case .failed(let msg):
            return String(format: NSLocalizedString("Failed: %@", comment: "server status: error message"), msg)
        }
    }
}

/// A model that barely fits the GPU (GPUFit): a notice, never a block --
/// with how to raise the GPU memory limit behind "How?". Compact in the
/// Models list: a short line, the whole notice as its tooltip.
struct GPUFitNotice: View {
    let fit: GPUFit
    var compact = false
    @State private var showsHow = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            if compact {
                Text("Barely fits the GPU memory").foregroundStyle(.orange)
            } else {
                Text(Self.message(fit)).fixedSize(horizontal: false, vertical: true)
            }
            if fit.sysctlCommand != nil {
                Button("How?") { showsHow.toggle() }
                    .buttonStyle(.link)
                    .popover(isPresented: $showsHow, arrowEdge: .bottom) { howTo }
            }
        }
        .font(.subheadline)
        .help(Text(Self.message(fit)))
    }

    static func message(_ fit: GPUFit) -> String {
        let weights = GPUFit.gigabytes(fit.weightsBytes)
        let limit = GPUFit.gigabytes(Int64(clamping: fit.gpuLimitBytes))
        return fit.suggestedWiredLimitMB != nil
            ? String(format: NSLocalizedString("This model takes %1$@ of the %2$@ GB the GPU may use; long prompts may run out of memory. Use a smaller model, or raise the GPU memory limit.", comment: "GPU fit notice: weights GB, GPU limit GB"), weights, limit)
            : String(format: NSLocalizedString("This model takes %1$@ of the %2$@ GB the GPU may use; long prompts may run out of memory. Use a smaller model.", comment: "GPU fit notice: weights GB, GPU limit GB"), weights, limit)
    }

    @ViewBuilder
    private var howTo: some View {
        if let command = fit.sysctlCommand {
            VStack(alignment: .leading, spacing: 8) {
                Text("Raise the GPU memory limit in Terminal:")
                HStack {
                    Text(verbatim: command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
                Text("Then restart the model server. The limit goes back to the default when the Mac restarts. LLMTray never changes it itself.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 360)
        }
    }
}

/// The menu bar's popover while the chat has its own window: the server,
/// model and tool controls, which the window leaves out.
struct TrayControlsView: View {
    @AppStorage(Pref.selectedModelID) private var selectedModelID: String?

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderView(selectedModelID: $selectedModelID)
            DownloadQueueRow()
        }
        .frame(width: 420)
            // Models added in Finder / LM Studio since the last look, as the
            // chat's popover does on opening.
            .onAppear { ModelCatalog.shared.rescan() }
    }
}
