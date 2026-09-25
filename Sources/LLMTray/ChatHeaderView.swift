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

    @Binding var selectedModelID: String?
    /// Shows the chats sidebar over the popover's chat. nil: the tray's
    /// controls while the chat has its own window -- no chat controls.
    var toggleSidebar: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ServerStatusLabel()
                Spacer()
                sessionControls
            }
            HStack(spacing: 6) {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(catalog.models) { m in
                        Text(m.displayName).tag(m.id as String?)
                    }
                }
                .labelsHidden()
                .disabled(!ops.canSwitchModel)
                .help(Text(benchmark.isRunning ? "Can't change models while auto-tune is running" : "Model"))

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
                Image(systemName: "slider.horizontal.3").foregroundColor(.secondary).font(.system(size: 11))
                profilePicker
                toolsMenu
                temperatureRow
            }
            RestartBanner()
        }
        .padding(12)
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
                Button { chat.newSession() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain)
                    .help("New chat (saved)")
                    // Only disabled when there's truly nothing to start fresh
                    // from -- an empty *persistent* session. A temporary chat is
                    // empty too, but this is the way back to a saved one.
                    .disabled(chat.currentSessionID != nil && chat.messages.isEmpty)
                Button { chat.newTemporaryChat() } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.plain)
                    .help("New temporary chat -- nothing about it is ever saved")
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
                    .disabled(selectedModelID == nil)
                    .help("Start server")
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
                .disabled(!isStoppedOrFailed || selectedModelID == nil)
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

    private var ops: OperationAvailability { OperationAvailability(server: server, chat: chat, benchmark: benchmark) }

    /// For the loaded model a switch can change launch arguments -- not
    /// while a request or the auto-tune could be cut off.
    private var canSwitchProfile: Bool {
        selectedModelID != nil && ops.canAssignProfile(toLoadedModel: selectedModelID == server.loadedModelPath)
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

    /// Launch-setting differences are applied by the "Restart Server"
    /// prompt, not by restarting here (that would cut off requests).
    private func switchProfile(to id: String) {
        guard canSwitchProfile, let modelID = selectedModelID else { return }
        profiles.assign(profileID: id, to: modelID)
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
            Text("Temperature").font(.system(size: 11)).foregroundColor(.secondary)
            Slider(value: Binding(
                get: { profiles.value(\.request.temperature, for: selectedModelID) },
                set: { profiles.set(\.request.temperature, $0, for: selectedModelID) }
            ), in: 0...2, step: 0.05).controlSize(.mini)
            Text(String(format: "%.2f", profiles.resolved(for: selectedModelID).temperature))
                .font(.system(size: 11)).monospacedDigit().frame(width: 32, alignment: .trailing)
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
            Text(statusText).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
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
        case .stopped:
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

/// The menu bar's popover while the chat has its own window: the server,
/// model and tool controls, which the window leaves out.
struct TrayControlsView: View {
    @AppStorage(Pref.selectedModelID) private var selectedModelID: String?

    var body: some View {
        ChatHeaderView(selectedModelID: $selectedModelID).frame(width: 420)
    }
}
