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
        case .downloads: return "Downloads"
        case .likes: return "Likes"
        case .lastModified: return "Recently updated"
        }
    }
}

/// A rough, honest heuristic -- not a promise. Compares a repo's on-disk
/// size against total (not currently-free) physical memory, since "will
/// this machine ever run this comfortably" is the more useful question
/// while browsing than "is there room for it this exact second," and free
/// memory fluctuates with whatever else happens to be running. Doesn't
/// account for KV-cache/activation overhead on top of the weights
/// themselves, which is real but depends on context length and isn't
/// knowable in advance -- the thresholds leave headroom for it, but a
/// model right at the "fits" boundary can still fail on a long context.
enum ModelFitLevel {
    case fits
    case tight
    case unlikely

    var color: Color {
        switch self {
        case .fits: return .green
        case .tight: return .orange
        case .unlikely: return .red
        }
    }

    var label: String {
        switch self {
        case .fits: return "Fits comfortably"
        case .tight: return "Tight -- may not leave room for context"
        case .unlikely: return "Larger than this Mac's RAM -- unlikely to load"
        }
    }

    static func estimate(sizeBytes: Int64, physicalMemoryBytes: UInt64) -> ModelFitLevel {
        let ratio = Double(sizeBytes) / Double(physicalMemoryBytes)
        if ratio < 0.45 { return .fits }
        if ratio < 0.70 { return .tight }
        return .unlikely
    }
}

private struct HFTreeEntry: Decodable {
    let type: String
    let path: String
    let size: Int?
}

/// Per-file bookkeeping keyed by repo-relative path (not URLSessionTask
/// identifier) -- a paused-then-resumed file gets a brand new task with a
/// new identifier, so path is the only stable key across that transition.
private struct FileDownload {
    let path: String
    let destination: URL
    let expectedBytes: Int64
    var writtenBytes: Int64 = 0
    var resumeData: Data?
    var isDone = false
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
    static let completionMarkerName = ".llmtray-complete"

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

    @Published var downloadingID: String?
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
    private var currentModelID = ""
    private var currentDestRoot: URL?

    // Mutated from urlSession's delegate callbacks (serialized onto one
    // queue by URLSession's default nil delegateQueue), from download()'s
    // setup code (which fully finishes before any task.resume()), and from
    // pause()/resumeDownload() bridged onto the main queue via Task --
    // never concurrently, since cancelling a task stops its delegate
    // callbacks before the resume-data completion handler runs. Needed
    // because didFinishDownloadingTo must move the temp file synchronously
    // (it's deleted the instant the delegate callback returns), which rules
    // out hopping through a MainActor Task for that part.
    nonisolated(unsafe) private var files: [String: FileDownload] = [:]
    nonisolated(unsafe) private var tasksByPath: [String: URLSessionDownloadTask] = [:]
    nonisolated(unsafe) private var pathByTaskID: [Int: String] = [:]
    nonisolated(unsafe) private var totalBytesExpected: Int64 = 0
    // Speed is measured between samples, not per didWriteData call (those
    // fire far too often for a stable rate) -- these track the last sample
    // point so publishProgress can rate-limit itself to ~2x/sec.
    nonisolated(unsafe) private var lastSampleDate: Date?
    nonisolated(unsafe) private var lastSampleBytes: Int64 = 0

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
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
                    modelCardError = "No README.md in this repo."
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

