import Darwin
import Foundation

/// Moves an item to the Trash. `verify` is asked with the URL actually used
/// (a coordinator may hand over another) right before the move, and must
/// hold. Never deletes: a failure is thrown as one (Hardening 6).
public protocol Trasher {
    func trash(_ url: URL, coordinated: Bool, verify: (URL) -> Bool) throws -> URL?
}

/// `FileManager.trashItem`, through `NSFileCoordinator` for file-provider
/// items.
public struct SystemTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL, coordinated: Bool, verify: (URL) -> Bool) throws -> URL? {
        func run(_ u: URL) throws -> URL? {
            guard verify(u) else { throw FolderAccessError.changed(u.path) }
            var out: NSURL?
            try FileManager.default.trashItem(at: u, resultingItemURL: &out)
            return out as URL?
        }
        guard coordinated else { return try run(url) }
        var coordinationError: NSError?
        var result: Result<URL?, Error> = .failure(FolderAccessError.system("coordinate", ECANCELED))
        withoutActuallyEscaping(verify) { verify in
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting,
                                                             error: &coordinationError) { u in
                result = Result {
                    guard verify(u) else { throw FolderAccessError.changed(u.path) }
                    var out: NSURL?
                    try FileManager.default.trashItem(at: u, resultingItemURL: &out)
                    return out as URL?
                }
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}

/// Runs an approved plan (adr/0014): one item at a time, each checked at the
/// moment of the operation by descriptors against the identities captured
/// when proposed, journaled before and after, stopping at the first failure.
public struct ChangeExecutor {
    public let denylist: FolderDenylist
    public let journal: ChangeJournal
    public let trasher: Trasher
    /// "keep both" tries "name 2" up to "name <this>".
    public var maxNumberedName = 999

    public init(denylist: FolderDenylist, journal: ChangeJournal, trasher: Trasher = SystemTrasher()) {
        self.denylist = denylist
        self.journal = journal
        self.trasher = trasher
    }

    public enum Status: Equatable, Sendable {
        case done(JournalResult)
        case failed(String)
        case notRun
    }

    public struct Report: Equatable, Sendable {
        public var planID: UUID
        public var outcomes: [(id: Int, status: Status)]
        /// The item that failed (the plan stopped there), if one did.
        public var stoppedAt: Int?

        public static func == (a: Report, b: Report) -> Bool {
            a.planID == b.planID && a.stoppedAt == b.stoppedAt
                && a.outcomes.map(\.id) == b.outcomes.map(\.id) && a.outcomes.map(\.status) == b.outcomes.map(\.status)
        }

        public var doneCount: Int { outcomes.filter { if case .done = $0.status { return true }; return false }.count }
    }

    /// The make_dir items this run made, by the path they were asked for:
    /// later items find their parents through them (under the name the
    /// file system took).
    private struct Made {
        var identity: FileIdentity
        var name: String
    }

    private struct Key: Hashable {
        var root: FileIdentity
        var components: [String]
    }

    public func execute(_ plan: ChangePlan, isCancelled: () -> Bool = { false }) -> Report {
        var report = Report(planID: plan.id, outcomes: [], stoppedAt: nil)
        var made: [Key: Made] = [:]
        do {
            try journal.append(JournalEvent(kind: .begin, date: Date(), chatID: plan.chatID), planID: plan.id)
        } catch {
            report.outcomes = plan.items.map { ($0.id, .notRun) }
            report.stoppedAt = plan.items.first?.id
            if let first = plan.items.first { report.outcomes[0] = (first.id, .failed("journal not written: \(error)")) }
            return report
        }
        for item in plan.items {
            if report.stoppedAt != nil || isCancelled() {
                report.outcomes.append((item.id, .notRun))
                continue
            }
            do {
                try journal.append(JournalEvent(kind: .pending, date: Date(), item: item.id, planItem: item), planID: plan.id)
            } catch {
                report.outcomes.append((item.id, .failed("journal not written, nothing changed: \(error)")))
                report.stoppedAt = item.id
                continue
            }
            do {
                let result = try run(item, made: &made)
                report.outcomes.append((item.id, .done(result)))
                try? journal.append(JournalEvent(kind: .done, date: Date(), item: item.id, result: result), planID: plan.id)
            } catch {
                report.outcomes.append((item.id, .failed("\(error)")))
                report.stoppedAt = item.id
                try? journal.append(JournalEvent(kind: .failed, date: Date(), item: item.id, message: "\(error)"), planID: plan.id)
            }
        }
        try? journal.append(JournalEvent(kind: .end, date: Date()), planID: plan.id)
        return report
    }

