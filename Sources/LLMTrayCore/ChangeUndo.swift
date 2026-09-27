import Darwin
import Foundation

/// Undo of a journaled plan (Hardening 7): items reversed newest first,
/// each only if it still matches what the journal recorded by identity --
/// moves moved back (exclusively), made folders removed if still empty,
/// trashed items put back from where the Trash put them. Stops at the first
/// conflict and says what remains reversible.
public struct ChangeUndo {
    public let denylist: FolderDenylist
    public let journal: ChangeJournal
    /// Change grants for the plan's chat: an item is reversed (or recovered)
    /// only while one still covers both its ends; else "grant revoked".
    public let canChange: ChangeGrantCheck

    typealias Uncertain = ChangeExecutor.Uncertain

    public init(denylist: FolderDenylist, journal: ChangeJournal, canChange: @escaping ChangeGrantCheck) {
        self.denylist = denylist
        self.journal = journal
        self.canChange = canChange
    }

    public struct Remaining: Equatable, Sendable {
        public var id: Int
        public var reversible: Bool
        public var reason: String?
    }

    public struct Report: Equatable, Sendable {
        public var planID: UUID
        public var undone: [Int]
        public var stopped: Remaining?
        /// Items still done after this undo, newest first, with whether each
        /// could still be reversed.
        public var remaining: [Remaining]
    }

    static let tooLarge = "the journal is too large to read whole"

    /// Called after an item's checks, right before its undo operation (and
    /// before an interrupted undo's folder is removed): tests swap things
    /// there to exercise the check-to-use window.
    var beforeOperation: ((PlanItem) -> Void)?

    /// Whether each done item could be reversed now (newest first), without
    /// changing anything. Interrupted items say so; a journal too large to
    /// read whole is one entry (id 0) saying so, as undo refuses it.
    public func reversibility(_ planID: UUID) -> [Remaining] {
        guard let record = journal.record(planID) else { return [] }
        if record.truncated { return [Remaining(id: 0, reversible: false, reason: Self.tooLarge)] }
        return record.items.reversed().compactMap { item -> Remaining? in
            switch item.state {
            case .incomplete:
                return Remaining(id: item.planItem.id, reversible: false, reason: "interrupted: its outcome is unknown")
            case .uncertain(let why):
                return Remaining(id: item.planItem.id, reversible: false, reason: "needs a look: \(why)")
            case .failed, .undone:
                return nil
            case .done(let r), .undoIncomplete(let r):
                do {
                    try reverse(item.planItem, r, dryRun: true, planID: planID)
                    return Remaining(id: item.planItem.id, reversible: true, reason: nil)
                } catch {
                    return Remaining(id: item.planItem.id, reversible: false, reason: "\(error)")
                }
            }
        }
    }

