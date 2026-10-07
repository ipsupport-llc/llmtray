import Foundation
import LLMTrayCore

/// The speed journal (LLMTrayCore.SpeedJournal) on disk, fed by the
/// server's per-request log line: every request, the chat's and external
/// clients' through the proxy -- not the Benchmark tab's own runs. Written
/// at most every few seconds (a busy agent doesn't postpone it), again
/// after a failed write, and at quit.
@MainActor
final class SpeedJournalStore: ObservableObject {
    static let shared = SpeedJournalStore()

    @Published private(set) var journal: SpeedJournal
    /// Per model and settings, kept with the journal (not per view render).
    @Published private(set) var summaries: [SpeedJournal.Summary]
    private var saveTask: Task<Void, Never>?
    private var dirty = false

    static var path: String { RuntimePaths.externalRuntimeDir + "/speed-journal.json" }

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = FileManager.default.contents(atPath: Self.path)
            .flatMap { try? decoder.decode(SpeedJournal.self, from: $0) } ?? SpeedJournal()
        journal = loaded
        summaries = loaded.summaries()
    }

    func record(_ stats: RequestStats, modelPath: String, arguments: [String]) {
        journal.add(.init(date: Date(), model: URL(fileURLWithPath: modelPath).lastPathComponent,
                          settings: SpeedJournal.settings(of: arguments), stats: stats))
        changed()
    }

    func clear() {
        journal.clear()
        summaries = journal.summaries()
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// Now, e.g. at quit.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty else { return }
        save()
    }

    private func changed() {
        summaries = journal.summaries()
        dirty = true
        // A save already waiting takes this change along.
        guard saveTask == nil else { return }
        scheduleSave(after: 3)
    }

    private func scheduleSave(after seconds: Double) {
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(journal)
            try FileManager.default.createDirectory(atPath: RuntimePaths.externalRuntimeDir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
            dirty = false
        } catch {
            // Tried again in a while (and at quit).
            dirty = true
            if saveTask == nil { scheduleSave(after: 30) }
        }
    }
}
