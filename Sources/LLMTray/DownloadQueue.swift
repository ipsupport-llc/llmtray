import Combine
import Foundation
import LLMTrayCore

/// The first-run wizard's downloads, one at a time (adr/0013): the chat
/// model through HFModelBrowser (as the Hugging Face browser downloads),
/// the image, edit and music models through FeatureSetup -- each enabled
/// on the Default profile once it's in place, as Settings does. Free space
/// is checked before each. The order and states are
/// LLMTrayCore.DownloadQueueState's, kept in Pref.downloadQueue while
/// anything waits or failed: a relaunch picks up with resume(), a failed
/// item stays to be retried.
@MainActor
final class DownloadQueue: ObservableObject {
    @Published private(set) var state: DownloadQueueState {
        didSet { if state != oldValue { save() } }
    }
    /// What the running item is doing (the downloader's own status line).
    @Published private(set) var detail = ""

    private let browser: HFModelBrowser
    private let setup: FeatureSetup
    private let profileID: String
    private var runner: Task<Void, Never>?
    /// The running chat-model download's end, resumed once.
    private var chatDownload: CheckedContinuation<String?, Never>?
    /// The browser's download is this queue's (not one the user started
    /// in the Hugging Face window): only then may cancel stop it.
    private var ownsBrowserDownload = false
    /// What save() last wrote.
    private var lastSaved: DownloadQueueState?
    /// The chat model's Hub lookup, stopped by a cancel (a stalled request
    /// mustn't hold up the queue).
    private var hubLookup: Task<(info: HubModelInfo, filesBytes: Int64?)?, Never>?
    private var watches: Set<AnyCancellable> = []
    /// An item ended (done, failed or cancelled) -- the wizard's server
    /// start waits for its chat model here.
    var onFinished: ((DownloadQueueState.Item) -> Void)?

    /// `browser`: the app's one HFModelBrowser, so the Hugging Face window
    /// shows the same download (and won't start a second one). What was
    /// left unfinished at the last quit is restored, waiting for resume().
    init(browser: HFModelBrowser, setup: FeatureSetup? = nil, profileID: String = Profile.defaultID) {
        self.browser = browser
        self.setup = setup ?? .shared
        self.profileID = profileID
        var saved = Self.load()
        saved.resetInterrupted()
        state = saved
    }

    /// Starts what's waiting (after a relaunch: the restored items).
    func resume() { pump() }

    private static func load() -> DownloadQueueState {
        guard let json = UserDefaults.standard[Pref.downloadQueue],
              let state = try? JSONDecoder().decode(DownloadQueueState.self, from: Data(json.utf8)) else { return DownloadQueueState() }
        return DownloadQueueState(items: state.items.filter(Self.isKept))
    }

    /// What's waiting, running or failed; nothing once it's all done or
    /// cancelled.
    /// Written only when that changes: progress (a relaunch starts over
    /// anyway) isn't kept, so a download's progress ticks write nothing.
    private func save() {
        let kept = DownloadQueueState(items: state.items.filter(Self.isKept).map { item in
            var item = item
            if case .running = item.status { item.status = .running(progress: nil) }
            return item
        })
        guard kept != lastSaved else { return }
        lastSaved = kept
        guard !kept.items.isEmpty, let data = try? JSONEncoder().encode(kept) else {
            UserDefaults.standard[Pref.downloadQueue] = nil
            return
        }
        UserDefaults.standard[Pref.downloadQueue] = String(decoding: data, as: UTF8.self)
    }

    private static func isKept(_ item: DownloadQueueState.Item) -> Bool {
        switch item.status {
        case .pending, .running, .failed: return true
        case .done, .cancelled: return false
        }
    }

    // MARK: - Adding

    /// A chat model by Hugging Face repo; `approxBytes` until the Hub's own
    /// size is read. Goes ahead of the other waiting items.
    func addChatModel(repo: String, approxBytes: Int64? = nil) {
        add(.init(kind: .chatModel, target: repo, approxBytes: approxBytes))
    }

    /// Image generation with `model`, turned on when it's downloaded.
    func addImageModel(_ model: ImageGenModel) {
        add(.init(kind: .imageModel, target: model.rawValue, approxBytes: FeatureSetup.downloadBytes(model)))
    }

    /// Image editing with `model` (one that supportsEditing).
    func addEditModel(_ model: ImageGenModel = .klein4b) {
        guard model.supportsEditing else { return }
        add(.init(kind: .editModel, target: model.rawValue, approxBytes: FeatureSetup.downloadBytes(model)))
    }

    /// Music generation with `model`, turned on when it's set up.
    func addMusicModel(_ model: MusicModel) {
        add(.init(kind: .musicModel, target: model.rawValue, approxBytes: FeatureSetup.downloadBytes(model)))
    }

    /// Project files' embedder (the feature is turned on separately: files
    /// are searched by their words until it's in place).
    func addEmbedder(_ entry: EmbedderEntry) {
        add(.init(kind: .embedder, target: entry.id, approxBytes: FeatureSetup.downloadBytes(entry)))
    }

