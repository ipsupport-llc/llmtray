import Foundation

/// The parent side of `LLMTray --extract`: runs the child under
/// `ProcessRunner.runSupervised` with a document's caps and turns its lines
/// and its end into pages or one typed failure. A document is complete or
/// failed -- never silently truncated: a cap hit anywhere fails it whole.
public enum DocumentExtraction {
    public struct Document: Equatable, Sendable {
        public var kind: DocumentKind
        public var pages: [ExtractedPage]
    }

    /// Runs `executable` (the app binary) as `<executable> --extract <path>
    /// --caps <json>` plus `extraArguments`. `useJetsam: false` leaves the
    /// kernel limit out, as on a system without the private symbol.
    public static func run(executable: String, url: URL, caps: ExtractionCaps = ExtractionCaps(),
                           extraArguments: [String] = [], useJetsam: Bool = true) async throws -> Document {
        let collector = Collector(caps: caps)
        let supervision = ProcessRunner.Supervision(
            timeout: caps.timeoutSeconds, maxStdoutBytes: caps.maxOutputBytes,
            maxFootprintBytes: UInt64(max(0, caps.memoryBytes)),
            jetsamLimitBytes: useJetsam ? caps.memoryBytes : nil)
        let exit = try await ProcessRunner.runSupervised(
            executable, ["--extract", url.path, "--caps", caps.json, "--parent", String(getpid())] + extraArguments,
            supervision: supervision, onLine: { collector.consume($0) })
        return try collector.finish(exit)
    }

    /// Takes the child's lines as they come (from the supervising thread),
    /// then the way it ended.
    public final class Collector: @unchecked Sendable {
        private let caps: ExtractionCaps
        private let lock = NSLock()
        private var pages: [ExtractedPage] = []
        private var summary: ExtractionSummary?
        private var stopped: ExtractionError?
        private var textBytes = 0

        public init(caps: ExtractionCaps) { self.caps = caps }

        /// False: stop the child (a cap, or a broken protocol).
        public func consume(_ line: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            func stop(_ e: ExtractionError) -> Bool { stopped = e; return false }
            guard summary == nil else { return stop(.crashed("output after the summary")) }
            guard let message = ExtractorMessage(line: line) else { return stop(.crashed("unreadable output line")) }
            switch message {
            case .page(let page):
                guard page.page == pages.count + 1 else { return stop(.crashed("page \(page.page) out of order")) }
                textBytes += page.text.utf8.count
                if textBytes > caps.maxTextBytes { return stop(.tooLarge(.text)) }
                if pages.count >= caps.maxPages { return stop(.tooLarge(.pages)) }
                pages.append(page)
            case .summary(let s):
                summary = s
            }
            return true
        }

        public func finish(_ exit: ProcessRunner.SupervisedExit) throws -> Document {
            lock.lock(); defer { lock.unlock() }
            switch exit.limit {
            case .timeout?, .cpu?: throw ExtractionError.timeout
            case .memory?: throw ExtractionError.memory
            case .stdout?: throw ExtractionError.tooLarge(.output)
            case .stoppedByCaller?: throw stopped ?? ExtractionError.crashed("stopped")
            case nil: break
            }
            if let signal = exit.signal { throw ExtractionError.crashed("signal \(signal)") }
            if let status = exit.status, status != 0 { throw ExtractionError.crashed("exit \(status)") }
            guard let summary else { throw ExtractionError.crashed("no summary") }
            if let failure = summary.failure { throw failure }
            guard summary.pages == pages.count else { throw ExtractionError.crashed("\(summary.pages) pages announced, \(pages.count) received") }
            guard summary.kind.isSupported else { throw ExtractionError.unsupported(summary.kind.rawValue) }
            let withText = pages.filter(\.hasText)
            if withText.isEmpty { throw ExtractionError.empty }
            if withText.allSatisfy(\.isJunk) { throw ExtractionError.junk }
            return Document(kind: summary.kind, pages: pages)
        }
    }
}
