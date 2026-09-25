import LLMTrayCore
import SwiftUI

// `@AppStorage(Pref.port) var port` -- the key's name and default come from
// LLMTrayCore.Pref, declared once.
extension AppStorage where Value == Int {
    init(_ key: PrefKey<Int>, store: UserDefaults? = nil) {
        self.init(wrappedValue: key.defaultValue, key.name, store: store)
    }
}

extension AppStorage where Value == Bool {
    init(_ key: PrefKey<Bool>, store: UserDefaults? = nil) {
        self.init(wrappedValue: key.defaultValue, key.name, store: store)
    }
}

extension AppStorage where Value == String? {
    init(_ key: PrefKey<String?>, store: UserDefaults? = nil) {
        self.init(key.name, store: store)
    }
}

extension OperationAvailability {
    /// The app's current activity, read from the objects that own it. Any
    /// chat tab's turn counts, not just the one on screen.
    @MainActor
    init(server: ServerManager, benchmark: BenchmarkRunner) {
        let phase: ActivitySnapshot.Server
        switch server.state {
        case .stopped: phase = server.isIdleUnloaded ? .idleUnloaded : .stopped
        case .starting: phase = .starting
        case .running: phase = .running
        case .failed: phase = .failed
        }
        self.init(ActivitySnapshot(
            server: phase, serverBusy: server.isBusy, chatBusy: ChatTabs.shared.isAnyBusy, benchmarkRunning: benchmark.isRunning
        ))
    }
}