    private func add(_ item: DownloadQueueState.Item) {
        guard state.enqueue(item) else { return }
        pump()
    }

    // MARK: - Control

    /// Stops `id`: a waiting item never runs; the running chat model's
    /// download stops. An image or music download can't be stopped part
    /// way (it's a pip / snapshot_download child); it finishes in the
    /// background and its feature is left off.
    func cancel(_ id: UUID) {
        guard state.cancel(id) else { return }
        stopRunning(id)
    }

    func cancelAll() {
        if let running = state.cancelAll() { stopRunning(running) }
    }

    func retry(_ id: UUID) {
        guard state.retry(id) != nil else { return }
        pump()
    }

    /// Done and cancelled items leave the list; failed ones stay.
    func removeFinished() { state.removeFinished() }

    /// A finished (failed) item leaves the list; if it was the wizard's
    /// chat model, the server start waiting for it is dropped too.
    func dismiss(_ id: UUID) {
        if let item = state.item(id), item.status.isFinished, item.kind == .chatModel,
           UserDefaults.standard[Pref.onboardingStartServerFor] == item.target {
            UserDefaults.standard[Pref.onboardingStartServerFor] = nil
        }
        state.dismiss(id)
    }

    private func stopRunning(_ id: UUID) {
        guard let item = state.item(id), item.kind == .chatModel else { return }
        if ownsBrowserDownload, browser.downloadingID == item.target {
            browser.cancelDownload()
        } else {
            // Still waiting for the Hub or another download: nothing of
            // ours is in the browser yet.
            hubLookup?.cancel()
            endChatDownload(nil)
        }
    }

    // MARK: - Running

    /// Starts the next item unless one runs.
    private func pump() {
        guard runner == nil, let item = state.startNext() else { return }
        detail = ""
        runner = Task { [weak self] in
            let error = await self?.run(item)
            guard let self else { return }
            self.state.finish(item.id, error: error)
            self.detail = ""
            if let finished = self.state.item(item.id) { self.onFinished?(finished) }
            self.watches.removeAll()
            self.runner = nil
            self.pump()
        }
    }

    /// nil on success, else the message.
    private func run(_ item: DownloadQueueState.Item) async -> String? {
        switch item.kind {
        case .chatModel:
            return await runChatModel(item)
        case .imageModel, .editModel:
            guard let model = ImageGenModel(rawValue: item.target) else { return String(format: NSLocalizedString("Unknown image model %@", comment: "download queue"), item.target) }
            // A Settings download first; it may take the space this needs.
            guard await waitForSettingsDownload(item) else { return nil }
            if !model.isDownloaded, let refusal = spaceRefusal(item, at: RuntimePaths.externalRuntimeDir) { return refusal }
            watch(setup.media.$mfluxStatusText)
            if let error = await setup.downloadImageModel(model) { return error.localizedDescription }
            // Cancelled while it ran: downloaded, but not turned on.
            guard isStillWanted(item) else { return nil }
            if item.kind == .imageModel {
                setup.setImageGenModel(model, profileID: profileID)
                setup.setImageGenerationEnabled(true, profileID: profileID)
            } else {
                setup.setImageEditModel(model, profileID: profileID)
            }
            return nil
        case .musicModel:
            guard let model = MusicModel(rawValue: item.target) else { return String(format: NSLocalizedString("Unknown music model %@", comment: "download queue"), item.target) }
            guard await waitForSettingsDownload(item) else { return nil }
            if !setup.isMusicModelReady(model) {
                if let refusal = spaceRefusal(item, at: RuntimePaths.externalRuntimeDir) { return refusal }
                watch(setup.media.$musicStatusText)
                if let error = await setup.downloadMusicModel(model) { return error.localizedDescription }
            }
            guard isStillWanted(item) else { return nil }
            setup.setMusicModel(model, profileID: profileID)
            setup.setMusicGenerationEnabled(true, profileID: profileID)
            return nil
        case .embedder:
            guard let entry = setup.projectFilesEmbedder, entry.id == item.target else {
                return String(format: NSLocalizedString("Unknown embedding model %@", comment: "download queue"), item.target)
            }
            if setup.isProjectFilesEmbedderReady { return nil }
            if let refusal = spaceRefusal(item, at: RuntimePaths.externalRuntimeDir) { return refusal }
            watch(setup.projectFiles.embedders.$statusText)
            if let error = await setup.downloadProjectFilesEmbedder() { return error.localizedDescription }
            return nil
        }
    }

    /// Not cancelled (nor retried under a new id) meanwhile.
    private func isStillWanted(_ item: DownloadQueueState.Item) -> Bool {
        state.isRunning(item.id)
    }

    /// An image or music download started in Settings runs first (the
    /// generators take one at a time). false: cancelled meanwhile.
    private func waitForSettingsDownload(_ item: DownloadQueueState.Item) async -> Bool {
        while setup.isDownloadingModel {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard isStillWanted(item) else { return false }
        }
        return isStillWanted(item)
    }

