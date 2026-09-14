import Foundation

extension Notification.Name {
    static let showHFBrowser = Notification.Name("LLMTray.showHFBrowser")
    static let modelsDidChange = Notification.Name("LLMTray.modelsDidChange")
}

struct HFModelSummary: Identifiable, Decodable, Hashable {
    var id: String { modelId }
    let modelId: String
    let downloads: Int?
    let likes: Int?

    enum CodingKeys: String, CodingKey {
        case modelId = "id"
        case downloads
        case likes
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
        Task {
            do {
                var comps = URLComponents(string: "https://huggingface.co/api/models")!
                comps.queryItems = [
                    URLQueryItem(name: "search", value: q),
                    // Narrows results to repos tagged for the mlx library --
                    // this server can only load mlx-format weights, so a
                    // plain PyTorch/GGUF hit would just fail to start.
                    URLQueryItem(name: "filter", value: "mlx"),
                    URLQueryItem(name: "sort", value: "downloads"),
                    URLQueryItem(name: "direction", value: "-1"),
                    URLQueryItem(name: "limit", value: "30"),
                ]
                let (data, _) = try await URLSession.shared.data(from: comps.url!)
                results = try JSONDecoder().decode([HFModelSummary].self, from: data)
            } catch {
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    func download(_ model: HFModelSummary, completion: @escaping () -> Void) {
        guard downloadingID == nil else { return }
        downloadingID = model.id
        currentModelID = model.id
        isPaused = false
        downloadProgress = 0
        downloadError = nil
        downloadStatusText = "Fetching file list…"
        onAllDone = completion

        Task {
            do {
                let treeURL = URL(string: "https://huggingface.co/api/models/\(model.id)/tree/main")!
                let (data, _) = try await URLSession.shared.data(from: treeURL)
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
            task = session.downloadTask(with: url)
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

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            self.downloadError = error.localizedDescription
        }
    }
}
