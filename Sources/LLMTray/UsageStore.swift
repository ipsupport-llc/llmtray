import Foundation
import LLMTrayCore

/// The usage statistics (UsageLedger) on disk, when turned on (Settings ›
/// Server, or the Server window's Usage tab): fed by the server's stats
/// lines like the speed journal, never sent anywhere. Written at most every
/// few seconds, and at quit.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var ledger: UsageLedger
    private var saveTask: Task<Void, Never>?
    private var dirty = false

    static let fileName = "usage.json"
    static var path: String { RuntimePaths.externalRuntimeDir + "/" + fileName }

    private init() {
        guard let data = FileManager.default.contents(atPath: Self.path) else {
            ledger = UsageLedger()
            return
        }
        if let loaded = try? JSONDecoder().decode(UsageLedger.self, from: data) {
            ledger = loaded
        } else {
            // Unreadable: kept aside, not written over by the next save.
            try? FileManager.default.removeItem(atPath: Self.path + ".unreadable")
            try? FileManager.default.moveItem(atPath: Self.path, toPath: Self.path + ".unreadable")
            ledger = UsageLedger()
        }
    }

    var isEnabled: Bool { UserDefaults.standard[Pref.usageStatsEnabled] }

    /// `date`: when the server reported it (a line held back during a
    /// benchmark comes later).
    func record(_ stats: RequestStats, modelPath: String, at date: Date) {
        ledger.record(stats, model: URL(fileURLWithPath: modelPath).lastPathComponent, at: date)
        dirty = true
        guard saveTask == nil else { return }
        scheduleSave(after: 3)
    }

    func clear() {
        ledger.clear()
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

    private func scheduleSave(after seconds: Double) {
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.save()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(ledger)
            try FileManager.default.createDirectory(atPath: RuntimePaths.externalRuntimeDir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
            dirty = false
        } catch {
            dirty = true
            if saveTask == nil { scheduleSave(after: 30) }
        }
    }
}
