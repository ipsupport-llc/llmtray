import Foundation
import LLMTrayCore
import SwiftUI

extension Notification.Name {
    static let showHFBrowser = Notification.Name("LLMTray.showHFBrowser")
    static let modelsDidChange = Notification.Name("LLMTray.modelsDidChange")
}

struct HFModelSummary: Identifiable, Decodable, Hashable {
    var id: String { modelId }
    let modelId: String
    let downloads: Int?
    let likes: Int?
    let lastModified: String?

    enum CodingKeys: String, CodingKey {
        case modelId = "id"
        case downloads
        case likes
        case lastModified
    }
}

enum HFSortOption: String, CaseIterable, Identifiable {
    case downloads
    case likes
    case lastModified

    var id: String { rawValue }
    /// Value HF's own `sort` query parameter expects -- happens to match
    /// this enum's cases 1:1 today, kept as an explicit mapping (not just
    /// rawValue) so a future rename of the case doesn't silently start
    /// sending an invalid sort value.
    var apiValue: String {
        switch self {
        case .downloads: return "downloads"
        case .likes: return "likes"
        case .lastModified: return "lastModified"
        }
    }
    var label: String {
        switch self {
        case .downloads: return NSLocalizedString("Downloads", comment: "")
        case .likes: return NSLocalizedString("Likes", comment: "")
        case .lastModified: return NSLocalizedString("Recently updated", comment: "")
        }
    }
}

/// The fit estimate itself is LLMTrayCore's (the wizard's recommendations
/// use it too); its dot and words are here.
extension ModelFitLevel {
    var color: Color {
        switch self {
        case .fits: return .green
        case .tight: return .orange
        case .unlikely: return .red
        }
    }

    var label: String {
        switch self {
        case .fits: return NSLocalizedString("Fits comfortably", comment: "")
        case .tight: return NSLocalizedString("Tight -- may not leave room for context", comment: "")
        case .unlikely: return NSLocalizedString("Larger than this Mac's RAM -- unlikely to load", comment: "")
        }
    }
}

private struct HFTreeEntry: Decodable {
    struct LFS: Decodable { let oid: String? }
    let type: String
    let path: String
    let size: Int?
    let oid: String?
    let lfs: LFS?
    /// The file's revision identity: the LFS sha256, else the git blob id.
    var revision: String? { lfs?.oid ?? oid }
}

/// Per-file bookkeeping keyed by repo-relative path (not URLSessionTask
/// identifier) -- a paused-then-resumed file gets a brand new task with a
/// new identifier, so path is the only stable key across that transition.
private struct FileDownload {
    let path: String
    let destination: URL
    let expectedBytes: Int64
    /// The Hub's id for this file's content (see HFTreeEntry.revision).
    var revision: String?
    var writtenBytes: Int64 = 0
    var resumeData: Data?
    var isDone = false
    /// Already on disk at its expected size and Hub revision when the
    /// download started (a relaunch mid-download): not fetched again, and
    /// kept if this attempt fails -- removed only by a cancel.
    var preexisting = false
    /// Restarted once from scratch after the file CDN refused it (its
    /// signed link expires an hour after the redirect: a long pause).
    var restarted = false
}

/// Searches the HF Hub for mlx-format models and downloads one straight
/// into <configured models root>/<org>/<name>/ -- the same layout
/// ModelDiscovery already scans, so a freshly downloaded model just shows
/// up in the picker once the download finishes.
@MainActor
final class HFModelBrowser: NSObject, ObservableObject, URLSessionDownloadDelegate {
    /// Written only after every file in the repo has finished downloading --
    /// this is what "already downloaded" actually checks (see
    /// ModelDiscovery.isDownloaded), not just config.json's existence,
    /// which would false-positive on a download interrupted partway through.
    static let completionMarkerName = ModelFolder.completionMarkerName
    /// Which revision of each file is on disk: a file is picked up after a
    /// relaunch only if its size AND its Hub id still match.
    static let manifestName = ModelFolder.manifestName