    public func undo(_ planID: UUID) -> Report {
        var report = Report(planID: planID, undone: [], stopped: nil, remaining: [])
        // What a crash left under a temporary name goes back first.
        _ = recover(planID)
        guard let record = journal.record(planID) else {
            report.stopped = Remaining(id: 0, reversible: false, reason: "no journal for this plan")
            return report
        }
        if record.truncated {
            report.stopped = Remaining(id: 0, reversible: false, reason: Self.tooLarge)
            report.remaining = [report.stopped!]
            return report
        }
        items: for item in record.items.reversed() {
            let result: JournalResult
            switch item.state {
            case .done(let r): result = r
            case .undoIncomplete(let r):
                // An undo interrupted after it moved the item back (or took a
                // made folder aside): finished, or picked up again.
                let back: Bool
                do {
                    back = try isBack(item.planItem, r, planID: planID)
                } catch let u as Uncertain {
                    report.stopped = Remaining(id: item.planItem.id, reversible: false, reason: "needs a look: \(u.description)")
                    break items
                } catch {
                    back = false
                }
                if back {
                    do {
                        try journal.append(JournalEvent(kind: .undone, date: Date(), item: item.planItem.id), planID: planID)
                    } catch {
                        report.stopped = Remaining(id: item.planItem.id, reversible: false,
                                                   reason: "undone, but the journal couldn't record it: \(error)")
                        break items
                    }
                    report.undone.append(item.planItem.id)
                    continue
                }
                result = r
            // Unknown outcomes are left alone (reported in `remaining`).
            case .failed, .undone, .incomplete, .uncertain: continue
            }
            let id = item.planItem.id
            do {
                try journal.append(JournalEvent(kind: .undoPending, date: Date(), item: id), planID: planID)
            } catch {
                report.stopped = Remaining(id: id, reversible: true, reason: "journal not written, nothing changed: \(error)")
                break items
            }
            do {
                try reverse(item.planItem, result, dryRun: false, planID: planID)
            } catch let u as Uncertain {
                try? journal.append(JournalEvent(kind: .uncertain, date: Date(), item: id, message: u.description), planID: planID)
                report.stopped = Remaining(id: id, reversible: false, reason: "needs a look: \(u.description)")
                break items
            } catch {
                try? journal.append(JournalEvent(kind: .undoFailed, date: Date(), item: id, message: "\(error)"), planID: planID)
                report.stopped = Remaining(id: id, reversible: false, reason: "\(error)")
                break items
            }
            // Reported undone only once that is on disk.
            do {
                try journal.append(JournalEvent(kind: .undone, date: Date(), item: id), planID: planID)
            } catch {
                report.stopped = Remaining(id: id, reversible: false, reason: "undone, but the journal couldn't record it: \(error)")
                break items
            }
            report.undone.append(id)
        }
        report.remaining = reversibility(planID)
        return report
    }

    // MARK: Reversing one item

    private func walker(_ root: FolderRoot) -> SafeFolderWalker { SafeFolderWalker(root: root, denylist: denylist) }

    /// The original parent, held to the identities captured at proposal.
    private func sourceParent(_ s: CapturedSource) throws -> OpenedDirectory {
        try walker(s.location.root).openDirectory(s.location.parentComponents, expected: s.parentChain)
    }

    /// Where a make_dir or move put the item, held to the recorded
    /// identities; the item there must be the recorded one.
    private func placed(_ item: PlanItem, _ r: JournalResult) throws -> (OpenedDirectory, String) {
        guard let d = item.destination, let comps = r.components, let name = comps.last, let chain = r.destinationChain else {
            throw FolderAccessError.invalidPath("the journal has no destination")
        }
        let dir = try walker(d.location.root).openDirectory(Array(comps.dropLast()), expected: chain)
        guard try Posix.lstatAt(dir.descriptor.fd, name)?.identity == r.identity else {
            throw FolderAccessError.changed("\(comps.joined(separator: "/")) was moved or replaced since")
        }
        return (dir, name)
    }

    /// The item in the Trash, by its canonical path, held to the recorded
    /// identity. By path: the Trash folder can't be opened without Full Disk
    /// Access (TCC), though its items can be looked at and moved; the
    /// identity is checked again after the move.
    private func inTrash(_ r: JournalResult) throws -> (path: String, device: Int32) {
        guard let path = r.trashURL else { throw FolderAccessError.notFound("the Trash didn't say where it put the item") }
        let url = URL(fileURLWithPath: path)
        guard let dirPath = Posix.realpath(url.deletingLastPathComponent().path) else {
            throw FolderAccessError.notFound(path)
        }
        let canonical = dirPath + "/" + url.lastPathComponent
        guard let st = Posix.lstatPath(canonical), st.identity == r.identity else {
            throw FolderAccessError.changed("\(url.lastPathComponent) is no longer in the Trash")
        }
        return (canonical, st.identity.device)
    }

    /// The name a made folder is taken aside under before it is removed:
    /// fixed per plan item, so a crash between the two is found again.
    static func asideName(planID: UUID, item: Int) -> String { ".llmtray-undo-\(planID.uuidString)-\(item)" }

