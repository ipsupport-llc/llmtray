import Foundation
import LLMTrayCore

/// Memory between chats (adr/0024): the notes on disk, and the memory
/// block each chat gets. Notes are written by the user in Settings for
/// now; learning them from chats comes with the reflection pass.
@MainActor
final class MemoryManager: ObservableObject {
    static let shared = MemoryManager()

    @Published private(set) var file = MemoryFile()
    /// The notes file exists but can't be read (damaged, or written by a
    /// newer LLMTray): nothing is sent or saved, so it isn't overwritten.
    @Published private(set) var unreadable = false
    /// The last save failed.
    @Published private(set) var saveFailed = false

    static var directory: String { RuntimePaths.externalRuntimeDir + "/memory" }
    static var path: String { directory + "/notes.json" }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The newest store format this build reads.
    static let fileVersion = 1

    var settings: MemorySettings { MemorySettings(defaults: .standard) }
    var isEnabled: Bool { settings.enabled }

    private init() {
        load()
    }

    func load() {
        // No file is no notes; a file that can't be read is not.
        guard FileManager.default.fileExists(atPath: Self.path) else {
            file = MemoryFile()
            unreadable = false
            return
        }
        guard let data = FileManager.default.contents(atPath: Self.path) else {
            unreadable = true
            return
        }
        guard let decoded = try? Self.decoder.decode(MemoryFile.self, from: data), decoded.version <= Self.fileVersion else {
            unreadable = true
            return
        }
        file = decoded
        unreadable = false
        sweep()
    }

    /// Applies a change and saves it. Not while the file is unreadable.
    /// Notes it removed leave every chat's block at once, saved chats too.
    /// False when it couldn't be saved (or the file can't be read).
    @discardableResult
    func change(_ apply: (inout MemoryFile) -> Void) -> Bool {
        guard !unreadable else { return false }
        var updated = file
        apply(&updated)
        guard updated != file else { return true }
        // Saved first: a change that didn't reach the disk isn't made (a
        // watermark moved in memory only would let compaction drop what
        // the queue never kept).
        guard save(updated) else { return false }
        let removed = Set(file.notes.map(\.id)).subtracting(updated.notes.map(\.id))
        file = updated
        if !removed.isEmpty { dropFromChats(removed) }
        return true
    }

    /// The user forgets a note: its tombstone gets the text's embedding when
    /// memory has it, so a rewording isn't learned again either.
    func forget(_ id: String) {
        let vector = file.note(id).flatMap(MemoryReflector.storedVector(for:))
        change { $0.forget(id, vector: vector) }
    }

    /// "Learn from past chats now": every saved chat's messages from before
    /// memory met it are queued (adr/0024), open ones through their tab.
    /// Messages from before seqs get them, saved with the chat, so later
    /// loads number them alike. Returns how many chats got anything queued,
    /// and how many are answering (theirs is queued once they're done).
    func learnFromPastChats() -> (queued: Int, waiting: Int) {
        guard isEnabled, !unreadable else { return (0, 0) }
        var count = 0
        var open = Set<UUID>()
        var busy: [(tab: ChatClient, chat: UUID)] = []
        for tab in ChatTabs.shared.tabs {
            guard let id = tab.currentSessionID else { continue }
            open.insert(id)
            if tab.isBusy {
                if !file.optedOut.contains(id), file.pausedWatermarks[id.uuidString] == nil { busy.append((tab, id)) }
            } else if tab.queuePastForMemory() { count += 1 }
        }
        if !busy.isEmpty { learnFromPast(busy, tries: 360) }
        for id in ChatSessionStore.ids() ?? [] where !open.contains(id) {
            let key = id.uuidString
            // Opted out, or waiting for the user's answer about while memory
            // was off: nothing to do.
            guard !file.optedOut.contains(id), file.pausedWatermarks[key] == nil,
                  var chat = ChatSessionStore.load(id: id) else { continue }
            var last = max(chat.lastSeq ?? 0, chat.messages.compactMap(\.seq).max() ?? 0, file.watermark(id) ?? 0)
            var numbered = false
            for i in chat.messages.indices where chat.messages[i].role == "user" && chat.messages[i].seq == nil {
                last += 1
                chat.messages[i].seq = last
                numbered = true
            }
            if numbered {
                chat.lastSeq = last
                guard ChatSessionStore.save(chat) else { continue }
            }
            let items = MemoryBatchMessage.reading(chat.messages.map {
                MemoryBatchMessage.Turn(role: $0.role, text: $0.content, isSummary: $0.isSummary, seq: $0.seq, date: $0.sentAt, model: $0.model)
            }, readFrom: 0, date: chat.createdAt)
            let project = ChatLibraryStore.shared.library.projectContext(forChat: id)?.id
            var queued = false
            // The past, then anything after the watermark not queued yet.
            change {
                queued = $0.enqueuePast(chat: id, project: project, messages: items, now: Date())
                if $0.enqueue(chat: id, project: project, messages: items, now: Date()) { queued = true }
            }
            if queued { count += 1 }
        }
        return (count, busy.count)
    }

