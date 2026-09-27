import Foundation

/// What the plan review looks up on disk before the user approves (adr/0014,
/// "Listing sizes and the plan's warnings"): the size of each folder the plan
/// moves or trashes, and the "copies" it trashes that aren't the same as
/// their original. Keyed by item id (ids are never reused).
public struct PlanChecks: Equatable, Sendable {
    /// Folders and packages moved or trashed, measured.
    public var sizes: [Int: FolderSize] = [:]
    /// Trashed files named like a copy ("x (1).zip", "x copy.zip") whose
    /// contents differ from the original's beside them: id -> the original's
    /// name.
    public var notIdentical: [Int: String] = [:]

    public init(sizes: [Int: FolderSize] = [:], notIdentical: [Int: String] = [:]) {
        self.sizes = sizes
        self.notIdentical = notIdentical
    }
}

/// Runs the review's checks, read only and bounded: by descriptors from the
/// grant root, each item held to the identity it was proposed with (one that
/// changed is left out -- the review marks it invalid anyway). Contents are
/// read only to compare a copy of the same size with its original -- never
/// of a hard link, an iCloud placeholder or a file named like a key.
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

    public let denylist: FolderDenylist
    public var limits: Limits

    public init(denylist: FolderDenylist, limits: Limits = Limits()) {
        self.denylist = denylist
        self.limits = limits
    }

    public func check(_ plan: ChangePlan, isCancelled: () -> Bool = { false }) -> PlanChecks {
        var out = PlanChecks()
        let now = ProcessInfo.processInfo.systemUptime
        let sizeDeadline = now + limits.sizeSeconds
        let hashDeadline = now + limits.hashSeconds
        for item in plan.items where item.kind != .makeDir {
            guard !isCancelled(), let s = item.source else { continue }
            let walker = SafeFolderWalker(root: s.location.root, denylist: denylist)
            guard let parent = try? walker.openDirectory(s.location.parentComponents, expected: s.parentChain) else { continue }
            switch s.kind {
            case .directory, .package:
                let t = ProcessInfo.processInfo.systemUptime
                guard t < sizeDeadline else { continue }
                let r = walker.subtreeScan(in: parent, s.location.name, budget: limits.sizePerFolder,
                                           deadline: min(sizeDeadline, t + limits.sizeSecondsPerFolder),
                                           expecting: s.identity, measure: true)
                if let size = r.size { out.sizes[item.id] = size }
            case .file where item.kind == .trash:
                if let original = Self.originalName(ofCopy: s.location.name),
                   differs(s, original: original, in: parent, walker: walker, deadline: hashDeadline, isCancelled: isCancelled) {
                    out.notIdentical[item.id] = original
                }
            default:
                break
            }
        }
        return out
    }

    /// Whether the copy `s` differs from `original` in the same folder: by
    /// size, else by SHA-256 of both. False when it can't be told (no
    /// original, a hard link, a placeholder, a key's name, too large, out of
    /// time).
    func differs(_ s: CapturedSource, original: String, in parent: OpenedDirectory, walker: SafeFolderWalker,
                 deadline: TimeInterval, isCancelled: () -> Bool) -> Bool {
        guard let copy = try? walker.entry(in: parent, s.location.name), copy.identity == s.identity, copy.kind == .file,
              let orig = try? walker.entry(in: parent, original), orig.kind == .file,
              orig.identity != copy.identity else { return false }
        if copy.stat.size != orig.stat.size { return true }
        let parentName = parent.components.last ?? (walker.root.path as NSString).lastPathComponent
        for e in [copy, orig] {
            if e.stat.isHardLinked || e.stat.isDataless || e.stat.size > limits.hashBytes
                || FolderDenylist.looksSecret(name: e.name, parentName: parentName) { return false }
        }
        let left = deadline - ProcessInfo.processInfo.systemUptime
        guard left > 0 else { return false }
        var caps = FileClassifier.Caps()
        caps.hashBytes = limits.hashBytes
        caps.hashSeconds = left
        let classifier = FileClassifier(caps: caps)
        func hash(_ e: FolderEntry) -> String? {
            let item = ResolvedItem(parent: parent, name: e.name, entry: e)
            guard let fd = try? walker.openFile(item) else { return nil }
            if case .sha256(let h) = classifier.sha256(fd, isCancelled: isCancelled) { return h }
            return nil
        }
        guard let a = hash(copy), let b = hash(orig) else { return false }
        return a != b
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

    private static let copyPattern = try! NSRegularExpression(
        pattern: #"^(.*\S) (?:\(\d{1,3}\)|copy(?: \d{1,3})?)((?:\.[A-Za-z0-9]{1,10})*)$"#)
}