    // MARK: One item

    private func run(_ item: PlanItem, made: inout [Key: Made]) throws -> JournalResult {
        switch item.kind {
        case .makeDir:
            guard let d = item.destination else { throw FolderAccessError.invalidPath("make_dir without a path") }
            let (parent, comps) = try openDestinationParent(d, made: made)
            let name = try Self.exclusive(d.location.name, policy: item.collision, isDirectory: true, limit: maxNumberedName) {
                mkdirat(parent.descriptor.fd, $0, 0o755) == 0 ? 0 : errno
            }
            guard let st = try Posix.lstatAt(parent.descriptor.fd, name), st.isDirectory else {
                throw FolderAccessError.changed(d.location.relativePath)
            }
            made[Key(root: d.location.root.identity, components: d.location.components)] = Made(identity: st.identity, name: name)
            return JournalResult(identity: st.identity, finalName: name, destinationChain: parent.chain,
                                 trashURL: nil, components: comps + [name])
        case .move:
            guard let s = item.source, let d = item.destination else { throw FolderAccessError.invalidPath("move without ends") }
            let src = try openSourceParent(s)
            let (dst, comps) = try openDestinationParent(d, made: made)
            if dst.chain.contains(s.identity) {
                throw FolderAccessError.invalidPath("can't move a folder into itself: \(d.location.relativePath)")
            }
            if src.descriptor.identity.device != dst.descriptor.identity.device {
                throw FolderAccessError.crossDevice(d.location.displayPath)
            }
            let name = try Self.renameExclusive(from: src.descriptor, s.location.name, to: dst.descriptor, d.location.name,
                                                identity: s.identity, policy: item.collision,
                                                isDirectory: s.kind == .directory, limit: maxNumberedName)
            // The rename moved whatever had the name: it must be the item.
            guard try Posix.lstatAt(dst.descriptor.fd, name)?.identity == s.identity else {
                _ = renameatx_np(dst.descriptor.fd, name, src.descriptor.fd, s.location.name, UInt32(RENAME_EXCL))
                throw FolderAccessError.changed(s.location.relativePath)
            }
            return JournalResult(identity: s.identity, finalName: name, destinationChain: dst.chain,
                                 trashURL: nil, components: comps + [name])
        case .trash:
            guard let s = item.source else { throw FolderAccessError.invalidPath("trash without a path") }
            let parent = try openSourceParent(s)
            guard let dirPath = parent.descriptor.currentPath else { throw FolderAccessError.changed(s.location.relativePath) }
            let parentIdentity = parent.descriptor.identity
            let url = URL(fileURLWithPath: dirPath + "/" + s.location.name)
            let out = try trasher.trash(url, coordinated: s.fileProvider) { u in
                Posix.lstatPath(u.path)?.identity == s.identity
                    && Posix.lstatPath(u.deletingLastPathComponent().path)?.identity == parentIdentity
            }
            if try Posix.lstatAt(parent.descriptor.fd, s.location.name)?.identity == s.identity {
                throw FolderAccessError.system("trash (still there)", EIO)
            }
            let trashed = out.flatMap { Posix.lstatPath($0.path) }
            return JournalResult(identity: trashed?.identity ?? s.identity, finalName: out?.lastPathComponent,
                                 destinationChain: nil, trashURL: out?.path, components: nil)
        }
    }

