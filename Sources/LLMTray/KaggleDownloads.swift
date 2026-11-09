import Foundation
import LLMTrayCore

/// Which place a model download comes from (adr/0032): Hugging Face, or our
/// Kaggle mirror when the setting says so or Hugging Face can't be reached
/// (a network that blocks it).
@MainActor
enum ModelSource {
    static var preference: ModelDownloadSource {
        ModelDownloadSource(rawValue: UserDefaults.standard[Pref.modelDownloadSource]) ?? .automatic
    }

    /// The last answer, kept a while: a download of several repos (a music
    /// model and its planner) asks once.
    private static var lastProbe: (at: Date, reachable: Bool)?

    /// Hugging Face answers its API with JSON. A network that blocks it
    /// fails the connection, or answers with its own page (HTML, a 403):
    /// either is "not reachable".
    static func hubReachable() async -> Bool {
        if let last = lastProbe, Date().timeIntervalSince(last.at) < (last.reachable ? 300 : 60) { return last.reachable }
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models?limit=1")!, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        var reachable = false
        if let (data, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           (try? JSONSerialization.jsonObject(with: data)) is [Any] {
            reachable = true
        }
        lastProbe = (Date(), reachable)
        return reachable
    }

    /// A Hugging Face download's failure, said plainly when the cause is
    /// that Hugging Face can't be reached and there's no Kaggle copy to
    /// fall back to; other failures as they are.
    static func explain(_ error: Error, repo: String) async -> Error {
        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { return error }
        guard await !hubReachable() else { return error }
        return Unreachable(repo: repo)
    }

    struct Unreachable: LocalizedError {
        let repo: String
        var errorDescription: String? {
            guard Kaggle.Mirror.handle(forHubRepo: repo) == nil else {
                // Reachable when it started, not now: a retry comes from Kaggle.
                return String(format: NSLocalizedString(
                    "Hugging Face stopped answering during the download. %@ has a copy on Kaggle: choose Kaggle first in Settings → Models to take it from there.",
                    comment: "download: HF lost mid-download, Kaggle mirror exists; repo"), repo)
            }
            return String(format: NSLocalizedString(
                "Hugging Face can't be reached from this network, and %@ has no copy on Kaggle to download instead.",
                comment: "download: HF blocked, no Kaggle mirror; repo"), repo)
        }
    }

    /// The Kaggle copy to download `repo` from, or nil: Hugging Face.
    static func kaggleCopy(of repo: String) async -> Kaggle.Handle? {
        await preference.kaggleCopy(of: repo) { await hubReachable() }
    }
}

/// Why a Kaggle download stopped, in words.
enum KaggleDownloadError: LocalizedError {
    case refused(status: Int, message: String?, handle: Kaggle.Handle)
    case noVersion(Kaggle.Handle)
    case noFiles(Kaggle.Handle)
    case truncated(file: String, expected: Int64, got: Int64)
    case failed(file: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .refused(let status, let message, let handle):
            return KaggleFetch.accessMessage(status: status, message: message, handle: handle)
        case .noVersion(let handle):
            return String(format: NSLocalizedString("Kaggle has no version of %@ to download.", comment: "kaggle: a variation without versions"), handle.path)
        case .noFiles(let handle):
            return String(format: NSLocalizedString("No files found in %@ on Kaggle.", comment: ""), handle.path)
        case .truncated(let file, let expected, let got):
            return "\(file): expected \(expected) bytes, got \(got)"
        case .failed(let file, let reason):
            return "\(file): \(reason)"
        }
    }
}

/// Kaggle's side of a download: a variation's current version and files,
/// and the whole of it fetched into a folder (image, music and voice models,
/// which the Hugging Face path fetches with huggingface_hub). The chat
/// models' downloads (HFModelBrowser) list the same way and fetch the
/// files themselves.
@MainActor
enum KaggleFetch {
    struct Listing {
        var version: Int
        var files: [Kaggle.File]
    }

    /// The variation's current version and every file of it (all pages).
    static func listing(_ handle: Kaggle.Handle) async throws -> Listing {
        KaggleToken.refresh()
        guard let url = Kaggle.instanceURL(handle) else { throw KaggleDownloadError.noVersion(handle) }
        let instance: Kaggle.Instance = try await get(url, handle: handle)
        guard let version = instance.versionNumber else { throw KaggleDownloadError.noVersion(handle) }
        var files: [Kaggle.File] = []
        var token: String?
        var pages = 0
        repeat {
            pages += 1
            guard let url = Kaggle.filesURL(handle, version: version, pageToken: token) else { break }
            let page: Kaggle.FilePage = try await get(url, handle: handle)
            files += page.files ?? []
            token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        } while token != nil && pages < 100
        guard !files.isEmpty else { throw KaggleDownloadError.noFiles(handle) }
        return Listing(version: version, files: files)
    }

