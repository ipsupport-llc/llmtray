import Darwin
import Foundation

/// The chat a folder tool call is for: its id (a saved chat's session id, a
/// temporary chat's own) and whether it's temporary (read only, grants only
/// within it: Hardening 8, 19).
public struct FolderChat: Equatable, Sendable {
    public var id: String
    public var temporary: Bool

    public init(id: String, temporary: Bool) {
        self.id = id
        self.temporary = temporary
    }
}

/// A folder the model's call needs and has no grant for: the user is asked.
public struct FolderGrantRequest: Equatable, Sendable {
    public var root: FolderRoot
    public var level: FolderAccessLevel

    public init(root: FolderRoot, level: FolderAccessLevel) {
        self.root = root
        self.level = level
    }
}

/// The user's answer to a grant prompt.
public enum GrantChoice: String, CaseIterable, Sendable {
    case once, hour, chat, always, deny

    /// What a prompt offers: a temporary chat's grants end with it; a grant
    /// the user starts themselves isn't for one call.
    public static func offered(temporaryChat: Bool, forCall: Bool = true) -> [GrantChoice] {
        let all: [GrantChoice] = temporaryChat ? [.once, .chat, .deny] : allCases
        return forCall ? all : all.filter { $0 != .once && $0 != .deny }
    }

    /// The grant's lifetime (nil for deny).
    public func lifetime(callKey: String, chatID: String, now: Date = Date()) -> GrantLifetime? {
        switch self {
        case .once: return .once(callKey: callKey, chatID: chatID)
        case .hour: return .until(now.addingTimeInterval(3600))
        case .chat: return .chat(chatID)
        case .always: return .always
        case .deny: return nil
        }
    }
}

/// A folder tool's answer for the model: a result, or a refusal (left out
/// of later turns).
public enum FolderToolAnswer: Equatable, Sendable {
    case text(String)
    case refused(String)

    public var text: String {
        switch self {
        case .text(let t), .refused(let t): return t
        }
    }
}

/// The folder tools' work (adr/0014), for the app and its tests: paths as
/// the model writes them resolved against the chat's grants, the grant
/// prompt's rules (Hardening 9), `files` and `change_files`, and the plan's
/// approval, execution, undo and recovery. Thread-safe as its parts are;
/// the file work is synchronous (call it off the main thread).
public final class FolderToolService: @unchecked Sendable {
    public let grants: FolderGrants
    public let denylist: FolderDenylist
    public let plans: ChangePlanStore
    public let journal: ChangeJournal
    public let home: String
    public var trasher: Trasher
    public var listingLimits = FolderFiles.Limits()
    public var duplicateLimits = DuplicateFinder.Limits()
    public var classifier = FileClassifier()
    /// Folders one `change_files` call may ask grants for.
    public var maxPromptsPerCall = 2

    /// Asks the user about one folder; nil when the call was stopped.
    public typealias Ask = @Sendable (FolderGrantRequest) async -> GrantChoice?

    public init(grants: FolderGrants, denylist: FolderDenylist, plans: ChangePlanStore = ChangePlanStore(),
                journal: ChangeJournal, home: String = NSHomeDirectory(), trasher: Trasher = SystemTrasher()) {
        self.grants = grants
        self.denylist = denylist
        self.plans = plans
        self.journal = journal
        let h = Posix.realpath(home) ?? home
        self.home = h.hasSuffix("/") && h.count > 1 ? String(h.dropLast()) : h
        self.trasher = trasher
    }

    public func display(_ path: String) -> String { FolderToolText.display(path, home: home) }

    // MARK: Grants in a chat

    /// The grants a chat may use now (a `once` grant only for its call).
    public func usableGrants(_ chat: FolderChat, callKey: String? = nil, now: Date = Date()) -> [FolderGrant] {
        grants.allGrants(now: now).filter { g in
            switch g.lifetime {
            case .always, .until: return !chat.temporary
            case .chat(let id): return id == chat.id
            case .once(let key, let id): return id == chat.id && key == callKey
            }
        }
    }

