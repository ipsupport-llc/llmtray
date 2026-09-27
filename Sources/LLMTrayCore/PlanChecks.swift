import Foundation

/// A file as a comparison saw it: the result holds only while this does.
public struct FileStamp: Codable, Equatable, Sendable {
    public var identity: FileIdentity
    public var size: Int64
    public var modified: Date

    public init(identity: FileIdentity, size: Int64, modified: Date) {
        self.identity = identity
        self.size = size
        self.modified = modified
    }

    init(_ e: FolderEntry) { self.init(identity: e.identity, size: e.stat.size, modified: e.stat.modified) }
}

/// A trashed file named like a copy ("x (1).zip", "x copy.zip"), compared
/// with the original beside it.
public struct CopyCheck: Equatable, Sendable {
    public enum Verdict: String, Equatable, Sendable {
        /// Same size and SHA-256: a real copy.
        case identical
        /// Another size, or other bytes.
        case differs
        /// Couldn't be told: no original, a hard link, an iCloud placeholder,
        /// a key's name, too large, out of time, access ended.
        case unknown
    }

    public var original: String
    public var verdict: Verdict
    /// Both files as compared (identical only): the verdict is dropped once
    /// either changes (`PlanChecker.stillIdentical`).
    public var copy: FileStamp?
    public var originalStamp: FileStamp?

    public init(original: String, verdict: Verdict, copy: FileStamp? = nil, originalStamp: FileStamp? = nil) {
        self.original = original
        self.verdict = verdict
        self.copy = copy
        self.originalStamp = originalStamp
    }
}

/// What the plan review looks up on disk before the user approves (adr/0014,
/// "Listing sizes and the plan's warnings"): the size of each folder the plan
/// moves or trashes, and how each trashed "copy" compares with its original.
/// Keyed by item id (ids are never reused).
public struct PlanChecks: Equatable, Sendable {
    /// Folders and packages moved or trashed, measured.
    public var sizes: [Int: FolderSize] = [:]
    /// Trashed files named like a copy, compared.
    public var copies: [Int: CopyCheck] = [:]

    public init(sizes: [Int: FolderSize] = [:], copies: [Int: CopyCheck] = [:]) {
        self.sizes = sizes
        self.copies = copies
    }

    /// Copies that differ from their original: id -> the original's name.
    public var notIdentical: [Int: String] { copies.filter { $0.value.verdict == .differs }.mapValues(\.original) }
    /// Copies that couldn't be compared: id -> the original's name.
    public var uncompared: [Int: String] { copies.filter { $0.value.verdict == .unknown }.mapValues(\.original) }
}

/// Runs the review's checks, read only and bounded: by descriptors from the
/// grant root, each item held to the identity it was proposed with (one that
/// changed is left out -- the review marks it invalid anyway), and only while
/// the chat may still read there (`canRead`, asked before each item, before
/// each content read and after; an item whose access ended keeps no result).
/// Contents are read only to compare a copy of the same size with its
/// original -- never of a hard link, an iCloud placeholder or a file named
/// like a key (Hardening 5, 15, 17: such a pair isn't compared at all).
public struct PlanChecker {
    public struct Limits: Sendable {
        public var sizePerFolder = 200_000
        public var sizeSecondsPerFolder: TimeInterval = 1
        /// All the measuring of one review.
        public var sizeSeconds: TimeInterval = 3
        /// Files larger than this aren't hashed (the copy stays "unknown").
        public var hashBytes: Int64 = 1 << 30
        /// All the hashing of one review.
        public var hashSeconds: TimeInterval = 5

        public init() {}
    }

    /// Whether the chat may still read at a location, for the item's
    /// proposal.
    public typealias ReadCheck = (_ location: FolderLocation, _ proposal: String?) -> Bool

    public let denylist: FolderDenylist
    public var limits: Limits

    public init(denylist: FolderDenylist, limits: Limits = Limits()) {
        self.denylist = denylist
        self.limits = limits
    }

