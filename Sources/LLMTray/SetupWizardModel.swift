import AppKit
import Combine
import Foundation
import LLMTrayCore

extension Notification.Name {
    /// Opens the setup wizard (Settings › General, the menu bar's menu).
    static let showSetupWizard = Notification.Name("LLMTray.showSetupWizard")
}

/// The first-run wizard's state and actions (adr/0013). The steps and the
/// plan are LLMTrayCore.SetupWizard's; everything is set through
/// FeatureSetup, ProfileManager (the Default profile) and the Pref keys
/// Settings uses -- the wizard is a guided front end to the same code.
/// Nothing is downloaded or turned on that the user didn't choose; the
/// runtime is set up on the "Your Mac" step (it would be on the first
/// Start anyway).
@MainActor
final class SetupWizardModel: ObservableObject {
    @Published var progress: SetupProgress {
        didSet { if progress != oldValue { save() } }
    }
    let hardware = HardwareProbe.current()
    @Published private(set) var runtime: RuntimeStatus = .unknown
    /// The runtime setup's latest log line.
    @Published private(set) var runtimeLine = ""
    @Published private(set) var picks: [ModelRecommendations.Pick] = []
    /// The image and music models offered while the switch is off.
    @Published var imagePick: ImageGenModel
    @Published var musicPick: MusicModel
    /// What Finish couldn't do: the Done step shows it.
    @Published private(set) var finishErrors: [String] = []
    @Published private(set) var isFinished = false

    let queue: DownloadQueue
    let server: ServerManager
    private let setup = FeatureSetup.shared
    private let profiles = ProfileManager.shared
    private let startServer: () -> Void
    private let serverLog: @MainActor @Sendable (String) -> Void
    private var runtimeTask: Task<Void, Never>?
    private var sizesTask: Task<Void, Never>?
    private var liveSizes: [String: Int64] = [:]
    /// Closes the window (Finish, Skip on the first step).
    var close: (() -> Void)?

    enum RuntimeStatus: Equatable {
        case unknown
        case checking
        /// A Light build with no Python 3.10+ to make the runtime with.
        case noPython
        case installing
        case ready
        case failed(String)
    }

    /// `automatic`: opened by itself on a first run (it then resumes where
    /// a relaunch left it); otherwise from the current settings.
    /// `startServer`: the app's own start path (the saved model).
    init(queue: DownloadQueue, server: ServerManager, automatic: Bool, startServer: @escaping () -> Void,
         serverLog: @escaping @MainActor @Sendable (String) -> Void) {
        self.queue = queue
        self.server = server
        self.startServer = startServer
        self.serverLog = serverLog
        let saved = Self.loadSaved()
        progress = SetupWizard.resume(saved: saved, current: Self.currentChoices(), automatic: automatic)
        imagePick = FeatureSetup.shared.imageGenModel()
        musicPick = FeatureSetup.shared.musicModel()
        if let model = progress.choices.imageModel.flatMap(ImageGenModel.init(rawValue:)) { imagePick = model }
        if let model = progress.choices.musicModel.flatMap(MusicModel.init(rawValue:)) { musicPick = model }
        // Offered while off: one that fits this Mac, if the current one doesn't.
        if progress.choices.imageModel == nil, !Self.fits(imageFit(imagePick)),
           let model = ImageGenModel.selectable.first(where: { Self.fits(imageFit($0)) }) {
            imagePick = model
        }
        if progress.choices.musicModel == nil, !Self.fits(musicFit(musicPick)),
           let model = MusicManager.selectable.first(where: { Self.fits(musicFit($0)) }) {
            musicPick = model
        }
        save()
    }

    // MARK: - Saved progress

    static func loadSaved() -> SetupProgress? {
        guard let json = UserDefaults.standard[Pref.onboardingProgress] else { return nil }
        return try? JSONDecoder().decode(SetupProgress.self, from: Data(json.utf8))
    }

    private func save() {
        guard !isFinished, let data = try? JSONEncoder().encode(progress) else { return }
        UserDefaults.standard[Pref.onboardingProgress] = String(decoding: data, as: UTF8.self)
    }

