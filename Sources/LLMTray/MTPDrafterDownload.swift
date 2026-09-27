import Foundation
import LLMTrayCore

/// Fetches a model's MTP drafter into the Hugging Face hub cache with the
/// runtime's huggingface_hub -- where HFHubCache finds it, so the model
/// server gets its folder and never goes to the network itself. Shared by a
/// server start that found it missing and the download queue (a model
/// downloaded with one): a fetch of a repo already running is joined, not
/// started twice.
@MainActor
enum MTPDrafterDownload {
    private static var running: [String: Task<String?, Never>] = [:]

    /// nil once it's in the cache, else why not.
    static func fetch(_ repo: String) async -> String? {
        if let task = running[repo] { return await task.value }
        let task = Task { @MainActor in await run(repo) }
        running[repo] = task
        let error = await task.value
        running[repo] = nil
        return error
    }

    private static func run(_ repo: String) async -> String? {
        if HFHubCache.localSnapshot(repo: repo) != nil { return nil }
        guard FileManager.default.isExecutableFile(atPath: MLXRuntimeInstaller.venvPython) else {
            return NSLocalizedString("the model runtime isn't installed yet", comment: "MTP drafter download")
        }
        HFToken.refresh()
        var environment = [
            // Whatever the app was started with: this one must reach the Hub.
            "HF_HUB_OFFLINE": "0",
            "HF_HUB_DISABLE_PROGRESS_BARS": "1",
        ]
        if let token = HFToken.value { environment["HF_TOKEN"] = token }
        do {
            // The repo goes in as an argument, not into the code.
            try await ProcessRunner.run(MLXRuntimeInstaller.venvPython, [
                "-c",
                """
                import sys
                from huggingface_hub import snapshot_download
                snapshot_download(repo_id=sys.argv[1])
                """,
                repo,
            ], environment: environment)
        } catch let failure as ProcessRunner.Failure {
            return failure.outputTail.split(separator: "\n").last.map(String.init) ?? failure.localizedDescription
        } catch {
            return error.localizedDescription
        }
        return HFHubCache.localSnapshot(repo: repo) == nil
            ? NSLocalizedString("the download finished incomplete", comment: "MTP drafter download") : nil
    }
}
