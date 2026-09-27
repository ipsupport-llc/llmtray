import Foundation

/// What a project's icon in the sidebar shows (adr/0012, UI -- the user's
/// design): the folder while nothing happens, a progress ring while it
/// indexes, ⏸ when paused, "waiting" while the chat model or a generator
/// holds the work, ⚠︎ with a count once files failed.
public struct ProjectRing: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case folder
        case indexing
        /// Paused automatically (the chat generates, a generator runs).
        case waiting
        /// Paused by the user.
        case paused
        /// Idle, with files that failed or aren't supported.
        case failed
    }

    public var kind: Kind
    /// Finished files of this run over its total, 0...1; nil when there's
    /// no count yet (files being copied in).
    public var fraction: Double?
    /// Files that need a look: this run's failures, or the project's.
    public var failed: Int

    public static let folder = ProjectRing(kind: .folder, fraction: nil, failed: 0)

    public init(kind: Kind, fraction: Double?, failed: Int) {
        self.kind = kind
        self.fraction = fraction
        self.failed = failed
    }

    /// `progress` nil or idle: nothing under way. `failedDocuments`: the
    /// project's documents failed or not supported, as the index has them.
    public init(progress: ProjectIndexProgress?, failedDocuments: Int) {
        let failed = max(failedDocuments, progress?.failed ?? 0)
        guard let p = progress, p.isActive else {
            self = failed > 0 ? ProjectRing(kind: .failed, fraction: nil, failed: failed) : .folder
            return
        }
        let fraction = p.total > 0 ? min(1, max(0, Double(p.done + p.failed) / Double(p.total))) : nil
        let kind: Kind
        switch p.state {
        case .paused: kind = .paused
        case .waiting: kind = .waiting
        case .running, .idle: kind = .indexing
        }
        self.init(kind: kind, fraction: fraction, failed: failed)
    }

    /// Anything to show instead of the folder.
    public var isShown: Bool { kind != .folder }
    /// Pause, Resume and Stop apply.
    public var isActive: Bool { kind == .indexing || kind == .waiting || kind == .paused }
}

/// The ring's hover text and the Files view's progress line: "Indexing 120
/// of 450 files · reading · ~20 min left". The wording comes from the app
/// (localized); what's said, in what order and how the time is rounded is
/// here, tested.
public struct ProjectIndexStatusText: Sendable {
    public struct Strings: Sendable {
        /// %1$lld the file being indexed (or reached), %2$lld the run's total.
        public var indexing = "Indexing %1$lld of %2$lld files"
        public var paused = "Paused at %1$lld of %2$lld files"
        public var pausedNoCount = "Paused"
        public var waiting = "Waiting for the chat or a generator to finish"
        public var addingFiles = "Adding files"
        public var copying = "copying"
        public var reading = "reading"
        public var embedding = "embedding"
        public var lessThanAMinute = "less than a minute left"
        /// %lld minutes.
        public var minutesLeft = "~%lld min left"
        /// %1$lld hours, %2$lld minutes.
        public var hoursMinutesLeft = "~%1$lld h %2$lld min left"
        /// %lld hours.
        public var hoursLeft = "~%lld h left"
        public var wordsOnly = "search by words only"
        /// %lld files.
        public var failed = "%lld failed"
        /// Idle: %lld files.
        public var needsALook = "%lld files couldn't be indexed"
        public var separator = " · "

        public init() {}
    }

    public var strings: Strings

    public init(strings: Strings = Strings()) {
        self.strings = strings
    }

    /// nil when there's nothing to say (idle, nothing failed).
    public func text(progress: ProjectIndexProgress?, failedDocuments: Int) -> String? {
        let failed = max(failedDocuments, progress?.failed ?? 0)
        guard let p = progress, p.isActive else {
            return failed > 0 ? String(format: strings.needsALook, Int64(failed)) : nil
        }
        var parts: [String] = []
        let finished = p.done + p.failed
        switch p.state {
        case .paused:
            parts.append(p.total > 0 ? String(format: strings.paused, Int64(min(finished, p.total)), Int64(p.total)) : strings.pausedNoCount)
        case .waiting:
            parts.append(strings.waiting)
            if p.total > 0 { parts.append(String(format: strings.indexing, Int64(min(finished + 1, p.total)), Int64(p.total))) }
        case .running, .idle:
            if p.total > 0 {
                // The file under way: the first reads "1 of 450", the last "450 of 450".
                parts.append(String(format: strings.indexing, Int64(min(finished + 1, p.total)), Int64(p.total)))
            } else {
                parts.append(strings.addingFiles)
            }
        }
        if p.state != .paused, let stage = p.stage {
            switch stage {
            case .copying: parts.append(strings.copying)
            case .reading: parts.append(strings.reading)
            case .embedding: parts.append(strings.embedding)
            }
        }
        if p.state == .running, let eta = p.remainingSeconds { parts.append(timeLeft(eta)) }
        if p.failed > 0 || failed > 0 { parts.append(String(format: strings.failed, Int64(failed))) }
        if p.wordsOnly { parts.append(strings.wordsOnly) }
        return parts.joined(separator: strings.separator)
    }

