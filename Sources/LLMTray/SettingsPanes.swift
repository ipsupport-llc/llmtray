import AppKit
import LLMTrayCore
import ServiceManagement
import SwiftUI

// Every user-facing string here is a LocalizedStringKey (a plain literal in
// Text/Toggle/Button/Section/SettingLabel), looked up in
// Localization/<lang>.lproj/Localizable.strings. The keys ARE the English
// text, so a string a language hasn't translated yet shows in English.

// MARK: - General

struct GeneralPane: View {
    @AppStorage(Pref.autoStartOnLaunch) private var autoStartOnLaunch
    @AppStorage(Pref.showReasoning) private var showReasoning
    @AppStorage(Pref.showToolCalls) private var showToolCalls
    @AppStorage(Pref.autoStopIdleMinutes) private var autoStopIdleMinutes
    @AppStorage(Pref.compactKeepStart) private var compactKeepStart
    @AppStorage(Pref.compactKeepEnd) private var compactKeepEnd
    @AppStorage(Pref.autoCompactThreshold) private var autoCompactThreshold
    // SMAppService is the source of truth (the user can also change it in
    // System Settings > Login Items), so it's read, not stored.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var language: String = AppLanguage.current

    var body: some View {
        Form {
            Section("Language") {
                Picker(selection: Binding(get: { language }, set: { language = $0; AppLanguage.set($0) })) {
                    Text("System").tag("")
                    ForEach(AppLanguage.available, id: \.self) { code in
                        Text(AppLanguage.name(of: code)).tag(code)
                    }
                } label: {
                    SettingLabel(title: "App language", help: "Overrides the macOS language for LLMTray only. Takes effect after LLMTray restarts. Untranslated text shows in English.")
                }
            }
            Section("Startup") {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                    SettingLabel(title: "Launch at login", help: "Start LLMTray automatically when you log in to this Mac.")
                }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
                Toggle(isOn: $autoStartOnLaunch) {
                    SettingLabel(title: "Start the server when LLMTray opens", help: "Loads the last-used model right away, so it's ready without pressing Play.")
                }
            }
            Section("Chat") {
                Toggle(isOn: $showReasoning) {
                    SettingLabel(title: "Show reasoning", help: "Shows the model's thinking (the collapsible \u{201C}Thought process\u{201D} block) above its answer.")
                }
                Toggle(isOn: $showToolCalls) {
                    SettingLabel(title: "Show tool calls", help: "Debugging: under an answer, which tools the model called and with what arguments; expand one to see what it returned. Only for the current chat -- tool calls aren't saved with it.")
                }
                Picker(selection: $autoStopIdleMinutes) {
                    Text("Never").tag(0)
                    ForEach([5, 15, 30, 60, 120], id: \.self) { m in
                        Text("After \(m) min").tag(m)
                    }
                } label: {
                    SettingLabel(title: "Unload model when idle", help: "Frees the memory a loaded model holds after this long without requests. It reloads automatically on the next request, with the usual loading delay.")
                }
            }
            Section("Compaction") {
                Stepper(value: $compactKeepStart, in: 1...20) {
                    SettingLabel(title: "Keep first messages: \(compactKeepStart)", help: "Compacting replaces the middle of a long chat with one model-written summary. This many messages at the start are kept word for word.")
                }
                Stepper(value: $compactKeepEnd, in: 1...20) {
                    SettingLabel(title: "Keep last messages: \(compactKeepEnd)", help: "This many of the most recent messages are kept word for word when compacting.")
                }
                Picker(selection: $autoCompactThreshold) {
                    Text("Off").tag(0)
                    ForEach([20, 40, 60, 100, 150], id: \.self) { n in
                        Text("Past \(n) messages").tag(n)
                    }
                } label: {
                    SettingLabel(title: "Auto-compact", help: "Compacts the chat automatically once it grows past this many messages. The Compact button in the chat works either way.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }
}

// MARK: - Models

struct ModelsPane: View {
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var navigation: SettingsNavigation
    @ObservedObject private var profiles = ProfileManager.shared
    @AppStorage(ModelDiscovery.modelsRootDefaultsKey) private var modelsRoot: String = ModelDiscovery.defaultModelsRoot
    @ObservedObject private var catalog = ModelCatalog.shared
    private var models: [LocalModel] { catalog.models }

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent {
                    HStack {
                        Text(modelsRoot).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                } label: {
                    SettingLabel(title: "Models folder", help: "Where LLMTray looks for MLX models (one folder per model, e.g. <org>/<name>). Point it at ~/.lmstudio/models to share models with LM Studio.")
                }
                LabeledContent {
                    Text(diskUsageText).monospacedDigit().foregroundStyle(.secondary)
                } label: {
                    SettingLabel(title: "Disk usage", help: "Space the models in this folder take, and what's still free on its disk.")
                }
                HStack {
                    Button("Use LM Studio's folder") { modelsRoot = NSString(string: "~/.lmstudio/models").expandingTildeInPath }
                    Button("Rescan", action: rescan)
                    Spacer()
                    Button("Browse Hugging Face…") { NotificationCenter.default.post(name: .showHFBrowser, object: nil) }
                }
            }
            Section {
                if models.isEmpty {
                    Text("No models found in this folder.").foregroundStyle(.secondary)
                }
                ForEach(models) { m in
                    modelRow(m)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Models")
                    SettingHelp(text: "Alias: the \u{201C}model\u{201D} name other tools send to LLMTray's API to get this model. Profile: which settings profile this model uses.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: rescan)
    }

    private func modelRow(_ m: LocalModel) -> some View {
        let taken = catalog.isAliasTaken(catalog.alias(for: m.id), excluding: m.id)
        return LabeledContent {
            HStack {
                TextField("alias", text: Binding(
                    get: { catalog.alias(for: m.id) },
                    set: { catalog.setAlias($0, for: m.id) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .foregroundStyle(taken ? .red : .primary)
                .help(Text(taken ? "Another model already uses this alias." : "The model name API clients send."))
                Picker("", selection: Binding(
                    get: { profiles.profileID(for: m.id) },
                    set: { profiles.assign(profileID: $0, to: m.id) }
                )) {
                    ForEach(profiles.profiles) { p in Text(p.name).tag(p.id) }
                }
                .labelsHidden()
                .frame(width: 140)
                // Auto-tune writes into the loaded model's profile and
                // restarts it between measurements.
                .disabled(!OperationAvailability(server: server, chat: chat, benchmark: benchmark)
                    .canAssignProfile(toLoadedModel: server.loadedModelPath == m.id))
            }
        } label: {
            VStack(alignment: .leading) {
                Text(m.displayName).lineLimit(1)
                if let size = catalog.sizes[m.id] {
                    Text(ModelCatalog.format(size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if server.loadedModelPath == m.id, case .running = server.state {
                    Text("Running").font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    private var diskUsageText: String {
        let used = catalog.sizes.isEmpty && !catalog.models.isEmpty ? "…" : ModelCatalog.format(catalog.totalBytes)
        let free = catalog.freeBytes.map(ModelCatalog.format) ?? "…"
        return String(format: NSLocalizedString("Models: %@ · free: %@", comment: "disk usage: models size, free space"), used, free)
    }

    private func rescan() {
        catalog.rescan()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: modelsRoot)
        panel.prompt = NSLocalizedString("Use Folder", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelsRoot = url.path
    }
}

// MARK: - Profiles

struct ProfilesPane: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var navigation: SettingsNavigation
    @ObservedObject private var profiles = ProfileManager.shared
    @State private var renaming: String?
    @State private var nameDraft = ""
    @State private var onlyOverrides = false
    @State private var imageModelDownloadError: String?

    private var selectedID: String { profiles.profile(id: navigation.profileID) != nil ? navigation.profileID : Profile.defaultID }
    private var selected: Profile { profiles.profile(id: selectedID) ?? profiles.defaultProfile }
    private var isDefault: Bool { selected.isDefault }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                editor
                RestartBanner().padding(8)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selectedID }, set: { navigation.profileID = $0 ?? Profile.defaultID })) {
                ForEach(profiles.profiles) { p in
                    HStack {
                        if renaming == p.id {
                            TextField("", text: $nameDraft, onCommit: {
                                profiles.rename(id: p.id, to: nameDraft)
                                renaming = nil
                            })
                        } else {
                            Text(p.name)
                        }
                        Spacer()
                        if !p.isDefault {
                            Text("\(p.overrideCount)").font(.caption).foregroundStyle(.secondary)
                                .help(Text("Settings this profile overrides; everything else comes from Default."))
                        }
                    }
                    .tag(p.id)
                    .contextMenu {
                        if !p.isDefault {
                            Button("Rename") { startRenaming(p) }
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button { navigation.profileID = profiles.create(name: NSLocalizedString("New profile", comment: "")).id } label: {
                    Image(systemName: "plus")
                }
                .help(Text("New profile (inherits everything from Default)"))
                Button { deleteSelected() } label: { Image(systemName: "minus") }
                    .disabled(isDefault || busy)
                    .help(Text("Delete this profile (models using it go back to Default)"))
                Button {
                    navigation.profileID = profiles.create(name: selected.name + " " + NSLocalizedString("copy", comment: "suffix of a duplicated profile's name"), copying: selected).id
                } label: { Image(systemName: "plus.square.on.square") }
                    .help(Text("Duplicate this profile"))
                Button { startRenaming(selected) } label: { Image(systemName: "pencil") }
                    .disabled(isDefault)
                    .help(Text("Rename this profile"))
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: RuntimePaths.externalRuntimeDir).appendingPathComponent("profiles"))
                } label: { Image(systemName: "folder") }
                    .help(Text("Show the profile files in Finder -- plain JSON, editable by hand, copyable to another Mac"))
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private var ops: OperationAvailability { OperationAvailability(server: server, chat: chat, benchmark: benchmark) }
    private var busy: Bool { !ops.canDeleteProfile }

    private func startRenaming(_ p: Profile) {
        guard !p.isDefault else { return }
        nameDraft = p.name
        renaming = p.id
    }

    private func deleteSelected() {
        let p = selected
        guard !p.isDefault else { return }
        let affected = profiles.models(assignedTo: p.id).map { ($0 as NSString).lastPathComponent }
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Delete profile \u{201C}%@\u{201D}?", comment: ""), p.name)
        alert.informativeText = affected.isEmpty
            ? NSLocalizedString("No model uses it.", comment: "")
            : String(format: NSLocalizedString("These models go back to Default: %@.", comment: ""), affected.joined(separator: ", "))
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profiles.delete(id: p.id)
        navigation.profileID = Profile.defaultID
    }

    // MARK: Editor

    private var editor: some View {
        Form {
            if !profiles.loadErrors.isEmpty {
                Section {
                    ForEach(profiles.loadErrors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Button("Show the profile files in Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: RuntimePaths.externalRuntimeDir).appendingPathComponent("profiles"))
                    }
                }
            }
            if !profiles.isEditable(id: selectedID) {
                Text("This profile's file can't be read, so it can't be edited here. Fix or delete the file, then reopen Settings.")
                    .foregroundStyle(.secondary)
            } else if benchmark.isRunning {
                Text("Auto-tune is running and writes into the loaded model's profile -- editing is paused until it finishes.")
                    .foregroundStyle(.secondary)
            }
            editorSections
                .disabled(!profiles.isEditable(id: selectedID) || !ops.canEditProfiles)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var editorSections: some View {
            Section {
                LabeledContent {
                    Toggle("Show only overrides", isOn: $onlyOverrides).disabled(isDefault)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.name).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Sampling") {
                row(\.request.temperature, "Temperature", "Randomness. Lower is more focused and repeatable, higher more varied. Coding: 0.2-0.6; chat: 0.7-1.0.") {
                    SliderValue(value: b(\.request.temperature), range: 0...2, step: 0.05, format: "%.2f")
                }
                row(\.request.topP, "Top-p", "Samples only from the most likely tokens whose probabilities add up to this. 1.0 turns it off.") {
                    SliderValue(value: b(\.request.topP), range: 0...1, step: 0.01, format: "%.2f")
                }
                row(\.request.topK, "Top-k", "Samples only from this many most likely tokens. 0 turns it off. Gemma 4 recommends 64.") {
                    Stepper(value: b(\.request.topK), in: 0...200, step: 8) {
                        Text(profiles.value(\.request.topK, profileID: selectedID) == 0 ? "Off" : "\(profiles.value(\.request.topK, profileID: selectedID))")
                    }
                }
                row(\.request.maxTokens, "Max tokens", "The longest answer the model may write. Also capped by the model's own context length.") {
                    TextField("", value: Binding(
                        get: { profiles.value(\.request.maxTokens, profileID: selectedID) },
                        set: { profiles.set(\.request.maxTokens, max(1, $0), profileID: selectedID) }
                    ), format: .number).frame(width: 90)
                }
            }
            Section("Prompt & tools") {
                row(\.request.systemPrompt, "System prompt", "Sent first in every in-app chat request. Default comes with a short starting prompt -- extend it or replace it. Not applied to external API clients.") {
                    TextEditor(text: b(\.request.systemPrompt)).frame(minHeight: 70)
                }
                row(\.tools.enabledTools, "Chat tools", "Tools the model may call in the in-app chat (needs a tool-calling model). Web tools send the model's query to that public service (DuckDuckGo, Google News, Wikipedia/Wikidata, Hacker News, date.nager.at, open.er-api.com, Open-Meteo); local ones never leave the Mac.") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ToolCatalog.entries) { tool in
                            Toggle(isOn: toolBinding(tool.name)) {
                                HStack(spacing: 4) {
                                    Text(tool.title)
                                    if tool.usesNetwork {
                                        Image(systemName: "globe").foregroundStyle(.secondary).imageScale(.small)
                                            .help(Text("Uses the internet"))
                                    }
                                    if let credit = tool.credit {
                                        Text(verbatim: credit).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                row(\.tools.toolUsePolicy, "Tool-use rule", "Added to the system prompt whenever tools are offered. The model's own tool template only says how to call a tool, never when not to. Empty disables it.") {
                    TextEditor(text: b(\.tools.toolUsePolicy)).frame(minHeight: 50)
                }
            }
            Section("Image generation") {
                row(\.tools.enableImageGeneration, "Enable image generation", "Gives the model a generate_image tool (needs a tool-calling model). The first time, the image model is downloaded.") {
                    Toggle("", isOn: enableImageGenerationBinding).labelsHidden().disabled(chat.isDownloadingModel)
                }
                row(\.tools.imageGenModel, "Image model", "Which Z-Image-Turbo quantization generates the images.") {
                    Picker("", selection: imageGenModelBinding) {
                        ForEach(ImageGenModel.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().disabled(chat.isDownloadingModel)
                }
                row(\.tools.imageQuality, "Canvas size", "Scales whatever width/height the model asks for. Balanced keeps 1024x1024 as is.") {
                    Picker("", selection: imageQualityBinding) {
                        ForEach(ImageQuality.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                row(\.tools.unloadModelDuringImageGen, "Unload chat model during generation", "Stops the chat model while an image generates, and reloads it after. Both at once can exceed this Mac's memory.") {
                    Toggle("", isOn: b(\.tools.unloadModelDuringImageGen)).labelsHidden()
                }
                if chat.isDownloadingModel {
                    HStack { ProgressView().controlSize(.small); Text(chat.mfluxStatusText).font(.caption).foregroundStyle(.secondary) }
                }
                if let imageModelDownloadError {
                    Text(imageModelDownloadError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Performance") {
                row(\.launch.kvBits, "KV cache", "Precision of the attention cache. 8-bit: nearly lossless, half the memory. 4-bit: a quarter, noticeably worse on long context. Full: best, most memory.") {
                    Picker("", selection: b(\.launch.kvBits)) {
                        ForEach(KVSettings.bitsChoices, id: \.self) { Text($0 == 0 ? "Full" : "\($0)-bit").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                row(\.launch.kvGroupSize, "KV group size", "Quantization group size for the KV cache. 64 is a good default.") {
                    Picker("", selection: b(\.launch.kvGroupSize)) {
                        ForEach(KVSettings.groupSizeChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
                row(\.launch.quantizedKVStart, "Quantize KV from token", "Keeps the first N tokens of context at full precision before quantizing. Higher trades memory savings for accuracy on long prompts.") {
                    TextField("", value: b(\.launch.quantizedKVStart), format: .number).frame(width: 90)
                }
                row(\.launch.prefillStepSize, "Prefill step", "How many prompt tokens are processed per step. Bigger is faster on long prompts but uses more memory. The benchmark's auto-tune can pick it.") {
                    Picker("", selection: b(\.launch.prefillStepSize)) {
                        ForEach([64, 128, 256, 512, 1024, 2048], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden().frame(width: 90)
                }
                row(\.launch.decodeConcurrency, "Concurrent requests", "How many requests are batched into one GPU step. Only helps when several clients use the server at once; uses more memory.") {
                    Stepper(value: b(\.launch.decodeConcurrency), in: 1...16) {
                        Text("\(profiles.value(\.launch.decodeConcurrency, profileID: selectedID))")
                    }
                }
                row(\.launch.promptCacheMB, "Prompt cache", "Memory kept for reusing earlier conversations' context, so a continued chat doesn't re-read its whole history. Capped so it can't grow until the server runs out of memory.") {
                    Stepper(value: b(\.launch.promptCacheMB), in: 128...8192, step: 128) {
                        Text("\(profiles.value(\.launch.promptCacheMB, profileID: selectedID)) MB")
                    }
                }
                row(\.launch.mtpDrafter, "Speculative decoding (MTP)", "For models with a published drafter (Gemma 4 26B): a small extra model guesses tokens ahead and the main model checks them in one pass. Same output, faster. Requests are then served one at a time.") {
                    Toggle("", isOn: b(\.launch.mtpDrafter)).labelsHidden()
                }
            }
            Section("Advanced") {
                row(\.launch.extraServerArgs, "Extra server arguments", "Any other mlx_lm.server flags, space-separated, e.g. --draft-model <path>.") {
                    TextField("", text: b(\.launch.extraServerArgs)).font(.system(.body, design: .monospaced))
                }
            }
    }

    private var subtitle: String {
        let users = profiles.models(assignedTo: selectedID).map { ($0 as NSString).lastPathComponent }
        if isDefault {
            return NSLocalizedString("The base profile: every other profile inherits from it.", comment: "")
        }
        let used = users.isEmpty ? NSLocalizedString("not used by any model", comment: "")
            : String(format: NSLocalizedString("used by %@", comment: ""), users.joined(separator: ", "))
        return String(format: NSLocalizedString("%d overridden, rest from Default · %@", comment: ""), selected.overrideCount, used)
    }

    /// One editable profile field: label + "?" help, a blue dot and a reset
    /// button when this (non-Default) profile overrides it.
    @ViewBuilder
    private func row<T, Content: View>(
        _ keyPath: WritableKeyPath<Profile, T?>, _ title: LocalizedStringKey, _ help: LocalizedStringKey,
        @ViewBuilder control: () -> Content
    ) -> some View {
        let overridden = !isDefault && profiles.source(keyPath, profileID: selectedID) == .overlay
        if !(onlyOverrides && !isDefault && !overridden) {
            LabeledContent {
                HStack {
                    control()
                    if overridden {
                        Button { profiles.reset(keyPath, profileID: selectedID) } label: {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Reset: inherit this setting from Default"))
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(overridden ? Color.accentColor : .clear).frame(width: 6, height: 6)
                    Text(title).fontWeight(overridden ? .semibold : .regular)
                        .foregroundStyle(isDefault || overridden ? .primary : .secondary)
                    SettingHelp(text: help)
                }
            }
        }
    }

    private func b<T>(_ keyPath: WritableKeyPath<Profile, T?>) -> Binding<T> {
        let id = selectedID
        return Binding(
            get: { profiles.value(keyPath, profileID: id) },
            set: { profiles.set(keyPath, $0, profileID: id) }
        )
    }

    private func toolBinding(_ name: String) -> Binding<Bool> {
        let id = selectedID
        return Binding(
            get: { profiles.value(\.tools.enabledTools, profileID: id).contains(name) },
            set: { on in
                var tools = profiles.value(\.tools.enabledTools, profileID: id).filter { $0 != name }
                if on { tools.append(name) }
                profiles.set(\.tools.enabledTools, tools, profileID: id)
            }
        )
    }

    private var imageGenModel: ImageGenModel {
        ImageGenModel(rawValue: profiles.value(\.tools.imageGenModel, profileID: selectedID)) ?? .gptqMixed
    }

    private var imageGenModelBinding: Binding<ImageGenModel> {
        Binding(
            get: { imageGenModel },
            set: { newModel in
                guard newModel != imageGenModel else { return }
                profiles.set(\.tools.imageGenModel, newModel.rawValue, profileID: selectedID)
                // Switching models while generation is on goes through the
                // same confirm-and-download step as enabling, instead of
                // leaving the first generate_image call to stall on a
                // multi-GB download.
                if profiles.value(\.tools.enableImageGeneration, profileID: selectedID) {
                    profiles.set(\.tools.enableImageGeneration, false, profileID: selectedID)
                    confirmAndDownloadImageModel()
                }
            }
        )
    }

    private var imageQualityBinding: Binding<ImageQuality> {
        Binding(
            get: { ImageQuality(rawValue: profiles.value(\.tools.imageQuality, profileID: selectedID)) ?? .balanced },
            set: { profiles.set(\.tools.imageQuality, $0.rawValue, profileID: selectedID) }
        )
    }

    private var enableImageGenerationBinding: Binding<Bool> {
        Binding(
            get: { profiles.value(\.tools.enableImageGeneration, profileID: selectedID) },
            set: { on in
                if on { confirmAndDownloadImageModel() } else { profiles.set(\.tools.enableImageGeneration, false, profileID: selectedID) }
            }
        )
    }

    /// Downloads the image model (if not cached yet) before enabling -- tens
    /// of GB, better with visible progress now than a stalled chat later.
    private func confirmAndDownloadImageModel() {
        guard !chat.isDownloadingModel else { return }
        let model = imageGenModel
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Enable image generation?", comment: "")
        alert.informativeText = String(format: NSLocalizedString("The first time, this downloads %@ (%@) to this Mac, now rather than in the middle of a chat.", comment: ""), model.displayName, model.approximateDownloadDescription)
        alert.addButton(withTitle: NSLocalizedString("Download and Enable", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        imageModelDownloadError = nil
        let id = selectedID
        Task {
            if let error = await chat.downloadImageModel(model) {
                imageModelDownloadError = error.localizedDescription
            } else {
                profiles.set(\.tools.enableImageGeneration, true, profileID: id)
            }
        }
    }
}

/// Slider with its value shown next to it.
struct SliderValue: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        HStack {
            Slider(value: $value, in: range, step: step).frame(width: 180)
            Text(String(format: format, value)).monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Server

struct ServerPane: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var benchmark: BenchmarkRunner
    @AppStorage(Pref.port) private var port
    @AppStorage(Pref.allowLAN) private var allowLAN
    @AppStorage(Pref.stallThresholdSeconds) private var stallThresholdSeconds
    @AppStorage(Pref.autoRestartStallThreshold) private var autoRestartStallThreshold
    @AppStorage(Pref.verboseServerLogging) private var verboseLogging

    /// Idle-unloaded counts as running: the listener still holds the port.
    private var isStopped: Bool {
        OperationAvailability(server: server, chat: chat, benchmark: benchmark).canEditNetworkSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Network") {
                    LabeledContent {
                        TextField("", value: $port, format: .number.grouping(.never)).frame(width: 80).disabled(!isStopped)
                    } label: {
                        SettingLabel(title: "Port", help: "The OpenAI-compatible API listens here (http://localhost:<port>/v1). Change it while the server is stopped.")
                    }
                    Toggle(isOn: $allowLAN) {
                        SettingLabel(title: "Allow connections from the local network", help: "Off: only this Mac can reach the server. On: other devices on your network can too -- anyone on it, so only on networks you trust.")
                    }
                    .disabled(!isStopped)
                }
                Section("Recovery") {
                    Stepper(value: $stallThresholdSeconds, in: 10...300, step: 10) {
                        SettingLabel(title: "Stall timeout: \(stallThresholdSeconds) s", help: "A request that produces nothing for this long counts as stalled. That happens when a server worker dies (e.g. out of GPU memory) while the process stays up.")
                    }
                    Stepper(value: $autoRestartStallThreshold, in: 0...10) {
                        SettingLabel(title: autoRestartStallThreshold == 0 ? "Auto-restart: off" : "Auto-restart after \(autoRestartStallThreshold) stalls", help: "Restarts the model process after this many stalled requests in a row, instead of leaving it wedged, and when its generation thread dies (e.g. out of GPU memory; at most 3 times in 10 minutes). 0 turns it off.")
                    }
                }
                Section("Diagnostics") {
                    Toggle(isOn: $verboseLogging) {
                        SettingLabel(title: "Verbose server logging", help: "Logs every generated token (DEBUG). Only for troubleshooting the model process -- it slows things down. Takes effect on the next server start.")
                    }
                    LabeledContent {
                        Button("Open Server Log…") { NotificationCenter.default.post(name: .showServerLog, object: nil) }
                    } label: {
                        SettingLabel(title: "Server log", help: "Live output of the model process: loading, errors, requests.")
                    }
                }
            }
            .formStyle(.grouped)
            RestartBanner().padding(8)
        }
    }
}

// MARK: - Benchmark

struct BenchmarkPane: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var benchmark: BenchmarkRunner
    @ObservedObject private var profiles = ProfileManager.shared
    @AppStorage(Pref.port) private var port

    private var alias: String {
        guard let path = server.loadedModelPath else { return "default" }
        return ModelCatalog.shared.requestName(for: path)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let path = server.loadedModelPath {
                    HStack(spacing: 4) {
                        Text("Target: \((path as NSString).lastPathComponent) · profile \(profiles.profile(for: path).name)")
                            .font(.headline)
                        SettingHelp(text: "Benchmarks run against the model that's loaded now. Auto-tune writes its results into that model's profile.")
                    }
                }
                BenchmarkView(benchmark: benchmark, port: port, modelAlias: alias)
            }
            .padding(20)
        }
    }
}

// MARK: - Updates

struct UpdatesPane: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var runtime: RuntimeManager
    let checkForAppUpdates: () -> Void
    @AppStorage(Pref.automaticUpdateChecks) private var autoCheck
    @AppStorage(Pref.checkUpdatesAtLaunch) private var checkAtLaunch
    @AppStorage(Pref.betaUpdates) private var beta

    /// Anything that could start the model process mid-update: running,
    /// starting, or idle-unloaded (the next request reloads it).
    private var isRunning: Bool {
        !OperationAvailability(server: server, chat: chat, benchmark: benchmark).canChangeRuntime
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section("LLMTray") {
                LabeledContent("Version", value: version)
                Toggle(isOn: $autoCheck) {
                    SettingLabel(title: "Check for updates automatically", help: "Checks about once a day in the background and offers new versions.")
                }
                Toggle(isOn: $checkAtLaunch) {
                    SettingLabel(title: "Also check when LLMTray starts", help: "A quiet check at every launch. Only shows anything if an update exists.")
                }
                Picker(selection: $beta) {
                    Text("Stable").tag(false)
                    Text("Beta").tag(true)
                } label: {
                    SettingLabel(title: "Update channel", help: "Beta: pre-release builds with features still being tested, and runtime updates from mlx-lm's beta branch. Switching back to Stable doesn't downgrade an installed beta; the next stable release replaces it.")
                }
                HStack {
                    Spacer()
                    Button("Check Now", action: checkForAppUpdates)
                }
            }
            Section("mlx-lm runtime") {
                LabeledContent {
                    Text(runtime.pinnedVersion().map(shortRef) ?? "unknown").font(.system(.body, design: .monospaced))
                } label: {
                    SettingLabel(title: "Installed", help: "The mlx-lm version (a commit of LLMTray's own fork) that runs the models. Updated separately from the app.")
                }
                runtimeStatus
                if isRunning {
                    Text("Stop the server to update the runtime.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Maintenance") {
                LabeledContent {
                    Button("Uninstall Runtime Data…", role: .destructive, action: uninstallRuntime)
                        .disabled(isRunning)
                } label: {
                    SettingLabel(title: "Runtime data", help: "Deletes the downloaded mlx-lm runtime (and the image-generation runtime). It's set up again from scratch on the next server start. Saved chats and profiles are kept.")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var runtimeStatus: some View {
        switch runtime.checkState {
        case .idle:
            HStack { Spacer(); Button("Check for Runtime Updates") { runtime.checkForUpdate() }.disabled(isRunning) }
        case .checking, .updating:
            HStack { Spacer(); ProgressView().controlSize(.small) }
        case .upToDate:
            HStack { Text("Up to date.").foregroundStyle(.secondary); Spacer(); Button("Check Again") { runtime.checkForUpdate() }.disabled(isRunning) }
        case .updateAvailable(let current, let latest):
            HStack {
                Text("\(shortRef(current)) → \(shortRef(latest)) available")
                Spacer()
                Button("Update") { runtime.applyUpdate(to: latest) }.disabled(isRunning)
            }
        case .failed(let message):
            HStack { Text(message).foregroundStyle(.red).lineLimit(2); Spacer(); Button("Retry") { runtime.checkForUpdate() } }
        }
    }

    private func shortRef(_ ref: String) -> String { ref.count > 12 ? String(ref.prefix(7)) : ref }

    private func uninstallRuntime() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Uninstall runtime data?", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Removes the downloaded mlx-lm runtime from %@. It's set up again on the next server start. Saved chats and profiles are kept.", comment: ""), RuntimePaths.externalRuntimeDir)
        alert.addButton(withTitle: NSLocalizedString("Uninstall", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        server.removeExternalRuntime()
    }
}

/// Per-app language override via the standard AppleLanguages default
/// (what System Settings > Language & Region > Applications writes too).
/// Read by the system at launch, so a change needs a relaunch.
enum AppLanguage {
    /// Languages shipped in the bundle (Resources/Localization/*.lproj).
    static var available: [String] {
        // Deduplicated: Bundle.localizations reports a language once per
        // .lproj folder and again per CFBundleLocalizations entry.
        Set(Bundle.main.localizations).filter { $0 != "Base" }.sorted { name(of: $0) < name(of: $1) }
    }

    /// "" = follow the system.
    static var current: String {
        guard let langs = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = langs.first else { return "" }
        return available.first { first.hasPrefix($0) } ?? ""
    }

    /// The language's own name: "Русский", "Українська", "Español".
    static func name(of code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized(with: Locale(identifier: code)) ?? code
    }

    static func set(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Restart LLMTray to change the language?", comment: "")
        alert.informativeText = NSLocalizedString("The running model server is stopped and started again.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Restart Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunch()
    }

    /// Starts a fresh instance once this one has exited, then quits.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