    /// The settings as they are, for the wizard to start from.
    static func currentChoices() -> SetupChoices {
        let defaults = UserDefaults.standard
        let setup = FeatureSetup.shared
        let profiles = ProfileManager.shared
        let tools = profiles.value(\.tools.enabledTools, profileID: Profile.defaultID)
        return SetupChoices(
            modelsFolder: setup.modelsFolder,
            chatModel: defaults[Pref.selectedModelID].map { .local(path: $0) },
            imageModel: setup.isImageGenerationEnabled() ? setup.imageGenModel().rawValue : nil,
            editModel: setup.imageEditModel()?.rawValue,
            musicModel: setup.isMusicGenerationEnabled() ? setup.musicModel().rawValue : nil,
            creatorMode: profiles.value(\.tools.creatorMode, profileID: Profile.defaultID),
            creatorCountdown: profiles.value(\.tools.creatorCountdown, profileID: Profile.defaultID),
            webTools: tools.contains(where: ToolCatalog.usesNetwork),
            projectFiles: setup.isProjectFilesEnabled,
            port: defaults[Pref.port],
            allowLAN: defaults[Pref.allowLAN],
            modelSwitchPolicy: defaults[Pref.modelSwitchPolicy],
            launchAtLogin: FeatureSetup.launchAtLogin,
            automaticUpdateChecks: defaults[Pref.automaticUpdateChecks],
            checkUpdatesAtLaunch: defaults[Pref.checkUpdatesAtLaunch],
            betaUpdates: defaults[Pref.betaUpdates],
            usageStatistics: UsageTelemetry.shared.isEnabled
        )
    }

    // MARK: - Moving through the steps

    var step: SetupStep { progress.step }

    func next() {
        // The folder the next step lists its models from.
        if step == .modelsFolder { perform(progress.applyEarly(.modelsFolder)) }
        if let next = step.next { progress.step = next }
    }

    func back() {
        if let previous = step.previous { progress.step = previous }
    }

    /// The step goes back to how it was; Skip on the first one ends the
    /// wizard (it counts as done).
    func skip() {
        guard step != .welcome else {
            complete()
            close?()
            return
        }
        // The wizard's download runs into the folder applied (or is done
        // there): the folder stays.
        if step == .modelsFolder, locksModelsFolder {
            progress.choices.modelsFolder = progress.baseline.modelsFolder
            progress.step = .chatModel
            return
        }
        perform(progress.skip())
    }

    /// Done, without applying what's still unapplied: the window was
    /// closed. The chat model picked on step 4 is kept, so the server
    /// starts with it: now if it's here, else once its download is done.
    func complete() {
        guard !isFinished else {
            // Finish ran (the window stayed open for its errors): a chat
            // model that arrived meanwhile waited for the window to close.
            if case .download = progress.choices.chatModel, UserDefaults.standard[Pref.onboardingStartServerFor] != nil {
                startChosenModel()
            }
            return
        }
        if progress.startsServer { startChosenModel() }
        markDone()
    }

    private func markDone() {
        isFinished = true
        runtimeTask = nil
        sizesTask?.cancel()
        UserDefaults.standard[Pref.onboardingCompleted] = SetupWizard.version
        UserDefaults.standard[Pref.onboardingProgress] = nil
    }

    /// Everything chosen, applied; the downloads queued (the chat model
    /// first). The window stays open to show what failed, if anything.
    func finish() {
        guard !isFinished else { return }
        // A port that's taken (or out of range) isn't applied unseen: the
        // Done step shows the note, with Use Anyway for a wrong check.
        checkPort()
        guard portProblem == nil else { return }
        finishErrors = actions.compactMap(perform)
        markDone()
        if finishErrors.isEmpty {
            close?()
            // What a first look should show is the app, not a menu-bar icon:
            // the chat in its own window (and the Dock), where the chat
            // model's download goes on.
            DispatchQueue.main.async { NotificationCenter.default.post(name: .detachChat, object: nil) }
        }
    }

    /// What Finish will do.
    var actions: [SetupAction] {
        SetupPlan.actions(from: progress.choices, baseline: progress.baseline, startsServer: progress.startsServer)
    }

