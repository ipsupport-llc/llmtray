import Foundation

/// Which of project_files' modes a turn declares (adr/0012, "The chat
/// side"), decided at the turn's start from the project's counts: no tool
/// for a chat without a project, a project without files or the feature
/// off (an ordinary chat's request); only the listing while nothing is
/// searchable yet; search, read and the listing once a file is.
public enum ProjectFilesMode: Equatable, Sendable {
    case none, listing, all

    public init(featureOn: Bool, project: ProjectContext?) {
        guard featureOn, let files = project?.files, files.documents > 0 else {
            self = .none
            return
        }
        self = files.searchable > 0 ? .all : .listing
    }
}

/// The one project tool, `project_files(query?, doc?, pages?, cursor?, pin?)`:
/// its declarations per mode, how its arguments read, what its answers say.
public enum ProjectFiles {
    public static let toolName = "project_files"

    /// What its calls are to the trust barrier: file text, the listing too.
    public static let trustKind = ToolTrust.Kind.project

    /// Search results: the default and the most a call gets.
    public static let defaultHits = 5
    public static let maxHits = 10

    /// The arguments as they're read: every mode's fields, whatever this
    /// turn declares (a model may send a field it saw earlier), plus
    /// `top_k`, taken but never declared (tokens for a rarely useful knob).
    public static let schema = ToolSchema(toolName, allDescription, [
        .init("query", .string, aliases: ["q", "search", "question", "text", "keywords", "search_query", "search_term"]),
        .init("doc", .integer, docDescription, aliases: ["file", "document", "doc_id", "file_id", "document_id", "id", "file_number"]),
        .init("pages", .string, pagesDescription, aliases: ["page", "page_range", "range", "page_number", "pages_range"]),
        .init("cursor", .string, aliases: ["next", "next_cursor", "continue", "continuation", "token"]),
        .init("pin", .boolean, pinDescription, aliases: ["pinned"]),
        .init("top_k", .integer, aliases: ["k", "limit", "n", "count", "max_results", "num_results", "results"]),
    ])

    static let allDescription = "Search and read the files of this chat's project. No arguments: list them."
    static let listingDescription = "List the files of this chat's project (none can be searched yet)."
    static let docDescription = "A file's id"
    static let pagesDescription = "With doc: pages to read verbatim, e.g. \"3\" or \"3-5\""
    static let pinDescription = "With doc: true loads the whole file into memory (context) for this project's chats, when the user asks; false stops"

    /// The declaration for a mode; nil for `.none`.
    public static func declaredSchema(for mode: ProjectFilesMode) -> ToolSchema? {
        switch mode {
        case .none: return nil
        case .listing: return ToolSchema(toolName, listingDescription, [])
        case .all: return ToolSchema(toolName, allDescription, schema.params.filter { $0.name != "top_k" })
        }
    }

    public static func definition(for mode: ProjectFilesMode) -> [String: Any]? { declaredSchema(for: mode)?.definition }

    // MARK: - reading a call

    /// A call as the tool will run it.
    public enum Request: Equatable, Sendable {
        /// The files whose id is `from` or more (`list:N` names the next
        /// one's id: a file removed or added meanwhile doesn't shift it).
        case list(from: Int)
        case search(query: String, doc: Int64?, limit: Int)
        case read(ReadCursor)
        /// Pin `doc` (its whole text in the project's requests) or unpin it.
        case pin(doc: Int64, on: Bool)
    }

    /// Where a read continues: `doc` at revision `rev`, from `offset` (code
    /// points) of `page`, through `last`. As text `3:1:12:450:20` -- what a
    /// cut result hands back (`doc:page:offset:last` without the revision
    /// reads the current one). An offset is only meaningful in the revision
    /// it was counted in: a file re-indexed since is read again from a page.
    public struct ReadCursor: Equatable, Sendable {
        public var doc: Int64
        public var rev: Int64?
        public var page: Int
        public var offset: Int
        public var last: Int

        public init(doc: Int64, rev: Int64? = nil, page: Int, offset: Int = 0, last: Int) {
            self.doc = doc
            self.rev = rev
            self.page = page
            self.offset = offset
            self.last = last
        }

        public var text: String { rev.map { "\(doc):\($0):\(page):\(offset):\(last)" } ?? "\(doc):\(page):\(offset):\(last)" }

        public init?(_ text: String) {
            var parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            var rev: Int64?
            if parts.count == 5 {
                guard let r = Int64(parts[1]), r > 0 else { return nil }
                rev = r
                parts.remove(at: 1)
            }
            guard parts.count == 4, let doc = Int64(parts[0]), let page = Int(parts[1]), let offset = Int(parts[2]),
                  let last = Int(parts[3]), doc > 0, page > 0, offset >= 0, last >= page else { return nil }
            self.init(doc: doc, rev: rev, page: page, offset: offset, last: last)
        }
    }