    private func watch(_ status: Published<String>.Publisher) {
        status.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.detail = $0 }
            .store(in: &watches)
    }

    /// Not enough free space for the item: the reason, else nil.
    private func spaceRefusal(_ item: DownloadQueueState.Item, at path: String) -> String? {
        let free = HardwareProbe.freeDiskBytes(at: path)
        guard !DownloadQueueState.hasRoom(for: item.approxBytes, free: free), let bytes = item.approxBytes else { return nil }
        return String(format: NSLocalizedString("Not enough free disk space: %@ needs about %@, %@ is free.", comment: "download queue: item, size, free space"),
                      Self.name(of: item), ModelCatalog.format(bytes), free.map(ModelCatalog.format) ?? "?")
    }

    /// What an item is, for its row and its messages.
    static func name(of item: DownloadQueueState.Item) -> String {
        switch item.kind {
        case .chatModel: return item.target
        case .imageModel, .editModel: return ImageGenModel(rawValue: item.target)?.displayName ?? item.target
        case .musicModel: return MusicModel(rawValue: item.target)?.displayName ?? item.target
        case .embedder: return FeatureSetup.shared.projectFilesEmbedder.flatMap { $0.id == item.target ? $0.displayName : nil } ?? item.target
        }
    }

    // MARK: - The chat model

    private func runChatModel(_ item: DownloadQueueState.Item) async -> String? {
        let repo = item.target
        if Self.isComplete(repo, root: ModelDiscovery.currentModelsRoot()) { return nil }
        // The Hub's size and access: the free-space check, and the
        // browser's gated-without-a-token message instead of a 401.
        let lookup = Task { await Self.hubInfo(repo) }
        hubLookup = lookup
        let hub = await lookup.value
        hubLookup = nil
        guard isStillWanted(item) else { return nil }
        if let info = hub {
            browser.infoByID[repo] = info.info
            if let bytes = info.filesBytes { state.setApproxBytes(item.id, bytes) }
        }
        // A download the user started in the Hugging Face window runs first
        // -- it may be this very repo, and it takes disk space. From here
        // to browser.download nothing awaits: none can start in between.
        while browser.downloadingID != nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard isStillWanted(item) else { return nil }
        }
        guard isStillWanted(item) else { return nil }
        // The folder as it is now (Settings may have changed it), fixed for
        // the download: the space, the marker and the files all go by it.
        let root = ModelDiscovery.currentModelsRoot()
        if Self.isComplete(repo, root: root) { return nil }
        if let refusal = spaceRefusal(state.item(item.id) ?? item, at: root) { return refusal }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            chatDownload = continuation
            browser.download(HFModelSummary(modelId: repo, downloads: nil, likes: nil, lastModified: nil), root: root) { [weak self] in
                NotificationCenter.default.post(name: .modelsDidChange, object: repo)
                // The marker is what a later run (a relaunch) goes by.
                self?.endChatDownload(Self.isComplete(repo, root: root) ? nil
                    : NSLocalizedString("The model downloaded, but its folder couldn't be marked complete.", comment: ""))
            }
            // Refused before it started (a gated repo without a token).
            guard browser.downloadingID == repo else {
                endChatDownload(browser.downloadError ?? NSLocalizedString("The download didn't start.", comment: ""))
                return
            }
            ownsBrowserDownload = true
            browser.$downloadProgress.receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.state.setProgress(item.id, $0) }
                .store(in: &watches)
            browser.$downloadStatusText.receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.detail = $0 }
                .store(in: &watches)
            // Ended without completing: failed or cancelled.
            browser.$downloadingID.receive(on: DispatchQueue.main)
                .dropFirst()
                .filter { $0 == nil }
                .sink { [weak self] _ in
                    guard let self else { return }
                    // The completion runs just after downloadingID clears.
                    DispatchQueue.main.async {
                        self.endChatDownload(self.browser.downloadError ?? NSLocalizedString("The download stopped.", comment: ""))
                    }
                }
                .store(in: &watches)
        }
    }

    /// Every file of the repo is in place: the browser's completion marker,
    /// written last. A config.json alone (ModelDiscovery.isDownloaded) may
    /// be from a download interrupted part way; one without the marker
    /// (copied in by hand, LM Studio's) is downloaded over -- the browser
    /// replaces each file.
    static func isComplete(_ repo: String, root: String) -> Bool {
        FileManager.default.fileExists(atPath: root + "/" + repo + "/" + HFModelBrowser.completionMarkerName)
    }

    private func endChatDownload(_ error: String?) {
        ownsBrowserDownload = false
        guard let continuation = chatDownload else { return }
        chatDownload = nil
        continuation.resume(returning: error)
    }

    /// The Hub's license, access and current files' size for `repo`; nil
    /// when it can't be read (offline, unknown repo).
    static func hubInfo(_ repo: String) async -> (info: HubModelInfo, filesBytes: Int64?)? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        HFToken.authorize(&request)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let info = HubModelInfo.parse(data) else { return nil }
        return (info, HubModelInfo.filesSize(data))
    }
}