    private static func get<T: Decodable>(_ url: URL, handle: Kaggle.Handle) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 30)
        KaggleToken.authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw KaggleDownloadError.refused(status: status, message: try? JSONDecoder().decode(Kaggle.APIError.self, from: data).message, handle: handle)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Every file of `handle` (those matching `patterns`, if given) into
    /// `dir`, as huggingface_hub's snapshot_download would put them. A file
    /// already there at its size is kept (a retry picks up). Cancelling the
    /// task stops it; what's half-written goes.
    /// Returns the version it fetched.
    @discardableResult
    static func download(_ handle: Kaggle.Handle, patterns: [String]? = nil, into dir: String,
                         status: ((String) -> Void)? = nil) async throws -> Int {
        do {
            return try await fetchAll(handle, patterns: patterns, into: dir, status: status)
        } catch {
            // A cancel is a cancel, whichever request it stopped.
            if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func fetchAll(_ handle: Kaggle.Handle, patterns: [String]?, into dir: String,
                                 status: ((String) -> Void)?) async throws -> Int {
        let listing = try await listing(handle)
        let files = Kaggle.select(listing.files, patterns: patterns)
        guard !files.isEmpty else { throw KaggleDownloadError.noFiles(handle) }
        let root = URL(fileURLWithPath: dir)
        // `dir` is the caller's staging folder (another repo's files may
        // share it). A file of this listing already there is kept only if
        // an earlier attempt of this very version left it (its stamp, one
        // per variation); otherwise every one of them goes before the stamp
        // is written, so a retry never mixes two versions.
        let stamp = root.appendingPathComponent(".llmtray-kaggle-\(handle.model)-\(handle.variation)")
        let identity = "\(handle.path)@\(listing.version)"
        let reuse = (try? String(contentsOf: stamp, encoding: .utf8)) == identity
        let fm = FileManager.default
        if !reuse {
            for file in files {
                let url = root.appendingPathComponent(file.name)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try identity.write(to: stamp, atomically: true, encoding: .utf8)
        let total = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var done: Int64 = 0
        let bigFiles = files.filter { DownloadParts.ranges(size: $0.size ?? 0) != nil }.count
        let connections = DownloadParts.connections(bigFiles: max(1, bigFiles))
        for file in files {
            try Task.checkCancellation()
            guard let url = Kaggle.fileURL(handle, version: listing.version, path: file.name) else {
                throw KaggleDownloadError.failed(file: file.name, reason: "bad path")
            }
            let destination = root.appendingPathComponent(file.name)
            let size = file.size ?? 0
            let onDisk = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            if reuse, size > 0, onDisk == size {
                done += size
                continue
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            let report: (Int64) -> Void = { written in
                guard let status, total > 0 else { return }
                status(String(format: NSLocalizedString("Downloading from Kaggle… %lld%%", comment: "kaggle download progress, percent"),
                              Int64(Double(base + written) / Double(total) * 100)))
            }
            report(0)
            if let ranges = DownloadParts.ranges(size: size) {
                try await fetchInParts(url: url, file: file.name, to: destination, size: size, ranges: ranges,
                                       connections: connections, handle: handle, progress: report)
            } else {
                try await fetchWhole(url: url, file: file.name, to: destination, size: size, handle: handle)
            }
            done += size
        }
        try? FileManager.default.removeItem(at: stamp)
        return listing.version
    }

    /// A small file in one request, retried twice on a dropped connection.
    private static func fetchWhole(url: URL, file: String, to destination: URL, size: Int64, handle: Kaggle.Handle) async throws {
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
            var request = URLRequest(url: url, timeoutInterval: 60)
            KaggleToken.authorize(&request)
            do {
                let (temp, response) = try await URLSession.shared.download(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    let body = try? Data(contentsOf: temp)
                    try? FileManager.default.removeItem(at: temp)
                    // Busy or a server hiccup: worth another try.
                    if status == 429 || status >= 500 {
                        throw KaggleDownloadError.failed(file: file, reason: "HTTP \(status)")
                    }
                    throw KaggleDownloadError.refused(status: status, message: body.flatMap { try? JSONDecoder().decode(Kaggle.APIError.self, from: $0).message }, handle: handle)
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
                let got = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? -1
                if size > 0, got != size {
                    try? FileManager.default.removeItem(at: destination)
                    throw KaggleDownloadError.truncated(file: file, expected: size, got: got)
                }
                return
            } catch let error as KaggleDownloadError {
                // A refusal won't change on a retry; a short file might.
                if case .refused = error { throw error }
                lastError = error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw KaggleDownloadError.failed(file: file, reason: lastError?.localizedDescription ?? "download failed")
    }

    /// A big file in byte ranges over several connections (PartFetcher),
    /// into a partial file renamed into place when every byte is in.
    private static func fetchInParts(url: URL, file: String, to destination: URL, size: Int64, ranges: [ClosedRange<Int64>],
                                     connections: Int, handle: Kaggle.Handle, progress: @escaping (Int64) -> Void) async throws {
        HFModelBrowser.removePartials(of: destination)
        let partial = destination.appendingPathExtension(UUID().uuidString + ".llmtray-partial")
        // Whatever way this ends, no partial stays (moved into place first
        // when it's done).
        defer { try? FileManager.default.removeItem(at: partial) }
        KaggleToken.refresh()
        let authorization = KaggleToken.value.map { (host: Kaggle.host, header: KaggleToken.header($0)) }
        let fetcher = PartFetcher(url: url, authorization: authorization, partial: partial, size: size, ranges: ranges,
                                  connections: connections)
        let end = OnceOutcome()
        let outcome: PartFetcher.Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                end.set(continuation)
                fetcher.onProgress = { written in MainActor.assumeIsolated { progress(written) } }
                fetcher.onFinish = { end.resume($0) }
                fetcher.start()
            }
        } onCancel: {
            // No onFinish after a cancel (one already on its way is
            // ignored by OnceOutcome): the wait ends here.
            fetcher.cancel()
            end.resume(.failed("cancelled"))
        }
        try Task.checkCancellation()
        switch outcome {
        case .done:
            try? FileManager.default.removeItem(at: destination)
            do { try FileManager.default.moveItem(at: partial, to: destination) } catch {
                try? FileManager.default.removeItem(at: partial)
                throw KaggleDownloadError.failed(file: file, reason: error.localizedDescription)
            }
        case .rangeIgnored:
            try? FileManager.default.removeItem(at: partial)
            try await fetchWhole(url: url, file: file, to: destination, size: size, handle: handle)
        case .refused(let status):
            try? FileManager.default.removeItem(at: partial)
            throw KaggleDownloadError.refused(status: status, message: nil, handle: handle)
        case .failed(let reason):
            try? FileManager.default.removeItem(at: partial)
            throw KaggleDownloadError.failed(file: file, reason: reason)
        }
    }

    /// Why Kaggle refused, in words: gated models need their terms accepted
    /// on kaggle.com and a token in Settings.
    nonisolated static func accessMessage(status: Int, message: String?, handle: Kaggle.Handle) -> String {
        let detail = message.map { " (\($0))" } ?? ""
        switch status {
        case 401, 403:
            return String(format: NSLocalizedString(
                "Kaggle refused %@ (HTTP %d)%@: it's gated or private. Accept its terms on its Kaggle page, then add a Kaggle token in Settings → Models.",
                comment: "kaggle: gated download refused; variation, status, server's reason"), handle.path, status, detail)
        case 404:
            return String(format: NSLocalizedString("%@ wasn't found on Kaggle.", comment: ""), handle.path)
        default:
            return String(format: NSLocalizedString("Kaggle answered HTTP %d for %@.", comment: ""), status, handle.path) + detail
        }
    }
}

/// A continuation resumed once, whichever comes first: the fetcher's end
/// or a cancel (which may come before the continuation exists).
private final class OnceOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PartFetcher.Outcome, Never>?
    private var outcome: PartFetcher.Outcome?
    private var resumed = false

    func set(_ continuation: CheckedContinuation<PartFetcher.Outcome, Never>) {
        lock.lock()
        if let outcome, !resumed {
            resumed = true
            lock.unlock()
            continuation.resume(returning: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ outcome: PartFetcher.Outcome) {
        lock.lock()
        guard !resumed, self.outcome == nil else { lock.unlock(); return }
        self.outcome = outcome
        guard let continuation else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        continuation.resume(returning: outcome)
    }
}