    static let listCursorPrefix = "list:"

    /// The values ToolArgumentParser read against `schema` as a request, or
    /// the error the model gets (what's wrong and a call to send instead).
    public static func request(_ values: [String: Any]) -> Result<Request, ArgumentError> {
        func text(_ key: String) -> String? {
            (values[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let doc = values["doc"] as? Int
        if let doc, doc <= 0 {
            return .failure(ArgumentError("\"doc\" is a file's id from the list (1, 2, ...), not \(doc)",
                                          retry: #"{"doc":<integer>}"#))
        }
        if let on = values["pin"] as? Bool {
            guard let doc else {
                return .failure(ArgumentError("\"pin\" needs \"doc\", the file's id (call with no arguments to list them)",
                                              retry: "{\"doc\":<integer>,\"pin\":\(on)}"))
            }
            return .success(.pin(doc: Int64(doc), on: on))
        }
        if let cursor = text("cursor") {
            if cursor.lowercased().hasPrefix(listCursorPrefix), let from = Int(cursor.dropFirst(listCursorPrefix.count)), from >= 0 {
                return .success(.list(from: from))
            }
            guard let read = ReadCursor(cursor) else {
                return .failure(ArgumentError("\"cursor\" must be one a result gave, not \"\(cursor.prefix(40))\"",
                                              retry: #"{"doc":<integer>,"pages":"3-5"}"#))
            }
            return .success(.read(read))
        }
        if let query = text("query") {
            let limit = min(maxHits, max(1, values["top_k"] as? Int ?? defaultHits))
            return .success(.search(query: String(query.prefix(500)), doc: doc.map(Int64.init), limit: limit))
        }
        let pages = text("pages")
        if let doc {
            guard let range = pages.map(pageRange) ?? 1...Int.max else {
                return .failure(ArgumentError("\"pages\" must be a page or a range like \"3-5\", not \"\(pages!.prefix(40))\"",
                                              retry: "{\"doc\":\(doc),\"pages\":\"3-5\"}"))
            }
            return .success(.read(ReadCursor(doc: Int64(doc), page: range.lowerBound, last: range.upperBound)))
        }
        if pages != nil {
            return .failure(ArgumentError("\"pages\" needs \"doc\", the file's id (call with no arguments to list them)",
                                          retry: "{\"doc\":<integer>,\"pages\":\"\(pages!.prefix(20))\"}"))
        }
        return .success(.list(from: 0))
    }

    /// A call that answers with names only (the listing, a pin): no file
    /// content comes back, so a pin after it is still the user's.
    public static func returnsNamesOnly(_ values: [String: Any]) -> Bool {
        switch request(values) {
        case .success(.list), .success(.pin), .failure: return true
        case .success(.search), .success(.read): return false
        }
    }

    /// "12", "3-5", "3–5", "3..5", "3 to 5", "p. 3", "pages 3-5", "3-" (to
    /// the end), "all"; a reversed range is turned round. nil: none of these.
    static func pageRange(_ raw: String) -> ClosedRange<Int>? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if s == "all" || s == "*" { return 1...Int.max }
        for prefix in ["pages", "page", "pp.", "pp", "p."] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        for dash in ["–", "—", "..", " to ", "to"] { s = s.replacingOccurrences(of: dash, with: "-") }
        s = s.replacingOccurrences(of: " ", with: "")
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        func number(_ p: Substring) -> Int? { Int(p).flatMap { $0 > 0 && $0 < 1_000_000 ? $0 : nil } }
        switch parts.count {
        case 1:
            return number(parts[0]).map { $0...$0 }
        case 2:
            guard let a = number(parts[0]) else { return nil }
            if parts[1].isEmpty { return a...Int.max }
            guard let b = number(parts[1]) else { return nil }
            return min(a, b)...max(a, b)
        default:
            return nil
        }
    }

    public struct ArgumentError: Error, Equatable {
        public var problem: String
        /// The arguments of a call to send instead.
        public var retry: String

        init(_ problem: String, retry: String) {
            self.problem = problem
            self.retry = retry
        }

        public var message: String { "\(toolName): \(problem). Retry: \(toolName)(\(retry))" }
    }

    // MARK: - what it answers besides file text

    /// The chat left the project (moved, or the project was deleted) since
    /// the turn began.
    public static let notInProjectText = "Not run: this chat is no longer in the project these files belong to. "
        + "Answer without them; the user can ask again."
    public static let projectGoneText = "Not run: this chat's project has been removed. Answer without its files."

    static func status(_ d: IndexedDocument) -> String {
        switch d.status {
        case .searchable, .embedded: return "ready"
        case .staged: return "waiting to be indexed"
        case .extracting: return "being read"
        case .failed: return "couldn't be read" + (d.error.map { ": \($0.prefix(80))" } ?? "")
        case .empty: return "no text found"
        case .unsupported: return "format not supported"
        case .notIndexed: return "not indexed (stopped by the user)"
        case .removing: return "being removed"
        }
    }

    /// A name for a result's heading: at most `maxBytes` (cut with …), nil
    /// when it's that short already.
    static func shortName(_ name: String, maxBytes: Int = 60) -> String? {
        guard name.utf8.count > maxBytes else { return nil }
        var out = ""
        for scalar in name.unicodeScalars {
            guard out.utf8.count + String(scalar).utf8.count + "…".utf8.count <= maxBytes else { break }
            out.unicodeScalars.append(scalar)
        }
        return out + "…"
    }

    /// Names, at most `limit` of them, "and N more".
    static func names(_ docs: [IndexedDocument], limit: Int = 5) -> String {
        let shown = docs.prefix(limit).map { "\($0.doc). \(shortName($0.name) ?? $0.name)" }.joined(separator: ", ")
        return docs.count > limit ? shown + " and \(docs.count - limit) more" : shown
    }
}

/// What embeds a search's query: the embedder's shared runner in the app
/// (`RunnerEmbedder`, interactive priority), a stand-in in tests.
public protocol ProjectQueryEmbedder: AnyObject {
    /// The vector set it matches (`EmbedderEntry.vectorSetModel`).
    var model: String { get }
    func embedQuery(_ text: String) async throws -> [Float]
}

extension RunnerEmbedder: ProjectQueryEmbedder {
    /// A query jumps ahead of queued index batches in the runner; paused
    /// (a generation holds or waits for the GPU) it throws `.paused` at once.
    public func embedQuery(_ text: String) async throws -> [Float] {
        let result = try await runner.embed([text], kind: .query, timeout: 10)
        guard result.count == 1 else { throw EmbedRunner.Failure.protocolViolation("no query vector") }
        return result.floats(0)
    }
}

/// What project_files answered: file text for the budget to fit, a plain
/// answer, or a refusal (left out of later turns).
public enum ProjectFilesAnswer: Equatable {
    case output(ProjectToolOutput)
    case text(String)
    case refused(String)
}

/// project_files' work (adr/0012): the listing, the hybrid search and
/// verbatim reads, through the project's reader in the app-wide registry.
/// Every call checks that the chat is still in the project (and the
/// project exists) when it starts and again just before it answers.
@MainActor
public final class ProjectFilesService {
    public struct Environment {
        public var registry: ProjectIndexRegistry
        /// The query embedder now; nil: not installed (words only).
        public var queryEmbedder: () -> ProjectQueryEmbedder?
        /// Why meaning search is off this session, when it is (the
        /// embedder kept failing).
        public var wordsOnlyReason: () -> String?
        /// A query's embedding at most (a cold start included); past it the
        /// search goes by words.
        public var embedTimeout: TimeInterval
        /// Pins or unpins a file (the app's indexer, which then shows it);
        /// nil: straight through the project's writer.
        public var setPinned: ((UUID, Int64, Bool) async throws -> Void)?

        public init(registry: ProjectIndexRegistry, queryEmbedder: @escaping () -> ProjectQueryEmbedder?,
                    wordsOnlyReason: @escaping () -> String? = { nil }, embedTimeout: TimeInterval = 15,
                    setPinned: ((UUID, Int64, Bool) async throws -> Void)? = nil) {
            self.registry = registry
            self.queryEmbedder = queryEmbedder
            self.wordsOnlyReason = wordsOnlyReason
            self.embedTimeout = embedTimeout
            self.setPinned = setPinned
        }
    }

    private let env: Environment
    /// Kept free of the byte budget: a piece shown earlier in the turn is
    /// named in a line that can be longer than a very short piece.
    static let slackBytes = 64

    public init(environment: Environment) {
        env = environment
    }

    /// Runs `request` for `project`. `byteBudget`: what the next request
    /// has room for (ProjectTextBudget), so a read is cut where its cursor
    /// continues rather than by the chat's fitting; `fileTextAllowed`
    /// false: no room was left earlier in the turn -- search and read refuse (the tool is no longer declared).
    /// `stillOwned`: the chat is still in the project, and it exists.
    /// `pinLimitTokens`: what the project's pinned files may take with the
    /// chat's model (PinLimit); nil: this chat can't pin.
    public func run(_ request: ProjectFiles.Request, project: UUID, byteBudget: Int, fileTextAllowed: Bool = true,
                    pinLimitTokens: Int? = nil, stillOwned: () -> Bool) async -> ProjectFilesAnswer {
        guard stillOwned() else { return .refused(ProjectFiles.notInProjectText) }
        let handle: ProjectIndexHandle
        do {
            handle = try await env.registry.open(project)
        } catch is ProjectIndexHandle.Closed {
            return .refused(ProjectFiles.projectGoneText)
        } catch {
            return .text("\(ProjectFiles.toolName): the project's index couldn't be opened (\(error)). Answer without the files.")
        }
        let answer: ProjectFilesAnswer
        do {
            let (docs, pins) = try await handle.read { (try $0.documents(), try $0.pins()) }
            let budget = max(0, byteBudget - Self.slackBytes)
            switch request {
            case .list(let from):
                answer = .output(listing(docs, from: from, project: project, budget: budget, note: nil, pins: pins))
            case .pin(let doc, let on):
                answer = try await pin(doc, on: on, docs: docs, pins: pins, handle: handle, project: project,
                                       limitTokens: pinLimitTokens, stillOwned: stillOwned)
            case .search, .read:
                if !fileTextAllowed { return .refused(ProjectTextBudget.noRoomText) }
                if !docs.contains(where: { $0.status.isSearchable }) {
                    let note = "No file can be searched or read yet -- they're still being indexed, or couldn't be read. The files:"
                    answer = .output(listing(docs, from: 0, project: project, budget: budget, note: note, pins: pins))
                } else if case .search(let query, let doc, let limit) = request {
                    answer = try await search(query, doc: doc, limit: limit, docs: docs, handle: handle, project: project)
                } else if case .read(let cursor) = request {
                    answer = try await read(cursor, docs: docs, handle: handle, project: project, budget: budget)
                } else {
                    answer = .text("")
                }
            }
        } catch is ProjectIndexHandle.Closed {
            return .refused(ProjectFiles.projectGoneText)
        } catch {
            return .text("\(ProjectFiles.toolName): the files couldn't be read (\(error)). Answer without them.")
        }
        // Checked again before any file text goes out: the chat may have
        // moved (or the project gone) while it searched.
        guard stillOwned() else { return .refused(ProjectFiles.notInProjectText) }
        return answer
    }

    // MARK: - listing

    func listing(_ docs: [IndexedDocument], from: Int, project: UUID, budget: Int, note: String?, pins: [Int64] = []) -> ProjectToolOutput {
        guard !docs.isEmpty else { return ProjectToolOutput(project: project, preamble: "This project has no files now.") }
        let searchable = docs.contains { $0.status.isSearchable }
        var head = note.map { $0 + "\n" } ?? ""
        head += "\(docs.count) file(s) in this project (id. name -- pages -- status):"
        let hint = searchable && note == nil
            ? "\nSearch: \(ProjectFiles.toolName)({\"query\":\"...\"}); read: \(ProjectFiles.toolName)({\"doc\":1,\"pages\":\"1-2\"}); load a whole file into memory when asked: {\"doc\":1,\"pin\":true}. Only a pinned file is in memory." : ""
        // Documents come in id order.
        let start = docs.firstIndex { $0.doc >= Int64(from) } ?? docs.count
        func row(_ d: IndexedDocument, name: String) -> String {
            let pages = d.pages.map { "\($0) page\($0 == 1 ? "" : "s")" } ?? "? pages"
            return "\(d.doc). \(name) -- \(pages) -- \(ProjectFiles.status(d))" + (pins.contains(d.doc) ? " -- pinned" : "")
        }
        func page(_ rows: [String]) -> ProjectToolOutput {
            var out = ProjectToolOutput(project: project, preamble: ([head] + rows).joined(separator: "\n") + hint)
            let next = start + rows.count
            if next < docs.count {
                out.epilogue = "\(docs.count - next) more: \(ProjectFiles.toolName)({\"cursor\":\"\(ProjectFiles.listCursorPrefix)\(docs[next].doc)\"})"
            }
            return out
        }
        var lines: [String] = []
        var output = ProjectToolOutput(project: project, preamble: head + hint)
        for d in docs[start...] {
            let trial = page(lines + [row(d, name: d.name)])
            if trial.fitsWhole(byteBudget: budget) {
                lines.append(row(d, name: d.name))
                output = trial
                continue
            }
            if lines.isEmpty {
                // Its own line is longer than the room: its name cut to fit,
                // so the listing still goes on (the cursor past it) rather
                // than ending at this file.
                let scalars = Array(d.name.unicodeScalars)
                func cut(_ n: Int) -> String { String(String.UnicodeScalarView(scalars[0..<n])) + "…" }
                var lo = -1, hi = scalars.count - 1
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if page([row(d, name: cut(mid))]).fitsWhole(byteBudget: budget) { lo = mid } else { hi = mid - 1 }
                }
                if lo >= 0 {
                    output = page([row(d, name: cut(lo))])
                } else {
                    // Not even its id fits: no file's line would (no cursor
                    // past one that wasn't shown).
                    output = ProjectToolOutput(project: project, preamble: head + "\n(no room to list them in this chat's context)")
                }
            }
            break
        }
        return output
    }

    // MARK: - search

    enum WordsOnly {
        case notInstalled, paused, unavailable(String), timedOut, noVectors, otherModel

        var text: String {
            switch self {
            case .notInstalled: return "the meaning-search model isn't installed"
            case .paused: return "an image or music generation is using the GPU"
            case .unavailable(let why): return "meaning search is unavailable: \(why.prefix(80))"
            case .timedOut: return "the meaning-search model didn't answer in time"
            case .noVectors: return "no file is indexed for meaning yet"
            case .otherModel: return "the files are being re-indexed for another meaning-search model"
            }
        }
    }

    func search(_ query: String, doc: Int64?, limit: Int, docs: [IndexedDocument], handle: ProjectIndexHandle,
                project: UUID) async throws -> ProjectFilesAnswer {
        var scope = docs
        if let doc {
            guard let target = docs.first(where: { $0.doc == doc }) else { return .text(noSuchFile(doc, docs)) }
            guard target.status.isSearchable else {
                return .text("File \(doc) (\(target.name)) is \(ProjectFiles.status(target)): it can't be searched yet.")
            }
            scope = [target]
        }
        let searchable = scope.filter { $0.status.isSearchable }
        let embedded = searchable.filter { $0.status == .embedded }
        var vector: [Float]?
        var model: String?
        var wordsOnly: WordsOnly?
        if embedded.isEmpty {
            wordsOnly = .noVectors   // nothing to score: the embedder isn't even started
        } else if let reason = env.wordsOnlyReason() {
            wordsOnly = .unavailable(reason)
        } else if let embedder = env.queryEmbedder() {
            // The files' vectors another model's: nothing this query's vector
            // could score, so the runner isn't started for it.
            let active = try await handle.read { try $0.activeVectorModel() }
            if let active, active != embedder.model {
                wordsOnly = .otherModel
            } else {
                model = embedder.model
                switch await Self.embed(query, with: embedder, timeout: env.embedTimeout) {
                case .success(let v): vector = v
                case .failure(let failure): wordsOnly = failure.reason
                }
            }
        } else {
            wordsOnly = .notInstalled
        }
        let result = try await handle.search(query, queryVector: vector, model: model,
                                             options: IndexSearchOptions(limit: limit, document: doc))
        if vector != nil, !result.usedDense { wordsOnly = .otherModel }

        var notes: [String] = []
        if let wordsOnly {
            notes.append("Searched by words only (\(wordsOnly.text)): try the words the files would use.")
        } else if embedded.count < searchable.count {
            let words = searchable.filter { $0.status != .embedded }
            notes.append("Searched by words only in \(ProjectFiles.names(words)) (not yet indexed for meaning).")
        }
        if doc == nil {
            let pending = docs.filter { [.staged, .extracting].contains($0.status) }
            if !pending.isEmpty { notes.append("Still being indexed, not searched: \(ProjectFiles.names(pending)).") }
            let failed = docs.filter { $0.status == .failed }
            if !failed.isEmpty { notes.append("Couldn't be read, not searched: \(ProjectFiles.names(failed)).") }
        }
        if result.hits.isEmpty {
            notes.append("No match for \"\(query.prefix(80))\"" + (doc.map { " in file \($0)" } ?? "") + ".")
        }
        let hits = result.hits.map {
            // A long name and heading cut in the result (the citation keeps
            // the name whole): at a small budget the hit's text still fits.
            ProjectHit(id: "c\($0.chunk)", doc: Int($0.doc), rev: Int($0.rev), page: $0.page, chunk: Int($0.chunk),
                       name: $0.name, label: ProjectFiles.shortName($0.name),
                       heading: $0.heading.map { ProjectFiles.shortName($0) ?? $0 }, text: $0.text)
        }
        return .output(ProjectToolOutput(project: project, preamble: notes.joined(separator: "\n"), hits: hits))
    }

    /// The query's vector, or why the search goes by words: paused at once
    /// while a generation holds the GPU; given up after `timeout`.
    static func embed(_ query: String, with embedder: ProjectQueryEmbedder, timeout: TimeInterval) async -> Result<[Float], WordsOnlyFailure> {
        // Raced without a task group: past the timeout the search goes on at
        // once, not after the request's own cancellation (the runner may
        // take a while to give it up).
        let work = Task { try await embedder.embedQuery(query) }
        let first = FirstResult<Result<[Float], Error>?>()
        let outcome: Result<[Float], Error>? = await withCheckedContinuation { continuation in
            first.continuation = continuation
            Task { first.resume(await work.result) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9))
                first.resume(nil)
            }
        }
        guard let outcome else {
            work.cancel()
            return .failure(WordsOnlyFailure(.timedOut))
        }
        switch outcome {
        case .success(let vector):
            return .success(vector)
        case .failure(EmbedRunner.Failure.paused):
            return .failure(WordsOnlyFailure(.paused))
        case .failure(EmbedRunner.Failure.unresponsive), .failure(EmbedRunner.Failure.runner(code: "timeout", _)):
            return .failure(WordsOnlyFailure(.timedOut))
        case .failure(let error):
            return .failure(WordsOnlyFailure(.unavailable("\(error)")))
        }
    }

    /// The first of several racers resumes the continuation; the rest are ignored.
    final class FirstResult<T>: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<T, Never>?

        func resume(_ value: T) {
            let c: CheckedContinuation<T, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            c?.resume(returning: value)
        }
    }

    struct WordsOnlyFailure: Error {
        let reason: WordsOnly
        init(_ reason: WordsOnly) { self.reason = reason }
    }

    // MARK: - read

    func read(_ cursor: ProjectFiles.ReadCursor, docs: [IndexedDocument], handle: ProjectIndexHandle, project: UUID,
              budget: Int) async throws -> ProjectFilesAnswer {
        guard let d = docs.first(where: { $0.doc == cursor.doc }) else { return .text(noSuchFile(cursor.doc, docs)) }
        guard d.status.isSearchable else {
            return .text("File \(d.doc) (\(d.name)) is \(ProjectFiles.status(d)): it can't be read yet.")
        }
        let (doc, rev) = (d.doc, d.rev)
        var cursor = cursor
        var changedNote: String?
        if let cited = cursor.rev, cited != rev {
            // Indexed again since: read again from that page of the current
            // revision (an offset counts only in the one it was counted in).
            // Short (no name): at a small budget the page's text still fits.
            changedNote = "File \(doc) changed since that read (indexed again): page \(cursor.page) is read again from its start."
            cursor = ProjectFiles.ReadCursor(doc: doc, rev: rev, page: cursor.page, offset: 0, last: cursor.last)
        }
        let requested = cursor.page...cursor.last
        let lengths = try await handle.read { try $0.pageLengths(doc: doc, rev: rev, in: requested) }
        let pageCount = d.pages ?? lengths.last?.page ?? 0
        guard !lengths.isEmpty else {
            let none = "File \(d.doc) (\(d.name)) has \(pageCount) page(s); page \(cursor.page) isn't one of them."
            return .text(changedNote.map { $0 + " " + none } ?? none)
        }
        let last = lengths.last!.page
        func cursorText(_ page: Int, _ offset: Int) -> String {
            "Not all shown: continue with \(ProjectFiles.toolName)({\"cursor\":\"\(ProjectFiles.ReadCursor(doc: doc, rev: rev, page: page, offset: offset, last: last).text)\"})."
        }
        // A long name cut in the result (the citation keeps it whole): at a
        // small budget the page's text still fits, and each cursor moves on.
        let label = ProjectFiles.shortName(d.name)
        var notes = changedNote.map { [$0] } ?? []
        if cursor.last != Int.max, cursor.last > last, cursor.offset == 0 {
            notes.append("\(label ?? d.name) has \(pageCount) page(s).")
        }
        // Its id names the range it holds: a piece of another length (the
        // same page read again under another budget) isn't "shown earlier".
        func hit(_ page: Int, _ start: Int, _ text: String) -> ProjectHit {
            ProjectHit(id: "r\(doc).\(rev).\(page).\(start)-\(start + text.unicodeScalars.count)", doc: Int(doc), rev: Int(rev),
                       page: page, name: d.name, label: label, text: text.isEmpty ? "(no text on this page)" : text)
        }
        func fill(_ preamble: String) async throws -> ProjectToolOutput {
            var output = ProjectToolOutput(project: project, preamble: preamble)
            for (i, entry) in lengths.enumerated() {
                let start = entry.page == cursor.page ? min(cursor.offset, entry.length) : 0
                let remaining = entry.length - start
                // Never more than could fit: a code point is at least a byte.
                let text = try await handle.read { try $0.pageText(doc: doc, rev: rev, page: entry.page, offset: start, count: min(remaining, budget)) } ?? ""
                let isLast = i == lengths.count - 1
                var whole = output
                whole.hits.append(hit(entry.page, start, text))
                whole.epilogue = isLast ? "" : cursorText(lengths[i + 1].page, 0)
                if text.unicodeScalars.count == remaining, whole.fitsWhole(byteBudget: budget) {
                    output = whole
                    continue
                }
                // The page doesn't fit whole: as much as does, cut at a space,
                // and the cursor where it stopped.
                let scalars = Array(text.unicodeScalars)
                func trial(_ n: Int) -> ProjectToolOutput {
                    var t = output
                    t.hits.append(hit(entry.page, start, String(String.UnicodeScalarView(scalars[0..<n]))))
                    t.epilogue = cursorText(entry.page, start + n)
                    return t
                }
                var lo = 0, hi = scalars.count - 1
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if trial(mid).fitsWhole(byteBudget: budget) { lo = mid } else { hi = mid - 1 }
                }
                let minimum = max(1, min(scalars.count, ProjectToolOutput.minimumPieceBytes / 4))
                var n = lo
                if n > 0, n < scalars.count, !scalars[n].properties.isWhitespace,
                   let space = scalars[max(0, n - 120)..<n].lastIndex(where: { $0.properties.isWhitespace }),
                   space > n / 2, space + 1 >= minimum {
                    n = space + 1
                }
                if n >= minimum {
                    output = trial(n)
                } else {
                    output.epilogue = cursorText(entry.page, start)
                    if output.hits.isEmpty { output.preamble = "No room for this page in this chat's context." }
                }
                break
            }
            return output
        }
        // The notes shortened, then left out, before the text is: a read
        // always moves on while any of it fits.
        var output = try await fill(notes.joined(separator: "\n"))
        if output.hits.isEmpty, !notes.isEmpty {
            if changedNote != nil { output = try await fill("Indexed again since that read.") }
            if output.hits.isEmpty { output = try await fill("") }
        }
        return .output(output)
    }

    // MARK: - pin

    /// Pins or unpins a file for the project's chats. From the user's next
    /// message on: a turn's requests carry what was pinned at its start.
    func pin(_ doc: Int64, on: Bool, docs: [IndexedDocument], pins: [Int64], handle: ProjectIndexHandle, project: UUID,
             limitTokens: Int?, stillOwned: () -> Bool) async throws -> ProjectFilesAnswer {
        let tool = ProjectFiles.toolName
        guard let limitTokens else { return .text("\(tool): files can't be pinned in this chat.") }
        guard let d = docs.first(where: { $0.doc == doc }) else { return .text(noSuchFile(doc, docs)) }
        let name = ProjectFiles.shortName(d.name) ?? d.name
        func write() async throws {
            if let set = env.setPinned {
                try await set(project, doc, on)
            } else {
                try await handle.write { try $0.setPinned(doc, on) }
            }
        }
        guard on else {
            guard pins.contains(doc) else { return .text("File \(doc) (\(name)) isn't pinned.") }
            guard stillOwned() else { return .refused(ProjectFiles.notInProjectText) }
            try await write()
            return .text("Unpinned file \(doc) (\(name)): from the user's next message it's no longer in your context; "
                         + "search or read it with \(tool) when needed.")
        }
        let measured = docs.filter { pins.contains($0.doc) || $0.doc == doc }
        let tokens = try await handle.read { try $0.pinTokens(of: measured) }
        switch PinnedFiles.check(doc, docs: docs, pins: pins, tokens: tokens, limitTokens: limitTokens) {
        case .noSuchFile:
            return .text(noSuchFile(doc, docs))
        case .alreadyPinned:
            return .text("File \(doc) (\(name)) is already pinned: its whole text is in your context from the next message of the user.")
        case .noText:
            return .text("Not pinned: file \(doc) (\(name)) is \(ProjectFiles.status(d)), so it has no text to pin yet.")
        case .tooLong(let t, let used, let limit):
            let pinned = used > 0 ? " (≈\(used) taken by the files pinned already)" : ""
            return .text("Not pinned: file \(doc) (\(name)) is ≈\(t) tokens, and this project's pinned files may take ≈\(limit) "
                         + "with this model\(pinned). Tell the user it's too long to pin; read it by pages instead: "
                         + "\(tool)({\"doc\":\(doc),\"pages\":\"1-3\"}).")
        case .fits(let t):
            guard stillOwned() else { return .refused(ProjectFiles.notInProjectText) }
            try await write()
            return .text("Pinned file \(doc) (\(name), ≈\(t) tokens): from the user's next message its whole text is in your "
                         + "context in this project's chats. For this answer, read it with \(tool)({\"doc\":\(doc),\"pages\":\"1-3\"}) if you need it.")
        }
    }

    func noSuchFile(_ doc: Int64, _ docs: [IndexedDocument]) -> String {
        let ids = docs.map(\.doc)
        let range = ids.isEmpty ? "none" : (ids.count == 1 ? "\(ids[0])" : "\(ids.first!)-\(ids.last!)")
        return "\(ProjectFiles.toolName): no file \(doc) in this project (ids: \(range)). "
            + "Call \(ProjectFiles.toolName)() to list them."
    }
}

extension ProjectToolOutput {
    /// Rendered in `byteBudget` bytes, nothing is cut or left out: the
    /// same text as with no limit.
    public func fitsWhole(byteBudget: Int) -> Bool {
        rendered(byteBudget: byteBudget).text == rendered(byteBudget: 1 << 40).text
    }
}

/// Where a citation chip leads (adr/0012, "Citations"): the file, read-only
/// from the project's index without opening it for writing -- also while
/// project files are off.
public enum CitationTarget: Equatable {
    /// The file (a copy, or the linked file); `changed`: its revision isn't
    /// the one the answer cited.
    case file(URL, page: Int, changed: Bool)
    /// Removed from the project, or its file is gone.
    case gone