    /// The folders a chat may use, for its menu and `files()`; one per
    /// folder, the widest level.
    public func accessibleFolders(_ chat: FolderChat, now: Date = Date()) -> [FolderGrant] {
        var best: [FolderRoot: FolderGrant] = [:]
        for g in usableGrants(chat, now: now) {
            if let b = best[g.root], b.level >= g.level { continue }
            best[g.root] = g
        }
        return best.values.sorted { $0.root.path < $1.root.path }
    }

    /// The user asked for access themselves: a grant, and the model may ask
    /// again (Hardening 9).
    @discardableResult
    public func userGrant(_ root: FolderRoot, level: FolderAccessLevel, choice: GrantChoice, chat: FolderChat?,
                          now: Date = Date()) throws -> FolderGrant? {
        if let chat { grants.userAskedForAccess(chatID: chat.id) }
        guard let lifetime = choice.lifetime(callKey: UUID().uuidString, chatID: chat?.id ?? "", now: now),
              choice != .once else { return nil }
        if chat == nil, case .chat = lifetime { return nil }
        return try grants.grant(root, level: level, lifetime: lifetime, chatID: chat?.id, temporaryChat: chat?.temporary ?? false,
                                origin: chat == nil ? .settings : .chat, now: now)
    }

    /// One edit of a standing grant's row in Settings.
    public enum GrantEdit: Equatable, Sendable {
        /// Look only (for as long as it may look), or look and propose
        /// changes (for as long as it has).
        case level(FolderAccessLevel)
        /// The row's level for an hour from now, or always.
        case lifetime(GrantChoice)
        /// After a change grant's time: looking on (an hour from now,
        /// always), or nil for nothing.
        case lookAfterChange(GrantChoice?)
    }

    /// A standing grant edited in Settings: its folder checked again as a new
    /// grant's is -- still there, grantable, and the same folder (path and
    /// identity) -- then the edit applied. Throws when anything doesn't hold;
    /// nothing changes then.
    @discardableResult
    public func updateGrant(_ id: UUID, _ edit: GrantEdit, now: Date = Date()) throws -> FolderGrant {
        guard let current = grants.standingGrants(now: now).first(where: { $0.id == id }) else {
            throw FolderGrants.GrantError.gone
        }
        func standing(_ choice: GrantChoice) throws -> GrantLifetime {
            guard choice == .hour || choice == .always,
                  let l = choice.lifetime(callKey: "", chatID: "", now: now) else { throw FolderGrants.GrantError.notStanding }
            return l
        }
        var level = current.level, lifetime = current.lifetime, readLifetime = current.readLifetime
        switch edit {
        case .level(.read):
            level = .read
            lifetime = current.lookLifetime
            readLifetime = nil
        case .level(.change):
            level = .change
        case .lifetime(let choice):
            lifetime = try standing(choice)
        case .lookAfterChange(let choice):
            guard current.level == .change else { return current }
            readLifetime = try choice.map(standing)
        }
        let root: FolderRoot
        do {
            root = try makeRoot(current.root.path)
        } catch {
            throw FolderGrants.GrantError.folderChanged
        }
        // Another folder at the path now (replaced, a link put in its place).
        guard root == current.root else { throw FolderGrants.GrantError.folderChanged }
        return try grants.update(id, root: root, level: level, lifetime: lifetime, readLifetime: readLifetime, now: now)
    }

    /// A folder picked by the user, checked for being grantable.
    public func makeRoot(_ path: String) throws -> FolderRoot {
        try SafeFolderWalker.makeRoot(path: path, denylist: denylist)
    }

    /// A chat ended: its per-chat and once grants, its denies and its
    /// pending plan go.
    public func endChat(_ chatID: String) {
        lock.lock()
        ended.insert(chatID)
        lock.unlock()
        grants.endChat(chatID)
        plans.cancel(chatID: chatID)
    }

    private let lock = NSLock()
    /// Chats ended (ids are never reused: a chat's id is per visit): a call
    /// that outlived its chat writes nothing for it -- no grant, no plan.
    private var ended: Set<String> = []

    public func hasEnded(_ chatID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended.contains(chatID)
    }

    enum GrantStep: Equatable {
        case granted
        case refused(String)
        case cancelled
    }