    func download(_ model: HFModelSummary, completion: @escaping () -> Void) {
        guard downloadingID == nil else { return }
        // A gated model's files answer 401 without a token (seen live: the
        // listing is open, the files aren't).
        if case .gated = infoByID[model.id]?.access, HFToken.value == nil {
            downloadError = String(format: NSLocalizedString(
                "%@ is gated: accept its license on huggingface.co/%@, then add a Hugging Face token in Settings → Models.",
                comment: "gated model, no token"), model.id, model.id)
            return
        }
        downloadingID = model.id
        currentModelID = model.id
        isPaused = false
        downloadProgress = 0
        downloadError = nil
        downloadStatusText = "Fetching file list…"
        onAllDone = completion

        Task {
            do {
                var treeRequest = URLRequest(url: URL(string: "https://huggingface.co/api/models/\(model.id)/tree/main")!)
                HFToken.authorize(&treeRequest)
                let (data, response) = try await URLSession.shared.data(for: treeRequest)
                if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                    downloadError = Self.accessMessage(status: status, repo: model.id)
                    downloadingID = nil
                    return
                }
                let entries = try JSONDecoder().decode([HFTreeEntry].self, from: data)
                    .filter { $0.type == "file" }
                guard !entries.isEmpty else {
                    downloadError = "No files found in \(model.id)"
                    downloadingID = nil
                    return
                }

                let modelsRoot = ModelDiscovery.currentModelsRoot()
                let destRoot = URL(fileURLWithPath: modelsRoot).appendingPathComponent(model.id)
                try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
                // Any marker from a previous, incomplete attempt at this
                // repo must not survive into this one -- it would make an
                // interrupted re-download look "Downloaded" again the
                // instant config.json (or whichever file) lands.
                try? FileManager.default.removeItem(at: destRoot.appendingPathComponent(Self.completionMarkerName))
                currentDestRoot = destRoot

                files.removeAll()
                tasksByPath.removeAll()
                pathByTaskID.removeAll()
                totalBytesExpected = entries.reduce(0) { $0 + Int64($1.size ?? 0) }
                lastSampleDate = nil
                lastSampleBytes = 0
                downloadStatusText = "Downloading \(entries.count) files…"

                for entry in entries {
                    files[entry.path] = FileDownload(
                        path: entry.path,
                        destination: destRoot.appendingPathComponent(entry.path),
                        expectedBytes: Int64(entry.size ?? 0)
                    )
                    startTask(forPath: entry.path)
                }
            } catch {
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
        downloadStatusText = "Paused"
        downloadSpeedBytesPerSec = 0
        downloadETASeconds = nil
        for (path, task) in tasksByPath {
            task.cancel(byProducingResumeData: { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.files[path]?.resumeData = data
                }
            })
        }
        tasksByPath.removeAll()
    }

    func resumeDownload() {
        guard downloadingID != nil, isPaused else { return }
        isPaused = false
        downloadStatusText = "Downloading…"
        // Reset the speed sample so the paused interval itself isn't
        // counted as zero-throughput time in the next rate calculation.
        lastSampleDate = nil
        lastSampleBytes = files.values.reduce(0) { $0 + $1.writtenBytes }
        for path in files.keys where files[path]?.isDone == false {
            startTask(forPath: path)
        }
    }

    /// Abandons the download entirely -- cancels whatever's in flight
    /// (without bothering to collect resume data, since it's being thrown
    /// away) and clears state so the row goes back to a plain "Download"
    /// button.
    func cancelDownload() {
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

        let now = Date()
        guard let last = lastSampleDate else {
            lastSampleDate = now
            lastSampleBytes = sum
            return
        }
        let dt = now.timeIntervalSince(last)
        // Rate-limit speed/ETA updates to ~2x/sec -- per-chunk instantaneous
        // rate is too noisy (chunk sizes vary a lot) to display directly.
        guard dt >= 0.5 else { return }
        let speed = Double(sum - lastSampleBytes) / dt
        lastSampleDate = now
        lastSampleBytes = sum
        let remaining = max(0, total - sum)
        let eta = speed > 0 ? Double(remaining) / speed : nil
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
        guard let path = pathByTaskID[downloadTask.taskIdentifier],
              let file = files[path] else { return }
        let dest = file.destination
        let fm = FileManager.default
        // An error page (401 gated, 404) must not be saved as the file.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            Task { @MainActor in
                let message = Self.accessMessage(status: status, repo: self.currentModelID)
                self.cancelDownload()   // clears downloadError: set after
                self.downloadError = message
            }
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
            }
        } catch {
            saveError = "Failed to save \(dest.lastPathComponent): \(error.localizedDescription)"
        }
        let allDone = files.values.allSatisfy { $0.isDone }
        Task { @MainActor in
            if let saveError {
                self.downloadError = saveError
            }
            if allDone {
                if let destRoot = self.currentDestRoot {
                    FileManager.default.createFile(
                        atPath: destRoot.appendingPathComponent(Self.completionMarkerName).path, contents: nil
                    )
                }
                self.downloadingID = nil
                self.downloadStatusText = "Done"
                self.downloadSpeedBytesPerSec = 0
                self.downloadETASeconds = nil
                self.onAllDone?()
                self.onAllDone = nil
            }
        }
    }

    /// Why Hugging Face refused a repo's files, in words.
    nonisolated static func accessMessage(status: Int, repo: String) -> String {
        switch status {
        case 401, 403:
            return String(format: NSLocalizedString(
                "Hugging Face refused %@ (HTTP %d): it's gated -- accept its license on huggingface.co/%@ and check the token in Settings → Models.",
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
        var request = request
        if request.url?.host != "huggingface.co" {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            self.downloadError = error.localizedDescription
        }
    }
}