    public static func resolve(_ c: Citation, projectDirectory: URL) -> CitationTarget {
        let path = projectDirectory.appendingPathComponent(ProjectIndex.databaseName).path
        guard FileManager.default.fileExists(atPath: path),
              let db = try? SQLiteConnection(path: path, readOnly: true) else { return .gone }
        defer { db.close() }
        db.setBusyTimeout(milliseconds: 1000)
        guard let d = try? ProjectIndex.documents(db, where: "doc = ? AND status != 'removing'", [.int(Int64(c.doc))]).first,
              let url = try? ProjectIndex.file(of: d, directory: projectDirectory, db),
              FileManager.default.fileExists(atPath: url.path) else { return .gone }
        return .file(url, page: c.page, changed: d.rev != Int64(c.rev))
    }

    /// The cited chunk's text, verbatim from its page (what the PDF viewer
    /// highlights); nil without a chunk, or once the cited revision's chunks
    /// are gone. Read-only, like `resolve`.
    public static func quote(_ c: Citation, projectDirectory: URL) -> String? {
        guard let chunk = c.chunk else { return nil }
        let path = projectDirectory.appendingPathComponent(ProjectIndex.databaseName).path
        guard FileManager.default.fileExists(atPath: path),
              let db = try? SQLiteConnection(path: path, readOnly: true) else { return nil }
        defer { db.close() }
        db.setBusyTimeout(milliseconds: 1000)
        return (try? db.rows("""
            SELECT substr(p.text, c.start + 1, c.len) FROM chunks c
            JOIN pages p ON p.doc = c.doc AND p.rev = c.rev AND p.page = c.page
            WHERE c.id = ? AND c.doc = ? AND c.rev = ? AND c.page = ?
            """, [.int(Int64(chunk)), .int(Int64(c.doc)), .int(Int64(c.rev)), .int(Int64(c.page))]) { $0.text(0) })?.first
    }
}

/// The in-app PDF viewer's pure part: which files it opens, the page a
/// citation lands on, and where the cited text is on it.
public enum CitationViewer {
    /// PDFs open in the viewer (at the cited page); other formats in their
    /// app, as before.
    public static func opensInViewer(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// A citation's 1-based page as a page index of a document with
    /// `pageCount` pages, clamped to it (a changed file may be shorter);
    /// nil for a document without pages.
    public static func pageIndex(_ page: Int, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        return min(max(page, 1), pageCount) - 1
    }

    /// Where `quote` (a chunk, as the index stored its page's text) is in
    /// `pageText` (the page's text now), in `pageText`'s UTF-16 units:
    /// the whole quote, else its first line of at least `minimumLine`
    /// characters (a partial highlight beats none); nil when neither is
    /// there -- nothing is highlighted then.
    public static func quoteRange(_ quote: String, in pageText: String) -> NSRange? {
        let text = pageText as NSString
        let whole = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty, text.length > 0 else { return nil }
        // Not .literal: a decomposed "é" (PDFKit on macOS 14) matches a composed one.
        let found = text.range(of: whole)
        if found.location != NSNotFound { return found }
        guard let line = whole.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.count >= minimumLine }) else { return nil }
        let partial = text.range(of: String(line.prefix(maximumLine)))
        return partial.location == NSNotFound ? nil : partial
    }

    /// A shorter first line matches too easily elsewhere on the page.
    static let minimumLine = 8
    static let maximumLine = 200
}
