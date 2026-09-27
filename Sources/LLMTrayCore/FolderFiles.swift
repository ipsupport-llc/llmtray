import Darwin
import Foundation

/// One `files` call (adr/0014): a folder gives a listing page (or, with
/// `onlyDuplicates`, the duplicate summary and a page of groups), a file
/// gives its info (with `hash`, its SHA-256). Everything is bounded and
/// paged by an opaque cursor: a folder of 10,000 files is never dumped.
public struct FolderQuery: Equatable, Sendable {
    /// Below the grant root; empty is the root.
    public var components: [String]
    public var recursive = false
    /// A shell pattern on names (`*.pdf`), case-insensitive.
    public var pattern: String?
    public var onlyDuplicates = false
    public var hash = false
    public var cursor: String?
    public var includeHidden = false

    public init(components: [String], recursive: Bool = false, pattern: String? = nil, onlyDuplicates: Bool = false,
                hash: Bool = false, cursor: String? = nil, includeHidden: Bool = false) {
        self.components = components
        self.recursive = recursive
        self.pattern = pattern
        self.onlyDuplicates = onlyDuplicates
        self.hash = hash
        self.cursor = cursor
        self.includeHidden = includeHidden
    }
}

public struct ListingPage: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Below the grant root (what `change_files` takes).
        public var path: String
        public var kind: EntryKind
        public var size: Int64?
        public var modified: Date
        /// Set only when true (Hardening 5).
        public var hardLinked: Bool?
        /// In iCloud, not downloaded. Set only when true.
        public var notDownloaded: Bool? = nil
        /// Folders and packages with something denied inside
        /// (`contains_protected_items`), or too large to check (`unchecked`);
        /// nil otherwise.
        public var protectedInside: ProtectedContents? = nil
    }

    public var entries: [Entry]
    /// The listed folder itself, when it isn't the grant's: denied items
    /// inside it (`contains_protected_items`), or too large to check.
    public var protectedInside: ProtectedContents? = nil
    /// Matching entries found (all of them, unless `scanTruncated`).
    public var total: Int
    /// The scan stopped at its cap, or left something out (a subfolder past
    /// the depth limit or that couldn't be entered, an entry that couldn't
    /// be looked at): there may be more than `total`.
    public var scanTruncated: Bool
    public var nextCursor: String?
}

public enum FolderFilesResult: Equatable, Sendable {
    case listing(ListingPage)
    case duplicates(DuplicatePage)
    case info(FileInfo)
}

public struct FolderFiles {
    public struct Limits: Sendable {
        /// Entries a listing scans at most (recursive ones included).
        public var maxScan = 20_000
        public var pageEntries = 200
        /// About this many bytes of paths per page.
        public var pageBytes = 8000
        public var maxDepth = 32
        public var duplicateGroupsPerPage = 20
        /// Entries read, in all, to flag a page's folders that contain
        /// protected items (each folder gets at most `protectedPerFolder`).
        public var protectedCheckPerPage = 50_000
        public var protectedPerFolder = 10_000

        public init() {}
    }

    public let walker: SafeFolderWalker
    public var classifier: FileClassifier
    public var limits: Limits
    public var duplicateLimits: DuplicateFinder.Limits

    public init(walker: SafeFolderWalker, classifier: FileClassifier = FileClassifier(), limits: Limits = Limits(),
                duplicateLimits: DuplicateFinder.Limits = DuplicateFinder.Limits()) {
        self.walker = walker
        self.classifier = classifier
        self.limits = limits
        self.duplicateLimits = duplicateLimits
    }

    public func run(_ q: FolderQuery, isCancelled: () -> Bool = { false }) throws -> FolderFilesResult {
        var isFolder = q.components.isEmpty
        if let last = q.components.last {
            let item = try walker.resolve(q.components)
            guard let entry = item.entry else { throw FolderAccessError.notFound(walker.display(q.components)) }
            isFolder = entry.kind == .directory
            if !isFolder {
                if q.onlyDuplicates { throw FolderAccessError.notADirectory(last) }
                return .info(try classifier.info(item, walker: walker, hash: q.hash, isCancelled: isCancelled))
            }
        }
        if q.onlyDuplicates {
            let offset = try Self.offset(q.cursor, tag: "d")
            var finder = DuplicateFinder(walker: walker, limits: duplicateLimits)
            finder.limits.includeHidden = q.includeHidden
            let report = try finder.find(q.components, recursive: q.recursive, isCancelled: isCancelled)
            return .duplicates(report.page(cursor: offset, maxGroups: limits.duplicateGroupsPerPage, maxBytes: limits.pageBytes))
        }
        return .listing(try listing(q, isCancelled: isCancelled))
    }