    @Published var query: String = ""
    @Published var results: [HFModelSummary] = []
    @Published var isSearching = false
    @Published var searchError: String?
    @Published var sortOption: HFSortOption = .downloads
    // Keyed by model id rather than stored on HFModelSummary itself --
    // sizes arrive one at a time as each repo's detail fetch completes
    // (see fetchSizes below), and HFModelSummary is a value type sitting
    // in the `results` array, so updating one field of one element in
    // place would mean finding-and-replacing by index on every single
    // completion instead of a plain dictionary write.
    @Published var sizesByID: [String: Int64] = [:]
    /// License and access (gated or not) of each shown result.
    @Published var infoByID: [String: HubModelInfo] = [:]

    let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory

    @Published var downloadingID: String? {
        didSet { Self.activeDownload = downloadingID }
    }
    /// The repo any browser is downloading into the models folder, for a
    /// model removal: not that model, nor its <org>/ folder meanwhile.
    private(set) static var activeDownload: String?
    @Published var isPaused = false
    @Published var downloadProgress: Double = 0
    @Published var downloadSpeedBytesPerSec: Double = 0
    @Published var downloadETASeconds: Double?
    @Published var downloadStatusText: String = ""
    @Published var downloadError: String?

    // Set (non-nil) to drive the model-card sheet's presentation --
    // modelCardID is the repo currently shown, independent of whatever's
    // being downloaded.
    @Published var modelCardID: String?
    @Published var modelCardMarkdown: String?
    @Published var modelCardLoading = false
    @Published var modelCardError: String?

    private var session: URLSession!
    private var onAllDone: (() -> Void)?
    /// Every download that completes, with its folder, before its own
    /// completion: the download queue adds the model's MTP drafter.
    var onModelDownloaded: ((_ folder: String) -> Void)?
    private var currentModelID = ""
    private var currentDestRoot: URL?