    /// Hardening 9: whether to ask, asking, and what the answer does.
    func obtain(_ request: FolderGrantRequest, chat: FolderChat, callKey: String, ask: Ask,
                isCancelled: @Sendable () -> Bool) async -> GrantStep {
        if chat.temporary, request.level > .read {
            return .refused("Temporary chats can only look at files, not change them.")
        }
        switch grants.shouldPrompt(path: request.root.path, identity: request.root.identity, level: request.level,
                                   chatID: chat.id, origin: .model) {
        case .refuse(let why):
            return .refused(Self.blockedNote(why))
        case .prompt:
            break
        }
        guard !isCancelled(), !hasEnded(chat.id), let choice = await ask(request),
              // Stopped (or the chat left) while the card was up: nothing is granted.
              !isCancelled(), !hasEnded(chat.id) else { return .cancelled }
        guard let lifetime = choice.lifetime(callKey: callKey, chatID: chat.id) else {
            grants.deny(request.root, level: request.level, chatID: chat.id)
            // The folder's name as asked (it may be a link's target) stays out.
            return .refused("The user declined \(request.level == .change ? "changes in" : "access to") that folder. "
                + "Don't ask again in this chat; they can allow it themselves.")
        }
        do {
            try grants.grant(request.root, level: request.level, lifetime: lifetime, chatID: chat.id, temporaryChat: chat.temporary,
                             origin: .chat)
            // The chat ended in between: what was just granted for it goes too.
            if hasEnded(chat.id) {
                grants.endChat(chat.id)
                return .cancelled
            }
            return .granted
        } catch {
            return .refused("The access couldn't be granted (\(error)). Answer without it.")
        }
    }

    static func blockedNote(_ why: String) -> String {
        why + " (They can use Allow Folder… in the chat's folder menu.)"
    }

    /// Before anything outside the grants is looked at: whether the model
    /// may prompt at all in this chat (after a deny it may not, and learns
    /// nothing about the path).
    func mayPrompt(_ path: String, level: FolderAccessLevel, chat: FolderChat) -> String? {
        if case .refuse(let why) = grants.shouldPrompt(path: path, identity: nil, level: level, chatID: chat.id, origin: .model) {
            return Self.blockedNote(why)
        }
        return nil
    }

    /// What the model is told of a path outside the grants that can't be
    /// asked for -- missing or never grantable alike: nothing outside a
    /// grant is visible, its existence included.
    static func notShareable(_ raw: String) -> String {
        "\(raw) isn't in a folder shared with this chat, and can't be asked for (it may not exist, or is a system or "
            + "private place: the home folder itself, Library, keys)"
    }

    // MARK: Paths

    enum PathError: Error, Equatable {
        case invalid(String)
        /// The model may not prompt in this chat now (a deny).
        case blocked(String)
    }

    /// A path as the model wrote it, made absolute: `~`, `file://`, `.` and
    /// empty components taken; `..` refused. A relative path is under the
    /// granted folder of that name, under the chat's one grant (when it
    /// exists there), else under the home folder.
    func absolute(_ raw: String, usable: [FolderGrant]) throws -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("file://") { p = URL(string: p)?.path ?? String(p.dropFirst(7)) }
        if p.utf8.contains(0) { throw PathError.invalid("a path can't contain NUL") }
        if p == "~" || p.hasPrefix("~/") {
            p = home + p.dropFirst(1)
        } else if !p.hasPrefix("/") {
            let first = p.split(separator: "/").first.map(String.init) ?? ""
            let roots = usable.map(\.root.path)
            if let named = roots.first(where: { ($0 as NSString).lastPathComponent == first })
                ?? roots.first(where: { ($0 as NSString).lastPathComponent.caseInsensitiveCompare(first) == .orderedSame }) {
                p = (named as NSString).deletingLastPathComponent + "/" + p
            } else if Set(roots).count == 1, let only = roots.first, Posix.lstatPath(only + "/" + p) != nil {
                p = only + "/" + p
            } else {
                p = home + "/" + p
            }
        }
        var parts: [String] = []
        for c in p.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if c == "." { continue }
            if c == ".." { throw PathError.invalid("use a full path without \"..\": \(raw)") }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Another spelling of `path` for grant matching: its existing part
    /// through `realpath` (/var -> /private/var), the last name kept as is
    /// (a link is the link, not what it points to).
    func canonicalSpelling(_ path: String) -> String? {
        var head = (path as NSString).deletingLastPathComponent
        var tail = [(path as NSString).lastPathComponent]
        while head != "/", !head.isEmpty, Posix.lstatPath(head) == nil {
            tail.insert((head as NSString).lastPathComponent, at: 0)
            head = (head as NSString).deletingLastPathComponent
        }
        guard let real = Posix.realpath(head.isEmpty ? "/" : head) else { return nil }
        let out = (real == "/" ? "" : real) + "/" + tail.joined(separator: "/")
        return out == path ? nil : out
    }

