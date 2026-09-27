import CryptoKit
import Darwin
import Foundation

/// Duplicates in a granted folder (adr/0014, `files(only_duplicates:)`): files
/// grouped by size, then by a quick hash of their first and last 64 KB, then
/// by a full SHA-256 for what is left. Names of one inode (hard links) are
/// "the same file", not duplicates, and their contents aren't read
/// (Hardening 5). Denied subtrees, packages, symlinks, aliases and other
/// volumes are skipped; files, bytes hashed and depth are capped, and the
/// scan can be cancelled -- a partial result says why it stopped.
public struct DuplicateFinder {
    public struct Limits: Sendable {
        public var maxFiles = 100_000
        /// Directory entries read in all (folders, links... included): a
        /// folder of a million names is never loaded whole.
        public var maxEntries = 200_000
        public var maxBytesHashed: Int64 = 16 << 30
        public var maxDepth = 64
        public var edgeBytes = 64 << 10
        public var chunkBytes = 1 << 20
        public var includeHidden = false
        /// Wall-clock cap on the whole scan; past it the result is partial
        /// (`stopped: time_limit`).
        public var maxSeconds: Double = 60

        public init() {}
    }

    public let walker: SafeFolderWalker
    public var limits: Limits
    /// Injectable for the time cap's tests.
    public var clock: () -> Date

    public init(walker: SafeFolderWalker, limits: Limits = Limits(), clock: @escaping () -> Date = Date.init) {
        self.walker = walker
        self.limits = limits
        self.clock = clock
    }

    private struct Candidate {
        var components: [String]
        var parentChain: [FileIdentity]
        var stat: EntryStat
    }

    private struct Budget {
        var bytes: Int64 = 0
        var stop: DuplicateReport.Stop?
        var deadline: Date
    }

    /// Past the time cap: the scan stops, partial.
    private func outOfTime(_ budget: inout Budget) -> Bool {
        if clock() >= budget.deadline {
            if budget.stop == nil { budget.stop = .timeLimit }
            return true
        }
        return false
    }

    /// Scans the folder at `components` (the grant root when empty). Files
    /// not downloaded from iCloud and secret-looking ones are counted, never
    /// read; reads run with dataless materialization off.
    public func find(_ components: [String] = [], recursive: Bool = true,
                     isCancelled: () -> Bool = { false }) throws -> DuplicateReport {
        try Materialization.off { try findReading(components, recursive: recursive, isCancelled: isCancelled) }
    }