    // Mutated from urlSession's delegate callbacks and from the main
    // actor (download(), pause/resume/cancel): the session delivers its
    // callbacks on the main queue, so the two never run at once (task
    // cancellation is asynchronous -- a sibling's callback can still come
    // in after cancelDownload()). nonisolated(unsafe) because
    // didFinishDownloadingTo must move the temp file synchronously (it's
    // deleted the instant the callback returns), not through a Task.
    nonisolated(unsafe) private var files: [String: FileDownload] = [:]
    nonisolated(unsafe) private var tasksByPath: [String: URLSessionDownloadTask] = [:]
    nonisolated(unsafe) private var pathByTaskID: [Int: String] = [:]
    nonisolated(unsafe) private var totalBytesExpected: Int64 = 0
    /// Set on the delegate queue the moment a file comes back as an HTTP
    /// error: later completions of the same download are ignored (none may
    /// declare it done), until the next download() resets it.
    nonisolated(unsafe) private var downloadFailed = false
    /// Bumped by every download() and cancelDownload(): an earlier one's
    /// steps still in flight (the file listing) see they're stale.
    private var downloadGeneration = 0
    /// Speed and time left over the last 10 s (TransferRate), not per chunk.
    nonisolated(unsafe) private var rate = TransferRate()

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    /// Fetches a repo's README.md (the "model card") from the raw file
    /// endpoint -- most mlx-community repos have one, but it's not
    /// guaranteed, so a 404 is a normal outcome here, not an error worth
    /// alarming about.
    func showModelCard(for modelID: String) {
        modelCardID = modelID
        modelCardMarkdown = nil
        modelCardError = nil
        modelCardLoading = true
        Task {
            defer { modelCardLoading = false }
            guard let url = URL(string: "https://huggingface.co/\(modelID)/raw/main/README.md") else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    modelCardError = NSLocalizedString("No README.md in this repo.", comment: "")
                    return
                }
                modelCardMarkdown = String(data: data, encoding: .utf8)
            } catch {
                modelCardError = error.localizedDescription
            }
        }
    }

    func dismissModelCard() {
        modelCardID = nil
    }

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isSearching = true
        searchError = nil
        sizesByID.removeAll()
        infoByID.removeAll()
        Task {
            do {
                var comps = URLComponents(string: "https://huggingface.co/api/models")!
                comps.queryItems = [
                    URLQueryItem(name: "search", value: q),
                    // Narrows results to repos tagged for the mlx library --
                    // this server can only load mlx-format weights, so a
                    // plain PyTorch/GGUF hit would just fail to start.
                    URLQueryItem(name: "filter", value: "mlx"),
                    URLQueryItem(name: "sort", value: sortOption.apiValue),
                    URLQueryItem(name: "direction", value: "-1"),
                    URLQueryItem(name: "limit", value: "30"),
                ]
                let (data, _) = try await URLSession.shared.data(from: comps.url!)
                let fetched = try JSONDecoder().decode([HFModelSummary].self, from: data)
                results = fetched
                fetchSizes(for: fetched)
            } catch {
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    /// Fetches each shown result's exact on-disk size from HF's per-model
    /// detail endpoint -- not available in bulk on the search/list endpoint
    /// itself (its `expand[]` allowlist doesn't include usedStorage,
    /// confirmed live: the API rejects it as an invalid option). Races
    /// every result's fetch concurrently and lets each one update
    /// sizesByID independently as it lands, rather than waiting for all
    /// ~30 to finish before showing any -- this is a one-time burst per
    /// search, not sustained load, so no throttling.
    private func fetchSizes(for models: [HFModelSummary]) {
        for model in models {
            Task {
                guard let url = URL(string: "https://huggingface.co/api/models/\(model.id)") else { return }
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let info = HubModelInfo.parse(data) else { return }
                infoByID[model.id] = info
                if let size = info.sizeBytes { sizesByID[model.id] = size }
            }
        }
    }

    /// `root`: the models folder to download into, fixed by the caller;
    /// nil: the one set when the file list arrives.
    func download(_ model: HFModelSummary, root: String? = nil, completion: @escaping () -> Void) {
        guard downloadingID == nil else { return }
        // An image, music or voice model goes through its own manager
        // (MediaModels), never into the chat models' path.
        guard MediaModels.entry(repo: model.id) == nil else { return }
        HFToken.refresh()
        // A gated model's files answer 401 without a token (seen live: the
        // listing is open, the files aren't).
        if case .gated = infoByID[model.id]?.access, HFToken.value == nil {
            downloadError = String(format: NSLocalizedString(
                "%@ is gated: accept its license on huggingface.co/%@, then add a Hugging Face token in Settings → Models.",
                comment: "gated model, no token"), model.id, model.id)
            return
        }
        downloadGeneration += 1
        let generation = downloadGeneration
        downloadingID = model.id
        currentModelID = model.id
        // Set once the folder is made: a cancel before that has none.
        currentDestRoot = nil
        isPaused = false
        downloadProgress = 0
        downloadError = nil
        downloadStatusText = NSLocalizedString("Fetching file list…", comment: "")
        onAllDone = completion

        Task {
            do {
                // Every file, subfolders included, over all pages (the
                // listing is paginated by a Link header).
                var entries: [HFTreeEntry] = []
                var next: URL? = URL(string: "https://huggingface.co/api/models/\(model.id)/tree/main?recursive=true")
                var pages = 0
                while let url = next, pages < 100 {
                    pages += 1
                    var treeRequest = URLRequest(url: url)
                    HFToken.authorize(&treeRequest)
                    let (data, response) = try await URLSession.shared.data(for: treeRequest)
                    guard generation == downloadGeneration else { return }   // cancelled meanwhile
                    let http = response as? HTTPURLResponse
                    if let status = http?.statusCode, !(200..<300).contains(status) {
                        downloadError = Self.accessMessage(status: status, repo: model.id)
                        downloadingID = nil
                        return
                    }
                    entries += try JSONDecoder().decode([HFTreeEntry].self, from: data).filter { $0.type == "file" }
                    next = Self.nextPage(http?.value(forHTTPHeaderField: "Link"))
                }
                guard !entries.isEmpty else {
                    downloadError = "No files found in \(model.id)"
                    downloadingID = nil
                    return
                }

                let modelsRoot = root ?? ModelDiscovery.currentModelsRoot()
                let destRoot = URL(fileURLWithPath: modelsRoot).appendingPathComponent(model.id)
                try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
                // Any marker from a previous, incomplete attempt at this
                // repo must not survive into this one -- it would make an
                // interrupted re-download look "Downloaded" again the
                // instant config.json (or whichever file) lands.
                try? FileManager.default.removeItem(at: destRoot.appendingPathComponent(Self.completionMarkerName))
                currentDestRoot = destRoot

                let manifestURL = destRoot.appendingPathComponent(Self.manifestName)
                let manifest = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))) ?? [:]
                files.removeAll()
                tasksByPath.removeAll()
                pathByTaskID.removeAll()
                downloadFailed = false
                totalBytesExpected = entries.reduce(0) { $0 + Int64($1.size ?? 0) }
                rate.reset()
                downloadStatusText = String(format: NSLocalizedString("Downloading %lld files…", comment: ""), entries.count)

                for entry in entries {
                    let destination = destRoot.appendingPathComponent(entry.path)
                    let expected = Int64(entry.size ?? 0)
                    var file = FileDownload(path: entry.path, destination: destination, expectedBytes: expected, revision: entry.revision)
                    // Picked up, not restarted: a file already there at its
                    // expected size and the same Hub revision (a download
                    // interrupted by quitting).
                    let onDisk = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
                    if expected > 0, onDisk == expected, let revision = entry.revision, manifest[entry.path] == revision {
                        file.isDone = true
                        file.preexisting = true
                        file.writtenBytes = expected
                    }
                    files[entry.path] = file
                    if !file.isDone { startTask(forPath: entry.path) }
                }
                if files.values.allSatisfy(\.isDone) { finishIfComplete() }
            } catch {
                // A cancelled download's late failure: another may have
                // started since, and is not this one to end.
                guard generation == downloadGeneration else { return }
                downloadError = error.localizedDescription
                downloadingID = nil
            }
        }
    }

    /// Pauses every in-flight file -- URLSession hands back resume data
    /// (an opaque blob encoding what's already been written plus range/etag
    /// info) via the completion handler on cancel(byProducingResumeData:),
    /// which resumeDownload() later hands to downloadTask(withResumeData:)
    /// to pick up roughly where it left off instead of restarting.
    func pauseDownload() {
        guard downloadingID != nil, !isPaused else { return }
        isPaused = true
        downloadStatusText = NSLocalizedString("Paused", comment: "")
        downloadSpeedBytesPerSec = 0
        downloadETASeconds = nil
        let generation = downloadGeneration
        for (path, task) in tasksByPath {
            task.cancel(byProducingResumeData: { [weak self] data in
                Task { @MainActor [weak self] in
                    // Late, after a cancel: not for whatever downloads now.
                    guard let self, self.downloadGeneration == generation else { return }
                    self.files[path]?.resumeData = data
                }
            })
        }
        tasksByPath.removeAll()
    }

    func resumeDownload() {
        guard downloadingID != nil, isPaused else { return }
        isPaused = false
        downloadStatusText = NSLocalizedString("Downloading…", comment: "")
        // Reset the speed sample so the paused interval itself isn't
        // counted as zero-throughput time in the next rate calculation.
        rate.reset()
        for path in files.keys where files[path]?.isDone == false {
            startTask(forPath: path)
        }
    }

    /// Abandons the download entirely -- cancels whatever's in flight
    /// (without bothering to collect resume data, since it's being thrown
    /// away), removes its files from the models folder (paused or not: half
    /// a model with a config.json passed for one), and clears
    /// state so the row goes back to a plain "Download" button.
    func cancelDownload() {
        let root = downloadingID != nil ? currentDestRoot : nil
        // In place: what this attempt saved, and what it found there from
        // an earlier one (its size and Hub revision in the manifest).
        let inPlace = files.values.filter(\.isDone).map(\.path)
        stopDownload()
        guard let root else { return }
        ModelFolder.removeUnfinishedDownload(atPath: root.path, files: inPlace)
        // No object: that would read as this repo finished (ChatPresentation).
        NotificationCenter.default.post(name: .modelsDidChange, object: nil)
    }

    /// Ends the download, leaving its files where they are.
    private func stopDownload() {
        downloadGeneration += 1
        for task in tasksByPath.values {
            task.cancel()
        }
        tasksByPath.removeAll()
        pathByTaskID.removeAll()
        files.removeAll()
        downloadingID = nil
        isPaused = false
        downloadError = nil
        downloadSpeedBytesPerSec = 0
        downloadETASeconds = nil
        onAllDone = nil
    }

    private func startTask(forPath path: String) {
        guard let file = files[path] else { return }
        let task: URLSessionDownloadTask
        if let resumeData = file.resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            let encodedPath = path
                .split(separator: "/")
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            guard let url = URL(string: "https://huggingface.co/\(currentModelID)/resolve/main/\(encodedPath)") else { return }
            var request = URLRequest(url: url)
            HFToken.authorize(&request)
            task = session.downloadTask(with: request)
        }
        files[path]?.resumeData = nil
        tasksByPath[path] = task
        pathByTaskID[task.taskIdentifier] = path
        task.resume()
    }

    /// nonisolated (not just called from a nonisolated context) because it
    /// reads the nonisolated(unsafe) byte counters directly and is invoked
    /// synchronously from didWriteData -- routing through the MainActor
    /// first would need an extra hop for a value that's stale the instant
    /// it's read anyway.
    private nonisolated func publishProgress() {
        let sum = files.values.reduce(Int64(0)) { $0 + $1.writtenBytes }
        let total = totalBytesExpected
        let progress = total > 0 ? min(1.0, Double(sum) / Double(total)) : 0
        Task { @MainActor in
            self.downloadProgress = progress
        }

        // A 10 s average, shown once a second: chunk sizes vary a lot, and
        // a per-chunk (or half-second) rate jumps too much to read.
        guard let (speed, eta) = rate.add(bytes: sum, total: total, at: ProcessInfo.processInfo.systemUptime) else { return }
        Task { @MainActor in
            self.downloadSpeedBytesPerSec = speed
            self.downloadETASeconds = eta
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let path = pathByTaskID[downloadTask.taskIdentifier] else { return }
        files[path]?.writtenBytes = totalBytesWritten
        publishProgress()
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard !downloadFailed, let path = pathByTaskID[downloadTask.taskIdentifier],
              let file = files[path] else { return }
        let dest = file.destination
        let fm = FileManager.default
        // An error page (401 gated, 404) must not be saved as the file, and
        // what this attempt already saved must not pass for a model (a
        // folder with a config.json is one to ModelDiscovery).
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let status = http.statusCode
            // The file CDN (not huggingface.co) refusing a resumed download:
            // its signed link expired during a pause. Once, from scratch.
            if http.url?.host != "huggingface.co", !file.restarted {
                files[path]?.restarted = true
                files[path]?.resumeData = nil
                files[path]?.writtenBytes = 0
                MainActor.assumeIsolated { self.startTask(forPath: path) }
                return
            }
            MainActor.assumeIsolated { self.failDownload(Self.accessMessage(status: status, repo: self.currentModelID)) }
            return
        }
        // `let`, not `var` -- assigned exactly once on every path below, so
        // it's an immutable value by the time the Task below captures it.
        // Strict concurrency checking flags a genuinely mutable var here as
        // an unchecked data race even though this control flow never
        // actually mutates it after the fact.
        let saveError: String?
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
            // No checksum available from the tree listing without another
            // API round trip per file, but the expected size is already in
            // hand -- cheap enough to catch a truncated/corrupt save (e.g.
            // a resumed download that didn't actually splice back together
            // right) instead of silently marking it done.
            let actualSize = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? -1
            if file.expectedBytes > 0 && actualSize != file.expectedBytes {
                saveError = "\(dest.lastPathComponent): expected \(file.expectedBytes) bytes, got \(actualSize)"
            } else {
                files[path]?.isDone = true
                saveError = nil
                MainActor.assumeIsolated { self.recordRevision(path) }
            }
        } catch {
            saveError = "Failed to save \(dest.lastPathComponent): \(error.localizedDescription)"
        }
        if let saveError {
            MainActor.assumeIsolated { self.failDownload(saveError) }
            return
        }
        Task { @MainActor in self.finishIfComplete() }
    }

    /// Notes a finished file's Hub revision in the folder's manifest.
    private func recordRevision(_ path: String) {
        guard let root = currentDestRoot, let revision = files[path]?.revision else { return }
        let url = root.appendingPathComponent(Self.manifestName)
        var manifest = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        manifest[path] = revision
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: url, options: .atomic) }
    }

    /// Every file in place: the marker, and the download is over.
    private func finishIfComplete() {
        guard !downloadFailed, !files.isEmpty, files.values.allSatisfy(\.isDone), downloadingID != nil else { return }
        if let destRoot = currentDestRoot {
            FileManager.default.createFile(atPath: destRoot.appendingPathComponent(Self.completionMarkerName).path, contents: nil)
        }
        downloadingID = nil
        if let destRoot = currentDestRoot { onModelDownloaded?(destRoot.path) }
        UsageTelemetry.shared.record(.modelDownload)   // a count: not which model
        downloadStatusText = NSLocalizedString("Done", comment: "")
        downloadSpeedBytesPerSec = 0
        downloadETASeconds = nil
        onAllDone?()
        onAllDone = nil
    }

    /// The rel="next" URL of a Link header.
    nonisolated static func nextPage(_ link: String?) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            if let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close {
                return URL(string: String(part[part.index(after: open)..<close]))
            }
        }
        return nil
    }

    /// Why Hugging Face refused a repo's files, in words.
    nonisolated static func accessMessage(status: Int, repo: String) -> String {
        switch status {
        case 401, 403:
            return String(format: NSLocalizedString(
                "Hugging Face refused %@ (HTTP %d): it's gated or private, or doesn't exist. If it's gated, accept its license on huggingface.co/%@ and check the token in Settings → Models.",
                comment: "gated download refused"), repo, status, repo)
        case 404:
            return String(format: NSLocalizedString("%@ wasn't found on Hugging Face.", comment: ""), repo)
        default:
            return String(format: NSLocalizedString("Hugging Face answered HTTP %d for %@.", comment: ""), status, repo)
        }
    }

    /// The token is for huggingface.co: a redirect to its file CDN (signed
    /// URLs) must not carry it.
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // URLSession drops Authorization on every redirect -- also to
        // huggingface.co's own /api/resolve-cache/ that small files of a
        // gated repo go through (401 without it): put back there, never
        // anywhere else.
        var request = request
        if request.url?.host == "huggingface.co", request.url?.scheme == "https" {
            // On the main queue (the session's delegate queue).
            MainActor.assumeIsolated { HFToken.authorize(&request) }
        } else {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled, !downloadFailed,
              let path = pathByTaskID[task.taskIdentifier], let file = files[path] else { return }
        // A dropped connection: once more, from where it stopped.
        if !file.restarted, let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            files[path]?.restarted = true
            files[path]?.resumeData = resume
            MainActor.assumeIsolated { self.startTask(forPath: path) }
            return
        }
        // Otherwise the download is over, not stuck below 100% for good.
        MainActor.assumeIsolated { self.failDownload(error.localizedDescription) }
    }

    /// Ends the whole download with `message`; what this attempt saved is
    /// removed (a folder with a config.json would pass for a model).
    private func failDownload(_ message: String) {
        downloadFailed = true
        let written = files.values.filter { $0.isDone && !$0.preexisting }.map(\.destination)
        let root = currentDestRoot
        stopDownload()   // clears downloadError: set after
        for url in written { try? FileManager.default.removeItem(at: url) }
        if let root, (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: root)
        }
        downloadError = message
        // The picker drops the unfinished folder.
        NotificationCenter.default.post(name: .modelsDidChange, object: nil)
    }
}