    /// Rough on purpose: whole minutes under an hour, 5-minute steps under
    /// ten hours, whole hours past that.
    public func timeLeft(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return strings.lessThanAMinute }
        if seconds < 60 { return strings.lessThanAMinute }
        let minutes = Int64((seconds / 60).rounded())
        if minutes < 60 { return String(format: strings.minutesLeft, max(1, minutes)) }
        if minutes < 600 {
            let stepped = Int64((Double(minutes) / 5).rounded()) * 5
            let h = stepped / 60, m = stepped % 60
            return m == 0 ? String(format: strings.hoursLeft, h) : String(format: strings.hoursMinutesLeft, h, m)
        }
        return String(format: strings.hoursLeft, Int64((Double(minutes) / 60).rounded()))
    }
}

/// Files dropped on a project or picked in Add Files… (adr/0012, "Formats
/// offered"): what goes to the ingest, what's refused at once and why.
public enum ProjectFileDrop {
    public struct Sorted: Equatable, Sendable {
        /// Offered formats, in the order given, each once.
        public var accepted: [URL] = []
        /// Not a format this version indexes.
        public var notSupported: [URL] = []
        /// Folders: linked folders come later (v1b).
        public var folders: [URL] = []

        public var isEmpty: Bool { accepted.isEmpty && notSupported.isEmpty && folders.isEmpty }
    }

    /// Hidden files (.DS_Store and the like) are left out without a word.
    public static func sort(_ items: [(url: URL, isDirectory: Bool)]) -> Sorted {
        var sorted = Sorted()
        var seen: Set<String> = []
        for (url, isDirectory) in items {
            let path = url.standardizedFileURL.path
            guard url.isFileURL, seen.insert(path).inserted, !url.lastPathComponent.hasPrefix(".") else { continue }
            if isDirectory {
                sorted.folders.append(url)
            } else if ProjectFileFormats.isOffered(url) {
                sorted.accepted.append(url)
            } else {
                sorted.notSupported.append(url)
            }
        }
        return sorted
    }

    /// Dropped or chosen files sorted as `sort` does, each one looked up
    /// (a folder, or a package that counts as a file) off the caller's
    /// actor: on a network volume or a slow disk that can take a while.
    /// What can't be looked up counts as a file.
    public static func sort(_ urls: [URL]) async -> Sorted {
        let work: @Sendable () -> Sorted = {
            sort(urls.map { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return (url: url, isDirectory: values?.isDirectory == true && values?.isPackage != true)
            })
        }
        return (try? await ProcessRunner.offMain(work)) ?? Sorted()
    }

    /// Names for a message: the first `limit`, and how many more.
    public static func names(_ urls: [URL], limit: Int = 3) -> (shown: [String], more: Int) {
        let names = urls.map(\.lastPathComponent)
        return (Array(names.prefix(limit)), max(0, names.count - limit))
    }
}

/// A project's documents counted for the Files view's header and the chat's
/// "Searches N files".
public struct ProjectFileTotals: Equatable, Sendable {
    public var files = 0
    public var searchable = 0
    public var pages = 0
    public var bytes: Int64 = 0
    /// Failed or not supported, or its last re-index failed (the earlier
    /// revision still searchable, the error kept): the ring's ⚠︎.
    public var failed = 0
    /// Stopped before they were indexed (Index Now).
    public var notIndexed = 0

    public init() {}

    public init(_ documents: [IndexedDocument]) {
        for d in documents where d.status != .removing {
            files += 1
            if d.status.isSearchable { searchable += 1 }
            pages += d.pages ?? 0
            bytes += d.bytes
            if d.status == .failed || d.status == .unsupported || (d.status.isSearchable && d.error != nil) { failed += 1 }
            if d.status == .notIndexed { notIndexed += 1 }
        }
    }
}