    private func findReading(_ components: [String], recursive: Bool, isCancelled: () -> Bool) throws -> DuplicateReport {
        var summary = DuplicateReport.Summary()
        var candidates: [Candidate] = []
        var links: [FileIdentity: (size: Int64, paths: [String])] = [:]
        var budget = Budget(deadline: clock().addingTimeInterval(limits.maxSeconds))

        var entriesRead = 0
        func scan(_ dir: OpenedDirectory, depth: Int) throws {
            let room = limits.maxEntries - entriesRead
            var entries = try walker.entries(of: dir, limit: room + 1)
            // Over the cap: what was read is scanned, then the scan stops.
            let capped = entries.count > room
            if capped { entries = Array(entries.prefix(room)) }
            defer { if capped, budget.stop == nil { budget.stop = .fileLimit } }
            entriesRead += entries.count
            entries.sort { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
            for e in entries {
                if budget.stop != nil { return }
                if isCancelled() { budget.stop = .cancelled; return }
                if outOfTime(&budget) { return }
                if !limits.includeHidden, e.name.hasPrefix(".") { continue }
                let comps = dir.components + [e.name]
                switch e.kind {
                case .file:
                    if summary.filesScanned >= limits.maxFiles { budget.stop = .fileLimit; return }
                    summary.filesScanned += 1
                    let parentName = dir.components.last ?? (walker.root.path as NSString).lastPathComponent
                    if e.stat.size == 0 {
                        summary.emptyFilesSkipped += 1
                    } else if FolderDenylist.looksSecret(name: e.name, parentName: parentName) {
                        summary.secretsNotRead += 1
                    } else if e.stat.isDataless {
                        summary.notDownloadedSkipped += 1
                    } else if e.stat.isHardLinked {
                        summary.hardLinkedNotRead += 1
                        links[e.identity, default: (e.stat.size, [])].paths.append(comps.joined(separator: "/"))
                    } else {
                        candidates.append(Candidate(components: comps, parentChain: dir.chain, stat: e.stat))
                    }
                case .directory:
                    guard recursive else { continue }
                    if e.identity.device != dir.descriptor.identity.device { summary.skippedItems += 1; continue }
                    if depth + 1 > limits.maxDepth { summary.skippedItems += 1; continue }
                    guard let sub = try? walker.step(dir, e.name) else { summary.skippedItems += 1; continue }
                    try scan(sub, depth: depth + 1)
                case .package, .symlink, .alias, .other:
                    summary.skippedItems += 1
                }
            }
        }
        try scan(try walker.openDirectory(components), depth: 0)

        // Size, then the quick hash, then the full one.
        var groups: [DuplicateReport.Group] = []
        let bySize = Dictionary(grouping: candidates, by: { $0.stat.size }).filter { $0.value.count > 1 }
        for size in bySize.keys.sorted(by: >) {
            if budget.stop != nil { break }
            var byQuick: [String: [Candidate]] = [:]
            for c in bySize[size]! {
                if budget.stop != nil { break }
                if let h = quickHash(c, budget: &budget, isCancelled: isCancelled) { byQuick[h, default: []].append(c) }
                else if budget.stop == nil { summary.unreadable += 1 }
            }
            for quick in byQuick.keys.sorted() where byQuick[quick]!.count > 1 {
                if budget.stop != nil { break }
                var byFull: [String: [Candidate]] = [:]
                let wholeInQuick = size <= Int64(limits.edgeBytes) * 2
                for c in byQuick[quick]! {
                    if budget.stop != nil { break }
                    if wholeInQuick { byFull[quick, default: []].append(c); continue }
                    if let h = fullHash(c, budget: &budget, isCancelled: isCancelled) { byFull[h, default: []].append(c) }
                    else if budget.stop == nil { summary.unreadable += 1 }
                }
                for (hash, members) in byFull where members.count > 1 {
                    let files = members.map {
                        DuplicateReport.File(path: $0.components.joined(separator: "/"), modified: $0.stat.modified, created: $0.stat.created)
                    }.sorted { $0.path < $1.path }
                    groups.append(.init(size: size, sha256: wholeInQuick ? nil : hash, files: files))
                }
            }
        }
        groups.sort { ($0.reclaimableBytes, $1.files[0].path) > ($1.reclaimableBytes, $0.files[0].path) }
        let sameFile = links.values.filter { $0.paths.count > 1 }
            .map { DuplicateReport.SameFile(size: $0.size, paths: $0.paths.sorted()) }
            .sorted { $0.paths[0] < $1.paths[0] }
        summary.groups = groups.count
        summary.duplicateFiles = groups.reduce(0) { $0 + $1.files.count - 1 }
        summary.reclaimableBytes = groups.reduce(0) { $0 + $1.reclaimableBytes }
        summary.sameFileGroups = sameFile.count
        summary.bytesHashed = budget.bytes
        summary.stopped = budget.stop
        return DuplicateReport(summary: summary, groups: groups, sameFile: sameFile)
    }

    private func open(_ c: Candidate) -> Descriptor? {
        guard let item = try? walker.resolve(c.components, expectedParents: c.parentChain),
              item.entry?.identity == c.stat.identity, let d = try? walker.openFile(item),
              d.stat.size == c.stat.size, !d.stat.isHardLinked, !d.stat.isDataless else { return nil }
        return d
    }

    private func charge(_ n: Int64, _ budget: inout Budget) -> Bool {
        if budget.bytes + n > limits.maxBytesHashed {
            budget.stop = .byteLimit
            return false
        }
        budget.bytes += n
        return true
    }

    /// SHA-256 over the size, the first and the last `edgeBytes` (the whole
    /// file when it is at most twice that).
    private func quickHash(_ c: Candidate, budget: inout Budget, isCancelled: () -> Bool) -> String? {
        if isCancelled() { budget.stop = .cancelled; return nil }
        if outOfTime(&budget) { return nil }
        guard let d = open(c) else { return nil }
        let size = c.stat.size
        let edge = Int64(limits.edgeBytes)
        let whole = size <= edge * 2
        guard charge(whole ? size : edge * 2, &budget) else { return nil }
        var hasher = SHA256()
        if whole {
            guard let all = try? FileClassifier.read(d.fd, offset: 0, count: Int(size)), all.count == size else { return nil }
            hasher.update(data: all)
            return FileClassifier.hex(hasher.finalize())
        }
        guard let head = try? FileClassifier.read(d.fd, offset: 0, count: Int(edge)),
              let tail = try? FileClassifier.read(d.fd, offset: size - edge, count: Int(edge)) else { return nil }
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: head)
        hasher.update(data: tail)
        return FileClassifier.hex(hasher.finalize())
    }