    /// The cursor string for a listing or duplicates offset.
    public static func cursor(_ offset: Int, tag: String) -> String { "\(tag)\(offset)" }

    static func offset(_ cursor: String?, tag: String) throws -> Int {
        guard let cursor, !cursor.isEmpty else { return 0 }
        guard cursor.hasPrefix(tag), let n = Int(cursor.dropFirst(tag.count)), n >= 0 else {
            throw FolderAccessError.invalidPath("unknown cursor \(cursor)")
        }
        return n
    }

    /// Flags the page's folders and packages whose subtree holds denied
    /// items (a move or trash of them is refused), within a budget.
    private func flagProtected(_ page: inout [ListingPage.Entry]) {
        var budget = limits.protectedCheckPerPage
        for i in page.indices where page[i].kind == .directory || page[i].kind == .package {
            guard budget > 0 else { page[i].protectedInside = .unchecked; continue }
            let comps = page[i].path.split(separator: "/").map(String.init)
            guard let parent = try? walker.openDirectory(Array(comps.dropLast())), let name = comps.last else {
                page[i].protectedInside = .unchecked
                continue
            }
            let (found, read) = walker.protectedScan(in: parent, name, budget: min(budget, limits.protectedPerFolder))
            budget -= read
            page[i].protectedInside = found == .none ? nil : found
        }
    }

    public func listing(_ q: FolderQuery, isCancelled: () -> Bool = { false }) throws -> ListingPage {
        let offset = try Self.offset(q.cursor, tag: "l")
        var found: [ListingPage.Entry] = []
        var scanned = 0
        var truncated = false
        func matches(_ name: String) -> Bool {
            guard let p = q.pattern, !p.isEmpty else { return true }
            return fnmatch(p, name, FNM_CASEFOLD) == 0
        }
        // Something left out along the way (not the cap): the listing says so.
        var incomplete = false
        func scan(_ dir: OpenedDirectory, depth: Int) throws {
            // The cap counts every name looked at, shown or not.
            let read = try walker.scanEntries(of: dir, limit: limits.maxScan - scanned)
            scanned += read.visited
            if read.skipped > 0 { incomplete = true }
            if read.capped { truncated = true }
            for e in read.entries {
                if isCancelled() { truncated = true; return }
                if !q.includeHidden, e.name.hasPrefix(".") { continue }
                let comps = dir.components + [e.name]
                if matches(e.name) {
                    found.append(.init(path: comps.joined(separator: "/"), kind: e.kind,
                                       size: e.kind == .file || e.kind == .symlink ? e.stat.size : nil,
                                       modified: e.stat.modified, hardLinked: e.stat.isHardLinked ? true : nil,
                                       notDownloaded: e.stat.isDataless ? true : nil))
                }
                if q.recursive, e.kind == .directory {
                    // A subfolder on another volume (it needs its own grant),
                    // past the depth limit, or that can't be entered (changed
                    // or unreadable since it was listed) makes the listing
                    // incomplete.
                    guard e.identity.device == dir.descriptor.identity.device, depth + 1 <= limits.maxDepth,
                          let sub = try? walker.step(dir, e.name) else {
                        incomplete = true
                        continue
                    }
                    try scan(sub, depth: depth + 1)
                }
            }
        }
        try scan(try walker.openDirectory(q.components), depth: 0)
        found.sort { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        var page: [ListingPage.Entry] = []
        var bytes = 0
        var i = offset
        while i < found.count, page.count < limits.pageEntries {
            let cost = found[i].path.utf8.count + 48
            if !page.isEmpty, bytes + cost > limits.pageBytes { break }
            page.append(found[i])
            bytes += cost
            i += 1
        }
        flagProtected(&page)
        var listed: ProtectedContents?
        if let name = q.components.last {
            let parent = try walker.openDirectory(Array(q.components.dropLast()))
            let found = walker.protectedContents(in: parent, name, budget: limits.protectedCheckPerPage)
            listed = found == .none ? nil : found
        }
        return ListingPage(entries: page, protectedInside: listed, total: found.count, scanTruncated: truncated || incomplete,
                           nextCursor: i < found.count ? Self.cursor(i, tag: "l") : nil)
    }
}