    private func reverse(_ item: PlanItem, _ r: JournalResult, dryRun: Bool, planID: UUID) throws {
        let excl = UInt32(RENAME_EXCL)
        let renameBack = ChangeExecutor.renameBack
        try PlanItemGrant.check(item, canChange)
        switch item.kind {
        case .makeDir:
            guard let d = item.destination else { throw FolderAccessError.invalidPath("the journal has no destination") }
            let (dir, name) = try placed(item, r)
            defer { withExtendedLifetime(dir) {} }
            if dryRun {
                guard try Self.emptiness(dir.descriptor, name) != .notEmpty else { throw FolderAccessError.notEmpty(name) }
                return
            }
            beforeOperation?(item)
            // Taken aside under a temporary name first: the rename takes one
            // exact folder, checked before it is removed (a folder swapped in
            // by name is put back, not removed).
            let fd = dir.descriptor.fd
            let temp = Self.asideName(planID: planID, item: item.id)
            guard renameatx_np(fd, name, fd, temp, excl) == 0 else {
                throw FolderAccessError.system("remove \(name)", errno)
            }
            // Put back under its name, confirmed: whatever was taken aside.
            func restore(_ why: FolderAccessError) throws -> Never {
                if let st = try? Posix.lstatAt(fd, temp), renameBack(fd, temp, fd, name, st.identity) { throw why }
                throw Uncertain(description: "\(name) was left as \(temp)")
            }
            if (try? Posix.lstatAt(fd, temp))?.identity != r.identity {
                try restore(.changed("\(name) was replaced since"))
            }
            // Its folder must still be inside the grant (it can be moved out
            // while held open): else nothing is removed there.
            if !walker(d.location.root).stillInside(dir) {
                try restore(.changed("\(comps(dir)) left the grant"))
            }
            // Finder may have left its .DS_Store there: alone, it goes too.
            Self.removeLoneDSStore(dir.descriptor, temp, identity: r.identity)
            if unlinkat(fd, temp, AT_REMOVEDIR) != 0 {
                let e = errno
                try restore(e == ENOTEMPTY || e == EEXIST ? .notEmpty(name) : .system("remove \(name)", e))
            }
            // Removal is by name: anything still (or newly) there means it
            // may not have been the folder checked a moment ago.
            if (try? Posix.lstatAt(fd, temp)) != nil {
                throw Uncertain(description: "\(temp) is still there after removing it")
            }
        case .move:
            guard let s = item.source, let d = item.destination else {
                throw FolderAccessError.invalidPath("the journal has no source")
            }
            let (dir, name) = try placed(item, r)
            let back = try sourceParent(s)
            defer { withExtendedLifetime((dir, back)) {} }
            if dryRun {
                if try Posix.lstatAt(back.descriptor.fd, s.location.name) != nil {
                    throw FolderAccessError.exists(s.location.relativePath)
                }
                return
            }
            beforeOperation?(item)
            // Looked at again right before the rename: still the item.
            guard try Posix.lstatAt(dir.descriptor.fd, name)?.identity == r.identity else {
                throw FolderAccessError.changed("\(name) was replaced since")
            }
            if renameatx_np(dir.descriptor.fd, name, back.descriptor.fd, s.location.name, excl) != 0 {
                let e = errno
                if e == EEXIST { throw FolderAccessError.exists(s.location.relativePath) }
                throw FolderAccessError.system("move back \(name)", e)
            }
            // What moved must be the item; anything swapped in goes back.
            guard let arrived = try? Posix.lstatAt(back.descriptor.fd, s.location.name) else {
                throw Uncertain(description: "moved \(name) back, but \(s.location.relativePath) can't be looked at")
            }
            if arrived.identity != r.identity {
                if renameBack(back.descriptor.fd, s.location.name, dir.descriptor.fd, name, arrived.identity) {
                    throw FolderAccessError.changed("\(name) was replaced since")
                }
                throw Uncertain(description: "something other than the item was moved to \(s.location.relativePath)")
            }
            // Both ends must still be inside the grant (either can be moved
            // out while held open): else it goes back where it was.
            if !walker(s.location.root).stillInside(back) || !walker(d.location.root).stillInside(dir) {
                if renameBack(back.descriptor.fd, s.location.name, dir.descriptor.fd, name, r.identity) {
                    throw FolderAccessError.changed("a folder of \(s.location.relativePath) left the grant")
                }
                throw Uncertain(description: "moved \(name) back while a folder left the grant")
            }
        case .trash:
            guard let s = item.source else { throw FolderAccessError.invalidPath("the journal has no source") }
            let trashed = try inTrash(r)
            let back = try sourceParent(s)
            defer { withExtendedLifetime(back) {} }
            if trashed.device != back.descriptor.identity.device {
                throw FolderAccessError.crossDevice(s.location.relativePath)
            }
            if dryRun {
                if try Posix.lstatAt(back.descriptor.fd, s.location.name) != nil {
                    throw FolderAccessError.exists(s.location.relativePath)
                }
                return
            }
            beforeOperation?(item)
            // Looked at again right before the rename: still the item.
            guard try Self.lstatIfPresent(trashed.path)?.identity == r.identity else {
                throw FolderAccessError.changed("\(s.location.name) changed in the Trash")
            }
            if renameatx_np(AT_FDCWD, trashed.path, back.descriptor.fd, s.location.name, excl) != 0 {
                let e = errno
                if e == EEXIST { throw FolderAccessError.exists(s.location.relativePath) }
                throw FolderAccessError.system("put back \(s.location.name)", e)
            }
            // Swapped in the Trash between the check and the move: back it goes.
            guard let arrived = try? Posix.lstatAt(back.descriptor.fd, s.location.name) else {
                throw Uncertain(description: "put \(s.location.relativePath) back, but it can't be looked at")
            }
            if arrived.identity != r.identity {
                if renameBack(back.descriptor.fd, s.location.name, AT_FDCWD, trashed.path, arrived.identity) {
                    throw FolderAccessError.changed("\(s.location.name) changed in the Trash")
                }
                throw Uncertain(description: "something other than the item came back to \(s.location.relativePath)")
            }
            // Its folder must still be inside the grant: else back to the Trash.
            if !walker(s.location.root).stillInside(back) {
                if renameBack(back.descriptor.fd, s.location.name, AT_FDCWD, trashed.path, r.identity) {
                    throw FolderAccessError.changed("the folder of \(s.location.relativePath) left the grant")
                }
                throw Uncertain(description: "put \(s.location.relativePath) back while its folder left the grant")
            }
        }
    }

