import Foundation

/// A place inside a grant: the grant's root and the components below it.
public struct FolderLocation: Codable, Hashable, Sendable {
    public var root: FolderRoot
    public var components: [String]

    public init(root: FolderRoot, components: [String]) {
        self.root = root
        self.components = components
    }

    public init(root: FolderRoot, path: String) throws {
        self.init(root: root, components: try SafeFolderWalker.components(path))
    }

    public var name: String { components.last ?? "" }
    public var parentComponents: [String] { Array(components.dropLast()) }
    public var relativePath: String { components.joined(separator: "/") }
    public var displayPath: String { components.isEmpty ? root.path : root.path + "/" + relativePath }
}

/// One op of a `change_files` call (adr/0014): the ops list is the plan the
/// user approves, whole or in part. `move.to` is the full new path (a move
/// into a folder names the item's name at the end; a rename is a move in
/// the same folder).
public enum ChangeRequest: Equatable, Sendable {
    case makeDir(FolderLocation)
    case move(from: FolderLocation, to: FolderLocation)
    case trash(FolderLocation)
}

public enum ChangeKind: String, Codable, Sendable {
    case makeDir = "make_dir"
    case move
    case trash
}

/// What a name collision does at execution. Decided by the file system
/// (`EEXIST` from an exclusive create or rename), never by comparing names.
public enum CollisionPolicy: String, Codable, Sendable {
    /// Report the conflict; nothing is overwritten.
    case fail
    /// Retry with "name 2", "name 3"... until the file system takes one.
    case keepBoth = "keep_both"
}

/// The item a move or trash acts on, as it was when proposed: what
/// execution holds it to.
public struct CapturedSource: Codable, Equatable, Sendable {
    public var location: FolderLocation
    /// Identities from the root down to the parent.
    public var parentChain: [FileIdentity]
    public var identity: FileIdentity
    public var kind: EntryKind
    public var size: Int64
    public var hardLinked: Bool
    public var fileProvider: Bool
}

/// Where a make_dir or move lands: the existing part of the parent path by
/// identity; the rest is made by earlier make_dir items of the plan.
public struct CapturedDestination: Codable, Equatable, Sendable {
    public var location: FolderLocation
    /// Identities from the root down to the deepest existing ancestor.
    public var existingChain: [FileIdentity]
    /// The name was taken when proposed (the plan can offer "keep both").
    public var existedAtProposal: Bool
}

public struct PlanItem: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var kind: ChangeKind
    public var source: CapturedSource?
    public var destination: CapturedDestination?
    public var collision: CollisionPolicy
    /// make_dir items that create this item's missing parents.
    public var dependsOn: [Int]
    /// What the review must say: a hard link, a file-provider item, a
    /// package...
    public var notes: [String]

    /// A one-line description for the plan review.
    public var summary: String {
        switch kind {
        case .makeDir: return "make folder \(destination?.location.relativePath ?? "")"
        case .move: return "move \(source?.location.relativePath ?? "") to \(destination?.location.relativePath ?? "")"
        case .trash: return "move \(source?.location.relativePath ?? "") to the Trash"
        }
    }
}

/// The pending changes of one chat: built from `change_files` ops, kept
/// across turns until the user approves (all or some) or cancels
/// (Hardening 3).
public struct ChangePlan: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var chatID: String
    public var created: Date
    public var items: [PlanItem]
    /// Bumped by every change to the pending plan: an approval names the
    /// revision the user reviewed, so nothing added after it rides along.
    public var revision: Int

    public init(id: UUID = UUID(), chatID: String, created: Date = Date(), items: [PlanItem] = [], revision: Int = 0) {
        self.id = id
        self.chatID = chatID
        self.created = created
        self.items = items
        self.revision = revision
    }
}

/// A plan the user approved, as `ChangePlanStore.approve` returned it -- the
/// only way to get one, and the only thing `ChangeExecutor` runs. One
/// approval runs once: `take()` hands the plan out a single time.
public final class ApprovedPlan: @unchecked Sendable {
    public let plan: ChangePlan
    private let lock = NSLock()
    private var taken = false

    init(plan: ChangePlan) {
        self.plan = plan
    }

    /// The plan, the first time; nil after.
    func take() -> ChangePlan? {
        lock.lock()
        defer { lock.unlock() }
        if taken { return nil }
        taken = true
        return plan
    }
}

public enum ChangePlanError: Error, Equatable, CustomStringConvertible {
    case temporaryChat
    case nothingPending
    case unknownItems([Int])
    /// A chosen item needs a make_dir item that wasn't chosen.
    case missingDependency(item: Int, needs: Int)
    case invalidated([Int: String])
    /// The plan changed after the user reviewed it.
    case stale(reviewed: Int, current: Int)

    public var description: String {
        switch self {
        case .temporaryChat: return "temporary chats can't change files"
        case .nothingPending: return "no pending changes"
        case .unknownItems(let ids): return "no such items: \(ids)"
        case .missingDependency(let i, let n): return "item \(i) needs item \(n) (the folder it goes into)"
        case .invalidated(let m): return "changed since proposed: " + m.keys.sorted().map { "\($0): \(m[$0]!)" }.joined(separator: "; ")
        case .stale(let r, let c): return "the plan changed since it was reviewed (revision \(r), now \(c))"
        }
    }
}