    // MARK: - Your Mac: the runtime

    var modelsFolderFreeBytes: Int64? { HardwareProbe.freeDiskBytes(at: progress.choices.modelsFolder) }

    /// Sets the runtime up in the background (the first Start would do the
    /// same, with its progress only in the server log). A Light build
    /// without Python stops at .noPython; Check Again looks again.
    func prepareRuntime() {
        guard runtimeTask == nil, runtime != .ready else { return }
        if MLXRuntimeInstaller.isReady {
            runtime = .ready
            return
        }
        runtime = .checking
        runtimeTask = Task { [weak self] in
            // Python makes the venv; with one in place (an update) or the
            // Full build's, none is needed.
            // (A venv without its marker is from a failed attempt: it's made
            // again.)
            let needsPython = !MLXRuntimeInstaller.isFullBuild
                && (!FileManager.default.fileExists(atPath: MLXRuntimeInstaller.venvDir)
                    || !FileManager.default.fileExists(atPath: MLXRuntimeInstaller.versionMarkerPath))
            if needsPython {
                let python = await PythonLocator.findModern(preferring: [MLXRuntimeInstaller.externalFrameworkPython()].compactMap { $0 })
                guard let self else { return }
                guard python != nil else {
                    self.runtime = .noPython
                    self.runtimeTask = nil
                    return
                }
            }
            guard let self else { return }
            self.runtime = .installing
            let log = self.serverLog
            let installer = MLXRuntimeInstaller(log: { [weak self] text in
                log(text)
                self?.showRuntimeLine(text)
            })
            do {
                try await installer.ensureReady()
                self.runtime = .ready
            } catch {
                self.runtime = .failed(error.localizedDescription)
            }
            self.runtimeTask = nil
        }
    }

    private func showRuntimeLine(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- ")) }
            .filter { !$0.isEmpty }
        if let last = lines.last { runtimeLine = String(last.prefix(160)) }
    }

    // MARK: - Models folder

    var defaultModelsFolder: String { ModelDiscovery.defaultModelsRoot }
    var lmStudioFolder: String? { setup.lmStudioFolderHasModels ? FeatureSetup.lmStudioFolder : nil }

    func models(in folder: String) -> [LocalModel] { ModelDiscovery.scanModels(root: folder) }