    private func comps(_ dir: OpenedDirectory) -> String {
        dir.components.isEmpty ? "the grant's folder" : dir.components.joined(separator: "/")
    }

    /// `lstat` by path, nil only when nothing is there (`ENOENT`,
    /// `ENOTDIR`): any other failure is thrown -- a lookup that fails is no
    /// proof that the item is gone.
    static func lstatIfPresent(_ path: String) throws -> EntryStat? {
        var st = Darwin.stat()
        if Darwin.lstat(path, &st) == 0 { return EntryStat(st) }
        let e = errno
        if e == ENOENT || e == ENOTDIR { return nil }
        throw FolderAccessError.system("look at \(path)", e)
    }

    /// After an interrupted undo: is the item where it was before the plan
    /// (or, for a made folder, gone)? A made folder found taken aside is
    /// removed if still empty and still inside the grant, else put back
    /// under its name.
    private func isBack(_ item: PlanItem, _ r: JournalResult, planID: UUID) throws -> Bool {
        try PlanItemGrant.check(item, canChange)
        switch item.kind {
        case .makeDir:
            guard let d = item.destination, let comps = r.components, let name = comps.last, let chain = r.destinationChain else { return false }
            let dir = try walker(d.location.root).openDirectory(Array(comps.dropLast()), expected: chain)
            defer { withExtendedLifetime(dir) {} }
            let fd = dir.descriptor.fd
            if try Posix.lstatAt(fd, name)?.identity == r.identity { return false }
            let aside = Self.asideName(planID: planID, item: item.id)
            guard try Posix.lstatAt(fd, aside)?.identity == r.identity else {
                // Removed -- or moved away by someone: can't be told apart.
                throw Uncertain(description: "\(name) is gone from its place; if it was removed, nothing is left to undo")
            }
            beforeOperation?(item)
            // Put back under its name, confirmed.
            func restore() throws -> Bool {
                if ChangeExecutor.renameBack(fd, aside, fd, name, expecting: r.identity) { return false }
                throw Uncertain(description: "\(name) was left as \(aside)")
            }
            // Removed only inside the grant.
            guard walker(d.location.root).stillInside(dir) else {
                _ = try restore()
                throw FolderAccessError.changed("\(self.comps(dir)) left the grant")
            }
            Self.removeLoneDSStore(dir.descriptor, aside, identity: r.identity)
            if unlinkat(fd, aside, AT_REMOVEDIR) == 0 {
                if (try? Posix.lstatAt(fd, aside)) != nil {
                    throw Uncertain(description: "\(aside) is still there after removing it")
                }
                return true
            }
            return try restore()
        case .move, .trash:
            guard let s = item.source else { return false }
            // Held in a local: the descriptor closes when the value goes.
            let parent = try sourceParent(s)
            let atSource = try withExtendedLifetime(parent) {
                try Posix.lstatAt(parent.descriptor.fd, s.location.name)?.identity == s.identity
            }
            guard atSource else { return false }
            // Also gone from where the plan put it (a hard link could make it
            // look back while still there). Looked at, not assumed: a lookup
            // that fails is no proof.
            let stillPlaced: Bool
            if item.kind == .trash {
                guard let path = r.trashURL else { throw Uncertain(description: "the journal has no Trash location") }
                do {
                    stillPlaced = try Self.lstatIfPresent(path)?.identity == r.identity
                } catch {
                    throw Uncertain(description: "can't look in the Trash for \(s.location.relativePath): \(error)")
                }
            } else {
                guard let d = item.destination, let comps = r.components, let name = comps.last,
                      let chain = r.destinationChain else {
                    throw Uncertain(description: "the journal has no destination")
                }
                do {
                    let dir = try walker(d.location.root).openDirectory(Array(comps.dropLast()), expected: chain)
                    stillPlaced = try withExtendedLifetime(dir) {
                        try Posix.lstatAt(dir.descriptor.fd, name)?.identity == r.identity
                    }
                } catch {
                    throw Uncertain(description: "can't look where \(s.location.relativePath) was put: \(error)")
                }
            }
            if stillPlaced { throw Uncertain(description: "\(s.location.relativePath) is in both places (a hard link?)") }
            return true
        }
    }

