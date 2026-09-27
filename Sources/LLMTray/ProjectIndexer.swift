import Combine
import Foundation
import LLMTrayCore

/// Project files' indexing, app-wide (adr/0012): one `ProjectIngestor`
/// (LLMTrayCore, where its logic and tests are) wired to the app -- the
/// supervised extractor (this binary, `--extract`), the embedder's shared
/// runner (EmbedderManager), `GenerationQueue.shared`'s background lane, and
/// the chat model's activity (any request through the proxy, or a chat tab
/// streaming), which every step waits out.
///
/// Off until the feature is turned on in Settings (`Pref.projectFilesEnabled`):
/// then nothing is opened, indexed or started. On, the projects that have
/// an index are opened at launch -- the reconcile finishes what a crash
/// left, and staged files and missing embeddings are queued. Without the
/// embedder installed documents stay searchable by their words and are
/// embedded once it is. Pause and Stop persist across a relaunch.
///
/// The Files view, the sidebar's ring and the menu bar's dot (PR 3.5) read
/// what's published here; linked folders (v1b) come later.
@MainActor
final class ProjectIndexer: ObservableObject {
    static let shared = ProjectIndexer()

    @Published private(set) var isEnabled: Bool
    /// Projects with indexing under way, paused or waiting (idle ones are absent).
    @Published private(set) var progress: [UUID: ProjectIndexProgress] = [:]
    /// Each opened project's documents (none removing).
    @Published private(set) var documents: [UUID: [IndexedDocument]] = [:]
    /// Why embedding is off this session, when it is (the embedder failed).
    @Published private(set) var embeddingUnavailable: String?
    /// Paused by the user, and stopped (Index Now resumes): kept across a relaunch.
    @Published private(set) var paused: Set<UUID> = []
    @Published private(set) var stopped: Set<UUID> = []
    /// What the last add to a project said about the files it didn't take
    /// (not supported, duplicates, failures), until it's dismissed or
    /// replaced by the next add's.
    @Published private(set) var addNotes: [UUID: String] = [:]
    /// Each opened project's pinned documents, in pin order (adr/0012,
    /// "Pinned files"), and each searchable document's pinned size in
    /// bytes (measured once per revision, off the main thread; tokens at
    /// the model's ratio, `pinTokens`).
    @Published private(set) var pins: [UUID: [Int64]] = [:]
    @Published private(set) var pinBytes: [UUID: [Int64: Int]] = [:]
    /// Each model's bytes-a-token samples from the server's counts
    /// (PinTokenRatios), here so the Files window redraws when one comes.
    @Published private(set) var pinTokenSamples = PinTokenRatios().samples
    /// The revision each size in `pinBytes` was measured at.
    private var pinTokenRevs: [UUID: [Int64: Int64]] = [:]
    private var pinRefreshes: [UUID: Task<Void, Never>] = [:]

    /// One writer and one reader per open project, for the indexer and
    /// (3.4b-ii) the project tools alike.
    let registry = ProjectIndexRegistry(directory: { URL(fileURLWithPath: ChatLibraryStore.projectStorage.directory(for: $0)) })
    let embedders = EmbedderManager()

    private var ingestor: ProjectIngestor?
    private var embedder: RunnerEmbedder?
    /// The default entry and whether it's installed, read at activation and
    /// whenever a download or removal ends (not at every progress update).
    private var entry: EmbedderEntry?
    private var embedderReady = false
    private var isForegroundBusy: () -> Bool = { false }
    private var watches: Set<AnyCancellable> = []
    private var started = false
    /// The previous activation's handles closing (off the main thread);
    /// the next activation opens nothing before it's done.
    private var closing: Task<Void, Never>?

    private init() {
        isEnabled = UserDefaults.standard[Pref.projectFilesEnabled]
    }

