import AppKit
import LLMTrayCore
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
    @AppStorage(Pref.autoTitleChats) private var autoTitleChats
    @AppStorage(Pref.chatWindowShowsModelControls) private var chatWindowShowsModelControls
    // Read from FeatureSetup (SMAppService), not stored: the user can also
    // change it in System Settings > Login Items.
    @State private var launchAtLogin = FeatureSetup.launchAtLogin
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
                LabeledContent {
                    Button("Set Up LLMTray…") { NotificationCenter.default.post(name: .showSetupWizard, object: nil) }
                } label: {
                    SettingLabel(title: "Setup assistant", help: "Goes through the models folder, a chat model, the optional features, the API and updates again, starting from your current settings.")
                }
                #if APP_STORE
                LabeledContent {
                    Button("Import…") { StandaloneImporter.run() }
                } label: {
                    SettingLabel(title: "Import from LLMTray (direct download)", help: "Brings over the chats, projects, profiles, the image, music, voice and embedding models and the settings of the version from ipsupport.us (quit it first). Chats and models here stay; its settings replace these. The models take no extra disk space. Chat models stay in your models folder: choose it in Settings › Models.")
                }
                #endif
            }
            #if !APP_STORE
            // adr/0019: not in the App Store build (the sandbox can't link it).
            CommandLineToolSection()
            #endif
            Section("Chat") {
                Toggle(isOn: $showReasoning) {
                    SettingLabel(title: "Show reasoning", help: "Shows the model's thinking (the collapsible \u{201C}Thought process\u{201D} block) above its answer.")
                }
                Toggle(isOn: $showToolCalls) {
                    SettingLabel(title: "Show tool calls", help: "Debugging: under an answer, which tools the model called and with what arguments; expand one to see what it returned. Only for the current chat -- tool calls aren't saved with it.")
                }
                Toggle(isOn: $chatWindowShowsModelControls) {
                    SettingLabel(title: "Show model controls in the chat window", help: "The model picker, Start/Stop, profile, tools and temperature above the chat in its own window. Off: the window is just the chats and the conversation -- those controls stay in the menu bar.")
                }
                Toggle(isOn: $autoTitleChats) {
                    SettingLabel(title: "Name new chats automatically", help: "After a new chat's first answer, the model gives it a short title for the chats list (one short extra request). Off: the start of the first message. Renaming a chat always works.")
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
            UsageStatisticsSection()
            Section("Support") {
                LabeledContent {
                    Button("Report a Bug…") { NotificationCenter.default.post(name: .showBugReport, object: nil) }
                } label: {
                    SettingLabel(title: "Something went wrong?", help: "Opens an email to the LLMTray team with a report attached: versions, the Mac, the model and server settings, the server log and recent crash reports. Your chats are never included, and you see the whole report first.")
                }
                LabeledContent {
                    Button("Rate LLMTray…") { NotificationCenter.default.post(name: .showReview, object: nil) }
                } label: {
                    SettingLabel(title: "Like LLMTray?", help: "A rating and a few words, sent to ipsupport.us: no account, no device identifiers. Reviews appear on the LLMTray website after moderation.")
                }
                LabeledContent {
                    Button("Support LLMTray…") { NotificationCenter.default.post(name: .showSupport, object: nil) }
                } label: {
                    SettingLabel(title: "Support development", help: "An optional tip: no subscriptions, no feature locks. Supporters can choose to be listed by a name they type.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = FeatureSetup.launchAtLogin }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try FeatureSetup.setLaunchAtLogin(enabled)
            launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }
}

/// "Share anonymous usage statistics" (adr/0015): on for a new install, the
/// consent text, exactly what a report holds, and the install ID's reset.
struct UsageStatisticsSection: View {
    @ObservedObject private var telemetry = UsageTelemetry.shared
    @State private var showsFields = false
    /// This Mac's values, read once (a sysctl, not in every body).
    @State private var environment: TelemetryEnvironment?

    var body: some View {
        Section("Usage statistics") {
            Toggle(isOn: Binding(get: { telemetry.isEnabled }, set: { telemetry.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share anonymous usage statistics")
                    Text("Help improve LLMTray?").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("Send an anonymous daily report: app and macOS version, chip, memory size, language, which features you used and the families of the models (never their names). No prompts, content, files or model names ever leave your Mac. You can turn this off at any time in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            DisclosureGroup(isExpanded: $showsFields) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("At most one report a day, covering one past day, to ipsupport.us. A day not sent yet goes on the next launch, up to 7 days back. Turning this off deletes what wasn't sent.")
                        .fixedSize(horizontal: false, vertical: true)
                    field("product", Text("The app's name."), value: TelemetryReport.product)
                    field("install_id", Text("A random ID made on this Mac, new each time this is turned on. Not tied to you or the Mac."),
                          value: telemetry.installID?.uuidString.lowercased())
                    field("day", Text("The day the counts are for."))
                    field("app_version", Text("LLMTray's version."), value: environment?.appVersion)
                    field("os_version", Text("The macOS version."), value: environment?.osVersion)
                    field("chip", Text("The Mac's chip."), value: environment?.chip)
                    field("memory_gb", Text("Its memory, in GB."), value: environment.map { String($0.memoryGB) })
                    field("locale", Text("The app's language (the language only, not the region)."), value: environment?.locale)
                    field("features", Text("How many times you used each of: chat, tool calls, the API server (other apps), image generation, image editing, music, model downloads."))
                    field("model_families", Text("The families of the models used that day (such as qwen or flux), never their names."))
                    Text("The server adds the approximate country from the connection. Never sent: prompts, chat content, generated images or audio, file names or paths, model names or repositories, API keys, account or contact details. Temporary chats count nothing.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            } label: {
                Text("What's sent")
            }
            LabeledContent {
                Button("Show Reports…") { TelemetryReportWindow.show() }
            } label: {
                SettingLabel(title: "The reports", help: "The exact JSON LLMTray sends: the reports waiting to go, today's so far, and the last one sent.")
            }
            if telemetry.isEnabled {
                LabeledContent {
                    Button("Reset ID") { telemetry.resetID() }
                } label: {
                    SettingLabel(title: "Install ID", help: "Makes a new random ID: later reports can't be matched to earlier ones.")
                }
            }
        }
        .task { if environment == nil { environment = TelemetryEnvironment.current() } }
    }

    private func field(_ name: String, _ meaning: Text, value: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(verbatim: name).font(.caption.monospaced()).foregroundStyle(.primary)
                if let value, !value.isEmpty {
                    Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            meaning.fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Models

struct ModelsPane: View {
    // A turn in any chat tab holds these back, not just the one on screen.
    @ObservedObject private var chatTabs = ChatTabs.shared
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var navigation: SettingsNavigation
    @ObservedObject private var profiles = ProfileManager.shared
    @AppStorage(ModelDiscovery.modelsRootDefaultsKey) private var modelsRoot: String = ModelDiscovery.defaultModelsRoot
    @ObservedObject private var catalog = ModelCatalog.shared
    private var models: [LocalModel] { catalog.models }
    /// What's typed; a saved token lives in the Keychain only (HFToken).
    @State private var hfToken = ""
    @State private var hfTokenSaved = HFToken.value != nil

    @State private var hfTokenError: String?
    /// The model the Delete confirmation is for, and why the last removal failed.
    @State private var toRemove: LocalModel?
    @State private var mediaToRemove: MediaModels.Entry?
    @State private var removeError: String?
    @ObservedObject private var switchPrompter = ModelSwitchPrompter.shared

    private func saveToken() {
        let token = hfToken.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        guard HFToken.set(token) else {
            // Kept in the field, so it isn't lost.
            hfTokenError = NSLocalizedString("The Keychain refused to save the token.", comment: "")
            return
        }
        hfTokenError = nil
        hfTokenSaved = HFToken.value != nil
        hfToken = ""
    }

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent {
                    HStack {
                        Text(modelsRoot).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                } label: {
                    #if APP_STORE
                    // No other app named in the App Store build (adr/0018 §5).
                    SettingLabel(title: "Models folder", help: "Where LLMTray looks for MLX models (one folder per model, e.g. <org>/<name>). Choose any folder, one shared with another app too.")
                    #else
                    SettingLabel(title: "Models folder", help: "Where LLMTray looks for MLX models (one folder per model, e.g. <org>/<name>). Point it at ~/.lmstudio/models to share models with LM Studio.")
                    #endif
                }
                LabeledContent {
                    Text(diskUsageText).monospacedDigit().foregroundStyle(.secondary)
                } label: {
                    SettingLabel(title: "Disk usage", help: "Space the models in this folder take, and what's still free on its disk.")
                }
                LabeledContent {
                    HStack {
                        if hfTokenSaved {
                            Text("Saved in your Keychain").foregroundStyle(.secondary)
                            Button("Remove") {
                                hfTokenError = HFToken.set(nil) ? nil : NSLocalizedString("The Keychain refused to remove the token.", comment: "")
                                hfTokenSaved = HFToken.value != nil
                            }
                        } else {
                            SecureField("hf_…", text: $hfToken)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .onSubmit(saveToken)
                            Button("Save", action: saveToken)
                                .disabled(hfToken.trimmingCharacters(in: .whitespaces).isEmpty)
                            Link(destination: URL(string: "https://huggingface.co/settings/tokens")!) { Text("Get one") }
                        }
                        if let hfTokenError {
                            Text(hfTokenError).font(.caption).foregroundStyle(.red)
                        }
                    }
                } label: {
                    SettingLabel(title: "Hugging Face token", help: "Only for gated models (Llama, some Gemma and FLUX repos): accept the model's license on its Hugging Face page, then paste a read token here. Kept in your Keychain, sent only to huggingface.co.")
                }
                HStack {
                    #if !APP_STORE
                    // A toggle: one click back from LM Studio's folder to ours.
                    if FeatureSetup.shared.isUsingLMStudioFolder {
                        Button("Use Default Folder") { FeatureSetup.shared.useDefaultFolder() }
                            .help(Text(verbatim: ModelDiscovery.defaultModelsRoot))
                    } else {
                        Button("Use LM Studio's folder") { FeatureSetup.shared.useLMStudioFolder() }
                    }
                    #endif
                    Button("Rescan", action: rescan)
                    Spacer()
                    Button("Browse Hugging Face…") { NotificationCenter.default.post(name: .showHFBrowser, object: nil) }
                }
            }
            Section {
                if models.isEmpty {
                    Text("No models found in this folder.").foregroundStyle(.secondary)
                }
                if let removeError {
                    Text(removeError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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
            let media = MediaModels.all.filter(MediaModels.isInstalled)
            if !media.isEmpty {
                Section {
                    ForEach(media) { mediaRow($0) }
                } header: {
                    HStack(spacing: 4) {
                        Text("Image, music and voice models")
                        SettingHelp(text: "Used by image generation, music and Voice Lab, which download them. They're kept in the models folder too, under their Hugging Face names.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: rescan)
        .confirmationDialog(
            Text("Move this model to the Trash?"), isPresented: Binding(get: { mediaToRemove != nil }, set: { if !$0 { mediaToRemove = nil } }),
            presenting: mediaToRemove
        ) { e in
            Button("Move to Trash", role: .destructive) { removeMedia(e) }
        } message: { e in
            Text(String(format: NSLocalizedString("\u{201C}%@\u{201D} (%@) goes to the Trash, where you can still restore it. %@ needs it: download it again in Settings to use it.",
                                                  comment: "deleting a media model: name, size, its kind"),
                        e.name, catalog.mediaSizes[e.repo].map(ModelCatalog.format) ?? "…", e.kind.title))
        }
        .confirmationDialog(
            Text("Move this model to the Trash?"), isPresented: Binding(get: { toRemove != nil }, set: { if !$0 { toRemove = nil } }),
            presenting: toRemove
        ) { m in
            Button("Move to Trash", role: .destructive) { remove(m) }
        } message: { m in
            Text(removeMessage(m))
        }
    }

    private func removeMessage(_ m: LocalModel) -> String {
        let size = catalog.sizes[m.id].map(ModelCatalog.format) ?? "…"
        var text = String(format: NSLocalizedString("\u{201C}%@\u{201D} (%@) goes to the Trash, where you can still restore it. Its alias and profile choice are forgotten.",
                                                    comment: "deleting a model: name, size"), m.displayName, size)
        #if !APP_STORE
        // No other app named in the App Store build (adr/0018 §5).
        if modelsRoot.contains("/.lmstudio/") {
            text += " " + NSLocalizedString("This folder is shared with LM Studio: the model is gone there too.", comment: "deleting a model from LM Studio's folder")
        }
        #endif
        return text
    }

    private func remove(_ m: LocalModel) {
        // Again at the confirmation: the server may have started on this
        // model (or a request for it) while the dialog was open.
        guard OperationAvailability(server: server, benchmark: benchmark).canRemoveModel(isLoaded: isInUse(m)) else {
            removeError = String(format: NSLocalizedString("\u{201C}%@\u{201D} wasn't removed: the server is busy or using it. Try again when it's idle.",
                                                           comment: "deleting a model refused at confirmation: name"), m.displayName)
            return
        }
        do {
            try catalog.remove(m)
            removeError = nil
        } catch let refusal as ModelRemoval.Refusal {
            let reason: String
            switch refusal {
            case .downloading: reason = NSLocalizedString("it's being downloaded", comment: "deleting a model refused: reason")
            case .inUse: reason = NSLocalizedString("it's in use or downloading", comment: "deleting a model refused: reason")
            case .notAModel, .outsideModelsFolder: reason = NSLocalizedString("it isn't a model folder in the models folder", comment: "deleting a model refused: reason")
            }
            removeError = String(format: NSLocalizedString("Couldn't move \u{201C}%@\u{201D} to the Trash: %@", comment: "deleting a model failed: name, reason"),
                                 m.displayName, reason)
        } catch {
            removeError = String(format: NSLocalizedString("Couldn't move \u{201C}%@\u{201D} to the Trash: %@", comment: "deleting a model failed: name, reason"),
                                 m.displayName, error.localizedDescription)
        }
    }

    /// The server has it loaded, or a client's switch to it waits for the
    /// user's answer (approved, the proxy would load it).
    private func isInUse(_ m: LocalModel) -> Bool {
        server.loadedModelPath == m.id || switchPrompter.pending?.target == m.id
    }

    private func mediaRow(_ e: MediaModels.Entry) -> some View {
        LabeledContent {
            Button { mediaToRemove = e } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(Text("Move this model to the Trash…"))
                .accessibilityLabel(Text("Delete model"))
        } label: {
            VStack(alignment: .leading) {
                Text(e.name).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(Text(verbatim: MediaModels.path(e)))
                HStack(spacing: 6) {
                    Text(e.kind.title)
                    if let size = catalog.mediaSizes[e.repo] { Text(ModelCatalog.format(size)).monospacedDigit() }
                    if let added = ModelRemoval.addedDate(modelPath: MediaModels.path(e)) {
                        Text(String(format: NSLocalizedString("Added %@", comment: "model list: when the model arrived"),
                                    added.formatted(date: .abbreviated, time: .omitted)))
                    }
                    if MediaModels.isInAppFolder(e) {
                        Text("in LLMTray's own folder").help(Text("Downloaded by an earlier version, on another disk than the models folder: it stays where it is."))
                    } else if MediaModels.isInOldPlace(e) {
                        Text("in an earlier models folder").help(Text(verbatim: MediaModels.path(e)))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func removeMedia(_ e: MediaModels.Entry) {
        do {
            try catalog.removeMedia(e)
            removeError = nil
        } catch let refusal as ModelRemoval.Refusal {
            let reason = refusal == .inUse ? NSLocalizedString("it's in use or downloading", comment: "deleting a model refused: reason")
                : NSLocalizedString("it isn't a model folder in the models folder", comment: "deleting a model refused: reason")
            removeError = String(format: NSLocalizedString("Couldn't move \u{201C}%@\u{201D} to the Trash: %@", comment: "deleting a model failed: name, reason"),
                                 e.name, reason)
        } catch {
            removeError = String(format: NSLocalizedString("Couldn't move \u{201C}%@\u{201D} to the Trash: %@", comment: "deleting a model failed: name, reason"),
                                 e.name, error.localizedDescription)
        }
    }

    /// "Added 3 Sep 2026 · used 2 hours ago" (or "never used").
    private func datesText(_ m: LocalModel) -> String? {
        guard let added = ModelRemoval.addedDate(modelPath: m.path) else { return nil }
        let addedText = String(format: NSLocalizedString("Added %@", comment: "model list: when the model arrived"),
                               added.formatted(date: .abbreviated, time: .omitted))
        let usedText = catalog.lastUsed[m.id].map {
            String(format: NSLocalizedString("used %@", comment: "model list: when the model was last used, e.g. \"2 hours ago\""),
                   $0.formatted(.relative(presentation: .named)))
        } ?? NSLocalizedString("never used", comment: "model list: the model was never loaded")
        return addedText + " · " + usedText
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
                .frame(width: 150)
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
                .disabled(!OperationAvailability(server: server, benchmark: benchmark)
                    .canAssignProfile(toLoadedModel: server.loadedModelPath == m.id))
                let canRemove = OperationAvailability(server: server, benchmark: benchmark)
                    .canRemoveModel(isLoaded: isInUse(m))
                Button { toRemove = m } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(!canRemove)
                    .help(Text(canRemove ? "Move this model to the Trash…" : "The server is using this model or busy with a request: stop it (or pick another model), or wait until it's idle."))
                    .accessibilityLabel(Text("Delete model"))
            }
        } label: {
            VStack(alignment: .leading) {
                // The whole name, on two lines when it's long.
                Text(m.displayName).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(Text(verbatim: m.path))
                HStack(spacing: 6) {
                    if let size = catalog.sizes[m.id] {
                        Text(ModelCatalog.format(size)).monospacedDigit()
                    }
                    ForEach(ModelCapabilities.of(m.path), id: \.self) { c in
                        Image(systemName: ModelCapabilities.symbol(c)).help(Text(ModelCapabilities.name(c)))
                            .accessibilityLabel(Text(ModelCapabilities.name(c)))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let dates = datesText(m) {
                    Text(dates).font(.caption).foregroundStyle(.secondary)
                }
                if server.loadedModelPath == m.id, case .running = server.state {
                    Text("Running").font(.caption).foregroundStyle(.green)
                }
                if let fit = catalog.fit(for: m.id) {
                    GPUFitNotice(fit: fit, compact: true)
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
        // ~/.llmtray, ~/.lmstudio: model folders are often hidden ones.
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: modelsRoot)
        panel.prompt = NSLocalizedString("Use Folder", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SandboxAccess.remember(url)
        FeatureSetup.shared.setModelsFolder(url.path)
    }
}

/// Project files (adr/0012), in Settings > Files: the feature's opt-in and
/// its embedding model, with its size, and the disk every project's files
/// and index take. Off, nothing is indexed, downloaded or started. Each
/// project's files are in its Files window (the project's menu in the chats
/// sidebar), which can turn the feature on too.
@MainActor
struct ProjectFilesSection: View {
    @ObservedObject private var indexer = ProjectIndexer.shared
    @ObservedObject private var embedders = ProjectIndexer.shared.embedders
    @State private var error: String?
    @State private var diskTotal: Int64?
    @AppStorage(Pref.pinnedFilesPercent) private var pinnedPercent
    private var setup: FeatureSetup { .shared }

    /// Re-measured when a project's documents change: added, removed,
    /// re-indexed, embedded (the vectors are most of an index), and when a
    /// project's indexing moves on or ends (its last slices, the checkpoint).
    private var diskKey: String {
        let docs = indexer.documents.map { project, docs in
            "\(project):\(docs.count):\(docs.map(\.rev).reduce(0, +)):\(docs.filter { $0.status == .embedded }.count)"
        }
        let runs = indexer.progress.map { "\($0.key)=\($0.value.state.rawValue):\($0.value.done):\($0.value.total)" }
        return (docs + runs).sorted().joined(separator: ",")
    }

    var body: some View {
        Section("Project files") {
            Toggle(isOn: Binding(get: { indexer.isEnabled }, set: { setEnabled($0) })) {
                SettingLabel(title: "Project files", help: "Files added to a project are indexed on this Mac, so its chats can search them. Search by meaning uses an embedding model; without it, files are searched by their words.")
            }
            LabeledContent {
                HStack {
                    Text(embedderStatus).foregroundStyle(.secondary).lineLimit(1)
                    if embedders.isBusy {
                        ProgressView().controlSize(.small)
                    } else if setup.isProjectFilesEmbedderDownloaded {
                        Button("Remove", action: remove)
                    } else if indexer.isEnabled, setup.projectFilesEmbedder != nil {
                        Button("Download", action: download)
                    }
                }
            } label: {
                SettingLabel(title: "Embedding model", help: "Turns file text into vectors for search by meaning, on this Mac. Removing it keeps the indexes: files are then searched by their words until it's downloaded again.")
            }
            if let reason = indexer.embeddingUnavailable {
                Text(String(format: NSLocalizedString("Search by meaning is off for now: %@", comment: ""), reason))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if indexer.isEnabled {
                LabeledContent {
                    HStack {
                        Slider(value: Binding(get: { Double(pinnedPercent) }, set: { pinnedPercent = Int($0.rounded()) }),
                               in: 10...90, step: 10)
                            .frame(maxWidth: 200)
                        Text(verbatim: "\(pinnedPercent)%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    SettingLabel(title: "Pinned files may take", help: "Of the model's context, and of the memory its weights leave for the context, what a project's pinned files may take together. The answer's max tokens stay free whatever this says. More leaves less room for the conversation, and a long first answer while the files are read in.")
                }
            }
            if let diskTotal, diskTotal > 0 {
                LabeledContent {
                    Text(ModelCatalog.format(diskTotal)).foregroundStyle(.secondary)
                } label: {
                    SettingLabel(title: "Projects' files on disk", help: "The copies of the files added to projects, and their indexes, together. A project's own are shown in its Files window; deleting a project deletes them.")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: diskKey) {
            // Debounced: the documents change after every indexing step,
            // so a run is measured once it pauses or ends.
            if diskTotal != nil { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            guard !Task.isCancelled else { return }
            let total = await ProjectIndexer.totalDiskUsage()
            if !Task.isCancelled { diskTotal = total }
        }
        .task(id: !indexer.progress.isEmpty) {
            // Indexing on: measured every 10 s besides the debounced changes
            // (their task restarts at each step; this one doesn't).
            while !Task.isCancelled, !indexer.progress.isEmpty {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                let total = await ProjectIndexer.totalDiskUsage()
                if !Task.isCancelled { diskTotal = total }
            }
        }
    }

    private var embedderStatus: String {
        if embedders.isBusy, !embedders.statusText.isEmpty { return embedders.statusText }
        guard let entry = setup.projectFilesEmbedder else { return NSLocalizedString("Unavailable", comment: "embedding model status") }
        let size = ModelCatalog.format(FeatureSetup.downloadBytes(entry))
        let state = setup.isProjectFilesEmbedderDownloaded
            ? NSLocalizedString("downloaded", comment: "embedding model status")
            : NSLocalizedString("not downloaded", comment: "embedding model status")
        return "\(entry.displayName) · \(size) · \(state)"
    }

    private func setEnabled(_ on: Bool) {
        error = nil
        guard on else {
            setup.disableProjectFiles()
            return
        }
        Task { error = await Self.turnOn() }
    }

    /// Turns Project files on, asking first whether to download the
    /// embedding model when it isn't here (the Settings switch, a project's
    /// Files window and its menu). Returns what failed, if anything.
    static func turnOn() async -> String? {
        let setup = FeatureSetup.shared
        let embedders = ProjectIndexer.shared.embedders
        guard !setup.isProjectFilesEmbedderReady, let entry = setup.projectFilesEmbedder, !embedders.isBusy else {
            setup.projectFiles.setEnabled(true)
            return nil
        }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Turn on project files?", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Search by meaning uses %@ (%@), downloaded to this Mac now. Without it, files are searched by their words only; you can download it here later.", comment: ""),
                                       entry.displayName, ModelCatalog.format(FeatureSetup.downloadBytes(entry)))
        alert.addButton(withTitle: NSLocalizedString("Download and Enable", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Enable Without It", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return await setup.enableProjectFiles(downloadingEmbedder: true)?.localizedDescription
        case .alertSecondButtonReturn:
            setup.projectFiles.setEnabled(true)
        default:
            break
        }
        return nil
    }

    private func download() {
        error = nil
        Task {
            if let failure = await setup.downloadProjectFilesEmbedder() { error = failure.localizedDescription }
        }
    }

    private func remove() {
        error = nil
        Task {
            if let failure = await setup.removeProjectFilesEmbedder() { error = failure.localizedDescription }
        }
    }
}

// MARK: - Profiles

struct ProfilesPane: View {
    // A turn in any chat tab holds these back, not just the one on screen.
    @ObservedObject private var chatTabs = ChatTabs.shared
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var navigation: SettingsNavigation
    @ObservedObject private var profiles = ProfileManager.shared
    @State private var renaming: String?
    @State private var nameDraft = ""
    @State private var onlyOverrides = false
    @State private var imageModelDownloadError: String?
    @State private var musicDownloadError: String?

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
                        Text(p.name)
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
                    .help(isDefault ? Text("Default can't be renamed: every model falls back to it") : Text("Rename this profile"))
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: RuntimePaths.externalRuntimeDir).appendingPathComponent("profiles"))
                } label: { Image(systemName: "folder") }
                    .help(Text("Show the profile files in Finder -- plain JSON, editable by hand, copyable to another Mac"))
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        // A sheet, not a text field in the list row: in a List with a
        // selection on macOS the row's field doesn't take the keyboard, so
        // renaming did nothing.
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Profile").font(.headline)
                TextField("Name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(commitRename)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Rename", action: commitRename)
                        .keyboardShortcut(.defaultAction)
                        .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
    }

    private func commitRename() {
        guard let id = renaming else { return }
        profiles.rename(id: id, to: nameDraft)
        renaming = nil
    }

    private var ops: OperationAvailability { OperationAvailability(server: server, benchmark: benchmark) }
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
                    Toggle("", isOn: enableImageGenerationBinding).labelsHidden()
                        .disabled(chat.isDownloadingModel || (!setup.isImageGenerationEnabled(profileID: selectedID) && !fits(setup.memoryFit(imageGenModel))))
                }
                row(\.tools.imageGenModel, "Image model", "Which model generates new images.") {
                    Picker("", selection: imageGenModelBinding) {
                        ForEach(ImageGenModel.selectable + (ImageGenModel.selectable.contains(imageGenModel) ? [] : [imageGenModel])) {
                            Text($0.displayName).tag($0).disabled(!fits(setup.memoryFit($0)))
                        }
                    }
                    .labelsHidden().disabled(chat.isDownloadingModel)
                }
                MemoryFitNote(fit: setup.memoryFit(imageGenModel))
                row(\.tools.imageEditModel, "Image editing", "Gives the model an edit_image tool: it changes an image from the chat -- one you attached or one generated here. Needs image generation on. Its own model, downloaded when you choose it.") {
                    Picker("", selection: imageEditModelBinding) {
                        Text("Off").tag(ImageGenModel?.none)
                        ForEach(ImageGenModel.selectable.filter(\.supportsEditing)) {
                            Text($0.displayName).tag(Optional($0)).disabled(!fits(setup.memoryFit(editingWith: $0)))
                        }
                    }
                    .labelsHidden().disabled(chat.isDownloadingModel)
                }
                // Nothing to say about editing that's off.
                MemoryFitNote(fit: setup.imageEditModel(profileID: selectedID).flatMap { setup.memoryFit(editingWith: $0) })
                row(\.tools.imageQuality, "Canvas size", "Scales whatever width/height the model asks for. Balanced keeps 1024x1024 as is.") {
                    Picker("", selection: imageQualityBinding) {
                        ForEach(ImageQuality.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                row(\.tools.unloadModelDuringImageGen, "Unload chat model during generation", "Stops the chat model while an image or music generates, and reloads it after. Both at once can exceed this Mac's memory.") {
                    Toggle("", isOn: b(\.tools.unloadModelDuringImageGen)).labelsHidden()
                }
                if chat.isDownloadingModel, !chat.mfluxStatusText.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text(chat.mfluxStatusText).font(.caption).foregroundStyle(.secondary) }
                }
                if let imageModelDownloadError {
                    Text(imageModelDownloadError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Creator mode") {
                row(\.tools.creatorMode, "Creator mode", "Before an image or song is made, shows what the model asked for -- the prompt, the model, the knobs -- to change first. It goes ahead by itself after the countdown unless you touch it.") {
                    Toggle("", isOn: b(\.tools.creatorMode)).labelsHidden()
                }
                row(\.tools.creatorCountdown, "Countdown", "Seconds before the draft goes ahead as it is. 0: wait until you press Generate.") {
                    Stepper(value: b(\.tools.creatorCountdown), in: 0...30) {
                        Text(verbatim: "\(profiles.value(\.tools.creatorCountdown, profileID: selectedID)) s")
                    }
                    .fixedSize()
                }
            }
            Section("Music generation") {
                row(\.tools.enableMusicGeneration, "Enable music generation", "Gives the model a generate_music tool: a song with sung lyrics, or an instrumental, from a description (ACE-Step 1.5, MIT license; about 20 seconds for 30 seconds of music). The first time, the model is downloaded.") {
                    Toggle("", isOn: enableMusicGenerationBinding).labelsHidden()
                        .disabled(chat.isDownloadingModel || (!setup.isMusicGenerationEnabled(profileID: selectedID) && !fits(setup.memoryFit(musicModel))))
                }
                row(\.tools.musicModel, "Music model", "turbo: a fuller, more finished-sounding mix. sft: sings the lyrics clearly, the voice upfront, about twice as long to make.") {
                    Picker("", selection: musicModelBinding) {
                        ForEach(MusicManager.selectable + (MusicManager.selectable.contains(musicModel) ? [] : [musicModel])) {
                            Text($0.displayName).tag($0).disabled(!fits(setup.memoryFit($0)))
                        }
                    }
                    .labelsHidden().disabled(chat.isDownloadingModel)
                }
                MemoryFitNote(fit: setup.memoryFit(musicModel))
                row(\.tools.musicCreativity, "Creativity", "How adventurous and unexpected the music is. turbo only: sft has no song planner to vary.") {
                    SliderValue(value: b(\.tools.musicCreativity), range: 0...1, step: 0.05, format: "%.2f")
                        .disabled(!musicModel.hasCreativity)
                }
                row(\.tools.musicAdherence, "Follow the description", "How strictly the music follows the style the model described. Higher: closer to it; lower: freer.") {
                    SliderValue(value: b(\.tools.musicAdherence), range: 0...1, step: 0.05, format: "%.2f")
                }
                row(\.tools.musicBitrate, "Audio quality", "How songs are kept, saved and shared. AAC 256 kbit/s: about 1 MB per 30 s, indistinguishable for most listening. Uncompressed WAV: about 6 MB per 30 s.") {
                    Picker("", selection: b(\.tools.musicBitrate)) {
                        ForEach(ResolvedProfile.musicBitrates, id: \.self) { rate in
                            if rate == 0 {
                                Text("Uncompressed (WAV)").tag(rate)
                            } else {
                                Text(String(format: NSLocalizedString("AAC %lld kbit/s", comment: "audio bit rate"), rate)).tag(rate)
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if chat.isDownloadingModel, !chat.musicStatusText.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text(chat.musicStatusText).font(.caption).foregroundStyle(.secondary) }
                }
                if let musicDownloadError {
                    Text(musicDownloadError).font(.caption).foregroundStyle(.red)
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

    private var setup: FeatureSetup { .shared }

    /// Not measured is no gate: only a model known not to fit is held back.
    private func fits(_ fit: FeatureFit?) -> Bool { fit?.isAvailable ?? true }

    private var imageGenModel: ImageGenModel { setup.imageGenModel(profileID: selectedID) }

    private var imageGenModelBinding: Binding<ImageGenModel> {
        Binding(
            get: { imageGenModel },
            set: { newModel in
                guard newModel != imageGenModel, fits(setup.memoryFit(newModel)) else { return }
                setup.setImageGenModel(newModel, profileID: selectedID)
                // Switching models while generation is on goes through the
                // same confirm-and-download step as enabling, instead of
                // leaving the first generate_image call to stall on a
                // multi-GB download.
                if setup.isImageGenerationEnabled(profileID: selectedID) {
                    setup.setImageGenerationEnabled(false, profileID: selectedID)
                    confirmAndEnableImageGeneration()
                }
            }
        )
    }

    private var imageEditModelBinding: Binding<ImageGenModel?> {
        Binding(
            get: { setup.imageEditModel(profileID: selectedID) },
            set: { newModel in
                if let newModel, !fits(setup.memoryFit(editingWith: newModel)) { return }
                // Off, or one already downloaded: set as is.
                guard let newModel, !newModel.isDownloaded else {
                    setup.setImageEditModel(newModel, profileID: selectedID)
                    return
                }
                // Downloaded first, like the generation model: an edit
                // mustn't stall on a multi-GB download mid-chat.
                confirmImageDownload(newModel, title: NSLocalizedString("Enable image editing?", comment: "")) { id in
                    await setup.enableImageEditing(newModel, profileID: id)
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

    private var enableMusicGenerationBinding: Binding<Bool> {
        Binding(
            get: { setup.isMusicGenerationEnabled(profileID: selectedID) },
            set: { on in
                guard on else {
                    setup.setMusicGenerationEnabled(false, profileID: selectedID)
                    return
                }
                let model = musicModel
                guard fits(setup.memoryFit(model)) else { return }
                confirmMusicDownload(model, title: NSLocalizedString("Enable music generation?", comment: ""),
                                     whenReady: { setup.setMusicGenerationEnabled(true, profileID: $0) },
                                     download: { await setup.enableMusicGeneration(model, profileID: $0) })
            }
        )
    }

    private var musicModel: MusicModel { setup.musicModel(profileID: selectedID) }

    /// A model not downloaded yet goes through the same confirmed download
    /// (only when music generation is on: it's downloaded when turned on).
    private var musicModelBinding: Binding<MusicModel> {
        Binding(
            get: { musicModel },
            set: { newModel in
                guard newModel != musicModel, fits(setup.memoryFit(newModel)) else { return }
                guard setup.isMusicGenerationEnabled(profileID: selectedID), !setup.isMusicModelReady(newModel) else {
                    setup.setMusicModel(newModel, profileID: selectedID)
                    return
                }
                confirmMusicDownload(newModel, title: NSLocalizedString("Switch the music model?", comment: ""),
                                     whenReady: { setup.setMusicModel(newModel, profileID: $0) },
                                     download: { await setup.switchMusicModel(to: newModel, profileID: $0) })
            }
        )
    }

    /// `model` ready: `whenReady(profile)` at once. Otherwise, confirmed,
    /// `download(profile)` (FeatureSetup installs mlx-audio, downloads the
    /// model and makes the change), its error shown here.
    private func confirmMusicDownload(_ model: MusicModel, title: String,
                                      whenReady: (String) -> Void,
                                      download: @escaping (String) async -> Error?) {
        let id = selectedID
        if setup.isMusicModelReady(model) {
            whenReady(id)
            return
        }
        guard !setup.isDownloadingModel else { return }
        guard confirmDownload(title: title, model: model.displayName, size: model.approximateDownloadDescription) else { return }
        musicDownloadError = nil
        Task {
            if let error = await download(id) {
                musicDownloadError = error.localizedDescription
            }
        }
    }

    private var enableImageGenerationBinding: Binding<Bool> {
        Binding(
            get: { setup.isImageGenerationEnabled(profileID: selectedID) },
            set: { on in
                if on { confirmAndEnableImageGeneration() } else { setup.setImageGenerationEnabled(false, profileID: selectedID) }
            }
        )
    }

    /// Downloads the image model (if not cached yet) before enabling -- tens
    /// of GB, better with visible progress now than a stalled chat later.
    private func confirmAndEnableImageGeneration() {
        let model = imageGenModel
        guard fits(setup.memoryFit(model)) else { return }
        confirmImageDownload(model, title: NSLocalizedString("Enable image generation?", comment: "")) { id in
            await setup.enableImageGeneration(model, profileID: id)
        }
    }

    /// Confirmed, `download(profile)` -- for the profile the choice was
    /// made for -- its error shown here.
    private func confirmImageDownload(_ model: ImageGenModel, title: String, download: @escaping (String) async -> Error?) {
        guard !setup.isDownloadingModel else { return }
        guard confirmDownload(title: title, model: model.displayName, size: model.approximateDownloadDescription) else { return }
        imageModelDownloadError = nil
        let id = selectedID
        Task {
            if let error = await download(id) {
                imageModelDownloadError = error.localizedDescription
            }
        }
    }

    private func confirmDownload(title: String, model: String, size: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(format: NSLocalizedString("The first time, this downloads %@ (%@) to this Mac, now rather than in the middle of a chat.", comment: ""), model, size)
        alert.addButton(withTitle: NSLocalizedString("Download and Enable", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        return alert.runModal() == .alertFirstButtonReturn
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
    // A turn in any chat tab holds these back, not just the one on screen.
    @ObservedObject private var chatTabs = ChatTabs.shared
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var benchmark: BenchmarkRunner
    @AppStorage(Pref.port) private var port
    @AppStorage(Pref.allowLAN) private var allowLAN
    @AppStorage(Pref.modelSwitchPolicy) private var modelSwitchPolicy
    @AppStorage(Pref.stallThresholdSeconds) private var stallThresholdSeconds
    @AppStorage(Pref.memoryMarginMB) private var memoryMarginMB
    @AppStorage(Pref.promptCacheSharePercent) private var promptCacheSharePercent
    @AppStorage(Pref.prefillSharePercent) private var prefillSharePercent
    @AppStorage(Pref.autoRestartStallThreshold) private var autoRestartStallThreshold
    @AppStorage(Pref.verboseServerLogging) private var verboseLogging

    /// Idle-unloaded counts as running: the listener still holds the port.
    private var isStopped: Bool {
        OperationAvailability(server: server, benchmark: benchmark).canEditNetworkSettings
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
                Section("Model switching") {
                    Picker(selection: $modelSwitchPolicy) {
                        Text("Switch at once").tag(ModelSwitchPolicy.auto.rawValue)
                        Text("Ask first").tag(ModelSwitchPolicy.ask.rawValue)
                        Text("Keep the loaded model").tag(ModelSwitchPolicy.keep.rawValue)
                    } label: {
                        SettingLabel(title: "When a client asks for another model", help: "An editor, an agent or a script asking for a model other than the one loaded. Switching unloads the loaded one -- the chat's too. Ask first: a notification with Switch / Keep; unanswered in a minute counts as Keep. Keep: the client gets an error naming the loaded model. The app's own chat always switches.")
                    }
                    .onChange(of: modelSwitchPolicy) { ModelSwitchPrompter.shared.policyChanged() }
                }
                Section("Memory") {
                    Stepper(value: $memoryMarginMB, in: 512...8192, step: 256) {
                        SettingLabel(title: "Kept free: \(memoryMarginMB) MB", help: "GPU memory the model server leaves alone beside the weights, for activations and macOS. The shares below split what's left after it.")
                    }
                    Stepper(value: $promptCacheSharePercent, in: 0...80, step: 5) {
                        SettingLabel(title: "Prompt cache: up to \(promptCacheSharePercent)% of the rest", help: "The most the cache of earlier prompts may take (the profile's Prompt cache size is also a cap). More makes long chats and agents faster; too much leaves no room for the prompt being read.")
                    }
                    Stepper(value: $prefillSharePercent, in: 5...50, step: 5) {
                        SettingLabel(title: "Reading a prompt: up to \(prefillSharePercent)%", help: "Working memory for reading a prompt in chunks; less reads long prompts in smaller, slower steps. With the prompt cache at most 90% together: the rest holds the prompt being read.")
                    }
                    if promptCacheSharePercent + prefillSharePercent > 90 {
                        Text("Together over 90%: reading a prompt gets \(max(0, 90 - promptCacheSharePercent))%.").font(.caption).foregroundStyle(.orange)
                    }
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
                ToolCallsSection()
            }
            .formStyle(.grouped)
            RestartBanner().padding(8)
        }
    }
}

/// The chat's tool calls in this version (ToolStatsStore): how often each
/// tool was called, how often it worked, what had to be repaired, what
/// failed. Kept on this Mac only.
struct ToolCallsSection: View {
    @ObservedObject private var store = ToolStatsStore.shared

    var body: some View {
        Section {
            let rows = store.current
            if rows.isEmpty {
                Text("No tool calls yet in this version.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Tool").gridColumnAlignment(.leading)
                        Text("Calls")
                        Text("OK")
                        Text("Repaired")
                        Text("Errors")
                        Text("Refused")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(rows, id: \.tool) { row in
                        GridRow {
                            Text(verbatim: row.tool).gridColumnAlignment(.leading)
                            Text(verbatim: "\(row.counts.calls)")
                            Text(verbatim: "\(row.counts.successes)")
                            Text(verbatim: "\(row.counts.repairedCalls)")
                            Text(verbatim: "\(row.counts.errorCount)")
                            Text(verbatim: "\(row.counts.refusals)")
                        }
                        .monospacedDigit()
                        .help(Text(verbatim: ToolCallStats.summary(row.counts)))
                    }
                }
            }
            LabeledContent {
                Button("Reset") { store.reset() }.disabled(rows.isEmpty)
            } label: {
                SettingLabel(title: "Tool call statistics", help: "Counted on this Mac for this version of LLMTray and never sent anywhere; a bug report includes the counts. Hover a row for what was repaired (a model's malformed call the app still understood) and which errors happened.")
            }
        } header: {
            Text("Tool calls")
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
    // A turn in any chat tab holds these back, not just the one on screen.
    @ObservedObject private var chatTabs = ChatTabs.shared
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var runtime: RuntimeManager
    let checkForAppUpdates: () -> Void
    @AppStorage(Pref.automaticUpdateChecks) private var autoCheck
    @AppStorage(Pref.checkUpdatesAtLaunch) private var checkAtLaunch
    @AppStorage(Pref.betaUpdates) private var beta
    @AppStorage(Pref.voiceLabEnabled) private var voiceLab
    @ObservedObject private var audioRuntime = AudioRuntime.shared
    @ObservedObject private var voiceSession = VoiceLabSession.shared
    @ObservedObject private var voiceStore = VoiceModelStore.shared

    /// Anything that could start the model process mid-update: running,
    /// starting, or idle-unloaded (the next request reloads it).
    private var isRunning: Bool {
        !OperationAvailability(server: server, benchmark: benchmark).canChangeRuntime
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section("LLMTray") {
                LabeledContent("Version", value: version)
                #if !APP_STORE
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
                #endif
                HStack {
                    Spacer()
                    Button("Check Now", action: checkForAppUpdates)
                }
            }
            #if !APP_STORE
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
            if voiceLab || audioRuntime.hasVenv {
                Section("mlx-audio runtime") {
                    LabeledContent {
                        Text(shortRef(AudioRuntime.mlxAudioCommit)).font(.system(.body, design: .monospaced))
                    } label: {
                        SettingLabel(title: "Pinned", help: "The mlx-audio version (a commit of LLMTray's own fork) that runs Voice Lab and music generation. Installed at the next voice or music start when it changes; offline, the installed one keeps working.")
                    }
                    audioRuntimeStatus
                    if audioBusy {
                        Text("Stop Voice Lab and music generation to update it.").font(.caption).foregroundStyle(.secondary)
                    }
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
            #endif
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

    /// Something running on the audio venv (or installing into it).
    private var audioBusy: Bool {
        voiceSession.isActive || chatTabs.music.isBusy || audioRuntime.isInstalling || voiceStore.isBusy
    }

    @ViewBuilder
    private var audioRuntimeStatus: some View {
        switch audioRuntime.updateState {
        case .idle:
            HStack {
                Spacer()
                Button("Reinstall") { audioRuntime.reinstall() }.disabled(audioBusy)
                Button("Check for Updates") { audioRuntime.checkForUpdate() }.disabled(audioBusy)
            }
        case .checking, .updating:
            HStack { Spacer(); ProgressView().controlSize(.small) }
        case .upToDate:
            HStack {
                Text(audioRuntime.isInstalled ? "Up to date." : "Up to date; installed at the next voice or music start.").foregroundStyle(.secondary)
                Spacer()
                Button("Reinstall") { audioRuntime.reinstall() }.disabled(audioBusy)
                Button("Check Again") { audioRuntime.checkForUpdate() }.disabled(audioBusy)
            }
        case .updateAvailable(let current, let latest):
            HStack {
                Text(current == latest ? "\(shortRef(current)) isn't installed yet" : "\(shortRef(current)) → \(shortRef(latest)) available")
                Spacer()
                Button(current == latest ? "Install" : "Update") { audioRuntime.applyUpdate(to: latest) }.disabled(audioBusy)
            }
        case .failed(let message):
            HStack { Text(message).foregroundStyle(.red).lineLimit(2); Spacer(); Button("Retry") { audioRuntime.checkForUpdate() }.disabled(audioBusy) }
        }
    }

    private func shortRef(_ ref: String) -> String { ref.count > 12 ? String(ref.prefix(7)) : ref }

    private func uninstallRuntime() {
        // The setup wizard (or a Start) is making the venv this deletes.
        guard !MLXRuntimeInstaller.isSettingUp else { return runtimeBusy() }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Uninstall runtime data?", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Removes the downloaded mlx-lm runtime and image generation (its runtime and image models) from %@. They're set up again on the next server start, or when image generation is turned on. Saved chats and profiles are kept.", comment: ""), RuntimePaths.externalRuntimeDir)
        alert.addButton(withTitle: NSLocalizedString("Uninstall", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // A setup may have started while the alert was up.
        guard !MLXRuntimeInstaller.isSettingUp else { return runtimeBusy() }
        server.removeExternalRuntime()
    }

    private func runtimeBusy() {
        let busy = NSAlert()
        busy.messageText = NSLocalizedString("The runtime is busy.", comment: "")
        busy.informativeText = NSLocalizedString("It is being set up or updated. Try again once that's done.", comment: "")
        busy.runModal()
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

    /// The language the UI would be in with `code` ("" = the system's).
    static func effective(_ code: String) -> String? {
        if !code.isEmpty { return code }
        // The system's own order, not this app's override.
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: available, forPreferences: system).first
    }

    static func set(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        // "System (English)" -> "English": the UI stays as it is, nothing
        // to restart for.
        if let running = Bundle.main.preferredLocalizations.first, effective(code) == running { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Restart LLMTray to change the language?", comment: "")
        alert.informativeText = NSLocalizedString("The running model server is stopped and started again.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Restart Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunch(reopening: .general)
    }

    /// Starts a fresh instance once this one has exited, then quits. The
    /// new instance opens Settings on `pane` again.
    static func relaunch(reopening pane: SettingsPane? = nil) {
        UserDefaults.standard[Pref.settingsPaneAfterRelaunch] = pane?.rawValue
        let path = Bundle.main.bundlePath
        #if APP_STORE
        // No shell in the sandbox (adr/0018 §3): the new instance is started
        // now and waits for this one to exit (AppDelegate's --after-pid).
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--after-pid", String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        #else
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
        #endif
    }
}
