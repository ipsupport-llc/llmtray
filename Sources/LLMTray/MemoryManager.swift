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
        guard let data = FileManager.default.contents(atPath: Self.path) else {
            file = MemoryFile()
            unreadable = false
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
    func change(_ apply: (inout MemoryFile) -> Void) {
        guard !unreadable else { return }
        var updated = file
        apply(&updated)
        guard updated != file else { return }
        file = updated
        save()
    }

    /// Expiry, at most once an hour as chats start.
    private var lastSweep: Date?
    func sweep(now: Date = Date()) {
        if let lastSweep, now.timeIntervalSince(lastSweep) < 3600 { return }
        lastSweep = now
        let settings = settings
        change { _ = $0.sweep(now: now, settings: settings) }
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

    /// The memory block for a chat in `project` (nil: none): `current`
    /// while it still holds (the chat's prompt stays the same for the
    /// server's cache), else a new one. nil with memory off, an unreadable
    /// store, or no note to send. `tokens` counts as the chat's estimate does.
    func snapshot(current: MemorySnapshot?, project: UUID?, tokens: (String) -> Int) -> MemorySnapshot? {
        let settings = settings
        guard settings.enabled, !unreadable else { return nil }
        sweep()
        let budget = settings.budgetTokens
        if let current, MemorySelection.isCurrent(current, file: file, settings: settings, project: project, budget: budget) {
            return current
        }
        return MemorySelection.choose(file, settings: settings, project: project, budget: budget, now: Date(), tokens: tokens)
    }
}