    /// At launch, after the library is read (its pending deletions finished).
    func start(server: ServerManager) {
        guard !started else { return }
        started = true
        isForegroundBusy = { [weak server] in (server?.isBusy ?? false) || ChatTabs.shared.isAnyStreaming }
        // A download or removal of the embedder ended.
        embedders.$isBusy.removeDuplicates().dropFirst().filter { !$0 }
            .sink { [weak self] _ in Task { @MainActor in await self?.embedderChanged() } }
            .store(in: &watches)
        if isEnabled { activate() }
    }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        UserDefaults.standard[Pref.projectFilesEnabled] = on
        guard started else { return }
        if on { activate() } else { deactivate() }
    }

    /// Anything indexing (the menu bar's dot), waiting included; not paused.
    var isAnyIndexing: Bool { Self.isIndexing(progress) }

    /// The rule itself, for a publisher's new value (`$progress` emits before it's set).
    nonisolated static func isIndexing(_ progress: [UUID: ProjectIndexProgress]) -> Bool {
        progress.values.contains { $0.state == .running || $0.state == .waiting }
    }

    var isEmbedderReady: Bool { embedderReady }

    /// project_files' work, over this registry and the embedder's runner.
    private(set) lazy var filesService = ProjectFilesService(environment: .init(
        registry: registry,
        queryEmbedder: { [weak self] in self?.currentEmbedder() as? RunnerEmbedder },
        wordsOnlyReason: { [weak self] in self?.ingestor?.embeddingUnavailable },
        setPinned: { [weak self] project, doc, on in try await self?.setPinned(doc, on, in: project) }))

    /// A project's file counts for a turn's start (which project_files modes
    /// it declares): read-only, without opening a closed project; `.empty`
    /// while the feature is off or when they can't be read.
    func summary(for project: UUID) async -> ProjectIndexSummary {
        guard isEnabled else { return .empty }
        return (try? await registry.summary(for: project)) ?? .empty
    }

    /// A project's pinned files for a turn's start: read-only, without
    /// opening a closed project; none while the feature is off or when they
    /// can't be read.
    func pinnedFiles(for project: UUID) async -> (files: [PinnedFileText], notes: [PinnedFileNote]) {
        guard isEnabled else { return ([], []) }
        return (try? await registry.pinnedFiles(for: project)) ?? ([], [])
    }

    /// Where a citation link leads: read-only from the project's index,
    /// also while the feature is off.
    static func citationTarget(_ c: Citation) async -> CitationTarget {
        let dir = URL(fileURLWithPath: ChatLibraryStore.projectStorage.directory(for: c.project))
        return await Task.detached(priority: .userInitiated) { CitationTarget.resolve(c, projectDirectory: dir) }.value
    }

    /// The cited chunk's text, for the PDF viewer's highlight: read-only too.
    static func citationQuote(_ c: Citation) async -> String? {
        let dir = URL(fileURLWithPath: ChatLibraryStore.projectStorage.directory(for: c.project))
        return await Task.detached(priority: .userInitiated) { CitationTarget.quote(c, projectDirectory: dir) }.value
    }

    // MARK: - wiring

    private func activate() {
        refreshEmbedder()
        let ingestor = ProjectIngestor(
            environment: ProjectIngestor.Environment(
                registry: registry,
                extract: { url in
                    guard let executable = Bundle.main.executablePath else { throw ExtractionError.crashed("no executable path") }
                    return try await DocumentExtraction.run(executable: executable, url: url)
                },
                embedder: { [weak self] in self?.currentEmbedder() },
                queue: GenerationQueue.shared,
                isForegroundBusy: { [weak self] in self?.isForegroundBusy() ?? false },
                citedPages: { await ProjectIndexer.citedPages(in: $0) }),
            paused: Self.load(Pref.projectIndexPaused), stopped: Self.load(Pref.projectIndexStopped))
        ingestor.onPersist = { paused, stopped in
            UserDefaults.standard[Pref.projectIndexPaused] = paused.map(\.uuidString).sorted()
            UserDefaults.standard[Pref.projectIndexStopped] = stopped.map(\.uuidString).sorted()
        }
        ingestor.onChange = { [weak self] in self?.publish() }
        self.ingestor = ingestor
        // A generation's grant stops the embed runner (its memory freed for
        // the generation); while one runs or waits, the runner is paused and
        // a search's query goes lexical-only instead of restarting it.
        GenerationQueue.shared.onInteractiveGrant = { [weak self] in
            await self?.embedder?.runner.stopAndWait()
        }
        GenerationQueue.shared.onInteractiveDemand = { [weak self] demand in
            self?.embedder?.runner.setPaused(demand)
        }
        let projects = ChatLibraryStore.shared.library.projects.map(\.id)
        let storage = ChatLibraryStore.projectStorage
        let previous = closing
        Task { @MainActor [weak self] in
            await previous?.value
            for id in projects where FileManager.default.fileExists(atPath: storage.directory(for: id) + "/" + ProjectIndex.databaseName) {
                // Turned off (or off and on again) meanwhile: this one's done.
                guard let self, self.ingestor === ingestor else { return }
                if let error = await ingestor.open(id) {
                    NSLog("LLMTray: project index %@ couldn't be opened: %@", id.uuidString, "\(error)")
                }
            }
        }
    }

    private func deactivate() {
        ingestor?.shutdown()
        ingestor = nil
        GenerationQueue.shared.onInteractiveGrant = nil
        GenerationQueue.shared.onInteractiveDemand = nil
        embedder?.runner.stop()
        embedder = nil
        let registry = registry
        let previous = closing
        closing = Task.detached(priority: .utility) {
            await previous?.value
            registry.closeAll()
        }
        publish()
    }

    private func refreshEmbedder() {
        entry = try? embedders.defaultEntry()
        embedderReady = entry.map(embedders.isReady) ?? false
        if !embedderReady {
            embedder?.runner.stop()
            embedder = nil
        }
    }

    /// The default entry's shared runner, when installed.
    private func currentEmbedder() -> ProjectEmbedder? {
        guard isEnabled, embedderReady, let entry else { return nil }
        if let embedder, embedder.entry == entry { return embedder }
        let runner = embedders.makeRunner(entry)
        // Wired while a generation runs: paused from the start.
        runner.setPaused(GenerationQueue.shared.hasInteractiveDemand)
        let made = RunnerEmbedder(runner: runner, entry: entry)
        embedder = made
        return made
    }

    /// Downloaded, repaired or removed: embedding resumes, or stops.
    func embedderChanged() async {
        refreshEmbedder()
        embedder?.runner.resetBackoff()
        await ingestor?.embedderChanged()
    }

    private func publish() {
        guard let ingestor else {
            if !progress.isEmpty { progress = [:] }
            if !documents.isEmpty { documents = [:] }
            if !paused.isEmpty { paused = [] }
            if !stopped.isEmpty { stopped = [] }
            pinRefreshes.values.forEach { $0.cancel() }
            pinRefreshes = [:]
            if !pins.isEmpty { pins = [:] }
            if !pinBytes.isEmpty { pinBytes = [:] }
            pinTokenRevs = [:]
            if !addNotes.isEmpty { addNotes = [:] }
            embeddingUnavailable = nil
            return
        }
        var next: [UUID: ProjectIndexProgress] = [:]
        for project in ChatLibraryStore.shared.library.projects {
            let p = ingestor.progress(for: project.id)
            if p.isActive { next[project.id] = p }
        }
        if next != progress { progress = next }
        if ingestor.documents != documents {
            // A removal unpins; a re-index changes a size.
            let changed = Set(ingestor.documents.keys).union(documents.keys).filter { ingestor.documents[$0] != documents[$0] }
            documents = ingestor.documents
            for project in changed { refreshPins(project) }
        }
        if ingestor.embeddingUnavailable != embeddingUnavailable { embeddingUnavailable = ingestor.embeddingUnavailable }
        if ingestor.paused != paused { paused = ingestor.paused }
        if ingestor.stopped != stopped { stopped = ingestor.stopped }
    }

    private static func load(_ key: PrefKey<[String]>) -> Set<UUID> {
        Set(UserDefaults.standard[key].compactMap(UUID.init(uuidString:)))
    }

    // MARK: - what the Files view and the sidebar call

    /// Copies the files into the project and queues them.
    func add(_ urls: [URL], to project: UUID) async -> [ProjectIngestor.AddResult] {
        guard let ingestor, ChatLibraryStore.shared.library.project(project) != nil else {
            return urls.map { _ in .failed(NSLocalizedString("Project files are turned off in Settings.", comment: "")) }
        }
        return await ingestor.add(urls, to: project)
    }

    /// Add Files… and a drop on the project (the Files view's or the
    /// sidebar's): formats this version doesn't index and folders are
    /// refused at once, the rest copied and queued; what wasn't taken is
    /// said in `addNotes[project]`.
    func addFiles(_ urls: [URL], to project: UUID) async {
        guard isEnabled else { return }
        // Looked up off the main actor, in order.
        let sorted = await ProjectFileDrop.sort(urls)
        guard !sorted.isEmpty, isEnabled else { return }
        addNotes[project] = nil
        var notes: [String] = []
        if !sorted.notSupported.isEmpty {
            notes.append(String(format: NSLocalizedString("Not supported yet: %@. This version indexes text, Markdown, code, PDF, Word (docx, doc), ODT, RTF and HTML.",
                                                          comment: "files refused at add: their names"), Self.nameList(sorted.notSupported)))
        }
        if !sorted.folders.isEmpty {
            notes.append(String(format: NSLocalizedString("Folders can't be added yet: %@. Add the files in them instead.",
                                                          comment: "folders refused at add: their names"), Self.nameList(sorted.folders)))
        }
        if !sorted.accepted.isEmpty {
            let results = await add(sorted.accepted, to: project)
            var duplicates: [URL] = []
            var failures: [String] = []
            for (url, result) in zip(sorted.accepted, results) {
                switch result {
                case .added: break
                case .duplicate: duplicates.append(url)
                case .notSupported:
                    failures.append(String(format: NSLocalizedString("%@: not supported yet", comment: "add result: a file name"), url.lastPathComponent))
                case .failed(let why): failures.append(url.lastPathComponent + ": " + why)
                }
            }
            if !duplicates.isEmpty {
                notes.append(String(format: NSLocalizedString("Already in the project: %@.", comment: "duplicate files at add: their names"),
                                    Self.nameList(duplicates)))
            }
            if !failures.isEmpty {
                notes.append(String(format: NSLocalizedString("Couldn't be added: %@", comment: "add failures"), failures.prefix(3).joined(separator: "; ")))
            }
        }
        if !notes.isEmpty, isEnabled { addNotes[project] = notes.joined(separator: "\n") }
    }

    func dismissAddNote(_ project: UUID) { addNotes[project] = nil }

    private static func nameList(_ urls: [URL]) -> String {
        let (shown, more) = ProjectFileDrop.names(urls)
        let list = shown.map { "\u{201C}" + $0 + "\u{201D}" }.joined(separator: ", ")
        guard more > 0 else { return list }
        return String(format: NSLocalizedString("%1$@ and %2$lld more", comment: "a list of file names, then how many more"), list, Int64(more))
    }

    func pause(_ project: UUID) { ingestor?.pause(project) }
    func resume(_ project: UUID) { ingestor?.resume(project) }
    func stop(_ project: UUID) async { await ingestor?.stop(project) }
    func indexNow(_ project: UUID) async { await ingestor?.indexNow(project) }
    func reindex(_ doc: Int64, in project: UUID) async { await ingestor?.reindex(doc, in: project) }
    func isPaused(_ project: UUID) -> Bool { paused.contains(project) }

    /// The project's ring in the sidebar.
    func ring(for project: UUID) -> ProjectRing {
        guard isEnabled else { return .folder }
        return ProjectRing(progress: progress[project], failedDocuments: ProjectFileTotals(documents[project] ?? []).failed)
    }

    /// The ring's hover text, the Files view's progress line.
    func statusText(for project: UUID) -> String? {
        guard isEnabled else { return nil }
        return Self.statusText.text(progress: progress[project], failedDocuments: ProjectFileTotals(documents[project] ?? []).failed)
    }

    private static let statusText: ProjectIndexStatusText = {
        var s = ProjectIndexStatusText.Strings()
        s.indexing = NSLocalizedString("Indexing %1$lld of %2$lld files", comment: "project indexing: the file under way, the total")
        s.paused = NSLocalizedString("Paused at %1$lld of %2$lld files", comment: "project indexing: files done, the total")
        s.pausedNoCount = NSLocalizedString("Paused", comment: "project indexing")
        s.waiting = NSLocalizedString("Waiting for the chat or a generator to finish", comment: "project indexing, paused automatically")
        s.addingFiles = NSLocalizedString("Adding files", comment: "project indexing")
        s.copying = NSLocalizedString("copying", comment: "project indexing stage")
        s.reading = NSLocalizedString("reading", comment: "project indexing stage")
        s.embedding = NSLocalizedString("embedding", comment: "project indexing stage")
        s.lessThanAMinute = NSLocalizedString("less than a minute left", comment: "project indexing time left")
        s.minutesLeft = NSLocalizedString("~%lld min left", comment: "project indexing time left: minutes")
        s.hoursMinutesLeft = NSLocalizedString("~%1$lld h %2$lld min left", comment: "project indexing time left: hours, minutes")
        s.hoursLeft = NSLocalizedString("~%lld h left", comment: "project indexing time left: hours")
        s.wordsOnly = NSLocalizedString("search by words only", comment: "project indexing: no embedding model")
        s.failed = NSLocalizedString("%lld failed", comment: "project indexing: files that failed")
        s.needsALook = NSLocalizedString("%lld files couldn't be indexed", comment: "project files that failed or aren't supported")
        return ProjectIndexStatusText(strings: s)
    }()

    /// The copies' and the index's size on disk (read off the main thread).
    static func diskUsage(for project: UUID) async -> (files: Int64, index: Int64) {
        let dir = ChatLibraryStore.projectStorage.directory(for: project)
        return await Task.detached(priority: .utility) {
            let files = DiskUsage.directorySize(dir + "/files") + DiskUsage.directorySize(dir + "/staging")
            let index = ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
                let path = dir + "/" + ProjectIndex.databaseName + suffix
                return sum + (((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            return (files, index)
        }.value
    }

    /// Every project's data together (Settings).
    static func totalDiskUsage() async -> Int64 {
        let root = ChatLibraryStore.projectStorage.root
        return await Task.detached(priority: .utility) { DiskUsage.directorySize(root) }.value
    }

    // MARK: - pinned files (adr/0012, "Pinned files")

    /// Pins or unpins a file (the Files window's pin, the model's
    /// project_files pin); the published pins follow.
    func setPinned(_ doc: Int64, _ on: Bool, in project: UUID) async throws {
        guard isEnabled else { return }
        let handle = try await registry.open(project)
        try await handle.write { try $0.setPinned(doc, on) }
        refreshPins(project)
        await pinRefreshes[project]?.value
    }

    /// Reads the project's pins, then measures the searchable documents
    /// not yet measured at their revision, one at a time on the reader (a
    /// search in between isn't held up by a whole project's scan).
    private func refreshPins(_ project: UUID) {
        pinRefreshes[project]?.cancel()
        let registry = registry
        pinRefreshes[project] = Task { [weak self] in
            guard let handle = try? await registry.open(project), let pinned = try? await handle.read({ try $0.pins() }),
                  let self, !Task.isCancelled else { return }
            if self.pins[project] != pinned { self.pins[project] = pinned }
            let docs = (self.documents[project] ?? []).filter { $0.status.isSearchable }
            let live = Set(docs.map(\.doc))
            self.pinTokenRevs[project] = (self.pinTokenRevs[project] ?? [:]).filter { live.contains($0.key) }
            let kept = (self.pinBytes[project] ?? [:]).filter { live.contains($0.key) }
            if self.pinBytes[project] != kept { self.pinBytes[project] = kept }
            // Kept as they're measured (a newer refresh goes on from them),
            // shown every few files: a bulk index doesn't leave every pin
            // "measuring" until the last one.
            var measured: [(doc: Int64, rev: Int64, bytes: Int)] = []
            for d in docs where self.pinTokenRevs[project]?[d.doc] != d.rev {
                if Task.isCancelled { break }
                guard let t = try? await handle.read({ try $0.pinBytes(of: [d]) })[d.doc] else { continue }
                measured.append((d.doc, d.rev, t))
                if measured.count >= 10 {
                    self.storePinSizes(measured, in: project)
                    measured = []
                }
            }
            self.storePinSizes(measured, in: project)
        }
    }

    private func storePinSizes(_ measured: [(doc: Int64, rev: Int64, bytes: Int)], in project: UUID) {
        guard !measured.isEmpty, isEnabled else { return }
        var sizes = pinBytes[project] ?? [:]
        for m in measured {
            sizes[m.doc] = m.bytes
            pinTokenRevs[project, default: [:]][m.doc] = m.rev
        }
        pinBytes[project] = sizes
    }

    /// A project's pinned sizes in tokens for `model`: at its learned ratio.
    func pinTokens(_ project: UUID, model: String?) -> [Int64: Int] {
        PinTokenRatio.tokens(pinBytes[project] ?? [:], bytesPerToken: pinTokenSamples.bytesPerToken(model: model))
    }

    /// What `model`'s pinned files are sized at (PinTokenRatio): learned
    /// from the server's counts, the estimator's 2 bytes before any.
    static func pinBytesPerToken(model: String?) -> Double {
        PinTokenRatios().bytesPerToken(model: model)
    }

    /// Whether `model`'s pinned text was counted: the Files window says
    /// "measured", else "estimate".
    func isPinRatioMeasured(model: String?) -> Bool { pinTokenSamples.isMeasured(model: model) }

    /// The server counted `promptTokens` for a request of `model`'s: a
    /// sample of its ratio when it's large enough and has no images
    /// (`carriedPins`: one of the pinned text's own).
    func recordPromptTokens(model: String?, _ measure: PromptTokenEstimator.Measure, promptTokens: Int, carriedPins: Bool) {
        let ratios = PinTokenRatios()
        guard ratios.record(model: model, measure, promptTokens: promptTokens, carriedPins: carriedPins) else { return }
        publishPinSamples(ratios)
    }

    /// A request of `model`'s that carried pinned text failed: the next
    /// turns size pins conservatively (PinTokenRatios.recordFailure).
    func recordPinnedRequestFailed(model: String?) {
        let ratios = PinTokenRatios()
        ratios.recordFailure(model: model)
        publishPinSamples(ratios)
    }

    private func publishPinSamples(_ ratios: PinTokenRatios) {
        let samples = ratios.samples
        if pinTokenSamples != samples { pinTokenSamples = samples }
    }

    /// What the project's pinned files may take with `settings`' model: half
    /// its context less the answer, or what its KV cache can hold in the GPU
    /// memory its weights leave.
    static func pinLimit(for settings: ChatSettings) -> PinLimit {
        let kvBits: Int
        if let path = settings.modelPath, !facts(path).disallowsQuantizedKV {
            kvBits = ProfileManager.shared.resolved(for: path).kvBits
        } else {
            kvBits = 0
        }
        let kv = settings.modelPath.map { KVCacheSize.bytesPerToken(modelPath: $0, kvBits: kvBits) } ?? KVCacheSize.fallbackBytesPerToken
        return PinLimit(context: settings.maxTokensCap, maxTokens: settings.maxTokens, gpuLimitBytes: gpuLimitBytes,
                        weightsBytes: settings.modelPath.map(weightsBytes) ?? 0, kvBytesPerToken: kv,
                        share: Double(UserDefaults.standard[Pref.pinnedFilesPercent]) / 100)
    }

    /// The same for a model by its id (the Files window's, at every
    /// render): its config read once.
    static func pinLimit(forModel modelID: String?) -> PinLimit {
        let cap = modelID.map { facts($0).maxContext } ?? ChatSettings.maxContext(forModel: nil)
        var settings = ChatSettings(profile: ProfileManager.shared.resolved(for: modelID), maxTokensCap: cap)
        settings.modelPath = modelID
        return pinLimit(for: settings)
    }

    /// What a model's config says that the limit needs, read once per path.
    private static var factsCache: [String: (maxContext: Int, disallowsQuantizedKV: Bool)] = [:]

    private static func facts(_ path: String) -> (maxContext: Int, disallowsQuantizedKV: Bool) {
        if let known = factsCache[path] { return known }
        let f = (ChatSettings.maxContext(forModel: path), ModelDiscovery.disallowsQuantizedKV(forModelPath: path))
        factsCache[path] = f
        return f
    }

    /// The GPU limit, read once (a Metal device each time otherwise).
    private static let gpuLimitBytes: UInt64? = HardwareProbe.current().gpuLimitBytes
    private static var weightsCache: [String: Int64] = [:]

    private static func weightsBytes(_ path: String) -> Int64 {
        if let known = weightsCache[path] { return known }
        let bytes = ModelWeights.bytes(inFolder: path)
        weightsCache[path] = bytes
        return bytes
    }

    func removeDocument(_ doc: Int64, from project: UUID) async throws {
        guard let ingestor else { return }
        try await ingestor.removeDocument(doc, from: project)
    }

    func displayStatus(_ d: IndexedDocument, in project: UUID) -> DocumentDisplayStatus {
        ingestor?.displayStatus(d, in: project) ?? DocumentDisplayStatus(d.status)
    }

    // MARK: - lifecycle

    /// Before the project's directory is removed: its jobs cancelled and its
    /// index closed; it isn't opened again this session.
    func projectWillBeDeleted(_ project: UUID) async {
        if let ingestor {
            await ingestor.forget(project)
        } else {
            let registry = registry
            try? await ProcessRunner.offMain { registry.retire(project) }
        }
    }

    /// The app is quitting: the work stops, every index is closed cleanly
    /// (a checkpoint, then the connections), the runner told to exit.
    func shutdown() {
        ingestor?.shutdown()
        embedder?.runner.stop()
        registry.closeAll()
    }

    // MARK: - citations

    /// Every page the project's chats cite -- the saved ones and those open
    /// in tabs, including what the current turn's tools returned -- or nil
    /// when a saved chat couldn't be read, or one was saved while they were
    /// read (a tab that saved an answer and closed meanwhile would be in
    /// neither): the sweep then keeps everything, until the next one.
    static func citedPages(in project: UUID) async -> Set<PageRef>? {
        let before = ChatSessionStore.saves
        let saved = await Task.detached(priority: .utility) { ChatSessionStore.citedPages(in: project) }.value
        guard var pages = saved, ChatSessionStore.saves == before else { return nil }
        for tab in ChatTabs.shared.tabs {
            let live = ChatMessage.citationsByAnswer(tab.messages).values.flatMap { $0 } + tab.messages.flatMap(\.returnedCitations)
            for c in live where c.project == project {
                pages.insert(PageRef(doc: Int64(c.doc), rev: Int64(c.rev), page: c.page))
            }
        }
        return pages
    }
}
