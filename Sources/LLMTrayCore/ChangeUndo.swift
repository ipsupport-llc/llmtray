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

    typealias Uncertain = ChangeExecutor.Uncertain

    public init(denylist: FolderDenylist, journal: ChangeJournal) {
        self.denylist = denylist
        self.journal = journal
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

    /// Whether each done item could be reversed now (newest first), without
    /// changing anything. Interrupted items say so.
    public func reversibility(_ planID: UUID) -> [Remaining] {
        guard let record = journal.record(planID) else { return [] }
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
        guard let record = journal.record(planID) else {
            report.stopped = Remaining(id: 0, reversible: false, reason: "no journal for this plan")
            return report
        }
        if record.truncated {
            report.stopped = Remaining(id: 0, reversible: false, reason: "the journal is too large to read whole")
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
        switch item.kind {
        case .makeDir:
            let (dir, name) = try placed(item, r)
            if dryRun {
                guard try Self.isEmptyDirectory(dir.descriptor, name) else { throw FolderAccessError.notEmpty(name) }
                return
            }
            // Taken aside under a temporary name first: the rename takes one
            // exact folder, checked before it is removed (a folder swapped in
            // by name is put back, not removed).
            let temp = Self.asideName(planID: planID, item: item.id)
            guard renameatx_np(dir.descriptor.fd, name, dir.descriptor.fd, temp, excl) == 0 else {
                throw FolderAccessError.system("remove \(name)", errno)
            }
            func restore(_ why: FolderAccessError) throws -> Never {
                if renameatx_np(dir.descriptor.fd, temp, dir.descriptor.fd, name, excl) == 0 { throw why }
                throw Uncertain(description: "\(name) was left as \(temp)")
            }
            if (try? Posix.lstatAt(dir.descriptor.fd, temp))?.identity != r.identity {
                try restore(.changed("\(name) was replaced since"))
            }
            if unlinkat(dir.descriptor.fd, temp, AT_REMOVEDIR) != 0 {
                let e = errno
                try restore(e == ENOTEMPTY || e == EEXIST ? .notEmpty(name) : .system("remove \(name)", e))
            }
            // Removal is by name: anything still (or newly) there means it
            // may not have been the folder checked a moment ago.
            if (try? Posix.lstatAt(dir.descriptor.fd, temp)) != nil {
                throw Uncertain(description: "\(temp) is still there after removing it")
            }
        case .move:
            guard let s = item.source else { throw FolderAccessError.invalidPath("the journal has no source") }
            let (dir, name) = try placed(item, r)
            let back = try sourceParent(s)
            if dryRun {
                if try Posix.lstatAt(back.descriptor.fd, s.location.name) != nil {
                    throw FolderAccessError.exists(s.location.relativePath)
                }
                return
            }
            if renameatx_np(dir.descriptor.fd, name, back.descriptor.fd, s.location.name, excl) != 0 {
                let e = errno
                if e == EEXIST { throw FolderAccessError.exists(s.location.relativePath) }
                throw FolderAccessError.system("move back \(name)", e)
            }
            // What moved must be the item; anything swapped in goes back.
            if (try? Posix.lstatAt(back.descriptor.fd, s.location.name))?.identity != r.identity {
                if renameatx_np(back.descriptor.fd, s.location.name, dir.descriptor.fd, name, excl) == 0 {
                    throw FolderAccessError.changed("\(name) was replaced since")
                }
                throw Uncertain(description: "something other than the item was moved to \(s.location.relativePath)")
            }
        case .trash:
            guard let s = item.source else { throw FolderAccessError.invalidPath("the journal has no source") }
            let trashed = try inTrash(r)
            let back = try sourceParent(s)
            if trashed.device != back.descriptor.identity.device {
                throw FolderAccessError.crossDevice(s.location.relativePath)
            }
            if dryRun {
                if try Posix.lstatAt(back.descriptor.fd, s.location.name) != nil {
                    throw FolderAccessError.exists(s.location.relativePath)
                }
                return
            }
            if renameatx_np(AT_FDCWD, trashed.path, back.descriptor.fd, s.location.name, excl) != 0 {
                let e = errno
                if e == EEXIST { throw FolderAccessError.exists(s.location.relativePath) }
                throw FolderAccessError.system("put back \(s.location.name)", e)
            }
            // Swapped in the Trash between the check and the move: back it goes.
            if (try? Posix.lstatAt(back.descriptor.fd, s.location.name))?.identity != r.identity {
                if renameatx_np(back.descriptor.fd, s.location.name, AT_FDCWD, trashed.path, excl) == 0 {
                    throw FolderAccessError.changed("\(s.location.name) changed in the Trash")
                }
                throw Uncertain(description: "something other than the item came back to \(s.location.relativePath)")
            }
        }
    }

    /// After an interrupted undo: is the item where it was before the plan
    /// (or, for a made folder, gone)? A made folder found taken aside is
    /// removed if still empty, else put back under its name.
    private func isBack(_ item: PlanItem, _ r: JournalResult, planID: UUID) throws -> Bool {
        switch item.kind {
        case .makeDir:
            guard let d = item.destination, let comps = r.components, let name = comps.last, let chain = r.destinationChain else { return false }
            let dir = try walker(d.location.root).openDirectory(Array(comps.dropLast()), expected: chain)
            if try Posix.lstatAt(dir.descriptor.fd, name)?.identity == r.identity { return false }
            let aside = Self.asideName(planID: planID, item: item.id)
            guard try Posix.lstatAt(dir.descriptor.fd, aside)?.identity == r.identity else {
                // Removed -- or moved away by someone: can't be told apart.
                throw Uncertain(description: "\(name) is gone from its place; if it was removed, nothing is left to undo")
            }
            if unlinkat(dir.descriptor.fd, aside, AT_REMOVEDIR) == 0 {
                if (try? Posix.lstatAt(dir.descriptor.fd, aside)) != nil {
                    throw Uncertain(description: "\(aside) is still there after removing it")
                }
                return true
            }
            if renameatx_np(dir.descriptor.fd, aside, dir.descriptor.fd, name, UInt32(RENAME_EXCL)) == 0 { return false }
            throw Uncertain(description: "\(name) was left as \(aside)")
        case .move, .trash:
            guard let s = item.source else { return false }
            // Held in a local: the descriptor closes when the value goes.
            let parent = try sourceParent(s)
            let atSource = try withExtendedLifetime(parent) {
                try Posix.lstatAt(parent.descriptor.fd, s.location.name)?.identity == s.identity
            }
            guard atSource else { return false }
            // Also gone from where the plan put it (a hard link could make it
            // look back while still there).
            let stillPlaced: Bool
            if item.kind == .trash {
                stillPlaced = r.trashURL.flatMap { Posix.lstatPath($0) }?.identity == r.identity
            } else {
                // Looked at, not assumed: a lookup that fails is no proof.
                guard let d = item.destination, let comps = r.components, let name = comps.last,
                      let chain = r.destinationChain else {
                    throw Uncertain(description: "the journal has no destination")
                }
                let dir: OpenedDirectory
                do {
                    dir = try walker(d.location.root).openDirectory(Array(comps.dropLast()), expected: chain)
                } catch {
                    throw Uncertain(description: "can't look where \(s.location.relativePath) was put: \(error)")
                }
                stillPlaced = try withExtendedLifetime(dir) {
                    try Posix.lstatAt(dir.descriptor.fd, name)?.identity == r.identity
                }
            }
            if stillPlaced { throw Uncertain(description: "\(s.location.relativePath) is in both places (a hard link?)") }
            return true
        }
    }

    static func isEmptyDirectory(_ parent: Descriptor, _ name: String) throws -> Bool {
        let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FolderAccessError.system("open \(name)", errno) }
        guard let stream = fdopendir(fd) else {
            close(fd)
            throw FolderAccessError.system("fdopendir", errno)
        }
        defer { closedir(stream) }
        while let ent = readdir(stream) {
            let n = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if n != "." && n != ".." { return false }
        }
        return true
    }
}
