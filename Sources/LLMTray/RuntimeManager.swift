import Foundation

/// Manages the pinned mlx-lm version used by runtime/run_server.sh's venv,
/// and this project's own patches on top of it (patch_mlx_server_kv.py,
/// patch_mlx_tool_parser.py). Deliberately does NOT auto-track upstream's
/// latest release -- an unannounced mlx-lm update could shift the exact
/// text/line patterns those patch scripts target, silently un-patching the
/// server (their idempotency guards check for *our* markers, not for
/// "is this still the mlx-lm version we tested against"). Bumping the pin
/// is a deliberate, visible action instead.
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

    private var runtimeDir: String { RuntimePaths.runtimeDir }
    private var pinFilePath: String { runtimeDir + "/mlx_lm_runtime.json" }
    // The venv itself lives outside the bundle now (see ServerManager's
    // venvDir / RuntimePaths.externalRuntimeDir) so Sparkle replacing
    // Contents/ on every auto-update doesn't wipe it -- this has to point
    // at the exact same place ServerManager actually runs the server from,
    // or "Update" here would pip-install into a venv nothing ever reads.
    private var venvDir: String { RuntimePaths.externalRuntimeDir + "/mlx_server_venv" }
    private var venvPython: String { venvDir + "/bin/python" }
    private var versionMarkerPath: String { venvDir + "/.llmtray_pinned_version" }

    func pinnedVersion() -> String? {
        guard let data = FileManager.default.contents(atPath: pinFilePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["pinned_version"] as? String
    }

    func checkForUpdate() {
        guard let current = pinnedVersion() else {
            checkState = .failed("could not read mlx_lm_runtime.json")
            return
        }
        checkState = .checking

        Task {
            do {
                let url = URL(string: "https://pypi.org/pypi/mlx-lm/json")!
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let info = obj["info"] as? [String: Any],
                      let latest = info["version"] as? String else {
                    checkState = .failed("unexpected PyPI response")
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

    /// Bumps the pin, reinstalls the venv's mlx-lm at the new version, and
    /// reapplies both patch scripts. If patching fails against the new
    /// version, this surfaces as a `.failed` state rather than silently
    /// leaving an unpatched server.py in place -- the venv is left on the
    /// new (possibly unpatched) version either way; rerunning
    /// runtime/run_server.sh manually will re-attempt the patch on next launch.
    func applyUpdate(to version: String) {
        checkState = .updating
        Task {
            do {
                try await runProcess(venvPython, ["-m", "pip", "install", "--quiet", "mlx-lm==\(version)"])
                try await runProcess(venvPython, [runtimeDir + "/patch_mlx_server_kv.py"])
                try await runProcess(venvPython, [runtimeDir + "/patch_mlx_tool_parser.py"])
                try writePinnedVersion(version)
                checkState = .upToDate(version)
            } catch {
                checkState = .failed("update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Updates both the bundled pin (what a fresh install/first bootstrap
    /// will target) and the external venv's own version marker (what
    /// ServerManager.ensureRuntimeReady compares against to decide whether
    /// the venv needs touching) -- if only the bundled copy changed, the
    /// next server start would see the marker "behind" the pin and
    /// re-install right back down to the bundle's original version,
    /// silently undoing the update this method just applied.
    private func writePinnedVersion(_ version: String) throws {
        let obj: [String: Any] = [
            "pinned_version": version,
            "_comment": "Pinned mlx-lm version for runtime/run_server.sh and LLMTray's runtime-update check. Bumped via LLMTray's Check for Updates action.",
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: pinFilePath))
        try version.write(toFile: versionMarkerPath, atomically: true, encoding: .utf8)
    }

    private func runProcess(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = arguments
            task.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            task.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: NSError(domain: "RuntimeManager", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(executable) exited \(proc.terminationStatus): \(output.suffix(500))"]))
                }
            }
            do {
                try task.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
