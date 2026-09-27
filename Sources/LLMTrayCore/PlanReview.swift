import Foundation

/// The plan review's state (adr/0014, Hardening 3, 13): a pending plan, the
/// items the user has ticked, those that no longer match what was proposed.
/// What an approval sends is the exact plan (id, revision) and the ticked
/// items; the store refuses anything stale.
public struct PlanReview: Equatable, Sendable {
    public private(set) var plan: ChangePlan
    public private(set) var selected: Set<Int>
    /// Items whose captured identities or grants no longer hold (id -> why):
    /// shown, never approvable.
    public var invalid: [Int: String]

    /// Items a newer revision added since the review began: unticked until
    /// the user ticks them (a Return or a quick click never approves what
    /// they haven't seen).
    public private(set) var added: Set<Int> = []

    /// What was looked up on disk for the review (`PlanChecker`), once it's
    /// in (`apply`).
    public private(set) var checks = PlanChecks()
    /// Items `apply` unticked (a copy that isn't identical): never again, so
    /// a tick the user puts back holds.
    public private(set) var autoUnticked: Set<Int> = []

    /// A review of `plan`; a newer revision of the plan reviewed in
    /// `previous` keeps the user's choices for the items it had, and the
    /// new items start unticked.
    public init(plan: ChangePlan, previous: PlanReview? = nil, invalid: [Int: String] = [:]) {
        self.plan = plan
        self.invalid = invalid
        let ids = Set(plan.items.map(\.id))
        if let previous, previous.plan.id == plan.id {
            let known = Set(previous.plan.items.map(\.id))
            selected = previous.selected.intersection(ids)
            added = previous.added.intersection(ids).union(ids.subtracting(known))
            checks = previous.checks
            autoUnticked = previous.autoUnticked
        } else {
            selected = ids
        }
        selected = closed(selected)
    }

    public var items: [PlanItem] { plan.items }

    /// What an approval sends: ticked and still valid.
    public var approvable: Set<Int> { closed(selected.subtracting(invalid.keys)) }

    public func isSelected(_ id: Int) -> Bool { selected.contains(id) }

    /// Ticks or unticks an item. Ticking one ticks the make_dir items it
    /// needs; unticking a make_dir unticks what goes into it.
    public mutating func set(_ id: Int, selected on: Bool) {
        guard plan.items.contains(where: { $0.id == id }) else { return }
        added.remove(id)   // looked at now
        if on {
            var add: [Int] = [id]
            while let next = add.popLast() {
                guard selected.insert(next).inserted || next == id else { continue }
                add += plan.items.first { $0.id == next }?.dependsOn ?? []
            }
        } else {
            var drop: [Int] = [id]
            while let next = drop.popLast() {
                guard selected.remove(next) != nil else { continue }
                drop += plan.items.filter { $0.dependsOn.contains(next) }.map(\.id)
            }
        }
    }

    /// The checks of this plan's items, in: a trashed copy that isn't
    /// identical to its original is unticked (once; the user may tick it).
    public mutating func apply(_ new: PlanChecks) {
        let ids = Set(plan.items.map(\.id))
        checks.sizes.merge(new.sizes.filter { ids.contains($0.key) }) { $1 }
        checks.notIdentical.merge(new.notIdentical.filter { ids.contains($0.key) }) { $1 }
        for id in new.notIdentical.keys where ids.contains(id) && autoUnticked.insert(id).inserted {
            set(id, selected: false)
        }
    }

    public mutating func setAll(_ on: Bool) {
        selected = on ? Set(plan.items.map(\.id)) : []
        added = []
    }

    /// Without items whose make_dir parents aren't in the set.
    func closed(_ ids: Set<Int>) -> Set<Int> {
        var out = ids
        var changed = true
        while changed {
            changed = false
            for item in plan.items where out.contains(item.id) && item.dependsOn.contains(where: { !out.contains($0) }) {
                out.remove(item.id)
                changed = true
            }
        }
        return out
    }

