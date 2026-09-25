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

    private init() {
        library = Self.readLibrary(at: libraryPath)
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

    /// Through ChatClient when it's the chat on screen (its next turn
    /// rewrites the file with the title it holds).
    func rename(_ id: UUID, to title: String, chat: ChatClient) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if chat.currentSessionID == id {
            chat.renameCurrentSession(title)
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

    func deleteProject(_ id: UUID) {
        library.deleteProject(id)
        saveLibrary()
    }

    /// The chat on screen is forgotten first: starting a new one saves the
    /// current one, which would bring the deleted chat back.
    func delete(_ id: UUID, chat: ChatClient) {
        if chat.currentSessionID == id {
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
    /// failed to read keeps its pin and project.
    private func pruneLibrary(onDisk: Set<UUID>) {
        var pruned = library
        pruned.prune(existing: onDisk)
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

    private static func readLibrary(at path: String) -> ChatLibrary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: path),
              let library = try? decoder.decode(ChatLibrary.self, from: data) else { return ChatLibrary() }
        return library
    }

    private func saveLibrary() {
        try? FileManager.default.createDirectory(atPath: ChatSessionStore.sessionsDir, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(library) else { return }
        try? data.write(to: URL(fileURLWithPath: libraryPath), options: .atomic)
    }
}