    private func fullHash(_ c: Candidate, budget: inout Budget, isCancelled: () -> Bool) -> String? {
        guard let d = open(c), charge(c.stat.size, &budget) else { return nil }
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < c.stat.size {
            if isCancelled() { budget.stop = .cancelled; return nil }
            if outOfTime(&budget) { return nil }
            guard let chunk = try? FileClassifier.read(d.fd, offset: offset, count: limits.chunkBytes), !chunk.isEmpty else { return nil }
            hasher.update(data: chunk)
            offset += Int64(chunk.count)
        }
        return offset == c.stat.size ? FileClassifier.hex(hasher.finalize()) : nil
    }
}

public struct DuplicateReport: Codable, Equatable, Sendable {
    public enum Stop: String, Codable, Sendable {
        case fileLimit = "file_limit", byteLimit = "byte_limit", cancelled
        /// The scan's time cap (`Limits.maxSeconds`).
        case timeLimit = "time_limit"
    }

    public struct File: Codable, Equatable, Sendable {
        /// Below the grant root.
        public var path: String
        public var modified: Date
        public var created: Date
    }

    public struct Group: Codable, Equatable, Sendable {
        public var size: Int64
        /// nil when the quick hash already covered the whole file.
        public var sha256: String?
        public var files: [File]

        public var reclaimableBytes: Int64 { size * Int64(files.count - 1) }
    }

    /// Several names of one file (hard links): removing one frees nothing.
    public struct SameFile: Codable, Equatable, Sendable {
        public var size: Int64
        public var paths: [String]
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var groups = 0
        /// Copies beyond one per group.
        public var duplicateFiles = 0
        public var reclaimableBytes: Int64 = 0
        public var filesScanned = 0
        public var bytesHashed: Int64 = 0
        public var emptyFilesSkipped = 0
        public var hardLinkedNotRead = 0
        /// In iCloud, not downloaded: not read (reading would download them).
        public var notDownloadedSkipped = 0
        /// Named like keys or credentials: not read.
        public var secretsNotRead = 0
        public var sameFileGroups = 0
        /// Packages, links, aliases, other volumes, unreadable folders.
        public var skippedItems = 0
        /// Changed or vanished while being read.
        public var unreadable = 0
        /// nil: the scan finished.
        public var stopped: Stop?
    }

    public var summary: Summary
    public var groups: [Group]
    public var sameFile: [SameFile]

    /// A page for the model: the summary and groups from `cursor` (paths and
    /// sizes only), at most `maxGroups` and about `maxBytes` of paths (at
    /// least one group). `nextCursor` is nil on the last page.
    public func page(cursor: Int = 0, maxGroups: Int = 20, maxBytes: Int = 4000, maxPathsPerGroup: Int = 10) -> DuplicatePage {
        var out: [DuplicatePage.Group] = []
        var bytes = 0
        var i = max(0, cursor)
        while i < groups.count, out.count < maxGroups {
            let g = groups[i]
            // One group of many copies is cut too: its first paths, and a count.
            let shown = Array(g.files.prefix(max(2, maxPathsPerGroup)))
            let cost = shown.reduce(16) { $0 + $1.path.utf8.count + 4 }
            if !out.isEmpty, bytes + cost > maxBytes { break }
            let more = g.files.count - shown.count
            out.append(.init(size: g.size, paths: shown.map(\.path), copies: g.files.count, morePaths: more > 0 ? more : nil))
            bytes += cost
            i += 1
        }
        return DuplicatePage(summary: summary, groups: out, nextCursor: i < groups.count ? FolderFiles.cursor(i, tag: "d") : nil)
    }
}

public struct DuplicatePage: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable {
        public var size: Int64
        public var paths: [String]
        /// All copies in the group (`paths` may show fewer).
        public var copies: Int
        /// Copies not listed in `paths`.
        public var morePaths: Int?
    }

    public var summary: DuplicateReport.Summary
    public var groups: [Group]
    public var nextCursor: String?
}