    public func check(_ plan: ChangePlan, canRead: @escaping ReadCheck = { _, _ in true },
                      isCancelled: () -> Bool = { false }) -> PlanChecks {
        var out = PlanChecks()
        let now = ProcessInfo.processInfo.systemUptime
        let sizeDeadline = now + limits.sizeSeconds
        let hashDeadline = now + limits.hashSeconds
        for item in plan.items where item.kind != .makeDir {
            guard !isCancelled(), let s = item.source else { continue }
            let readable = { canRead(s.location, item.proposal) }
            guard readable() else { continue }
            let walker = SafeFolderWalker(root: s.location.root, denylist: denylist)
            guard let parent = try? walker.openDirectory(s.location.parentComponents, expected: s.parentChain) else { continue }
            switch s.kind {
            case .directory, .package:
                let t = ProcessInfo.processInfo.systemUptime
                guard t < sizeDeadline else { continue }
                let r = walker.subtreeScan(in: parent, s.location.name, budget: limits.sizePerFolder,
                                           deadline: min(sizeDeadline, t + limits.sizeSecondsPerFolder),
                                           expecting: s.identity, measure: true)
                if let size = r.size, readable() { out.sizes[item.id] = size }
            case .file where item.kind == .trash:
                guard let original = Self.originalName(ofCopy: s.location.name) else { continue }
                var c = compare(s, original: original, in: parent, walker: walker, deadline: hashDeadline,
                                readable: readable, isCancelled: isCancelled)
                // Access ended meanwhile: nothing of what was read is kept.
                if !readable() { c = CopyCheck(original: original, verdict: .unknown) }
                out.copies[item.id] = c
            default:
                break
            }
        }
        return out
    }

    /// The copy `s` against `original` in the same folder: the pair is left
    /// alone (unknown) when either is a hard link, a placeholder or named
    /// like a key; else by size, then by SHA-256 of both.
    func compare(_ s: CapturedSource, original: String, in parent: OpenedDirectory, walker: SafeFolderWalker,
                 deadline: TimeInterval, readable: () -> Bool, isCancelled: () -> Bool) -> CopyCheck {
        let unknown = CopyCheck(original: original, verdict: .unknown)
        guard let copy = try? walker.entry(in: parent, s.location.name), copy.identity == s.identity, copy.kind == .file,
              let orig = try? walker.entry(in: parent, original), orig.kind == .file,
              orig.identity != copy.identity else { return unknown }
        let parentName = parent.components.last ?? (walker.root.path as NSString).lastPathComponent
        for e in [copy, orig] {
            if e.stat.isHardLinked || e.stat.isDataless || FolderDenylist.looksSecret(name: e.name, parentName: parentName) {
                return unknown
            }
        }
        if copy.stat.size != orig.stat.size { return CopyCheck(original: original, verdict: .differs) }
        guard copy.stat.size <= limits.hashBytes else { return unknown }
        var caps = FileClassifier.Caps()
        caps.hashBytes = limits.hashBytes
        func hash(_ e: FolderEntry) -> String? {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            // Right before the read: still allowed, still in time.
            guard left > 0, readable() else { return nil }
            caps.hashSeconds = left
            let item = ResolvedItem(parent: parent, name: e.name, entry: e)
            guard let fd = try? walker.openFile(item) else { return nil }
            if case .sha256(let h) = FileClassifier(caps: caps).sha256(fd, isCancelled: isCancelled) { return h }
            return nil
        }
        guard let a = hash(copy), let b = hash(orig) else { return unknown }
        if a != b { return CopyCheck(original: original, verdict: .differs) }
        return CopyCheck(original: original, verdict: .identical, copy: FileStamp(copy), originalStamp: FileStamp(orig))
    }

