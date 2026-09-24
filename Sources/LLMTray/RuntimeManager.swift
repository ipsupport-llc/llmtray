import Foundation
import LLMTrayCore

/// Manages the pinned commit of our own mlx-lm fork (ipsupport-llc/mlx-lm,
/// `main` branch) used by runtime/run_server.sh's venv. This app installs
/// mlx_lm exclusively from that fork -- never from PyPI -- since it carries
/// real fixes/features upstream doesn't have (NemotronH MTP self-
/// speculative decode, RotatingKVCache quantization, native
/// prism_hadamard_qwen35 support, server flags). Deliberately does NOT
/// auto-track the branch tip on every launch -- an in-progress commit on
/// `main` could be broken or mid-change; bumping the pin is a deliberate,
/// visible action instead (via Check for Updates here, which compares
/// against `main`'s current tip -- or `beta`'s, with beta updates on --
/// through the GitHub API).
@MainActor
final class RuntimeManager: ObservableObject {
    enum CheckState: Equatable {
        case idle
        case checking
        case upToDate(String)
        case updateAvailable(current: String, latest: String)
        case updating
        case failed(String)
    }

    @Published private(set) var checkState: CheckState = .idle

    private static let repo = "ipsupport-llc/mlx-lm"
    private static let stableBranch = "main"
    /// With "Receive beta updates" on, runtime updates follow the fork's
    /// `beta` branch: a runtime fix can reach beta testers without a new
    /// app build. Falls back to main if that branch doesn't exist.
    private static let betaBranch = "beta"
    private static var trackedBranch: String {
        UserDefaults.standard[Pref.betaUpdates] ? betaBranch : stableBranch
    }

    private var runtimeDir: String { RuntimePaths.runtimeDir }
    private var pinFilePath: String { runtimeDir + "/mlx_lm_runtime.json" }
    // The exact venv ServerManager runs the server from (outside the
    // bundle, so Sparkle updates don't wipe it) -- anything else and
    // "Update" here would pip-install into a venv nothing ever reads.
    private var venvPython: String { MLXRuntimeInstaller.venvPython }
    private var versionMarkerPath: String { MLXRuntimeInstaller.versionMarkerPath }

    func pinnedVersion() -> String? {
        guard let data = FileManager.default.contents(atPath: pinFilePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["pinned_ref"] as? String
    }

    func checkForUpdate() {
        guard let current = pinnedVersion() else {
            checkState = .failed("could not read mlx_lm_runtime.json")
            return
        }
        checkState = .checking

        Task {
            do {
                var latest = try await Self.tipCommit(of: Self.trackedBranch)
                if latest == nil, Self.trackedBranch != Self.stableBranch {
                    latest = try await Self.tipCommit(of: Self.stableBranch)
                }
                guard let latest else {
                    checkState = .failed("unexpected GitHub API response")
                    return
                }
                if latest == current {
                    checkState = .upToDate(current)
                } else {
                    checkState = .updateAvailable(current: current, latest: latest)
                }
            } catch {
                checkState = .failed(error.localizedDescription)
            }
        }
    }

    /// The branch tip's commit SHA, nil if the branch doesn't exist (404).
    private static func tipCommit(of branch: String) async throws -> String? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/commits/\(branch)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["sha"] as? String
    }

    /// Bumps the pin and reinstalls the venv's mlx-lm at the new commit. If
    /// the install fails, this surfaces as a `.failed` state rather than
    /// silently leaving the venv on a half-installed commit; the venv is
    /// left on whatever the failed pip run got to either way -- rerunning
    /// this action will retry the install against the same target commit.
    func applyUpdate(to commit: String) {
        checkState = .updating
        Task {
            do {
                let gitURL = "git+https://github.com/\(Self.repo).git@\(commit)"
                try await ProcessRunner.run(venvPython, ["-m", "pip", "install", "--quiet", "--force-reinstall", gitURL])
                try writePinnedVersion(commit)
                checkState = .upToDate(commit)
            } catch {
                checkState = .failed("update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Updates both the bundled pin (what a fresh install/first bootstrap
    /// will target) and the external venv's own version marker (what
    /// MLXRuntimeInstaller.ensureReady compares against to decide whether
    /// the venv needs touching) -- if only the bundled copy changed, the
    /// next server start would see the marker "behind" the pin and
    /// re-install right back down to the bundle's original commit,
    /// silently undoing the update this method just applied.
    private func writePinnedVersion(_ commit: String) throws {
        let obj: [String: Any] = [
            "repo": Self.repo,
            "pinned_ref": commit,
            "_comment": "Pinned commit of our own mlx-lm fork's main branch for runtime/run_server.sh and LLMTray's runtime-update check. Bumped via LLMTray's Check for Updates action.",
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: pinFilePath))
        try commit.write(toFile: versionMarkerPath, atomically: true, encoding: .utf8)
    }
}
