import Foundation

/// The two builds' bundle ids (adr/0018 §1): the App Store build has its
/// own, so both can be installed side by side -- but only one may run at a
/// time (the port, the models, the memory). build_app.sh writes the App
/// Store id into that flavor's Info.plist; Resources/Info.plist carries the
/// standalone one (AppIdentityTests checks both stay in step with these).
/// The in-app purchase ids keep the `us.ipsupport.llmtray` prefix whatever
/// the bundle id (SupporterTier.productID): App Store Connect and the
/// supporters API know them by that.
public enum AppIdentity {
    public static let standaloneBundleID = "us.ipsupport.llmtray"
    public static let appStoreBundleID = "us.ipsupport.llmtray.appstore"
    public static let bundleIDs = [standaloneBundleID, appStoreBundleID]

    /// This build's id (what its Info.plist should say).
    public static var bundleID: String {
        #if APP_STORE
        appStoreBundleID
        #else
        standaloneBundleID
        #endif
    }

    /// A running LLMTray other than this process, by what the single-instance
    /// check does about it.
    public enum Conflict: Equatable, Sendable {
        /// Another copy of this build: it takes over, this one quits.
        case sameBuild(pid: Int32)
        /// The other build: this one says so and quits.
        case otherBuild(bundleID: String, pid: Int32)
    }

    public struct Running: Equatable, Sendable {
        public let bundleID: String?
        public let pid: Int32
        public init(bundleID: String?, pid: Int32) {
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    /// What, among `running`, this process (`ownBundleID`, `ownPID`) must
    /// give way to; the same build first. No bundle id of its own (`swift
    /// run`): nothing, as before -- a dev run beside an installed copy is on
    /// purpose. A test id of build_appstore.sh's (neither of ours): both
    /// builds are "the other one".
    public static func conflict(ownBundleID: String?, ownPID: Int32, running: [Running]) -> Conflict? {
        guard let own = ownBundleID, !own.isEmpty else { return nil }
        let others = running.filter { $0.pid != ownPID }
        if let same = others.first(where: { $0.bundleID == own }) { return .sameBuild(pid: same.pid) }
        if let other = others.first(where: { $0.bundleID.map { $0 != own && bundleIDs.contains($0) } ?? false }),
           let id = other.bundleID {
            return .otherBuild(bundleID: id, pid: other.pid)
        }
        return nil
    }
}
