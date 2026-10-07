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
    private static var running: [String: (id: UUID, task: Task<String?, Never>)] = [:]

    /// nil once it's in the cache, else why not.
    static func fetch(_ repo: String) async -> String? {
        if let fetch = running[repo] { return await fetch.task.value }
        let id = UUID()
        let task = Task { @MainActor in await run(repo) }
        running[repo] = (id, task)
        let error = await task.value
        // Only the fetch that started it: a later one may have its own now.
        if running[repo]?.id == id { running[repo] = nil }
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

/// A model's own MTP head (ModelDiscovery.mtpHeadFile) from its Hugging
/// Face repo, for a model installed before the head was published. Through
/// the runtime's huggingface_hub, like the drafter: the token and retries
/// are its. Into a fresh temporary folder, never the model's: the caller
/// puts it in place (`install`) only if the model is still there.
@MainActor
enum MTPHeadDownload {
    enum Result: Equatable {
        /// The file, in a temporary folder of its own (the caller removes it).
        case downloaded(URL)
        /// The repo has no head, or is missing or gated.
        case notPublished
        case failed(String)
    }

    /// The exit code the script uses for a repo without the file.
    private static let notFoundStatus: Int32 = 3

    static func fetch(repo: String) async -> Result {
        guard FileManager.default.isExecutableFile(atPath: MLXRuntimeInstaller.venvPython) else {
            return .failed(NSLocalizedString("the model runtime isn't installed yet", comment: "MTP drafter download"))
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("llmtray-mtp-head-" + UUID().uuidString)
        HFToken.refresh()
        var environment = ["HF_HUB_OFFLINE": "0", "HF_HUB_DISABLE_PROGRESS_BARS": "1"]
        if let token = HFToken.value { environment["HF_TOKEN"] = token }
        do {
            try await ProcessRunner.run(MLXRuntimeInstaller.venvPython, [
                "-c",
                """
                import sys
                from huggingface_hub import hf_hub_download
                from huggingface_hub.errors import EntryNotFoundError, GatedRepoError, RepositoryNotFoundError
                try:
                    hf_hub_download(repo_id=sys.argv[1], filename="config.json", local_dir=sys.argv[3])
                    hf_hub_download(repo_id=sys.argv[1], filename=sys.argv[2], local_dir=sys.argv[3])
                except (EntryNotFoundError, GatedRepoError, RepositoryNotFoundError):
                    sys.exit(\(notFoundStatus))
                """,
                repo, ModelDiscovery.mtpHeadFile, staging.path,
            ], environment: environment)
        } catch let failure as ProcessRunner.Failure {
            try? FileManager.default.removeItem(at: staging)
            if failure.status == notFoundStatus { return .notPublished }
            return .failed(failure.outputTail.split(separator: "\n").last.map(String.init) ?? failure.localizedDescription)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return .failed(error.localizedDescription)
        }
        return .downloaded(staging.appendingPathComponent(ModelDiscovery.mtpHeadFile))
    }

    /// Moves a fetched head into the model folder; nil when it's there
    /// (also when one arrived meanwhile), else why not. The repo's config
    /// (fetched with it) must describe the same architecture as the
    /// model's: the folder's name alone doesn't say which model it holds.
    static func install(_ staged: URL, into folder: String) -> String? {
        let target = folder + "/" + ModelDiscovery.mtpHeadFile
        let repoConfig = staged.deletingLastPathComponent().appendingPathComponent("config.json").path
        guard ModelDiscovery.sameArchitecture(repoConfig, folder + "/config.json") else {
            return NSLocalizedString("the head is for another model", comment: "MTP head download: the repo's config differs from the model's")
        }
        do {
            try FileManager.default.moveItem(atPath: staged.path, toPath: target)
        } catch {
            if FileManager.default.fileExists(atPath: target) { return nil }
            return error.localizedDescription
        }
        return nil
    }
}