    private func openSourceParent(_ s: CapturedSource) throws -> OpenedDirectory {
        let walker = SafeFolderWalker(root: s.location.root, denylist: denylist)
        let parent = try walker.openDirectory(s.location.parentComponents, expected: s.parentChain)
        guard let st = try Posix.lstatAt(parent.descriptor.fd, s.location.name) else {
            throw FolderAccessError.notFound(s.location.relativePath)
        }
        if st.identity != s.identity || denylist.isDenied(identity: st.identity, name: s.location.name) {
            throw FolderAccessError.changed(s.location.relativePath)
        }
        return parent
    }

    /// The destination's parent: its existing part held to the captured
    /// identities, the rest to what this run made (under the names taken).
    private func openDestinationParent(_ d: CapturedDestination, made: [Key: Made]) throws -> (OpenedDirectory, [String]) {
        let asked = d.location.parentComponents
        var actual: [String] = []
        var expected: [FileIdentity?] = d.existingChain
        for (i, name) in asked.enumerated() {
            if i + 1 < d.existingChain.count {
                actual.append(name)
                continue
            }
            let key = Key(root: d.location.root.identity, components: Array(asked[0...i]))
            guard let m = made[key] else {
                throw FolderAccessError.notFound("\(asked[0...i].joined(separator: "/")) (its make_dir didn't run)")
            }
            actual.append(m.name)
            expected.append(m.identity)
        }
        let walker = SafeFolderWalker(root: d.location.root, denylist: denylist)
        return (try walker.openDirectory(actual, expected: expected), actual)
    }

    // MARK: Names decided by the file system

    /// "name 2.ext" (the extension kept for files and packages; folders
    /// numbered at the end), kept within 255 bytes.
    public static func numberedName(_ name: String, _ n: Int, isDirectory: Bool) -> String {
        let ns = name as NSString
        var ext = isDirectory ? "" : ns.pathExtension
        var base = ext.isEmpty ? name : ns.deletingPathExtension
        if base.isEmpty {
            base = name
            ext = ""
        }
        let suffix = " \(n)" + (ext.isEmpty ? "" : "." + ext)
        while base.utf8.count + suffix.utf8.count > 255, !base.isEmpty { base.removeLast() }
        return base + suffix
    }

    /// Calls `attempt` (0 or an errno) with the name, then numbered names on
    /// `EEXIST` when the policy is keep-both.
    static func exclusive(_ name: String, policy: CollisionPolicy, isDirectory: Bool, limit: Int,
                          _ attempt: (String) -> Int32) throws -> String {
        for n in 1...max(1, limit) {
            let candidate = n == 1 ? name : numberedName(name, n, isDirectory: isDirectory)
            let e = attempt(candidate)
            if e == 0 { return candidate }
            if e != EEXIST { throw FolderAccessError.system("create \(candidate)", e) }
            if policy == .fail { throw FolderAccessError.exists(candidate) }
        }
        throw FolderAccessError.exists(name)
    }

    /// `renameatx_np(RENAME_EXCL)`, keep-both numbering on `EEXIST`. A rename
    /// whose destination is the item itself -- a case- or
    /// normalization-only rename on an insensitive volume -- goes through a
    /// temporary name, still exclusively.
    static func renameExclusive(from src: Descriptor, _ srcName: String, to dst: Descriptor, _ dstName: String,
                                identity: FileIdentity, policy: CollisionPolicy, isDirectory: Bool, limit: Int) throws -> String {
        let excl = UInt32(RENAME_EXCL)
        return try exclusive(dstName, policy: policy, isDirectory: isDirectory, limit: limit) { candidate in
            if renameatx_np(src.fd, srcName, dst.fd, candidate, excl) == 0 { return 0 }
            let e = errno
            guard e == EEXIST, src.identity == dst.identity,
                  (try? Posix.lstatAt(dst.fd, candidate))??.identity == identity,
                  Array(candidate.utf8) != Array(srcName.utf8) else { return e }
            let temp = ".llmtray-rename-\(UUID().uuidString)"
            guard renameatx_np(src.fd, srcName, src.fd, temp, excl) == 0 else { return errno }
            if renameatx_np(src.fd, temp, dst.fd, candidate, excl) == 0 { return 0 }
            let e2 = errno
            _ = renameatx_np(src.fd, temp, src.fd, srcName, excl)
            return e2
        }
    }
}