/// Turns `change_files` ops into plan items, capturing identities now so
/// execution can refuse anything that changed.
public struct ChangePlanner {
    public let denylist: FolderDenylist

    public init(denylist: FolderDenylist) {
        self.denylist = denylist
    }

    public struct Result {
        public var items: [PlanItem]
        /// Ops refused (index into the request list, why): the model can fix
        /// and resend them.
        public var rejected: [(index: Int, error: Error)]
    }

    /// Plans `requests` after the items already in `existing` (their
    /// make_dir items can be parents of new ones). Temporary chats can't
    /// change files (Hardening 8).
    public func plan(_ requests: [ChangeRequest], after existing: [PlanItem] = [], temporaryChat: Bool = false) throws -> Result {
        if temporaryChat { throw ChangePlanError.temporaryChat }
        var items: [PlanItem] = []
        var rejected: [(Int, Error)] = []
        var nextID = (existing.map(\.id).max() ?? 0) + 1
        for (index, request) in requests.enumerated() {
            do {
                let item = try planOne(request, id: nextID, prior: existing + items)
                items.append(item)
                nextID += 1
            } catch {
                rejected.append((index, error))
            }
        }
        return Result(items: items, rejected: rejected)
    }

    private func planOne(_ request: ChangeRequest, id: Int, prior: [PlanItem]) throws -> PlanItem {
        switch request {
        case .makeDir(let loc):
            let (dest, deps) = try destination(loc, prior: prior)
            if dest.existedAtProposal { throw FolderAccessError.exists(loc.relativePath) }
            return PlanItem(id: id, kind: .makeDir, source: nil, destination: dest, collision: .fail, dependsOn: deps, notes: [])
        case .move(let from, let to):
            // Byte for byte: "é" composed and decomposed are different
            // requests (Swift's == would call them equal).
            if from.root == to.root, from.components.map({ Array($0.utf8) }) == to.components.map({ Array($0.utf8) }) {
                throw FolderAccessError.invalidPath("moving to where it is: \(to.relativePath)")
            }
            let source = try capture(from, prior: prior)
            let (dest, deps) = try destination(to, prior: prior)
            if from.root.identity.device != to.root.identity.device || dest.existingChain.first?.device != source.identity.device {
                throw FolderAccessError.crossDevice(to.displayPath)
            }
            if dest.existingChain.contains(source.identity) {
                throw FolderAccessError.invalidPath("can't move a folder into itself: \(to.relativePath)")
            }
            return PlanItem(id: id, kind: .move, source: source, destination: dest,
                            collision: .fail, dependsOn: deps, notes: notes(source))
        case .trash(let loc):
            let source = try capture(loc, prior: prior)
            var n = notes(source)
            if source.fileProvider {
                n.append("managed by a file provider: moving it to the Trash removes it from your other devices too")
            }
            return PlanItem(id: id, kind: .trash, source: source, destination: nil, collision: .fail, dependsOn: [], notes: n)
        }
    }

    private func notes(_ s: CapturedSource) -> [String] {
        var n: [String] = []
        if s.hardLinked { n.append("has more than one name (a hard link): the other names keep the file") }
        if s.kind == .package { n.append("a package: moved as one item") }
        if s.kind == .symlink { n.append("a symbolic link: the link itself, not what it points to") }
        if s.kind == .alias { n.append("an alias: the alias itself, not what it points to") }
        return n
    }

    private func capture(_ loc: FolderLocation, prior: [PlanItem]) throws -> CapturedSource {
        let walker = SafeFolderWalker(root: loc.root, denylist: denylist)
        let item = try walker.resolve(loc.components)
        guard let entry = item.entry else { throw FolderAccessError.notFound(loc.relativePath) }
        if prior.contains(where: { $0.source?.identity == entry.identity }) {
            throw FolderAccessError.invalidPath("already in the plan: \(loc.relativePath)")
        }
        let path = item.parent.descriptor.currentPath.map { $0 + "/" + entry.name }
        return CapturedSource(location: loc, parentChain: item.parent.chain, identity: entry.identity, kind: entry.kind,
                              size: entry.stat.size, hardLinked: entry.stat.isHardLinked,
                              fileProvider: path.map(SafeFolderWalker.isFileProviderItem) ?? false)
    }

