import Foundation
import LLMTrayCore

/// The chat's tool-call counts (ToolCallStats), per app version, in
/// Application Support/LLMTray/tool_call_stats.json: shown in Settings >
/// Server, counted into a bug report, never sent by themselves.
@MainActor
final class ToolStatsStore: ObservableObject {
    static let shared = ToolStatsStore(url: URL(fileURLWithPath: RuntimePaths.externalRuntimeDir).appendingPathComponent("tool_call_stats.json"))

    /// Not written anywhere (the CLI's runs, tests).
    static func inMemory() -> ToolStatsStore { ToolStatsStore(url: nil) }

    @Published private(set) var stats: ToolCallStats
    private let url: URL?
    private var saveTask: Task<Void, Never>?

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    init(url: URL?) {
        self.url = url
        stats = url.map(ToolCallStats.load) ?? ToolCallStats()
    }

    /// This version's counts, busiest tool first.
    var current: [(tool: String, counts: ToolCallStats.Counts)] {
        (stats.versions[Self.version]?.tools ?? [:])
            .sorted { $0.value.calls != $1.value.calls ? $0.value.calls > $1.value.calls : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    func record(tool: String?, known: Bool, repairs: [ToolRepair], outcome: ToolCallStats.Outcome) {
        stats.record(tool: tool, known: known, version: Self.version, repairs: repairs, outcome: outcome)
        scheduleSave()
    }

    func reset() {
        stats = ToolCallStats()
        scheduleSave(delay: 0)
    }

    /// Written a moment later: a round of calls is one write.
    private func scheduleSave(delay: UInt64 = 2_000_000_000) {
        guard let url else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let stats = self?.stats else { return }
            try? stats.save(to: url)
        }
    }
}