    // MARK: What it says

    /// A plan's parts, counted (the app words them in the user's language).
    public struct Counts: Equatable, Sendable {
        public var folders = 0
        /// Moves into another folder.
        public var moves = 0
        /// All moved items are files.
        public var movesAreFiles = true
        /// Distinct folders the moves go into.
        public var destinations = 0
        /// Moves within their folder (a new name).
        public var renames = 0
        public var trashes = 0

        public var total: Int { folders + moves + renames + trashes }
    }

    public static func counts(_ items: [PlanItem]) -> Counts {
        var c = Counts()
        var destinations = Set<[String]>()
        for item in items {
            switch item.kind {
            case .makeDir: c.folders += 1
            case .trash: c.trashes += 1
            case .move:
                guard let s = item.source, let d = item.destination else { continue }
                if s.location.root == d.location.root, s.location.parentComponents == d.location.parentComponents {
                    c.renames += 1
                } else {
                    c.moves += 1
                    if s.kind != .file { c.movesAreFiles = false }
                    destinations.insert([d.location.root.path] + d.location.parentComponents)
                }
            }
        }
        c.destinations = destinations.count
        return c
    }

    public var counts: Counts { Self.counts(plan.items) }
    public var selectedCounts: Counts { Self.counts(plan.items.filter { selected.contains($0.id) }) }

    /// "move 47 files into 6 folders, trash 3": the model's wording.
    public static func englishSummary(_ c: Counts) -> String {
        func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
        var parts: [String] = []
        if c.folders > 0 { parts.append("make " + n(c.folders, "folder", "folders")) }
        if c.moves > 0 {
            parts.append("move " + n(c.moves, c.movesAreFiles ? "file" : "item", c.movesAreFiles ? "files" : "items")
                         + " into " + n(c.destinations, "folder", "folders"))
        }
        if c.renames > 0 { parts.append("rename " + String(c.renames)) }
        if c.trashes > 0 { parts.append("trash " + String(c.trashes)) }
        return parts.isEmpty ? "no changes" : parts.joined(separator: ", ")
    }

    // MARK: The plan as a whole

    /// Past this many moved or trashed items the review says how many, and
    /// how much.
    public static let largePlanItems = 200

    /// What the review says above Approve (adr/0014, "Listing sizes and the
    /// plan's warnings").
    public enum PlanWarning: Equatable, Sendable {
        /// Items taken out of subfolders of the folder the plan tidies: how
        /// many subfolders, the first names.
        case reachesIntoSubfolders(count: Int, names: [String])
        /// More than `largePlanItems` items moved or trashed: how many, their
        /// bytes (`atLeast`: a folder among them wasn't measured whole).
        case large(items: Int, bytes: Int64, atLeast: Bool)
        /// A trashed "copy" that differs from its original (the copy's name).
        case notIdentical(name: String)
    }

    /// For what Approve would do now (the ticked, valid items), and every
    /// copy found not identical, ticked or not.
    public var planWarnings: [PlanWarning] {
        let chosen = plan.items.filter { approvable.contains($0.id) }
        var out: [PlanWarning] = []
        let reach = Self.reachedSubfolders(chosen)
        if !reach.isEmpty { out.append(.reachesIntoSubfolders(count: reach.count, names: Array(reach.prefix(3)))) }
        let touched = chosen.filter { $0.kind != .makeDir }
        if touched.count > Self.largePlanItems {
            let size = Self.bytes(touched, checks)
            out.append(.large(items: touched.count, bytes: size.bytes, atLeast: size.atLeast))
        }
        for item in plan.items where checks.notIdentical[item.id] != nil {
            out.append(.notIdentical(name: item.source?.location.name ?? ""))
        }
        return out
    }

