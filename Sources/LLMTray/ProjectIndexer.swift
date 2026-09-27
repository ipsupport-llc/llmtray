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
/// Linked folders (v1b) and the Files view (PR 3.5) come later; this is
/// what they call.
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

    /// Anything indexing (the menu bar's dot, 3.5).
    var isAnyIndexing: Bool { progress.values.contains { $0.state == .running || $0.state == .waiting } }

    var isEmbedderReady: Bool { embedderReady }

    /// project_files' work, over this registry and the embedder's runner.
    private(set) lazy var filesService = ProjectFilesService(environment: .init(
        registry: registry,
        queryEmbedder: { [weak self] in self?.currentEmbedder() as? RunnerEmbedder },
        wordsOnlyReason: { [weak self] in self?.ingestor?.embeddingUnavailable }))

    /// A project's file counts for a turn's start (which project_files modes
    /// it declares): read-only, without opening a closed project; `.empty`
    /// while the feature is off or when they can't be read.
    func summary(for project: UUID) async -> ProjectIndexSummary {
        guard isEnabled else { return .empty }
        return (try? await registry.summary(for: project)) ?? .empty
    }

    /// Where a citation chip leads: read-only from the project's index,
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
            embeddingUnavailable = nil
            return
        }
        var next: [UUID: ProjectIndexProgress] = [:]
        for project in ChatLibraryStore.shared.library.projects {
            let p = ingestor.progress(for: project.id)
            if p.isActive { next[project.id] = p }
        }
        if next != progress { progress = next }
        if ingestor.documents != documents { documents = ingestor.documents }
        if ingestor.embeddingUnavailable != embeddingUnavailable { embeddingUnavailable = ingestor.embeddingUnavailable }
    }

    private static func load(_ key: PrefKey<[String]>) -> Set<UUID> {
        Set(UserDefaults.standard[key].compactMap(UUID.init(uuidString:)))
    }

    // MARK: - what the Files view (3.5) calls

    /// Copies the files into the project and queues them.
    func add(_ urls: [URL], to project: UUID) async -> [ProjectIngestor.AddResult] {
        guard let ingestor, ChatLibraryStore.shared.library.project(project) != nil else {
            return urls.map { _ in .failed(NSLocalizedString("Project files are turned off in Settings.", comment: "")) }
        }
        return await ingestor.add(urls, to: project)
    }

    func pause(_ project: UUID) { ingestor?.pause(project) }
    func resume(_ project: UUID) { ingestor?.resume(project) }
    func stop(_ project: UUID) async { await ingestor?.stop(project) }
    func indexNow(_ project: UUID) async { await ingestor?.indexNow(project) }
    func isPaused(_ project: UUID) -> Bool { ingestor?.paused.contains(project) ?? false }

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
