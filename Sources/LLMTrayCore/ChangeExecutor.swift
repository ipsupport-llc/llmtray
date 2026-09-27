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

    /// Called after an item's checks, right before its operation: tests
    /// swap things there to exercise the check-to-use window.
    var beforeOperation: ((PlanItem) -> Void)?

    public enum Status: Equatable, Sendable {
        case done(JournalResult)
        /// Nothing was changed.
        case failed(String)
        /// Something may have changed and it couldn't be established what:
        /// the plan stops, the journal keeps the item as incomplete, the user
        /// is told to look.
        case uncertain(String)
        case notRun
    }

    public struct Report: Equatable, Sendable {
        public var planID: UUID
        public var outcomes: [(id: Int, status: Status)]
        /// The item that failed or was uncertain (the plan stopped there).
        public var stoppedAt: Int?

        public static func == (a: Report, b: Report) -> Bool {
            a.planID == b.planID && a.stoppedAt == b.stoppedAt
                && a.outcomes.map(\.id) == b.outcomes.map(\.id) && a.outcomes.map(\.status) == b.outcomes.map(\.status)
        }

        public var doneCount: Int { outcomes.filter { if case .done = $0.status { return true }; return false }.count }
    }

    /// Thrown once an operation has run but its outcome can't be confirmed
    /// (or undone): never reported as a plain failure, which would tell undo
    /// there is nothing to reverse.
    struct Uncertain: Error, CustomStringConvertible {
        var description: String
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

    public func execute(_ approved: ApprovedPlan, isCancelled: () -> Bool = { false }) -> Report {
        var report = Report(planID: approved.plan.id, outcomes: [], stoppedAt: nil)
        // An approval runs once -- and a plan with a journal already ran.
        guard let plan = approved.take(), !journal.exists(approved.plan.id) else {
            report.outcomes = approved.plan.items.map { ($0.id, .notRun) }
            if let first = approved.plan.items.first {
                report.outcomes[0] = (first.id, .failed("this approval was already used: approve again"))
                report.stoppedAt = first.id
            }
            return report
        }
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
            let result: JournalResult
            do {
                result = try run(item, made: &made)
            } catch let u as Uncertain {
                report.outcomes.append((item.id, .uncertain(u.description)))
                report.stoppedAt = item.id
                try? journal.append(JournalEvent(kind: .uncertain, date: Date(), item: item.id, message: u.description), planID: plan.id)
                continue
            } catch {
                report.outcomes.append((item.id, .failed("\(error)")))
                report.stoppedAt = item.id
                // If this line is lost the item stays "pending": incomplete,
                // the safe reading.
                try? journal.append(JournalEvent(kind: .failed, date: Date(), item: item.id, message: "\(error)"), planID: plan.id)
                continue
            }
            do {
                try journal.append(JournalEvent(kind: .done, date: Date(), item: item.id, result: result), planID: plan.id)
                report.outcomes.append((item.id, .done(result)))
            } catch {
                // Changed, but undo couldn't find it: stop here.
                report.outcomes.append((item.id, .uncertain("done, but the journal couldn't record it: \(error)")))
                report.stoppedAt = item.id
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
            beforeOperation?(item)
            // Made under a staging name and held open, so its identity is the
            // folder this call made; then renamed (exclusively) to the name.
            let fd = parent.descriptor.fd
            let staging = ".llmtray-new-\(UUID().uuidString)"
            guard mkdirat(fd, staging, 0o700) == 0 else { throw FolderAccessError.system("make \(d.location.name)", errno) }
            let newFD = openat(fd, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard newFD >= 0, let created = try? Descriptor(fd: newFD, stat: Posix.fstat(newFD)) else {
                if newFD >= 0 { close(newFD) }
                throw Uncertain(description: "made \(staging), then couldn't open it")
            }
            // Still the folder mkdirat made, as far as can be told: ours,
            // private, empty. (One swapped in by the same user would have to
            // be an empty private folder too: harmless to publish.)
            guard created.stat.isDirectory, created.stat.identity.device == parent.descriptor.identity.device,
                  created.stat.mode & 0o077 == 0,
                  Self.ownedByUs(created), (try? ChangeUndo.isEmptyDirectory(parent.descriptor, staging)) == true else {
                throw Uncertain(description: "\(staging) isn't the folder just made")
            }
            _ = fchmod(created.fd, 0o755)
            let name: String
            do {
                name = try Self.exclusive(d.location.name, policy: item.collision, isDirectory: true, limit: maxNumberedName) {
                    renameatx_np(fd, staging, fd, $0, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
                }
            } catch {
                // Not taken: the staging folder goes, if it is still ours.
                if (try? Posix.lstatAt(fd, staging))?.identity == created.identity, unlinkat(fd, staging, AT_REMOVEDIR) == 0 {
                    throw error
                }
                throw Uncertain(description: "\(error); \(staging) was left behind")
            }
            guard let published = try? Posix.lstatAt(fd, name), published.identity == created.identity else {
                // Something else was published: back to where it came from.
                if let other = try? Posix.lstatAt(fd, name),
                   Self.renameBack(fd, name, fd, staging, expecting: other.identity) {
                    throw FolderAccessError.changed(d.location.relativePath)
                }
                throw Uncertain(description: "made \(name), but what is there now isn't it")
            }
            // The parent must still be inside the grant (it can be moved out
            // while held open): else the folder is taken back.
            if !stillInside(parent, root: d.location.root) {
                if Self.renameBack(fd, name, fd, staging, expecting: created.identity), unlinkat(fd, staging, AT_REMOVEDIR) == 0 {
                    throw FolderAccessError.changed(d.location.relativePath)
                }
                throw Uncertain(description: "made \(name) in a folder that left the grant")
            }
            made[Key(root: d.location.root.identity, components: d.location.components)] = Made(identity: created.identity, name: name)
            return JournalResult(identity: created.identity, finalName: name, destinationChain: parent.chain,
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
            beforeOperation?(item)
            let name = try Self.renameExclusive(from: src.descriptor, s.location.name, to: dst.descriptor, d.location.name,
                                                identity: s.identity, policy: item.collision,
                                                isDirectory: s.kind == .directory, limit: maxNumberedName)
            // A rename moves whatever has the name: it must have been the
            // item, else what was swapped in goes back where it was.
            let moved = try? Posix.lstatAt(dst.descriptor.fd, name)
            if let moved, moved.identity == s.identity {
                // Both ends must still be inside the grant (either can be
                // moved out while held open): else it goes back.
                if stillInside(src, root: s.location.root), stillInside(dst, root: d.location.root) {
                    return JournalResult(identity: s.identity, finalName: name, destinationChain: dst.chain,
                                         trashURL: nil, components: comps + [name])
                }
                if Self.renameBack(dst.descriptor.fd, name, src.descriptor.fd, s.location.name, expecting: s.identity) {
                    throw FolderAccessError.changed(s.location.relativePath)
                }
                throw Uncertain(description: "moved \(s.location.relativePath) while a folder left the grant")
            }
            if let moved, Self.renameBack(dst.descriptor.fd, name, src.descriptor.fd, s.location.name, expecting: moved.identity) {
                throw FolderAccessError.changed(s.location.relativePath)
            }
            throw Uncertain(description: "moved \(s.location.relativePath), but what arrived isn't the item")
        case .trash:
            guard let s = item.source else { throw FolderAccessError.invalidPath("trash without a path") }
            let parent = try openSourceParent(s)
            let parentIdentity = parent.descriptor.identity
            beforeOperation?(item)
            // Foundation trashes by path, so no path is trusted: it is
            // established again from the grant root right before the call,
            // and once more where the call is about to move (a coordinator
            // may hand over another URL: it must be the same path).
            guard let path = trashPath(s, parentIdentity: parentIdentity) else {
                throw FolderAccessError.changed(s.location.relativePath)
            }
            let out: URL?
            do {
                out = try trasher.trash(URL(fileURLWithPath: path), coordinated: s.fileProvider) { u in
                    u.path == path && trashPath(s, parentIdentity: parentIdentity) == path
                }
            } catch {
                // The Trash said no: nothing moved -- unless the item is gone.
                if (try? Posix.lstatAt(parent.descriptor.fd, s.location.name))?.identity == s.identity { throw error }
                throw Uncertain(description: "the Trash failed (\(error)) and \(s.location.relativePath) isn't where it was")
            }
            guard let out else { throw Uncertain(description: "the Trash didn't say where it put \(s.location.relativePath)") }
            // Foundation moves by path: what went must be the item, else
            // what was swapped in is put back.
            guard let trashed = Posix.lstatPath(out.path) else {
                throw Uncertain(description: "\(out.path) isn't in the Trash")
            }
            if trashed.identity == s.identity {
                // It must have gone from inside the grant: its folder still in
                // its place after the call, else it is put back.
                if stillInside(parent, root: s.location.root) {
                    return JournalResult(identity: trashed.identity, finalName: out.lastPathComponent,
                                         destinationChain: nil, trashURL: out.path, components: nil)
                }
                if Self.renameBack(AT_FDCWD, out.path, parent.descriptor.fd, s.location.name, expecting: s.identity) {
                    throw FolderAccessError.changed(s.location.relativePath)
                }
                throw Uncertain(description: "trashed \(s.location.relativePath) while its folder left the grant: it is at \(out.path)")
            }
            if Self.renameBack(AT_FDCWD, out.path, parent.descriptor.fd, s.location.name, expecting: trashed.identity) {
                throw FolderAccessError.changed(s.location.relativePath)
            }
            throw Uncertain(description: "something other than \(s.location.relativePath) went to the Trash: \(out.path)")
        }
    }

    /// An exclusive rename back, confirmed: the name then holds `expecting`.
    static func renameBack(_ fromFD: Int32, _ from: String, _ toFD: Int32, _ to: String, expecting: FileIdentity) -> Bool {
        renameatx_np(fromFD, from, toFD, to, UInt32(RENAME_EXCL)) == 0
            && (try? Posix.lstatAt(toFD, to))?.identity == expecting
    }

    private func stillInside(_ dir: OpenedDirectory, root: FolderRoot) -> Bool {
        SafeFolderWalker(root: root, denylist: denylist).stillInside(dir)
    }

    /// The path the Trash gets, established again each time it is asked:
    /// the item's folder walked from the grant root by descriptors (still
    /// the held one, still in its place, the item in it by identity), spelled
    /// as the file system has it now, inside the grant root's path, with no
    /// symlink on the way (its realpath is itself). Nil when any of that
    /// doesn't hold.
    private func trashPath(_ s: CapturedSource, parentIdentity: FileIdentity) -> String? {
        guard let again = try? openSourceParent(s), again.descriptor.identity == parentIdentity,
              let dir = again.descriptor.currentPath, Posix.realpath(dir) == dir,
              dir == s.location.root.path || dir.hasPrefix(s.location.root.path + "/"),
              Posix.lstatPath(dir)?.identity == parentIdentity else { return nil }
        let path = dir + "/" + s.location.name
        guard Posix.lstatPath(path)?.identity == s.identity else { return nil }
        return withExtendedLifetime(again) { path }
    }

    static func ownedByUs(_ d: Descriptor) -> Bool {
        var st = Darwin.stat()
        return Darwin.fstat(d.fd, &st) == 0 && st.st_uid == geteuid()
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
        var stranded: String?
        func attempt(_ candidate: String) -> Int32 {
            if renameatx_np(src.fd, srcName, dst.fd, candidate, excl) == 0 { return 0 }
            let e = errno
            guard e == EEXIST, src.identity == dst.identity,
                  (try? Posix.lstatAt(dst.fd, candidate))?.identity == identity,
                  Array(candidate.utf8) != Array(srcName.utf8) else { return e }
            let temp = ".llmtray-rename-\(UUID().uuidString)"
            guard renameatx_np(src.fd, srcName, src.fd, temp, excl) == 0 else { return errno }
            if renameatx_np(src.fd, temp, dst.fd, candidate, excl) == 0 { return 0 }
            let e2 = errno
            if !renameBack(src.fd, temp, src.fd, srcName, expecting: identity) { stranded = temp }
            return e2
        }
        do {
            return try exclusive(dstName, policy: policy, isDirectory: isDirectory, limit: limit, attempt)
        } catch {
            if let stranded { throw Uncertain(description: "left under a temporary name: \(stranded)") }
            throw error
        }
    }
}
