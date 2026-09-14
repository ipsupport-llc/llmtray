import Foundation
import Combine

/// Real thermal state via the public ProcessInfo API (no special
/// permissions needed). True system-wide GPU utilization would need either
/// `powermetrics` (requires sudo -- not viable to prompt for repeatedly
/// from a background menu bar app) or the private IOReport framework (used
/// by tools like Stats.app/asitop, undocumented and fragile across macOS
/// versions) -- neither is worth the complexity/risk here, so "GPU busy"
/// is approximated as "this app's own request is actively streaming a
/// generation" instead of true hardware residency.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.thermalState = ProcessInfo.processInfo.thermalState
            }
        }
    }

    var isThrottling: Bool {
        thermalState == .serious || thermalState == .critical
    }

    /// .fair fires well before .serious -- confirmed on this machine at
    /// 99% GPU / 91°C with the clock already dropping (1360 -> 1038 MHz),
    /// while .serious/.critical stayed unset. Surfacing this as a distinct
    /// warm/orange state means the icon reacts before the (much higher)
    /// bar for "throttling" red is ever reached, instead of staying silent
    /// through most of a real heavy-load session.
    var isWarm: Bool {
        thermalState == .fair
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