    func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        // ~/.llmtray, ~/.lmstudio: model folders are often hidden ones.
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: progress.choices.modelsFolder)
        panel.prompt = NSLocalizedString("Use Folder", comment: "")
        guard panel.runModal() == .OK, let url = panel.url, !locksModelsFolder else { return }
        SandboxAccess.remember(url)
        progress.choices.modelsFolder = url.path
    }

    // MARK: - Chat model

    /// The curated list for this Mac, with the Hub's current sizes once
    /// read (the list's own until then).
    func loadPicks() {
        picks = setup.recommendedChatModels(liveSizes: liveSizes)
        guard sizesTask == nil, liveSizes.isEmpty else { return }
        let repos = picks.map(\.model.repo)
        sizesTask = Task { [weak self] in
            var sizes: [String: Int64] = [:]
            await withTaskGroup(of: (String, Int64?).self) { group in
                for repo in repos {
                    group.addTask { (repo, await DownloadQueue.hubInfo(repo)?.filesBytes) }
                }
                for await (repo, bytes) in group {
                    if let bytes { sizes[repo] = bytes }
                }
            }
            guard let self, !Task.isCancelled, !sizes.isEmpty else { return }
            self.liveSizes = sizes
            self.picks = self.setup.recommendedChatModels(liveSizes: sizes)
        }
    }

    /// Local folders that are complete copies of a pick, read when the
    /// models, the picks or the chat downloads change -- never per redraw.
    @Published private(set) var completePickFolders: Set<String> = []

    func refreshLocalCopies(localPaths: [String]) {
        let matched = picks.compactMap { ModelRecommendations.localPath(of: $0.model.repo, in: localPaths) }
        let complete = Set(matched.filter { ModelFolder.isComplete(atPath: $0) })
        if complete != completePickFolders { completePickFolders = complete }
    }

    var selectedLocalPath: String? {
        if case .local(let path) = progress.choices.chatModel { return path }
        return nil
    }

    var selectedDownloadRepo: String? {
        if case .download(let repo, _) = progress.choices.chatModel { return repo }
        return nil
    }

    /// A model already here: it's the selected one now.
    func pick(local model: LocalModel) {
        stopWizardDownload(keeping: nil)
        progress.choices.chatModel = .local(path: model.path)
        progress.startsServer = true
        perform(progress.applyEarly(.chatModel))
    }

    /// A download starts right away (adr/0013: it's the one thing needed
    /// to chat) and goes on while the wizard does; the server starts with
    /// it once it's there.
    func pick(download pick: ModelRecommendations.Pick) {
        let repo = pick.model.repo
        stopWizardDownload(keeping: repo)
        progress.choices.chatModel = .download(repo: repo, approxBytes: pick.sizeBytes)
        progress.startsServer = true
        UserDefaults.standard[Pref.onboardingStartServerFor] = repo
        perform(progress.applyEarly(.chatModel))
        // Picked again after it was cancelled or failed (the queue keeps
        // one of each).
        queue.addChatModel(repo: repo, approxBytes: pick.sizeBytes)
    }

    /// `repo` waits, runs, or failed (to be retried) in the queue.
    private func hasQueuedDownload(_ repo: String) -> Bool {
        queue.state.items.contains { $0.kind == .chatModel && $0.target == repo && $0.status != .cancelled && $0.status != .done }
    }

    /// The wizard's chat download is waiting or running.
    var isWizardDownloadActive: Bool {
        guard let repo = selectedDownloadRepo else { return false }
        return queue.state.items.contains { $0.kind == .chatModel && $0.target == repo && !$0.status.isFinished }
    }

    /// The picked download is here.
    var isWizardDownloadComplete: Bool {
        guard let repo = selectedDownloadRepo else { return false }
        return DownloadQueue.isComplete(repo, root: ModelDiscovery.currentModelsRoot())
    }

    /// The picked download is coming into the folder applied, or is there:
    /// the folder stays (Finish looks for the model in it), until another
    /// chat model is picked.
    var locksModelsFolder: Bool { isWizardDownloadActive || isWizardDownloadComplete }

    /// A download this wizard started for another pick is cancelled.
    private func stopWizardDownload(keeping repo: String?) {
        guard case .download(let started, _) = progress.baseline.chatModel, started != repo else { return }
        cancelDownload(started)
    }

    private func cancelDownload(_ started: String) {
        if let item = queue.state.items.first(where: { $0.kind == .chatModel && $0.target == started && !$0.status.isFinished }) {
            queue.cancel(item.id)
        }
        if UserDefaults.standard[Pref.onboardingStartServerFor] == started {
            UserDefaults.standard[Pref.onboardingStartServerFor] = nil
        }
    }

    /// Needs a Hugging Face token the user hasn't saved yet.
    func needsToken(_ pick: ModelRecommendations.Pick) -> Bool { pick.model.gated && HFToken.value == nil }

    func browseHuggingFace() {
        NotificationCenter.default.post(name: .showHFBrowser, object: nil)
    }

    // MARK: - What else

    func imageModelSize(_ model: ImageGenModel) -> String {
        model.isDownloaded ? NSLocalizedString("downloaded", comment: "setup: model size") : model.approximateDownloadDescription
    }

    func imageFit(_ model: ImageGenModel) -> FeatureFit? { setup.memoryFit(model) }
    func editFit(_ model: ImageGenModel) -> FeatureFit? { setup.memoryFit(editingWith: model) }
    func musicFit(_ model: MusicModel) -> FeatureFit? { setup.memoryFit(model) }

    /// Not measured is no gate: only a model known not to fit is held back.
    static func fits(_ fit: FeatureFit?) -> Bool { fit?.isAvailable ?? true }

    func musicModelSize(_ model: MusicModel) -> String {
        setup.isMusicModelReady(model) ? NSLocalizedString("downloaded", comment: "setup: model size") : model.approximateDownloadDescription
    }

    var embedderDescription: String? {
        guard let entry = setup.projectFilesEmbedder else { return nil }
        let size = setup.isProjectFilesEmbedderDownloaded ? NSLocalizedString("downloaded", comment: "setup: model size")
            : ModelCatalog.format(FeatureSetup.downloadBytes(entry))
        return "\(entry.displayName) · \(size)"
    }

    // MARK: - Apps and agents

    /// The network settings change only while the server is stopped, as in
    /// Settings.
    var canEditNetwork: Bool {
        if case .stopped = server.state { return true }
        if case .failed = server.state { return true }
        return false
    }

    var baseURLSnippet: String { "OPENAI_BASE_URL=http://localhost:\(progress.choices.port)/v1" }

    /// What's wrong with the chosen port, checked before the server first
    /// starts on it (checkPort): another app holds it, or it's out of range.
    @Published private(set) var portProblem: PortProblem?
    /// The first free port after it, for the note's button.
    @Published private(set) var freePort: Int?
    /// "Use Anyway": a port the check calls taken, kept -- the check could
    /// be wrong, and must never stop Finish for good.
    private var portAcceptedAnyway: Int?

    enum PortProblem: Equatable {
        case inUse(Int)
        case outOfRange(Int)
    }

    /// Only while the server is stopped (not idle-unloaded): otherwise
    /// it's LLMTray's own listener holding the port. Bound as the server
    /// would bind it (the LAN choice).
    func checkPort() {
        let port = progress.choices.port
        let loopbackOnly = !progress.choices.allowLAN
        guard canEditNetwork, !server.isIdleUnloaded, port != portAcceptedAnyway else {
            portProblem = nil
            freePort = nil
            return
        }
        switch PortCheck.status(port, loopbackOnly: loopbackOnly) {
        case .free:
            portProblem = nil
            freePort = nil
            return
        case .inUse: portProblem = .inUse(port)
        case .outOfRange: portProblem = .outOfRange(port)
        }
        let start = PortCheck.validRange.contains(port) ? port : Pref.port.defaultValue - 1
        freePort = PortCheck.nextFree(after: start) { PortCheck.isInUse($0, loopbackOnly: loopbackOnly) }
    }

    /// The port picked in the note: saved at once to the Pref Settings'
    /// port field uses (SetupProgress.adoptPort), then checked again.
    func usePort(_ port: Int) {
        guard canEditNetwork, PortCheck.validRange.contains(port) else { return }
        perform(progress.adoptPort(port))
        checkPort()
    }

    /// Keeps a port the check calls taken (it may be wrong): no note, and
    /// Finish goes ahead.
    func usePortAnyway() {
        guard case .inUse(let port) = portProblem else { return }
        portAcceptedAnyway = port
        checkPort()
    }

    func copySnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(baseURLSnippet, forType: .string)
    }

    // MARK: - Doing it

    private func perform(_ actions: [SetupAction]) {
        for action in actions { _ = perform(action) }
    }

    /// nil when done, else what went wrong.
    private func perform(_ action: SetupAction) -> String? {
        let defaults = UserDefaults.standard
        let id = Profile.defaultID
        switch action {
        case .setModelsFolder(let path):
            setup.setModelsFolder(path)
        case .selectModel(let path):
            defaults[Pref.selectedModelID] = path
        case .clearModelSelection:
            defaults[Pref.selectedModelID] = nil
        case .cancelChatDownload(let repo):
            cancelDownload(repo)
        case .setPort(let port):
            // As in Settings: the listener keeps its port and binding
            // until the server stops.
            guard canEditNetwork else { return NSLocalizedString("The port and network access can change only while the server is stopped.", comment: "setup error") }
            defaults[Pref.port] = port
        case .setAllowLAN(let on):
            guard canEditNetwork else { return NSLocalizedString("The port and network access can change only while the server is stopped.", comment: "setup error") }
            defaults[Pref.allowLAN] = on
        case .setModelSwitchPolicy(let policy):
            defaults[Pref.modelSwitchPolicy] = policy
            ModelSwitchPrompter.shared.policyChanged()
        case .setCreatorMode(let on):
            profiles.set(\.tools.creatorMode, on, profileID: id)
        case .setCreatorCountdown(let seconds):
            profiles.set(\.tools.creatorCountdown, seconds, profileID: id)
        case .setWebTools(let on):
            var tools = profiles.value(\.tools.enabledTools, profileID: id).filter { !ToolCatalog.usesNetwork($0) }
            if on { tools += ToolCatalog.entries.filter(\.usesNetwork).map(\.name) }
            profiles.set(\.tools.enabledTools, tools, profileID: id)
        case .disableImageGeneration:
            setup.setImageGenerationEnabled(false, profileID: id)
        case .disableImageEditing:
            setup.setImageEditModel(nil, profileID: id)
        case .disableMusicGeneration:
            setup.setMusicGenerationEnabled(false, profileID: id)
        case .setProjectFiles(let on):
            if on { setup.projectFiles.setEnabled(true) } else { setup.disableProjectFiles() }
        case .setLaunchAtLogin(let on):
            do {
                try FeatureSetup.setLaunchAtLogin(on)
            } catch {
                return String(format: NSLocalizedString("Launch at login: %@", comment: "setup error"), error.localizedDescription)
            }
        case .setAutomaticUpdateChecks(let on):
            defaults[Pref.automaticUpdateChecks] = on
        case .setCheckUpdatesAtLaunch(let on):
            defaults[Pref.checkUpdatesAtLaunch] = on
        case .setBetaUpdates(let on):
            defaults[Pref.betaUpdates] = on
        case .setUsageStatistics(let on):
            UsageTelemetry.shared.setEnabled(on)
        case .downloadChatModel(let repo, let bytes):
            queue.addChatModel(repo: repo, approxBytes: bytes)
        case .downloadImageModel(let raw):
            guard let model = ImageGenModel(rawValue: raw) else { return nil }
            queue.addImageModel(model)
        case .downloadEditModel(let raw):
            guard let model = ImageGenModel(rawValue: raw) else { return nil }
            queue.addEditModel(model)
        case .downloadMusicModel(let raw):
            guard let model = MusicModel(rawValue: raw) else { return nil }
            queue.addMusicModel(model)
        case .downloadEmbedder:
            if let entry = setup.projectFilesEmbedder, !setup.isProjectFilesEmbedderReady { queue.addEmbedder(entry) }
        case .startServer:
            startChosenModel()
        }
        return nil
    }

    /// A model that's here starts now; one still downloading when it's
    /// done (AppDelegate, Pref.onboardingStartServerFor).
    private func startChosenModel() {
        switch progress.choices.chatModel {
        case .local(let path):
            UserDefaults.standard[Pref.selectedModelID] = path
            startServer()
        case .download(let repo, _):
            let root = ModelDiscovery.currentModelsRoot()
            guard DownloadQueue.isComplete(repo, root: root) else {
                // Waits for the download, unless it was cancelled (or
                // dismissed after failing): then nothing is coming.
                UserDefaults.standard[Pref.onboardingStartServerFor] = hasQueuedDownload(repo) ? repo : nil
                return
            }
            UserDefaults.standard[Pref.onboardingStartServerFor] = nil
            ModelCatalog.shared.rescan()
            UserDefaults.standard[Pref.selectedModelID] = root + "/" + repo
            startServer()
        case nil:
            break
        }
    }

    // MARK: - The summary

    /// One plain line per thing Finish does (downloads excluded: they're
    /// listed with the queue).
    var summaryLines: [String] {
        actions.compactMap { action in
            switch action {
            case .setModelsFolder(let path):
                return String(format: NSLocalizedString("Models folder: %@", comment: "setup summary"), (path as NSString).abbreviatingWithTildeInPath)
            case .selectModel(let path):
                return String(format: NSLocalizedString("Chat model: %@", comment: "setup summary"), LocalModel(path: path).displayName)
            case .clearModelSelection, .cancelChatDownload:
                return nil
            case .setPort(let port):
                return String(format: NSLocalizedString("Port: %lld", comment: "setup summary"), port)
            case .setAllowLAN(let on):
                return on ? NSLocalizedString("Other devices on your network can use the server", comment: "setup summary")
                    : NSLocalizedString("Only this Mac can use the server", comment: "setup summary")
            case .setModelSwitchPolicy(let raw):
                return String(format: NSLocalizedString("When an app asks for another model: %@", comment: "setup summary"), Self.policyName(raw))
            case .setCreatorMode(let on):
                return on ? NSLocalizedString("Creator mode on", comment: "setup summary") : NSLocalizedString("Creator mode off", comment: "setup summary")
            case .setCreatorCountdown(let seconds):
                return String(format: NSLocalizedString("Creator mode countdown: %lld s", comment: "setup summary"), seconds)
            case .setWebTools(let on):
                return on ? NSLocalizedString("Web tools on", comment: "setup summary") : NSLocalizedString("Web tools off", comment: "setup summary")
            case .disableImageGeneration: return NSLocalizedString("Image generation off", comment: "setup summary")
            case .disableImageEditing: return NSLocalizedString("Image editing off", comment: "setup summary")
            case .disableMusicGeneration: return NSLocalizedString("Music off", comment: "setup summary")
            case .setProjectFiles(let on):
                return on ? NSLocalizedString("Project files on", comment: "setup summary") : NSLocalizedString("Project files off", comment: "setup summary")
            case .setLaunchAtLogin(let on):
                return on ? NSLocalizedString("Opens at login", comment: "setup summary") : NSLocalizedString("Doesn't open at login", comment: "setup summary")
            case .setAutomaticUpdateChecks(let on):
                return on ? NSLocalizedString("Checks for updates automatically", comment: "setup summary") : NSLocalizedString("No automatic update checks", comment: "setup summary")
            case .setCheckUpdatesAtLaunch(let on):
                return on ? NSLocalizedString("Checks for updates at launch", comment: "setup summary") : NSLocalizedString("No update check at launch", comment: "setup summary")
            case .setBetaUpdates(let on):
                return on ? NSLocalizedString("Update channel: Beta", comment: "setup summary") : NSLocalizedString("Update channel: Stable", comment: "setup summary")
            case .setUsageStatistics(let on):
                return on ? NSLocalizedString("Sends anonymous usage statistics", comment: "setup summary") : NSLocalizedString("No usage statistics", comment: "setup summary")
            case .startServer:
                switch progress.choices.chatModel {
                case .local(let path):
                    return String(format: NSLocalizedString("The server starts with %@", comment: "setup summary"), LocalModel(path: path).displayName)
                case .download(let repo, _):
                    guard isWizardDownloadComplete || hasQueuedDownload(repo) else { return nil }
                    return String(format: NSLocalizedString("The server starts once %@ is downloaded", comment: "setup summary"), repo)
                case nil:
                    return nil
                }
            case .downloadChatModel, .downloadImageModel, .downloadEditModel, .downloadMusicModel, .downloadEmbedder:
                return nil
            }
        }
    }

    /// The downloads Finish adds, by name and size.
    var summaryDownloads: [String] {
        actions.compactMap { action in
            switch action {
            case .downloadChatModel(let repo, let bytes):
                return bytes.map { "\(repo) · \(ModelCatalog.format($0))" } ?? repo
            case .downloadImageModel(let raw), .downloadEditModel(let raw):
                return ImageGenModel(rawValue: raw).map { "\($0.displayName) · \(imageModelSize($0))" }
            case .downloadMusicModel(let raw):
                return MusicModel(rawValue: raw).map { "\($0.displayName) · \(musicModelSize($0))" }
            case .downloadEmbedder:
                return setup.isProjectFilesEmbedderReady ? nil : embedderDescription
            default:
                return nil
            }
        }
    }

    static func policyName(_ raw: String) -> String {
        switch ModelSwitchPolicy(rawValue: raw) ?? .auto {
        case .auto: return NSLocalizedString("Switch at once", comment: "")
        case .ask: return NSLocalizedString("Ask first", comment: "")
        case .keep: return NSLocalizedString("Keep the loaded model", comment: "")
        }
    }
}