    /// The deepest existing ancestor of `loc`'s parent by descriptors; each
    /// missing component must be made by an earlier make_dir item.
    private func destination(_ loc: FolderLocation, prior: [PlanItem]) throws -> (CapturedDestination, [Int]) {
        guard !loc.components.isEmpty else { throw FolderAccessError.invalidPath("the grant root itself") }
        // A denied name (".ssh", a keychain) would make the item invisible.
        if let denied = loc.components.first(where: denylist.isDenied(name:)) {
            throw FolderAccessError.notGrantable(denied)
        }
        let walker = SafeFolderWalker(root: loc.root, denylist: denylist)
        var dir = try walker.openRoot()
        let parent = loc.parentComponents
        var existing = 0
        var deps: [Int] = []
        for name in parent {
            do {
                dir = try walker.step(dir, name)
                existing += 1
            } catch FolderAccessError.notFound {
                break
            }
        }
        for depth in existing..<parent.count {
            let prefix = Array(parent[0...depth])
            guard let maker = prior.last(where: {
                $0.kind == .makeDir && $0.destination?.location.root.identity == loc.root.identity
                    && $0.destination?.location.components == prefix
            }) else {
                throw FolderAccessError.notFound("\(prefix.joined(separator: "/")) (make it first)")
            }
            deps.append(maker.id)
        }
        let taken = existing == parent.count ? try walker.entry(in: dir, loc.name) != nil : false
        return (CapturedDestination(location: loc, existingChain: dir.chain, existedAtProposal: taken), deps)
    }

    /// Items whose captured identities no longer hold (id -> why): the review
    /// shows them; approval refuses them.
    public func invalidItems(_ plan: ChangePlan) -> [Int: String] {
        var out: [Int: String] = [:]
        for item in plan.items {
            do {
                if let s = item.source {
                    let walker = SafeFolderWalker(root: s.location.root, denylist: denylist)
                    let r = try walker.resolve(s.location.components, expectedParents: s.parentChain)
                    if r.entry?.identity != s.identity { throw FolderAccessError.changed(s.location.relativePath) }
                }
                if let d = item.destination {
                    let walker = SafeFolderWalker(root: d.location.root, denylist: denylist)
                    let comps = Array(d.location.parentComponents.prefix(d.existingChain.count - 1))
                    _ = try walker.openDirectory(comps, expected: d.existingChain)
                }
            } catch {
                out[item.id] = "\(error)"
            }
        }
        return out
    }
}

/// The pending plans, one per chat, in memory (a restart forgets them:
/// nothing was approved). Thread-safe.
public final class ChangePlanStore: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [String: ChangePlan] = [:]

    public init() {}

    /// Adds planned items to the chat's pending plan (made if none).
    @discardableResult
    public func add(_ items: [PlanItem], chatID: String, now: Date = Date()) -> ChangePlan {
        lock.lock()
        defer { lock.unlock() }
        var plan = plans[chatID] ?? ChangePlan(chatID: chatID, created: now)
        plan.items += items
        plan.revision += 1
        plans[chatID] = plan
        return plan
    }

    public func pending(chatID: String) -> ChangePlan? {
        lock.lock()
        defer { lock.unlock() }
        return plans[chatID]
    }

    /// Sets an item's collision policy ("keep both" in the review).
    public func setCollision(_ policy: CollisionPolicy, item: Int, chatID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var plan = plans[chatID], let i = plan.items.firstIndex(where: { $0.id == item }) else { return }
        plan.items[i].collision = policy
        plan.revision += 1
        plans[chatID] = plan
    }

    public func cancel(chatID: String) {
        lock.lock()
        plans[chatID] = nil
        lock.unlock()
    }

    /// The user's approval of `items` (nil: all) of the plan `revision` they
    /// reviewed: every chosen item is checked again against its captured
    /// identities (`validator`), the pending plan is taken out and the
    /// approved part returned in plan order. Refused, leaving the plan
    /// pending, if the plan changed since `revision`, an item is unknown,
    /// needs an unchosen make_dir, or no longer matches.
    public func approve(chatID: String, revision: Int, items: Set<Int>? = nil,
                        validator: ChangePlanner) throws -> ApprovedPlan {
        guard let snapshot = pending(chatID: chatID), !snapshot.items.isEmpty else { throw ChangePlanError.nothingPending }
        if snapshot.revision != revision { throw ChangePlanError.stale(reviewed: revision, current: snapshot.revision) }
        let chosen = items ?? Set(snapshot.items.map(\.id))
        let unknown = chosen.subtracting(snapshot.items.map(\.id))
        if !unknown.isEmpty { throw ChangePlanError.unknownItems(unknown.sorted()) }
        for item in snapshot.items where chosen.contains(item.id) {
            if let missing = item.dependsOn.first(where: { !chosen.contains($0) }) {
                throw ChangePlanError.missingDependency(item: item.id, needs: missing)
            }
        }
        var approved = snapshot
        approved.items = snapshot.items.filter { chosen.contains($0.id) }
        // File checks outside the lock; the revision check below makes sure
        // they were made on what is taken out.
        let bad = validator.invalidItems(approved)
        if !bad.isEmpty { throw ChangePlanError.invalidated(bad) }
        lock.lock()
        defer { lock.unlock() }
        guard let current = plans[chatID] else { throw ChangePlanError.nothingPending }
        if current.revision != revision || current.id != snapshot.id {
            throw ChangePlanError.stale(reviewed: revision, current: current.revision)
        }
        plans[chatID] = nil
        return ApprovedPlan(plan: approved)
    }
}