    /// Whether a folder has an entry named exactly `name`, byte for byte (as
    /// `readdir` gives it, not as a lookup matches it).
    static func holdsExactly(_ dir: Descriptor, _ name: String) throws -> Bool {
        let fd = dup(dir.fd)
        guard fd >= 0 else { throw FolderAccessError.system("dup", errno) }
        guard let stream = fdopendir(fd) else {
            let e = errno
            close(fd)
            throw FolderAccessError.system("fdopendir", e)
        }
        defer { closedir(stream) }
        rewinddir(stream)
        let want = Array(name.utf8)
        while let n = try SafeFolderWalker.nextName(stream) {
            if Array(n.utf8) == want { return true }
        }
        return false
    }

    static func isEmptyDirectory(_ parent: Descriptor, _ name: String) throws -> Bool {
        try emptiness(parent, name) == .empty
    }

    enum Emptiness { case empty, onlyDSStore, notEmpty }

    /// Whether a folder is empty -- or holds only Finder's `.DS_Store`, which
    /// a made folder gets just by being looked at in Finder.
    static func emptiness(_ parent: Descriptor, _ name: String) throws -> Emptiness {
        let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FolderAccessError.system("open \(name)", errno) }
        guard let stream = fdopendir(fd) else {
            close(fd)
            throw FolderAccessError.system("fdopendir", errno)
        }
        defer { closedir(stream) }
        var dsStore = false
        while let n = try SafeFolderWalker.nextName(stream) {
            if n == "." || n == ".." { continue }
            if Array(n.utf8) == Array(".DS_Store".utf8), !dsStore { dsStore = true; continue }
            return .notEmpty
        }
        return dsStore ? .onlyDSStore : .empty
    }

    /// Removes `.DS_Store` from the folder `name` when it is the folder's
    /// only entry, the folder is `identity` and the entry a plain file with
    /// one name. Anything else is left as it is (the removal of the folder
    /// then fails as "not empty").
    static func removeLoneDSStore(_ parent: Descriptor, _ name: String, identity: FileIdentity) {
        guard (try? emptiness(parent, name)) == .onlyDSStore else { return }
        let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard (try? Posix.fstat(fd))?.identity == identity,
              let st = try? Posix.lstatAt(fd, ".DS_Store"), st.isRegularFile, st.linkCount == 1 else { return }
        _ = unlinkat(fd, ".DS_Store", 0)
    }

    // MARK: Recovery after a crash

    public struct Recovery: Equatable, Sendable {
        public var planID: UUID
        /// Items put back under their names from a temporary one (their
        /// operation didn't happen: journaled as failed).
        public var restored: [Int] = []
        /// Items left for the user to look at, and why.
        public var needsLook: [Int: String] = [:]
        /// Items whose staging folder was found and left in place. Recovery
        /// never removes one: removal goes by name, and a folder swapped in
        /// between a check and the removal would go instead. Before its
        /// identity was journaled a folder under that name can't even be
        /// told from one someone else made there.
        public var leftBehind: [Int: String] = [:]
    }

    /// Recovery for the newest `limit` plans with anything left under a
    /// temporary name: to run when the journal is opened (app launch, the
    /// journal's list) -- `undo` runs it for its plan first.
    public func recoverInterrupted(limit: Int = 50) -> [Recovery] {
        journal.records(limit: limit).filter { $0.items.contains { $0.staging != nil } }
            .map { recover($0.planID) }
            .filter { !$0.restored.isEmpty || !$0.needsLook.isEmpty || !$0.leftBehind.isEmpty }
    }

    /// Finds what a crash left of a plan's temporary names (journaled before
    /// each was made) and undoes it, for interrupted items only: the
    /// temporary names of items whose outcome is settled (done, failed,
    /// undone) are never touched, whatever is found under them now. An
    /// interrupted item found under its temporary name (or in its staging
    /// folder) goes back under its own name -- by identity, exclusively, its
    /// folder still inside the grant before and after; a name taken since
    /// leaves it where it is, reported. A staging folder is acted on only
    /// when it is the one whose identity was journaled right after it was
    /// made (before that, only the item itself is looked for in it), and is
    /// never removed: it is reported (`leftBehind`). Nothing else is touched.
    public func recover(_ planID: UUID) -> Recovery {
        var out = Recovery(planID: planID)
        // A plan running in this process isn't interrupted: its names are
        // in use.
        guard !ChangeExecutor.isRunning(planID), let record = journal.record(planID), !record.truncated else { return out }
        for item in record.items {
            guard let st = item.staging else { continue }
            switch item.state {
            case .incomplete, .uncertain: break
            case .done, .failed, .undone, .undoIncomplete: continue
            }
            let id = item.planItem.id
            do {
                let step = try recoverOne(item.planItem, st, stagingIdentity: item.stagingIdentity)
                if let note = step.leftBehind { out.leftBehind[id] = note }
                if let why = step.needsLook { out.needsLook[id] = why }
                if step.restored {
                    out.restored.append(id)
                    var why = step.putBack ? "interrupted, and undone from its temporary name"
                        : "interrupted before it changed anything"
                    if let note = step.leftBehind { why += "; \(note)" }
                    try? journal.append(JournalEvent(kind: .failed, date: Date(), item: id, message: why), planID: planID)
                }
            } catch {
                out.needsLook[id] = "\(error)"
            }
        }
        return out
    }

    /// What recovering one item did.
    private struct RecoveryStep {
        /// Its operation is known not to have happened (the item back under
        /// its name, or never moved): journaled as failed.
        var restored = false
        /// The item was moved back from its temporary name.
        var putBack = false
        /// Its staging folder, left where it is.
        var leftBehind: String?
        /// Its outcome still needs a look.
        var needsLook: String?
    }

    /// The points of a recovery operation (tests swap things there).
    enum RecoveryPoint { case beforeRename, afterRename }

    /// Called at each `RecoveryPoint` of a recovery operation.
    var recoveryHook: ((RecoveryPoint, PlanItem) -> Void)?

    private func recoverOne(_ item: PlanItem, _ st: StagingRecord, stagingIdentity: FileIdentity?) throws -> RecoveryStep {
        let w = walker(st.root)
        let dir = try w.openDirectory(st.parentComponents, expected: st.parentChain)
        defer { withExtendedLifetime(dir) {} }
        let pfd = dir.descriptor.fd
        var out = RecoveryStep()
        /// A trash that never took the item: it is still under its name (a
        /// trashed item leaves it), so nothing changed.
        func trashNeverRan() throws -> Bool {
            guard st.kind == .trash, let s = item.source,
                  let here = try Posix.lstatAt(pfd, s.location.name), here.identity == s.identity else { return false }
            // With other names, one of them could have been linked here after
            // the Trash took the item: no proof.
            if here.isHardLinked {
                throw Uncertain(description: "interrupted: \(s.location.relativePath) has other names (hard links), "
                    + "so whether the Trash took it can't be told")
            }
            return true
        }
        func leftGrant() -> FolderAccessError { .changed("\(comps(dir)) left the grant") }
        /// The item from `from` (in `fromFD`) back under its own name,
        /// exclusively, confirmed by identity -- only while its folder is
        /// inside the grant, before and after (else it is taken back). Out of
        /// a held staging folder (`folder`), that folder must still be the
        /// one under its name in the item's folder, before and after too.
        func putBack(from fromFD: Int32, _ from: String, _ shown: String, folder: Descriptor? = nil) throws {
            guard let s = item.source else { throw FolderAccessError.invalidPath("the journal has no source") }
            func folderInPlace() -> Bool {
                guard let folder else { return true }
                return (try? Posix.lstatAt(pfd, st.name))?.identity == folder.identity
            }
            recoveryHook?(.beforeRename, item)
            guard w.stillInside(dir) else { throw leftGrant() }
            guard folderInPlace() else { throw FolderAccessError.changed("\(st.name) was moved since") }
            // Looked at again right before the rename: it must still be the
            // item.
            guard try Posix.lstatAt(fromFD, from)?.identity == s.identity else {
                throw FolderAccessError.changed("\(from) (\(shown)) was replaced since")
            }
            if renameatx_np(fromFD, from, pfd, s.location.name, UInt32(RENAME_EXCL)) != 0 {
                let e = errno
                if e == EEXIST { throw FolderAccessError.exists("\(s.location.relativePath) (the item is \(shown))") }
                throw FolderAccessError.system("put back \(s.location.name)", e)
            }
            recoveryHook?(.afterRename, item)
            // A rename moves whatever has the name: something swapped in
            // goes back where it came from.
            guard let arrived = try? Posix.lstatAt(pfd, s.location.name) else {
                throw Uncertain(description: "put \(s.location.relativePath) back, but it can't be looked at")
            }
            if arrived.identity != s.identity {
                if ChangeExecutor.renameBack(pfd, s.location.name, fromFD, from, expecting: arrived.identity) {
                    throw FolderAccessError.changed("\(from) (\(shown)) was replaced since")
                }
                throw Uncertain(description: "something other than the item was put back as \(s.location.relativePath)")
            }
            if !w.stillInside(dir) || !folderInPlace() {
                if ChangeExecutor.renameBack(pfd, s.location.name, fromFD, from, expecting: s.identity) {
                    throw folderInPlace() ? leftGrant() : FolderAccessError.changed("\(st.name) was moved since")
                }
                throw Uncertain(description: "put \(s.location.relativePath) back while a folder of it moved")
            }
            out.putBack = true
        }
        guard let staged = try Posix.lstatAt(pfd, st.name) else {
            out.restored = try trashNeverRan()
            // Its folder made and gone, the item not under its name: the Trash
            // may have taken it (a crash between the cleanup and `done`).
            if !out.restored, st.kind == .trash, stagingIdentity != nil, let s = item.source {
                throw Uncertain(description: "interrupted: \(s.location.relativePath) isn't in its place; it may be in the Trash")
            }
            // A rename whose item is gone from both names: it may have been
            // renamed (a crash before `done`).
            // By the exact name bytes: a case-only rename's new name answers
            // to the old one on a case-insensitive volume.
            if st.kind == .rename, let s = item.source, let d = item.destination,
               try (Posix.lstatAt(pfd, s.location.name))?.identity != s.identity
                || !Self.holdsExactly(dir.descriptor, s.location.name) {
                throw Uncertain(description: "interrupted: \(s.location.relativePath) may have been renamed to "
                    + d.location.relativePath)
            }
            // A made folder gone from its staging name: it may have been
            // published (a crash before `done`).
            if st.kind == .makeDir, let made = stagingIdentity, let d = item.destination {
                if (try? Posix.lstatAt(pfd, d.location.name))?.identity == made {
                    throw Uncertain(description: "interrupted: the folder was made as \(d.location.relativePath)")
                }
                throw Uncertain(description: "interrupted: the folder may have been made (as \(d.location.relativePath) "
                    + "or a numbered name)")
            }
            return out
        }
        // Something to change: only while a change grant still covers it.
        try PlanItemGrant.check(item, canChange)
        switch st.kind {
        case .rename:
            // The item itself under the temporary name.
            guard let s = item.source else { return out }
            guard staged.identity == s.identity else {
                throw Uncertain(description: "\(st.name) isn't \(s.location.relativePath)")
            }
            try putBack(from: pfd, st.name, "at \(st.name)")
            out.restored = true
            return out
        case .trash, .makeDir:
            guard staged.isDirectory else { throw Uncertain(description: "\(st.name) isn't a folder") }
            let sfd = openat(pfd, st.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard sfd >= 0, let folder = try? Descriptor(fd: sfd, stat: Posix.fstat(sfd)) else {
                if sfd >= 0 { close(sfd) }
                throw FolderAccessError.system("open \(st.name)", errno)
            }
            guard folder.identity == staged.identity else { throw FolderAccessError.changed(st.name) }
            // Journaled once made: then it must be that folder. Before that
            // (the crash came between making it and journaling it) a folder
            // under this name may be someone else's; the item is moved in
            // only after the identity is journaled, and a make_dir publishes
            // only after it, so neither operation happened.
            let ours = stagingIdentity != nil
            if let made = stagingIdentity, folder.identity != made || !ChangeExecutor.ownedByUs(folder) {
                throw Uncertain(description: "\(st.name) isn't the folder LLMTray made")
            }
            // Only the item itself, found in it by identity, goes back.
            if st.kind == .trash, let s = item.source, let inside = try Posix.lstatAt(folder.fd, s.location.name) {
                if inside.identity == s.identity {
                    try putBack(from: folder.fd, s.location.name, "in \(st.name)", folder: folder)
                    out.restored = true
                } else if ours {
                    throw Uncertain(description: "\(st.name) holds something other than \(s.location.relativePath)")
                }
            }
            // The folder itself is never removed: removal goes by name, and a
            // folder swapped in between a check and the removal would go
            // instead. It is reported, for the user to remove.
            out.leftBehind = ours
                ? "\(st.name), the folder LLMTray made for this change, was left in \(comps(dir)): once empty it can be removed"
                : "\(st.name) was left in \(comps(dir)): LLMTray can't tell it is the folder it made"
            // A make_dir that never published its folder changed nothing.
            if !out.restored { out.restored = try st.kind == .makeDir || trashNeverRan() }
            // Neither in the folder made for it nor under its name: the Trash
            // may have taken it.
            if !out.restored, ours, st.kind == .trash, let s = item.source {
                out.needsLook = "interrupted: \(s.location.relativePath) isn't in its place; it may be in the Trash"
            }
            return out
        }
    }
}