    /// Chats answering when "Learn from past chats now" was pressed: theirs
    /// is queued once they're done (looked at every 5 s, half an hour at most).
    /// A chat left meanwhile (another one in its tab, the tab closed) waits
    /// for the button again.
    private func learnFromPast(_ chats: [(tab: ChatClient, chat: UUID)], tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                let open = chats.filter { c in ChatTabs.shared.tabs.contains { $0 === c.tab } && c.tab.currentSessionID == c.chat }
                var queued = false
                for c in open where !c.tab.isBusy {
                    if c.tab.queuePastForMemory() { queued = true }
                }
                if queued { MemoryReflector.shared.poke(after: 1) }
                let waiting = open.filter { $0.tab.isBusy }
                if !waiting.isEmpty, tries > 1 { self.learnFromPast(waiting, tries: tries - 1) }
            }
        }
    }

    /// Expiry: at most once an hour as chats start, and at once when the
    /// settings it depends on changed.
    private var lastSweep: (date: Date, settings: MemorySettings)?
    func sweep(now: Date = Date()) {
        let settings = settings
        if let lastSweep, lastSweep.settings == settings, now.timeIntervalSince(lastSweep.date) < 3600 { return }
        lastSweep = (now, settings)
        change { _ = $0.sweep(now: now, settings: settings) }
    }

    /// Forgotten (or deleted) notes leave the chats that got them: open
    /// ones drop their block (ChatClient, synchronously, before anything
    /// saves it again), then saved ones are rewritten without it. On the
    /// main actor, as chats save there: no save races this.
    private func dropFromChats(_ ids: Set<String>) {
        NotificationCenter.default.post(name: .memoryNotesRemoved, object: nil, userInfo: ["ids": ids])
        ChatSessionStore.dropMemorySnapshots(holdingAnyOf: ids)
    }

    private func save(_ file: MemoryFile) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(file)
            // Atomic: a crash mid-write mustn't lose the notes.
            try data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
            saveFailed = false
            return true
        } catch {
            saveFailed = true
            return false
        }
    }

    /// The memory block for a chat in `project` (nil: none) on a model
    /// with `contextTokens` of context: `current`
    /// while it still holds (the chat's prompt stays the same for the
    /// server's cache), else a new one (empty when no note fits). nil with
    /// memory off or an unreadable store. `tokens` counts as the chat's
    /// estimate does.
    func snapshot(current: MemorySnapshot?, project: UUID?, contextTokens: Int?, tokens: (String) -> Int) -> MemorySnapshot? {
        let settings = settings
        guard settings.enabled, !unreadable else { return nil }
        sweep()
        let budget = MemorySelection.budget(settings, contextTokens: contextTokens)
        if let current, MemorySelection.isCurrent(current, file: file, settings: settings, project: project,
                                                  budget: budget, tokens: tokens) {
            return current
        }
        return MemorySelection.choose(file, settings: settings, project: project, budget: budget, now: Date(), tokens: tokens)
    }
}

extension Notification.Name {
    /// Memory notes were removed; userInfo "ids": Set<String>.
    static let memoryNotesRemoved = Notification.Name("LLMTray.memoryNotesRemoved")
}