    /// The subfolders a plan reaches into, by name (sorted). Per grant: the
    /// folder the plan tidies is the deepest one holding every moved or
    /// trashed item (the longest common parent of their sources); when some
    /// items sit right in it, the others -- in its subfolders -- are taken
    /// out of those subfolders, named by the subfolder right under it. A plan
    /// whose items all sit in subfolders (the user named them) reaches into
    /// nothing; nor does a plan that moves a subfolder whole.
    public static func reachedSubfolders(_ items: [PlanItem]) -> [String] {
        var byRoot: [FolderRoot: [[String]]] = [:]
        for item in items where item.kind != .makeDir {
            guard let s = item.source else { continue }
            byRoot[s.location.root, default: []].append(s.location.parentComponents)
        }
        var names = Set<String>()
        for parents in byRoot.values {
            guard var base = parents.first else { continue }
            for p in parents.dropFirst() {
                base = zip(base, p).prefix { $0.0 == $0.1 }.map { $0.0 }
            }
            guard parents.contains(base) else { continue }
            for p in parents where p.count > base.count { names.insert(p[base.count]) }
        }
        return names.sorted()
    }

    /// The items' bytes: files by their size when proposed, folders as
    /// measured (`atLeast` when one wasn't, or only partly).
    static func bytes(_ items: [PlanItem], _ checks: PlanChecks) -> (bytes: Int64, atLeast: Bool) {
        var total: Int64 = 0
        var atLeast = false
        for item in items {
            guard let s = item.source else { continue }
            switch s.kind {
            case .directory, .package:
                if let m = checks.sizes[item.id] {
                    total += m.bytes
                    if m.partial { atLeast = true }
                } else {
                    atLeast = true
                }
            case .file: total += s.size
            default: break
            }
        }
        return (total, atLeast)
    }

    /// A trash item's size for its row: a file's, or a folder's as measured
    /// (nil: not measured).
    public func trashSize(_ item: PlanItem) -> FolderSize? {
        guard item.kind == .trash, let s = item.source else { return nil }
        switch s.kind {
        case .file: return FolderSize(items: 1, bytes: s.size)
        case .directory, .package: return checks.sizes[item.id]
        default: return nil
        }
    }

    /// What the review must say about an item (Hardening 5, 6, 12).
    public enum Warning: Equatable, Sendable {
        /// More than one name: the other names keep the file.
        case hardLink
        /// A file provider (iCloud Drive...) manages it: trashing it removes
        /// it from the user's other devices too.
        case fileProvider(trash: Bool)
        case package
        case symlink
        case alias
        /// The name is taken now: the move fails unless "keep both".
        case nameTaken
        /// Restore from the Trash with LLMTray's Undo, not Finder's Put Back.
        case trashRestore
    }

    public static func warnings(_ item: PlanItem) -> [Warning] {
        var w: [Warning] = []
        if let s = item.source {
            if s.hardLinked { w.append(.hardLink) }
            if s.fileProvider { w.append(.fileProvider(trash: item.kind == .trash)) }
            switch s.kind {
            case .package: w.append(.package)
            case .symlink: w.append(.symlink)
            case .alias: w.append(.alias)
            default: break
            }
        }
        if item.kind == .move, item.destination?.existedAtProposal == true, item.collision == .fail { w.append(.nameTaken) }
        if item.kind == .trash { w.append(.trashRestore) }
        return w
    }
}

/// An executed plan's outcome, counted for the result card and the model.
public struct PlanOutcome: Equatable, Sendable {
    public var done = 0
    public var failed = 0
    public var uncertain = 0
    public var notRun = 0
    /// The failure or uncertainty that stopped it, with its item.
    public var stoppedAt: Int?
    public var problem: String?

    public init(_ report: ChangeExecutor.Report) {
        for (id, status) in report.outcomes {
            switch status {
            case .done: done += 1
            case .failed(let why):
                failed += 1
                if id == report.stoppedAt { problem = why }
            case .uncertain(let why):
                uncertain += 1
                if id == report.stoppedAt { problem = why }
            case .notRun: notRun += 1
            }
        }
        stoppedAt = report.stoppedAt
    }
}
