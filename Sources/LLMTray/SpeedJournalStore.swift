import Foundation
import LLMTrayCore

/// The speed journal (LLMTrayCore.SpeedJournal) on disk, fed by the
/// server's per-request log line: every request, the chat's and external
/// clients' through the proxy. Saved a few seconds after the last request,
/// not per request.
@MainActor
final class SpeedJournalStore: ObservableObject {
    static let shared = SpeedJournalStore()

    @Published private(set) var journal: SpeedJournal
    private var saveTask: Task<Void, Never>?

    static var path: String { RuntimePaths.externalRuntimeDir + "/speed-journal.json" }

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        journal = FileManager.default.contents(atPath: Self.path)
            .flatMap { try? decoder.decode(SpeedJournal.self, from: $0) } ?? SpeedJournal()
    }

    func record(_ stats: RequestStats, modelPath: String, arguments: [String]) {
        journal.add(.init(date: Date(), model: URL(fileURLWithPath: modelPath).lastPathComponent,
                          settings: SpeedJournal.settings(of: arguments), stats: stats))
        scheduleSave()
    }

    func clear() {
        journal.clear()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = journal
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(atPath: RuntimePaths.externalRuntimeDir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
        }
    }
}
