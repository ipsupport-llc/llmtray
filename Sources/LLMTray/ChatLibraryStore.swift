import Combine
import Foundation
import LLMTrayCore

/// The saved chats as the sidebar lists them, and their pins and projects
/// (library.json next to the session files). Read in full once, off the
/// main thread; after that only the chat a save or delete names is read
/// again -- every turn saves its chat.
@MainActor
final class ChatLibraryStore: ObservableObject {
    static let shared = ChatLibraryStore()

    @Published private(set) var chats: [ChatSummary] = []
    @Published private(set) var library = ChatLibrary()
    @Published private(set) var isLoaded = false

    private var libraryPath: String { ChatSessionStore.sessionsDir + "/library.json" }
    private var observer: AnyCancellable?
    private var isLoadingAll = false
    private var changedWhileLoading: Set<UUID> = []

    /// Projects' own directories (adr/0012).
    static let projectStorage = ProjectStorage(root: RuntimePaths.externalRuntimeDir + "/projects")

    private init() {
        let (library, state) = Self.readLibrary(at: libraryPath)
        self.library = library
        finishProjectDeletions(libraryState: state)
        observer = NotificationCenter.default.publisher(for: .sessionsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reload($0.object as? UUID) }
        reload(nil)
    }

    // MARK: - Reading

    /// `id`: just that chat (saved or deleted); nil: all of them.
    func reload(_ id: UUID?) {
        guard let id else {
            isLoadingAll = true
            Task.detached(priority: .utility) {
                let all = ChatSessionStore.list().map(Self.summary)
                let onDisk = ChatSessionStore.ids()
                await MainActor.run {
                    self.chats = all
                    self.isLoaded = true
                    self.isLoadingAll = false
                    // Saved or deleted while the list was read: its snapshot
                    // may be older.
                    let changed = self.changedWhileLoading
                    self.changedWhileLoading = []
                    changed.forEach { self.reload($0) }
                    if let onDisk {
                        self.pruneLibrary(onDisk: onDisk.union(changed.filter { ChatSessionStore.exists($0) }))
                    }
                }
            }
            return
        }
        if isLoadingAll { changedWhileLoading.insert(id) }
        chats.removeAll { $0.id == id }
        if let file = ChatSessionStore.load(id: id) {
            chats.append(Self.summary(file))
            chats.sort { $0.updatedAt > $1.updatedAt }
        } else {
            forgetInLibrary(id)
        }
    }

    nonisolated private static func summary(_ file: ChatSessionFile) -> ChatSummary {
        // Title and text, capped: a search needn't scan a book per chat.
        var text = file.title
        var length = text.utf8.count
        for message in file.messages {
            guard length < 40_000 else { break }
            text += "\n" + message.content
            length += message.content.utf8.count + 1
        }
        return ChatSummary(id: file.id, title: file.title, updatedAt: file.updatedAt, searchText: text.lowercased())
    }

    /// A pinned chat shows under Pinned only.
    func chats(inProject project: UUID) -> [ChatSummary] {
        chats.filter { library.projectOfChat[$0.id] == project && !library.isPinned($0.id) }
    }

    var pinnedChats: [ChatSummary] {
        library.pinned.compactMap { id in chats.first { $0.id == id } }
    }

    /// Recents: neither pinned nor in a project.
    var recentChats: [ChatSummary] {
        chats.filter { !library.isPinned($0.id) && library.projectOfChat[$0.id] == nil }
    }

    // MARK: - Changes

    /// Through its ChatClient when it's open in a tab (its next turn
    /// rewrites the file with the title it holds).
    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let tabs = ChatTabs.shared
        if let index = tabs.index(of: id) {
            tabs.tabs[index].renameCurrentSession(title)
        } else {
            ChatSessionStore.rename(id: id, to: title)
        }
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        library.setPinned(id, pinned)
        saveLibrary()
    }

    func move(_ id: UUID, to project: UUID?) {
        library.move(id, to: project)
        saveLibrary()
    }

    @discardableResult
    func addProject(named name: String) -> ChatLibrary.Project? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let project = library.addProject(named: name)
        saveLibrary()
        return project
    }

    func renameProject(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        library.renameProject(id, to: name)
        saveLibrary()
    }

    /// Applies from the next message of its chats.
    func setInstructions(_ id: UUID, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let project = library.project(id), project.instructions != text else { return }
        library.setInstructions(id, text)
        saveLibrary()
    }

    /// Its chats stay, projectless from their next message (open tabs
    /// too); its directory goes, through a deletion record, so a crash
    /// halfway is finished at the next launch.
    func deleteProject(_ id: UUID) {
        let storage = Self.projectStorage
        // Its directory can't be deleted safely (no record could be
        // written): the project stays, as it is.
        guard storage.beginDeletion(id) else { return }
        ProjectInstructionsWindow.close(id)
        library.deleteProject(id)
        // Not saved (a full disk): the project would come back at the next
        // launch without its directory. The record finishes it then.
        guard saveLibrary() else { return }
        storage.finishDeletion(id)
    }

    /// Deletions a crash left halfway: the project out of the library
    /// first, then its directory. Not when library.json couldn't be read.
    private func finishProjectDeletions(libraryState: ProjectStorage.LibraryState) {
        let storage = Self.projectStorage
        let pending = storage.pendingDeletions(library: libraryState)
        guard !pending.isEmpty else { return }
        let stillListed = pending.filter { library.project($0) != nil }
        stillListed.forEach { library.deleteProject($0) }
        if !stillListed.isEmpty { guard saveLibrary() else { return } }
        pending.forEach { storage.finishDeletion($0) }
    }

    /// A tab showing it forgets it first (starting a new chat there saves
    /// the current one, which would bring the deleted chat back).
    func delete(_ id: UUID) {
        let tabs = ChatTabs.shared
        if let index = tabs.index(of: id) {
            let chat = tabs.tabs[index]
            chat.forgetCurrentSession()
            chat.newSession()
        }
        ChatSessionStore.delete(id: id)
    }

    // MARK: - library.json

    private func forgetInLibrary(_ id: UUID) {
        guard library.isPinned(id) || library.projectOfChat[id] != nil else { return }
        library.forget(id)
        saveLibrary()
    }

    /// By the files there are, not the ones that decoded: a chat that
    /// failed to read keeps its pin and project. A chat open in a tab keeps
    /// its project too: one started in a project has no file until its
    /// first turn.
    private func pruneLibrary(onDisk: Set<UUID>) {
        var pruned = library
        pruned.prune(existing: onDisk.union(ChatTabs.shared.tabs.compactMap(\.currentSessionID)))
        guard pruned != library else { return }
        library = pruned
        saveLibrary()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// An unreadable file loads as empty, as it always has -- and says so,
    /// so nothing is deleted on the strength of it.
    private static func readLibrary(at path: String) -> (ChatLibrary, ProjectStorage.LibraryState) {
        guard FileManager.default.fileExists(atPath: path) else { return (ChatLibrary(), .missing) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: path),
              let library = try? decoder.decode(ChatLibrary.self, from: data) else { return (ChatLibrary(), .unreadable) }
        return (library, .loaded)
    }

    /// True once it's on disk.
    @discardableResult
    private func saveLibrary() -> Bool {
        try? FileManager.default.createDirectory(atPath: ChatSessionStore.sessionsDir, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(library) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: libraryPath), options: .atomic)) != nil
    }
}
