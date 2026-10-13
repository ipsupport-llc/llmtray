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
        let removed = Set(file.notes.map(\.id)).subtracting(updated.notes.map(\.id))
        file = updated
        save()
        if !removed.isEmpty { dropFromChats(removed) }
        return !saveFailed
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

    private func save() {
        do {
            try FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(file)
            // Atomic: a crash mid-write mustn't lose the notes.
            try data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
            saveFailed = false
        } catch {
            saveFailed = true
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
