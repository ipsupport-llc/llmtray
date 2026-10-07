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
/// Callbacks come on the main queue.
final class PartFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Part {
        let range: ClosedRange<Int64>
        var written: Int64 = 0
        var task: URLSessionDataTask?
        var retries = 0
        var isDone: Bool { written == Int64(range.count) }
    }

    /// Bytes written so far, at most once per ~0.25 s.
    var onProgress: ((Int64) -> Void)?
    /// nil: every part is in; else why the file failed.
    var onFinish: ((String?) -> Void)?

    private let url: URL
    private let token: String?
    private let partial: URL
    private let queue = OperationQueue()
    private var session: URLSession!
    private var handle: FileHandle?
    private var parts: [Part]
    private var taskPart: [Int: Int] = [:]
    private var paused = false
    private var finished = false
    private var lastReport: TimeInterval = 0
    private static let maxRetries = 3

    init(url: URL, token: String?, partial: URL, ranges: [ClosedRange<Int64>]) {
        self.url = url
        self.token = token
        self.partial = partial
        self.parts = ranges.map { Part(range: $0) }
        super.init()
        queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = DownloadParts.maxParts
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// Creates `partial` at the file's full size (sparse until written) and
    /// starts every part.
    func start() {
        queue.addOperation { [self] in
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: partial)
                guard fm.createFile(atPath: partial.path, contents: nil) else {
                    return finish("can't create \(partial.lastPathComponent)")
                }
                let h = try FileHandle(forWritingTo: partial)
                try h.truncate(atOffset: UInt64(parts.last.map { $0.range.upperBound + 1 } ?? 0))
                handle = h
            } catch {
                return finish(error.localizedDescription)
            }
            for i in parts.indices { startPart(i) }
        }
    }

    func pause() {
        queue.addOperation { [self] in
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
            for i in parts.indices where !parts[i].isDone { startPart(i) }
        }
    }

    /// Stops for good; `partial` is the caller's to remove.
    func cancel() {
        queue.addOperation { [self] in
            finished = true
            for i in parts.indices { parts[i].task?.cancel() }
            try? handle?.close()
            handle = nil
            session.invalidateAndCancel()
        }
    }

    // On the queue.
    private func startPart(_ i: Int) {
        guard !finished, !paused, !parts[i].isDone, parts[i].task == nil else { return }
        var request = URLRequest(url: url)
        if let token, url.host == "huggingface.co" { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let from = parts[i].range.lowerBound + parts[i].written
        request.setValue(DownloadParts.header(from...parts[i].range.upperBound), forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        parts[i].task = task
        taskPart[task.taskIdentifier] = i
        task.resume()
    }

    private func finish(_ error: String?) {
        guard !finished else { return }
        finished = true
        for i in parts.indices { parts[i].task?.cancel() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        let onFinish = onFinish
        DispatchQueue.main.async { onFinish?(error) }
    }

    private func report(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastReport >= 0.25 else { return }
        lastReport = now
        let total = parts.reduce(0) { $0 + $1.written }
        let onProgress = onProgress
        DispatchQueue.main.async { onProgress?(total) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let i = taskPart[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            return completionHandler(.cancel)
        }
        let from = parts[i].range.lowerBound + parts[i].written
        let range = from...parts[i].range.upperBound
        if DownloadParts.isPart(status: http.statusCode, contentRange: http.value(forHTTPHeaderField: "Content-Range"), of: range) {
            return completionHandler(.allow)
        }
        completionHandler(.cancel)
        finish(http.statusCode == 200
               ? "the server sent the whole file for a part"
               : "HTTP \(http.statusCode) for a part of \(url.lastPathComponent)")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, let i = taskPart[dataTask.taskIdentifier], let handle else { return }
        let left = Int64(parts[i].range.count) - parts[i].written
        let chunk = Int64(data.count) > left ? data.prefix(Int(left)) : data
        do {
            try handle.seek(toOffset: UInt64(parts[i].range.lowerBound + parts[i].written))
            try handle.write(contentsOf: chunk)
        } catch {
            return finish(error.localizedDescription)
        }
        parts[i].written += Int64(chunk.count)
        parts[i].retries = 0   // getting somewhere: the retries are for a stuck part
        report()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let i = taskPart.removeValue(forKey: task.taskIdentifier), !finished else { return }
        parts[i].task = nil
        if paused { return }
        if parts[i].isDone {
            if parts.allSatisfy(\.isDone) {
                report(force: true)
                finish(nil)
            }
            return
        }
        // Cut off (an error, or a clean end short of the range): from where
        // it stopped, a few times.
        guard parts[i].retries < Self.maxRetries else {
            return finish(error?.localizedDescription ?? "a part of \(url.lastPathComponent) ended early")
        }
        parts[i].retries += 1
        startPart(i)
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
        if request.value(forHTTPHeaderField: "Range") == nil,
           let i = taskPart[task.taskIdentifier] {
            let from = parts[i].range.lowerBound + parts[i].written
            request.setValue(DownloadParts.header(from...parts[i].range.upperBound), forHTTPHeaderField: "Range")
        }
        completionHandler(request)
    }
}
