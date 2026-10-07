import Foundation
import LLMTrayCore

/// Fetches one big file in byte ranges over several connections at once
/// (DownloadParts) into `partial`, each range written at its offset as it
/// arrives -- no part files, no joining, no second copy on disk. Every part
/// knows how far it got, so a pause or a dropped connection continues it
/// from there with a new range request (URLSession's own resume data would
/// ask for "N-", past the part's end). Each request goes to the repo's
/// resolve URL, so a CDN link that expired during a pause doesn't matter.
///
/// Its own session and serial queue: the writes stay off the main thread.
/// Only a part's current task may write to it or end it: a cancelled one's
/// late callbacks are ignored. Callbacks come on the main queue.
final class PartFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Equatable {
        case done
        /// An HTTP status that won't change on a retry (401, 403, 404...).
        case refused(Int)
        case failed(String)
    }

    private struct Part {
        let range: ClosedRange<Int64>
        var written: Int64 = 0
        var task: URLSessionDataTask?
        var attempts = 0
        var isDone: Bool { written == Int64(range.count) }
        var next: ClosedRange<Int64> { (range.lowerBound + written)...range.upperBound }
    }

    /// Bytes written so far, at most once per ~0.25 s.
    var onProgress: ((Int64) -> Void)?
    var onFinish: ((Outcome) -> Void)?

    let partial: URL
    private let url: URL
    private let token: String?
    private let size: Int64
    private let queue = OperationQueue()
    private var session: URLSession!
    private var handle: FileHandle?
    private var parts: [Part]
    private var paused = false
    private var finished = false
    private var lastReport: TimeInterval = 0
    /// Set at once by cancel() (not through the queue): a start still
    /// waiting on the queue mustn't touch the file system after it.
    private let cancelLock = NSLock()
    private var cancelledNow = false
    /// Attempts per part (connection drops, 429, 5xx), with a growing wait.
    private static let maxAttempts = 8

    init(url: URL, token: String?, partial: URL, size: Int64, ranges: [ClosedRange<Int64>], connections: Int) {
        self.url = url
        self.token = token
        self.partial = partial
        self.size = size
        self.parts = ranges.map { Part(range: $0) }
        super.init()
        queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = max(1, connections)
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelledNow
    }

    /// Creates `partial` at the file's full size (sparse until written) and
    /// starts every part.
    func start() {
        queue.addOperation { [self] in
            guard !isCancelled, !finished else { return }
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: partial.path, contents: nil) else {
                    return finish(.failed("can't create \(partial.lastPathComponent)"))
                }
                let h = try FileHandle(forWritingTo: partial)
                do {
                    try h.truncate(atOffset: UInt64(size))
                } catch {
                    try? h.close()
                    throw error
                }
                handle = h
            } catch {
                return finish(.failed(error.localizedDescription))
            }
            for i in parts.indices { startPart(i) }
        }
    }

    func pause() {
        queue.addOperation { [self] in
            guard !finished else { return }
            paused = true
            for i in parts.indices {
                parts[i].task?.cancel()
                parts[i].task = nil
            }
        }
    }

    func resume() {
        queue.addOperation { [self] in
            guard paused, !finished else { return }
            paused = false
            // Paused after the last byte, before its task ended: done.
            if parts.allSatisfy(\.isDone) { return complete() }
            for i in parts.indices where !parts[i].isDone { startPart(i) }
        }
    }

    /// Stops for good, no callbacks after it; `partial` is the caller's to
    /// remove (the fetcher won't create it afterwards).
    func cancel() {
        cancelLock.lock()
        cancelledNow = true
        cancelLock.unlock()
        queue.addOperation { [self] in
            finished = true
            onProgress = nil
            onFinish = nil
            for i in parts.indices { parts[i].task?.cancel() }
            try? handle?.close()
            handle = nil
            session.invalidateAndCancel()
        }
    }

    // MARK: - On the queue

    private func startPart(_ i: Int) {
        guard !finished, !paused, !isCancelled, !parts[i].isDone, parts[i].task == nil else { return }
        var request = URLRequest(url: url)
        if let token, url.host == "huggingface.co" { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(DownloadParts.header(parts[i].next), forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        task.taskDescription = String(i)
        parts[i].task = task
        parts[i].attempts += 1
        task.resume()
    }

    /// The part `task` is the current task of, or nil (a cancelled one's
    /// late callback).
    private func part(of task: URLSessionTask) -> Int? {
        guard let i = task.taskDescription.flatMap(Int.init), parts.indices.contains(i), parts[i].task === task else { return nil }
        return i
    }

    private func complete() {
        report(force: true)
        finish(.done)
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        for i in parts.indices {
            parts[i].task?.cancel()
            parts[i].task = nil
        }
        if outcome == .done { try? handle?.synchronize() }
        try? handle?.close()
        handle = nil
        // Cancel, not finish: a failed file's other ranges stop now.
        session.invalidateAndCancel()
        guard !isCancelled else { return }
        let onFinish = onFinish
        DispatchQueue.main.async { onFinish?(outcome) }
    }

    private func report(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastReport >= 0.25, !isCancelled else { return }
        lastReport = now
        let total = parts.reduce(0) { $0 + $1.written }
        let onProgress = onProgress
        DispatchQueue.main.async { onProgress?(total) }
    }

    /// A part that stopped short (dropped, or a 429 / 5xx): again from
    /// where it stopped, after a growing wait; the file fails after
    /// maxAttempts.
    private func retry(_ i: Int, _ why: String) {
        parts[i].task = nil
        guard parts[i].attempts < Self.maxAttempts else {
            return finish(.failed("\(url.lastPathComponent): \(why)"))
        }
        let wait = min(30.0, pow(2.0, Double(parts[i].attempts - 1)))
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.queue.addOperation { self?.startPart(i) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished, let i = part(of: dataTask) else { return completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return finish(.failed("not an HTTP response"))
        }
        let status = http.statusCode
        if DownloadParts.isPart(status: status, contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                                of: parts[i].next, size: size) {
            return completionHandler(.allow)
        }
        completionHandler(.cancel)
        switch status {
        case 200:
            finish(.failed("the server sent the whole file for a part"))
        case 429, 500...599:
            retry(i, "HTTP \(status)")
        case 206:
            finish(.failed("an unexpected range in the answer"))
        default:
            finish(.refused(status))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, let i = part(of: dataTask), let handle else { return }
        let left = Int64(parts[i].range.count) - parts[i].written
        let chunk = Int64(data.count) > left ? data.prefix(Int(left)) : data
        do {
            try handle.seek(toOffset: UInt64(parts[i].range.lowerBound + parts[i].written))
            try handle.write(contentsOf: chunk)
        } catch {
            return finish(.failed(error.localizedDescription))
        }
        parts[i].written += Int64(chunk.count)
        report()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished, let i = part(of: task) else { return }
        parts[i].task = nil
        if paused { return }
        if parts[i].isDone {
            if parts.allSatisfy(\.isDone) { complete() }
            return
        }
        // Cut off, or a short 206: the rest of the range.
        retry(i, error?.localizedDescription ?? "a range ended early")
    }

    /// The token is for huggingface.co: a redirect to the file CDN (signed
    /// URLs) must not carry it; the Range header goes along.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        if request.url?.host == "huggingface.co", request.url?.scheme == "https", let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        if request.value(forHTTPHeaderField: "Range") == nil, let i = part(of: task) {
            request.setValue(DownloadParts.header(parts[i].next), forHTTPHeaderField: "Range")
        }
        completionHandler(request)
    }
}