    static func components(_ path: String, under root: String) -> [String] {
        guard path != root else { return [] }
        return path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1).split(separator: "/").map(String.init)
    }

    /// The location of `path` under a usable grant at `level` (consuming a
    /// `once` grant made for this call), or nil.
    func authorized(_ path: String, level: FolderAccessLevel, chat: FolderChat, callKey: String) -> FolderLocation? {
        for spelling in [path, canonicalSpelling(path)].compactMap({ $0 }) {
            if let g = grants.authorize(path: spelling, level: level, chatID: chat.id, callKey: callKey, temporaryChat: chat.temporary) {
                return FolderLocation(root: g.root, components: Self.components(spelling, under: g.root.path))
            }
        }
        return nil
    }

    /// The location under a usable grant at `level`, without using anything
    /// up (a `once` grant for this call counts).
    func covered(_ path: String, level: FolderAccessLevel, chat: FolderChat, callKey: String) -> FolderLocation? {
        let usable = usableGrants(chat, callKey: callKey).filter { $0.level >= level }
        for spelling in [path, canonicalSpelling(path)].compactMap({ $0 }) {
            let matching = usable.filter { $0.covers(spelling) }
            // The innermost grant: its root is the nearest.
            if let g = matching.max(by: { $0.root.path.count < $1.root.path.count }) {
                return FolderLocation(root: g.root, components: Self.components(spelling, under: g.root.path))
            }
        }
        return nil
    }

    /// The folder to ask a grant for so that `path` can be read: the folder
    /// itself, or a file's folder. Throws what the model is told when there's
    /// none (nothing there; a place never granted).
    func folderToAsk(for path: String, raw: String) throws -> FolderRoot {
        let spelled = canonicalSpelling(path) ?? path
        guard let st = Posix.lstatPath(spelled) else { throw PathError.invalid(Self.notShareable(raw)) }
        let folder = st.isDirectory ? spelled : (spelled as NSString).deletingLastPathComponent
        do {
            return try makeRoot(folder)
        } catch {
            throw PathError.invalid(Self.notShareable(raw))
        }
    }

    // MARK: files

    /// One `files` call: the folders the chat may use (no path), a listing,
    /// duplicates or a file's info, within `byteBudget`. Asks for a read
    /// grant when the path has none (at most once per call).
    /// `changeNextMessage`: changes are off in this turn once it has read and
    /// back with the user's next message (`ToolTrust.changeWaitsForNextMessage`);
    /// a result from a folder the chat may propose changes in then ends by
    /// saying so (`FolderToolText.nextMessageNote`).
    public func files(_ request: FolderTools.FilesRequest, chat: FolderChat, callKey: String, byteBudget: Int,
                      changeNextMessage: Bool = false,
                      ask: Ask, isCancelled: @escaping @Sendable () -> Bool = { false }) async -> FolderToolAnswer {
        let name = FolderTools.filesName
        guard let raw = request.path else {
            return .text(FolderToolText.accessible(accessibleFolders(chat), home: home))
        }
        let path: String
        do {
            path = try absolute(raw, usable: usableGrants(chat, callKey: callKey))
        } catch PathError.invalid(let why) {
            return .text("\(name): \(why).")
        } catch {
            return .text("\(name): \(error).")
        }
        var location = authorized(path, level: .read, chat: chat, callKey: callKey)
        if location == nil {
            if let blocked = mayPrompt(path, level: .read, chat: chat) { return .refused(blocked) }
            let root: FolderRoot
            do {
                root = try folderToAsk(for: path, raw: raw)
            } catch PathError.invalid(let why) {
                return .text("\(name): \(why).")
            } catch {
                return .text("\(name): \(error).")
            }
            switch await obtain(FolderGrantRequest(root: root, level: .read), chat: chat, callKey: callKey, ask: ask,
                                isCancelled: isCancelled) {
            case .cancelled: return .refused("Cancelled by the user.")
            case .refused(let why): return .refused(why)
            case .granted: break
            }
            location = authorized(path, level: .read, chat: chat, callKey: callKey)
        }
        guard let location else {
            return .text("\(name): \(raw) isn't in a folder shared with this chat.")
        }
        // A grant revoked or expired while it reads (a long listing, a
        // duplicate scan) stops the read, and nothing of it is told.
        let revoked = Flag()
        let stillGranted = { [self] () -> Bool in
            let ok = !hasEnded(chat.id) && grants.coversRead(path: location.displayPath, chatID: chat.id, callKey: callKey,
                                                             temporaryChat: chat.temporary)
            if !ok { revoked.set() }
            return ok
        }
        let note = changeNextMessage && !chat.temporary
            && covered(path, level: .change, chat: chat, callKey: callKey) != nil ? FolderToolText.nextMessageNote : nil
        let room = byteBudget - (note.map { $0.utf8.count + 1 } ?? 0)
        let answer = run(request, at: location, byteBudget: room, isCancelled: { isCancelled() || !stillGranted() })
        guard !revoked.isSet, stillGranted() else {
            return .refused("Access to that folder was withdrawn while it was being read: nothing from it can be used. "
                + "Answer without it.")
        }
        // Only under a result read from the folder, not under an error.
        if let note, case .text(let t) = answer, !t.hasPrefix(name + ":") { return .text(t + "\n" + note) }
        return answer
    }

    /// Set once, from any thread.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// The read itself, by descriptors from the grant root.
    func run(_ request: FolderTools.FilesRequest, at location: FolderLocation, byteBudget: Int,
             isCancelled: @escaping () -> Bool) -> FolderToolAnswer {
        let walker = SafeFolderWalker(root: location.root, denylist: denylist)
        var limits = listingLimits
        limits.pageBytes = max(512, min(limits.pageBytes, byteBudget / 2))
        var dupLimits = duplicateLimits
        dupLimits.includeHidden = request.hidden
        let tool = FolderFiles(walker: walker, classifier: classifier, limits: limits, duplicateLimits: dupLimits)
        let query = FolderQuery(components: location.components, recursive: request.recursive, pattern: request.pattern,
                                onlyDuplicates: request.onlyDuplicates, hash: request.hash, cursor: request.cursor,
                                includeHidden: request.hidden)
        let shown = display(location.displayPath)
        do {
            switch try tool.run(query, isCancelled: isCancelled) {
            case .listing(let page):
                return .text(FolderToolText.listing(page, request: request, folder: shown, components: location.components,
                                                    byteBudget: byteBudget))
            case .duplicates(let page):
                return .text(FolderToolText.duplicates(page, request: request, folder: shown, components: location.components,
                                                       byteBudget: byteBudget))
            case .info(let info):
                return .text(FolderToolText.info(info, path: shown, byteBudget: byteBudget))
            }
        } catch let error as FolderAccessError {
            return .text("\(FolderTools.filesName): \(errorText(error)).")
        } catch {
            return .text("\(FolderTools.filesName): \(error).")
        }
    }

    /// A Core error with its paths as the model sees them.
    func errorText(_ error: Error) -> String {
        var s = "\(error)"
        if s.contains(home) { s = s.replacingOccurrences(of: home + "/", with: "~/") }
        return s
    }

    // MARK: change_files

    /// One `change_files` call: its ops planned against the grants and
    /// added to the chat's pending plan -- nothing changes (Hardening 3).
    /// Asks for a change grant for the folders the ops need and have none
    /// for (`maxPromptsPerCall` at most). Temporary chats can't change files.
    public func propose(_ ops: [FolderTools.RawOp], chat: FolderChat, callKey: String, ask: Ask,
                        isCancelled: @escaping @Sendable () -> Bool = { false }) async -> FolderToolAnswer {
        let name = FolderTools.changeName
        if chat.temporary { return .refused("Temporary chats can only look at files, not change them. Answer in text.") }
        // Each op's ends, made absolute.
        struct Ends { var from: String; var to: String? }
        var ends: [Ends] = []
        let usable = usableGrants(chat, callKey: callKey)
        do {
            for op in ops {
                let from = try absolute(op.path, usable: usable)
                var to: String?
                if op.kind == .move {
                    if let t = op.to {
                        to = try absolute(t, usable: usable)
                    } else if let n = op.newName {
                        try SafeFolderWalker.validateName(n)
                        to = (from as NSString).deletingLastPathComponent + "/" + n
                    }
                }
                ends.append(Ends(from: from, to: to))
            }
        } catch PathError.invalid(let why) {
            return .text("\(name): \(why). Nothing was added to the plan.")
        } catch {
            return .text("\(name): \(errorText(error)). Nothing was added to the plan.")
        }
        // A move "to" a folder -- one there, or made by an earlier op or
        // item -- goes into it.
        let pending = plans.pending(chatID: chat.id)?.items ?? []
        var madeDirs = Set(pending.compactMap { $0.kind == .makeDir ? $0.destination?.location.displayPath : nil })
        for (i, op) in ops.enumerated() {
            if op.kind == .makeDir { madeDirs.insert(ends[i].from) }
            guard op.kind == .move, let to = ends[i].to, op.to != nil else { continue }
            let spelled = canonicalSpelling(to) ?? to
            let st = Posix.lstatPath(spelled)
            let isFolder = madeDirs.contains(to) || madeDirs.contains(spelled) || op.to?.hasSuffix("/") == true
                || (st?.isDirectory == true && !SafeFolderWalker.isPackage(path: spelled))
            if isFolder { ends[i].to = to + "/" + (ends[i].from as NSString).lastPathComponent }
        }
        // Grants: every end under a change grant, asking for what's missing.
        var asked = 0
        while true {
            var missing: [String] = []
            for e in ends {
                for p in [e.from, e.to].compactMap({ $0 }) where covered(p, level: .change, chat: chat, callKey: callKey) == nil {
                    missing.append(p)
                }
            }
            if missing.isEmpty { break }
            let folders: [FolderRoot]
            do {
                folders = try foldersToAsk(forChanges: missing, chat: chat, callKey: callKey)
            } catch PathError.blocked(let why) {
                return .refused(why)
            } catch PathError.invalid(let why) {
                return .text("\(name): \(why). Nothing was added to the plan.")
            } catch {
                return .text("\(name): \(errorText(error)). Nothing was added to the plan.")
            }
            guard asked + folders.count <= maxPromptsPerCall else {
                return .text("\(name): these changes span too many folders. Ask the user to allow their common folder "
                    + "(Allow Folder… in the chat's folder menu), then send them again. Nothing was added to the plan.")
            }
            for root in folders {
                asked += 1
                switch await obtain(FolderGrantRequest(root: root, level: .change), chat: chat, callKey: callKey, ask: ask,
                                    isCancelled: isCancelled) {
                case .cancelled: return .refused("Cancelled by the user.")
                case .refused(let why): return .refused(why)
                case .granted: break
                }
            }
        }
        // A once grant is used up by this call; its items keep the key.
        var requests: [ChangeRequest] = []
        var opIndex: [Int] = []
        var rejected: [(index: Int, error: Error)] = []
        for (i, op) in ops.enumerated() {
            guard let from = covered(ends[i].from, level: .change, chat: chat, callKey: callKey) else {
                rejected.append((i, FolderAccessError.notGranted(display(ends[i].from))))
                continue
            }
            switch op.kind {
            case .makeDir: requests.append(.makeDir(from))
            case .trash: requests.append(.trash(from))
            case .move:
                guard let t = ends[i].to, let to = covered(t, level: .change, chat: chat, callKey: callKey) else {
                    rejected.append((i, FolderAccessError.notGranted(display(ends[i].to ?? ""))))
                    continue
                }
                requests.append(.move(from: from, to: to))
            }
            opIndex.append(i)
        }
        for root in Set(requests.flatMap(Self.roots)) {
            _ = grants.authorize(path: root.path, level: .change, chatID: chat.id, callKey: callKey)
        }
        let planner = ChangePlanner(denylist: denylist, canChange: grants.changeCheck(chatID: chat.id))
        let result: ChangePlanner.Result
        do {
            result = try planner.plan(requests, after: pending, proposal: callKey)
        } catch {
            return .text("\(name): \(errorText(error)).")
        }
        rejected += result.rejected.map { (opIndex[$0.index], $0.error) }
        rejected.sort { $0.index < $1.index }
        // Stopped, or the chat left, meanwhile: nothing lands in a plan
        // nobody sees (a later proposal would carry it along).
        if isCancelled() || hasEnded(chat.id) { return .refused("Cancelled by the user.") }
        let plan = result.items.isEmpty ? plans.pending(chatID: chat.id) : plans.add(result.items, chatID: chat.id)
        // Ended in between the check and the add: taken out again.
        if hasEnded(chat.id) {
            plans.cancel(chatID: chat.id)
            return .refused("Cancelled by the user.")
        }
        return .text(proposalText(added: result.items.count, rejected: rejected, ops: ops, plan: plan))
    }

    static func roots(_ r: ChangeRequest) -> [FolderRoot] {
        switch r {
        case .makeDir(let l), .trash(let l): return [l.root]
        case .move(let f, let t): return [f.root, t.root]
        }
    }

    /// The folders to ask change grants for so that `paths` are covered: a
    /// read grant's folder when one covers the path (an upgrade), else the
    /// item's folder (its nearest existing one); folders inside another
    /// asked for are left out.
    func foldersToAsk(forChanges paths: [String], chat: FolderChat, callKey: String) throws -> [FolderRoot] {
        var roots: [FolderRoot] = []
        for p in paths {
            if let read = covered(p, level: .read, chat: chat, callKey: callKey) {
                roots.append(read.root)
                continue
            }
            // Outside every grant: nothing is looked at while the model may not prompt.
            if let blocked = mayPrompt(p, level: .change, chat: chat) { throw PathError.blocked(blocked) }
            var folder = (p as NSString).deletingLastPathComponent
            while folder != "/", !folder.isEmpty, Posix.lstatPath(folder) == nil {
                folder = (folder as NSString).deletingLastPathComponent
            }
            do {
                roots.append(try makeRoot(folder))
            } catch {
                throw PathError.invalid(Self.notShareable(display(p)))
            }
        }
        var out: [FolderRoot] = []
        for r in roots.sorted(by: { $0.path.count < $1.path.count }) where !out.contains(where: { FolderGrants.isWithin(r.path, $0.path) }) {
            out.append(r)
        }
        return out
    }

    func proposalText(added: Int, rejected: [(index: Int, error: Error)], ops: [FolderTools.RawOp], plan: ChangePlan?) -> String {
        var out: String
        if added > 0, let plan {
            let c = PlanReview.counts(plan.items)
            out = "Added \(added) change\(added == 1 ? "" : "s") to the plan waiting for the user's approval (now: "
                + "\(PlanReview.englishSummary(c))). Nothing has changed yet: the user reviews the plan in the chat and "
                + "approves all, some or none of it. Tell them it's ready; don't call \(FolderTools.changeName) again for these."
        } else {
            out = "Nothing was added to the plan."
        }
        if !rejected.isEmpty {
            let shown = rejected.prefix(12).map { r -> String in
                let op = ops.indices.contains(r.index) ? ops[r.index] : nil
                let what = op.map { "\($0.kind.rawValue) \($0.path)" } ?? "op"
                return "- ops[\(r.index)] \(what): \(errorText(r.error))"
            }
            out += "\nNot added (fix and send only these again):\n" + shown.joined(separator: "\n")
            if rejected.count > shown.count { out += "\n…and \(rejected.count - shown.count) more." }
        }
        return out
    }

    // MARK: The plan

    /// The review's items that no longer match (id -> why), checked against
    /// the file system and the grants.
    public func invalidItems(_ plan: ChangePlan) -> [Int: String] {
        ChangePlanner(denylist: denylist, canChange: grants.changeCheck(chatID: plan.chatID)).invalidItems(plan)
            .mapValues { $0.replacingOccurrences(of: home + "/", with: "~/") }
    }

    /// What the review looks up on disk: folder sizes, how trashed copies
    /// compare (`PlanChecker`, read only, bounded), only while the chat may
    /// still read there.
    public func checks(_ plan: ChangePlan, isCancelled: () -> Bool = { false }) -> PlanChecks {
        let chat = plan.chatID
        return PlanChecker(denylist: denylist).check(plan, canRead: { [grants] loc, proposal in
            grants.coversRead(path: loc.displayPath, chatID: chat, callKey: proposal ?? "")
        }, isCancelled: isCancelled)
    }

    /// Why ticked copies can't be approved as they stand (id -> why): not
    /// compared yet, or found identical and changed since (either file). A
    /// copy the user ticked though it differs or couldn't be compared is
    /// their call.
    func copyProblems(_ review: PlanReview) -> [Int: String] {
        let checker = PlanChecker(denylist: denylist)
        var out: [Int: String] = [:]
        for item in review.plan.items where review.approvable.contains(item.id) && PlanChecker.isCopyCandidate(item) {
            let name = item.source?.location.relativePath ?? ""
            guard let c = review.checks.copies[item.id] else {
                out[item.id] = "\(name) wasn't compared with its original yet"
                continue
            }
            if c.verdict == .identical, !checker.stillIdentical(item, c, plan: review.plan) {
                out[item.id] = "\(name) or its original changed since they were compared"
            }
        }
        return out
    }

    private let copiesLock = NSLock()
    /// The comparisons approved plans were approved on, by plan id: held to
    /// at execution.
    private var approvedCopies: [UUID: [Int: CopyCheck]] = [:]

    /// The user's approval of the ticked items of the exact plan reviewed.
    public func approve(_ review: PlanReview) throws -> ApprovedPlan {
        let chat = review.plan.chatID
        let problems = copyProblems(review)
        if !problems.isEmpty { throw ChangePlanError.invalidated(problems) }
        let approved = try plans.approve(chatID: chat, planID: review.plan.id, revision: review.plan.revision,
                                         items: review.approvable,
                                         validator: ChangePlanner(denylist: denylist, canChange: grants.changeCheck(chatID: chat)))
        let identical = review.checks.copies.filter { $0.value.verdict == .identical && review.approvable.contains($0.key) }
        copiesLock.lock()
        approvedCopies[approved.plan.id] = identical
        copiesLock.unlock()
        return approved
    }

    /// Runs an approved plan, one item at a time.
    public func execute(_ approved: ApprovedPlan, isCancelled: () -> Bool = { false },
                        progress: (Int, Int) -> Void = { _, _ in }) -> ChangeExecutor.Report {
        copiesLock.lock()
        let copies = approvedCopies.removeValue(forKey: approved.plan.id) ?? [:]
        copiesLock.unlock()
        var executor = ChangeExecutor(denylist: denylist, journal: journal, trasher: trasher,
                                      canChange: grants.changeCheck(chatID: approved.plan.chatID))
        // A copy trashed as identical must still be: either file changed
        // since the comparison fails it (and stops the plan there).
        let checker = PlanChecker(denylist: denylist)
        let plan = approved.plan
        executor.verifyItem = { item in
            guard let c = copies[item.id] else { return }
            if !checker.stillIdentical(item, c, plan: plan) {
                throw FolderAccessError.changed("\(item.source?.location.relativePath ?? "") or its original, since they were compared")
            }
        }
        return executor.execute(approved, isCancelled: isCancelled, progress: progress)
    }

    /// Undo of a journaled plan, under the change grants of its chat.
    public func undo(_ planID: UUID) -> ChangeUndo.Report {
        let chat = journal.record(planID)?.chatID ?? ""
        return ChangeUndo(denylist: denylist, journal: journal, canChange: grants.changeCheck(chatID: chat)).undo(planID)
    }

    /// Interrupted plans put right where it can be (at launch: only standing
    /// grants exist then), and old clean journals pruned.
    public func recoverInterrupted() -> [ChangeUndo.Recovery] {
        let out = ChangeUndo(denylist: denylist, journal: journal, canChange: grants.changeCheck(chatID: "")).recoverInterrupted()
        journal.prune()
        return out
    }
}
