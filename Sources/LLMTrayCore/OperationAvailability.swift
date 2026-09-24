/// What the app is doing right now, as far as deciding which operations are
/// safe goes.
public struct ActivitySnapshot: Equatable {
    public enum Server: Equatable {
        case stopped
        /// The model process was unloaded but the listener is up; the next
        /// request reloads it.
        case idleUnloaded
        case starting
        case running
        case failed
    }

    public var server: Server
    /// A request is in flight through the proxy (in-app or external).
    public var serverBusy: Bool
    /// The in-app chat is streaming, running a tool or compacting.
    public var chatBusy: Bool
    /// The benchmark / auto-tune is running (it restarts the server and
    /// writes into the loaded model's profile).
    public var benchmarkRunning: Bool

    public init(server: Server, serverBusy: Bool = false, chatBusy: Bool = false, benchmarkRunning: Bool = false) {
        self.server = server
        self.serverBusy = serverBusy
        self.chatBusy = chatBusy
        self.benchmarkRunning = benchmarkRunning
    }
}

/// One place that decides which operations are allowed, so the popover and
/// Settings can't disagree (they used to gate the same action differently).
public struct OperationAvailability: Equatable {
    public let snapshot: ActivitySnapshot

    public init(_ snapshot: ActivitySnapshot) {
        self.snapshot = snapshot
    }

    /// Something would be cut off by a restart or a model/profile change.
    public var isBusy: Bool {
        snapshot.serverBusy || snapshot.chatBusy || snapshot.benchmarkRunning
    }

    /// Restart the model process (to apply launch settings).
    public var canRestartServer: Bool {
        snapshot.server == .running && !isBusy
    }

    /// Pick another model in the popover.
    public var canSwitchModel: Bool {
        snapshot.server != .starting && !snapshot.benchmarkRunning
    }

    /// Assign a profile to a model. For the loaded model it can change the
    /// launch arguments, so also not while starting or with work in flight.
    public func canAssignProfile(toLoadedModel: Bool) -> Bool {
        guard !snapshot.benchmarkRunning else { return false }
        guard toLoadedModel else { return true }
        return snapshot.server != .starting && !isBusy
    }

    /// Edit profile values: auto-tune writes into the loaded model's profile.
    public var canEditProfiles: Bool {
        !snapshot.benchmarkRunning
    }

    /// Delete a profile (models using it fall back to Default, which can
    /// change the loaded model's launch arguments).
    public var canDeleteProfile: Bool {
        !isBusy
    }

    /// Port / LAN: the listener binds them, and it's also up while
    /// idle-unloaded.
    public var canEditNetworkSettings: Bool {
        snapshot.server == .stopped || snapshot.server == .failed
    }

    /// Update or uninstall the runtime: nothing may start the model process
    /// meanwhile -- idle-unloaded counts, the next request reloads it.
    public var canChangeRuntime: Bool {
        snapshot.server == .stopped || snapshot.server == .failed
    }
}