    /// Whether an "identical" verdict still holds for `item` at approval:
    /// both files unchanged (identity, size, modification time) where they
    /// were compared. False for any other verdict.
    public func stillIdentical(_ item: PlanItem, _ check: CopyCheck) -> Bool {
        guard check.verdict == .identical, let s = item.source, let stamp = check.copy, let origStamp = check.originalStamp else {
            return false
        }
        let walker = SafeFolderWalker(root: s.location.root, denylist: denylist)
        guard let parent = try? walker.openDirectory(s.location.parentComponents, expected: s.parentChain),
              let copy = try? walker.entry(in: parent, s.location.name), FileStamp(copy) == stamp,
              let orig = try? walker.entry(in: parent, check.original) else { return false }
        return FileStamp(orig) == origStamp
    }

    /// Right before a copy found identical is trashed: both hashed again
    /// where they are now -- the original followed to where an earlier item
    /// of `plan` moved it (by its identity) -- within the same caps and
    /// exclusions. Throws, so the item fails, when either isn't the file
    /// compared, can't be hashed (a trashed original included), or the
    /// hashes differ.
    public func verifyBeforeTrash(_ item: PlanItem, _ check: CopyCheck, plan: ChangePlan) throws {
        let shown = item.source?.location.relativePath ?? ""
        func fail(_ why: String) -> FolderAccessError { .changed("\(shown): \(why); not trashed as a copy") }
        guard check.verdict == .identical, let s = item.source, let stamp = check.copy, let origStamp = check.originalStamp else {
            throw fail("not compared")
        }
        // Where the original is now: in place, or where an earlier move took it.
        var origLocation = FolderLocation(root: s.location.root, components: s.location.parentComponents + [check.original])
        for earlier in plan.items.prefix(while: { $0.id != item.id }) where earlier.source?.identity == origStamp.identity {
            guard earlier.kind == .move, let d = earlier.destination else { throw fail("its original was trashed") }
            origLocation = d.location
        }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.hashSeconds
        func hash(_ loc: FolderLocation, _ identity: FileIdentity, expected: [FileIdentity?]) throws -> String {
            let walker = SafeFolderWalker(root: loc.root, denylist: denylist)
            guard let item = try? walker.resolve(loc.components, expectedParents: expected), let e = item.entry,
                  e.kind == .file, e.identity == identity else { throw fail("changed since it was compared") }
            let parentName = item.parent.components.last ?? (walker.root.path as NSString).lastPathComponent
            if e.stat.isHardLinked || e.stat.isDataless || e.stat.size > limits.hashBytes
                || FolderDenylist.looksSecret(name: e.name, parentName: parentName) { throw fail("can't be compared") }
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0, let fd = try? walker.openFile(item) else { throw fail("couldn't be read") }
            var caps = FileClassifier.Caps()
            caps.hashBytes = limits.hashBytes
            caps.hashSeconds = left
            guard case .sha256(let h) = FileClassifier(caps: caps).sha256(fd) else { throw fail("couldn't be hashed") }
            return h
        }
        let a = try hash(s.location, stamp.identity, expected: s.parentChain)
        let b = try hash(origLocation, origStamp.identity, expected: [])
        if a != b { throw fail("no longer identical to its original") }
    }

    /// "report.pdf" for "report (1).pdf", "report copy.pdf" or
    /// "report copy 2.pdf" -- the names browsers and Finder give a second
    /// download or a duplicate; nil for any other name.
    public static func originalName(ofCopy name: String) -> String? {
        let ns = name as NSString
        guard let m = copyPattern.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let stem = ns.substring(with: m.range(at: 1))
        let ext = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
        return stem + ext
    }

    /// A trash of a file named like a copy: it starts unticked until the
    /// comparison says it's a real one.
    public static func isCopyCandidate(_ item: PlanItem) -> Bool {
        guard item.kind == .trash, let s = item.source, s.kind == .file else { return false }
        return originalName(ofCopy: s.location.name) != nil
    }

    private static let copyPattern = try! NSRegularExpression(
        pattern: #"^(.*\S) (?:\(\d{1,3}\)|copy(?: \d{1,3})?)((?:\.[A-Za-z0-9]{1,10})*)$"#)
}
