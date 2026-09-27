import AppKit
import Foundation
import LLMTrayCore

/// Opt-in usage statistics (adr/0015): off until the user turns it on in
/// Settings → General. Counts uses per local day and sends each finished
/// day once, at launch and every few hours; today's goes after it ends.
/// Off stops sending at once and erases what wasn't sent; on again makes
/// a new install ID. A temporary chat counts nothing: its callers don't
/// record.
@MainActor
final class UsageTelemetry: ObservableObject {
    static let shared = UsageTelemetry()

    /// How often, while running, finished days are looked for.
    static let interval: TimeInterval = 3 * 3600
    /// After launch: not in the way of the app starting.
    static let launchDelay: TimeInterval = 60

    @Published private(set) var isEnabled: Bool
    @Published private(set) var installID: UUID?

    private let defaults: UserDefaults
    private let store: TelemetryCounterStore
    private let uploader: TelemetryUploader
    private var timer: Timer?
    private var sendTask: Task<Void, Never>?
    /// Bumped by each send and by turning off: a cancelled send finishing
    /// late doesn't clear a newer one.
    private var sendGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        store = TelemetryCounterStore(url: dir.appendingPathComponent("LLMTray/telemetry.json"))
        // LLMTRAY_TELEMETRY_ENDPOINT: a local server to develop against;
        // nothing is ever sent to ipsupport.us from a test.
        let endpoint = ProcessInfo.processInfo.environment["LLMTRAY_TELEMETRY_ENDPOINT"].flatMap(URL.init(string:))
            ?? TelemetryClient.endpoint
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        uploader = TelemetryUploader(client: TelemetryClient(endpoint: endpoint, userAgent: "LLMTray/" + version))
        isEnabled = defaults[Pref.telemetryEnabled]
        installID = defaults[Pref.telemetryInstallID].flatMap(UUID.init(uuidString:))
        if isEnabled, installID == nil { regenerateID() }
        if !isEnabled, installID != nil || !store.counters.days.isEmpty { turnOff() }
    }

    // MARK: - Settings

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        if on {
            isEnabled = true
            defaults[Pref.telemetryEnabled] = true
            regenerateID()
            touchToday()
            schedule()
        } else {
            turnOff()
        }
    }

    /// A new install ID; what's unsent goes with it. A send in flight is
    /// cancelled: nothing goes out under the old ID after this.
    func resetID() {
        guard isEnabled else { return }
        cancelSend()
        // The counts gathered under the old ID go too: sent under the new
        // one they'd tie the two together (and a day in flight twice).
        store.erase()
        regenerateID()
    }

    private func cancelSend() {
        sendTask?.cancel()
        sendTask = nil
        sendGeneration += 1
    }

    private func regenerateID() {
        let id = UUID()
        installID = id
        defaults[Pref.telemetryInstallID] = id.uuidString
    }

    private func turnOff() {
        isEnabled = false
        defaults[Pref.telemetryEnabled] = false
        defaults[Pref.telemetryInstallID] = nil
        installID = nil
        cancelSend()
        timer?.invalidate()
        timer = nil
        store.erase()
    }

    // MARK: - Counting

    /// One use of `feature` today, with the family of the model it used
    /// (a path or repo: only its family is kept). Nothing when off.
    func record(_ feature: TelemetryFeature, model: String? = nil) {
        guard isEnabled else { return }
        let family = model.flatMap { $0.isEmpty ? nil : TelemetryModelFamily.of(model: $0) }
        store.update { $0.record(feature, family: family, on: TelemetryDay.string(for: Date())) }
    }

    private func touchToday() {
        store.update { $0.touch(TelemetryDay.string(for: Date())) }
    }

    // MARK: - Sending

    /// At launch: a first look shortly after, then every few hours.
    func start() {
        guard isEnabled else { return }
        touchToday()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        // Target/selector, not a closure (adr/0008: CI's toolchain).
        let first = Timer(fireAt: Date().addingTimeInterval(Self.launchDelay), interval: Self.interval, target: self,
                          selector: #selector(tick), userInfo: nil, repeats: true)
        first.tolerance = 60
        RunLoop.main.add(first, forMode: .common)
        timer = first
    }

    @objc private func tick() {
        guard isEnabled, sendTask == nil else { return }
        touchToday()   // running today
        sendGeneration += 1
        let generation = sendGeneration
        sendTask = Task { [weak self] in
            guard let self else { return }
            await self.uploader.run(store: self.store, installID: { [weak self] in
                guard let self, self.isEnabled else { return nil }
                return self.installID
            }, environment: { TelemetryEnvironment.current() })
            if generation == self.sendGeneration { self.sendTask = nil }
        }
    }
}
