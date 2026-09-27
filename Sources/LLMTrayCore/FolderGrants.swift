import Foundation

/// What a grant allows (adr/0014): read (listing, info) or change -- which
/// means "may propose changes here", each still approved (Hardening 3). A
/// read grant never implies change.
public enum FolderAccessLevel: Int, Codable, Comparable, Sendable {
    case read = 1
    case change = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// How long a grant lasts, the user's pick when asked.
public enum GrantLifetime: Codable, Equatable, Sendable {
    /// One exact call (identified by `callKey`) in one chat, consumed by it.
    case once(callKey: String, chatID: String)
    /// Until a date ("for an hour").
    case until(Date)
    /// For one chat.
    case chat(String)
    /// Always for this folder.
    case always

    /// Standing grants survive a restart; once and per-chat ones don't.
    public var isStanding: Bool {
        switch self {
        case .until, .always: return true
        case .once, .chat: return false
        }
    }

    /// The later of two standing lifetimes: always wins, else the later date.
    static func later(_ a: Self, _ b: Self) -> Self {
        switch (a, b) {
        case (.until(let x), .until(let y)): return .until(max(x, y))
        case (.until, _): return b
        default: return a
        }
    }

    func hasEnded(now: Date) -> Bool {
        if case .until(let d) = self { return now >= d }
        return false
    }
}

/// Where a standing grant was given, shown under it in Settings.
public enum GrantOrigin: String, Codable, Sendable {
    /// From a chat: its prompt or its folder menu.
    case chat
    /// In Settings.
    case settings
}

/// A grant: `level` for `lifetime`. A standing change grant can also let
/// the chat look for longer than it may propose changes (`readLifetime`):
/// when the change part ends, it is a read grant for that lifetime.
///
/// Stored so an older build reading the file never gets more than this one
/// grants: `level` and `lifetime` are the strongest access with its own
/// lifetime (what an older build reads and honours); `readLifetime` is a new,
/// optional key an older build ignores -- to it, the longer look just ends
/// with the change, never the other way round.
public struct FolderGrant: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var root: FolderRoot
    public var level: FolderAccessLevel
    public var lifetime: GrantLifetime
    /// A change grant's look lifetime when it outlasts `lifetime`; nil
    /// otherwise (always nil for a read grant).
    public var readLifetime: GrantLifetime?
    public var created: Date
    /// nil for grants stored before it was kept.
    public var origin: GrantOrigin?

    public init(id: UUID = UUID(), root: FolderRoot, level: FolderAccessLevel, lifetime: GrantLifetime,
                readLifetime: GrantLifetime? = nil, created: Date, origin: GrantOrigin? = nil) {
        self.id = id
        self.root = root
        self.level = level
        self.lifetime = lifetime
        self.readLifetime = readLifetime
        self.created = created
        self.origin = origin
        normalize()
    }

    /// How long the chat may look (a change grant looks too).
    public var lookLifetime: GrantLifetime { readLifetime ?? lifetime }
    /// How long it may propose changes; nil for a read grant.
    public var changeLifetime: GrantLifetime? { level == .change ? lifetime : nil }

    /// `readLifetime` only where it outlasts a standing change grant.
    mutating func normalize() {
        guard let r = readLifetime else { return }
        if level != .change || !lifetime.isStanding || !r.isStanding || GrantLifetime.later(lifetime, r) == lifetime {
            readLifetime = nil
        }
    }

    /// Another standing grant of the same folder folded into this one. Look:
    /// the later of both (any grant looks; always wins). Change: the later
    /// of the change grants' only -- a merge never widens change. The folder
    /// as last checked; the first origin known.
    func merged(with other: FolderGrant) -> FolderGrant {
        var g = self
        g.root = other.root
        g.origin = origin ?? other.origin
        let look = GrantLifetime.later(lookLifetime, other.lookLifetime)
        let change: GrantLifetime?
        switch (changeLifetime, other.changeLifetime) {
        case (let a?, let b?): change = GrantLifetime.later(a, b)
        case (let a?, nil), (nil, let a?): change = a
        case (nil, nil): change = nil
        }
        if let change {
            g.level = .change
            g.lifetime = change
            g.readLifetime = look
        } else {
            g.level = .read
            g.lifetime = look
            g.readLifetime = nil
        }
        g.normalize()
        return g
    }

    /// The grant as it stands at `now`: a change grant whose change part
    /// ended is a read grant for its look lifetime; nil once all of it ended.
    public func current(now: Date) -> FolderGrant? {
        guard lifetime.hasEnded(now: now) else { return self }
        guard level == .change, let r = readLifetime, !r.hasEnded(now: now) else { return nil }
        var g = self
        g.level = .read
        g.lifetime = r
        g.readLifetime = nil
        return g
    }

    /// All of it ended.
    public func isExpired(now: Date) -> Bool { current(now: now) == nil }

    /// Whether a canonical absolute path is this grant's folder or inside it
    /// (by spelling: the walk from the root by descriptors is what makes the
    /// spelling trustworthy).
    public func covers(_ path: String) -> Bool { FolderGrants.isWithin(path, root.path) }
}

/// A refusal the user gave in one chat (Hardening 9). It holds for the chat
/// against the same folder by identity, anything inside or around it, and
/// any level at or above the one refused.
public struct FolderDeny: Equatable, Sendable {
    public var chatID: String
    public var root: FolderRoot
    public var level: FolderAccessLevel
    public var date: Date

    func matches(path: String, identity: FileIdentity?, level: FolderAccessLevel) -> Bool {
        guard level >= self.level else { return false }
        if let identity, identity == root.identity { return true }
        return FolderGrants.isWithin(path, root.path) || FolderGrants.isWithin(root.path, path)
    }
}

/// Where a request for access comes from: the model asking, or the user
/// asking for it themselves.
public enum AccessRequestOrigin: Sendable {
    case model, user
}

public enum PromptDecision: Equatable, Sendable {
    case prompt
    /// Don't show the user a prompt; the model gets this.
    case refuse(String)
}

/// The grants and denies, decided in code (adr/0014, Hardening 8, 9). Standing
/// grants (until a date, always) persist to `storeURL`; per-chat and once
/// grants and denies live in memory. Thread-safe: `once` is consumed under
/// the lock by exactly one call.
public final class FolderGrants: @unchecked Sendable {
    public enum GrantError: Error, Equatable {
        /// Temporary chats get read access for the chat only.
        case temporaryChat
        /// The grant edited is gone (revoked, ended).
        case gone
        /// The folder at the grant's path isn't the one granted any more.
        case folderChanged
        /// Settings edits standing grants: an hour or always.
        case notStanding
    }

    private let lock = NSLock()
    private var grants: [FolderGrant] = []
    private var denies: [FolderDeny] = []
    /// Chats where a deny stopped the model from prompting again, until the
    /// user asks for access themselves.
    private var promptsBlocked: Set<String> = []
    /// `once` grants used up by their call, kept for their chat: the change
    /// that call proposed -- only that one, by its call key -- is still
    /// checked against them at approval, execution and undo (they authorize
    /// no new call and no later proposal).
    private var consumedOnce: [FolderGrant] = []
    private let storeURL: URL?

    /// Loads the standing grants in `storeURL` (expired ones dropped; two of
    /// one folder, from before they were merged, become one).
    public init(storeURL: URL?, now: Date = Date()) {
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode([FolderGrant].self, from: data) {
            let live = stored.compactMap { g -> FolderGrant? in
                var g = g
                g.normalize()
                return g.lifetime.isStanding ? g.current(now: now) : nil
            }
            for g in live {
                if let i = grants.firstIndex(where: { $0.root.path == g.root.path }) {
                    grants[i] = grants[i].merged(with: g)
                } else {
                    grants.append(g)
                }
            }
            if grants != stored { try? saveLocked() }
        }
    }

    public static func isWithin(_ path: String, _ folder: String) -> Bool {
        if path == folder { return true }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix)
    }

    // MARK: Granting

    /// Adds a grant the user gave. A standing grant of a folder that has one
    /// (the same path: a parent's and a child's stay apart) is merged into it
    /// -- one per folder, never widening change (`FolderGrant.merged`). A grant for a folder removes this chat's denies it
    /// answers (the user changed their mind). Temporary chats: read only, and
    /// no grant outlives the chat.
    @discardableResult
    public func grant(_ root: FolderRoot, level: FolderAccessLevel, lifetime: GrantLifetime,
                      chatID: String?, temporaryChat: Bool = false, origin: GrantOrigin? = nil,
                      now: Date = Date()) throws -> FolderGrant {
        if temporaryChat {
            guard level == .read else { throw GrantError.temporaryChat }
            switch lifetime {
            case .once(_, let id) where id == chatID: break
            case .chat(let id) where id == chatID: break
            default: throw GrantError.temporaryChat
            }
        }
        var g = FolderGrant(root: root, level: level, lifetime: lifetime, created: now, origin: origin)
        lock.lock()
        defer { lock.unlock() }
        if lifetime.isStanding {
            let before = grants
            grants = grants.compactMap { $0.current(now: now) }
            if let i = grants.firstIndex(where: { $0.lifetime.isStanding && $0.root.path == root.path }) {
                g = grants[i].merged(with: g)
                grants[i] = g
            } else {
                grants.append(g)
            }
            // A standing grant exists only once it is on disk.
            do {
                try saveLocked()
            } catch {
                grants = before
                throw error
            }
        } else {
            grants.append(g)
        }
        if let chatID {
            denies.removeAll { $0.chatID == chatID && $0.level <= level
                && ($0.root.identity == root.identity || Self.isWithin($0.root.path, root.path)) }
        }
        return g
    }

    /// Removes a grant -- a `once` grant already used by its call too, so
    /// the change it proposed is no longer covered; a standing one is removed
    /// on disk first (a revoke that didn't stick throws and changes nothing).
    public func revoke(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        consumedOnce.removeAll { $0.id == id }
        guard let i = grants.firstIndex(where: { $0.id == id }) else { return }
        let removed = grants.remove(at: i)
        if removed.lifetime.isStanding {
            do {
                try saveLocked()
            } catch {
                grants.insert(removed, at: i)
                throw error
            }
        }
    }

    /// Sets a standing grant's level, lifetime and longer look lifetime as
    /// the user edited them in Settings (lower too, unlike a merge); `root` is
    /// the folder just checked again, which must still be the one granted
    /// (path and identity). On disk first.
    @discardableResult
    public func update(_ id: UUID, root: FolderRoot, level: FolderAccessLevel, lifetime: GrantLifetime,
                       readLifetime: GrantLifetime? = nil, now: Date = Date()) throws -> FolderGrant {
        guard lifetime.isStanding, readLifetime?.isStanding ?? true else { throw GrantError.notStanding }
        lock.lock()
        defer { lock.unlock() }
        let before = grants
        grants = grants.compactMap { $0.current(now: now) }
        guard let i = grants.firstIndex(where: { $0.id == id && $0.lifetime.isStanding }) else {
            grants = before
            throw GrantError.gone
        }
        guard grants[i].root == root else {
            grants = before
            throw GrantError.folderChanged
        }
        grants[i].level = level
        grants[i].lifetime = lifetime
        grants[i].readLifetime = readLifetime
        grants[i].normalize()
        do {
            try saveLocked()
        } catch {
            grants = before
            throw error
        }
        return grants[i]
    }

    /// A chat ended (closed, deleted): its grants and denies go.
    public func endChat(_ chatID: String) {
        lock.lock()
        grants.removeAll {
            switch $0.lifetime {
            case .chat(let id), .once(_, let id): return id == chatID
            case .until, .always: return false
            }
        }
        consumedOnce.removeAll { if case .once(_, let id) = $0.lifetime { return id == chatID }; return false }
        denies.removeAll { $0.chatID == chatID }
        promptsBlocked.remove(chatID)
        lock.unlock()
    }

    /// The standing grants, for Settings (expired ones left out).
    public func standingGrants(now: Date = Date()) -> [FolderGrant] {
        lock.lock()
        defer { lock.unlock() }
        return grants.compactMap { $0.lifetime.isStanding ? $0.current(now: now) : nil }
    }

    /// As they stand at `now` (`FolderGrant.current`).
    public func allGrants(now: Date = Date()) -> [FolderGrant] {
        lock.lock()
        defer { lock.unlock() }
        return grants.compactMap { $0.current(now: now) }
    }

    // MARK: Checking

    /// The grant that lets `callKey` (one exact tool call) reach `path` (a
    /// canonical absolute path) at `level` in `chatID`, or nil. Standing and
    /// chat grants are preferred; a matching `once` grant is consumed by this
    /// call, atomically -- a second call with the same key finds nothing.
    /// A temporary chat is never authorized to change anything, whatever
    /// grants exist, and reads only through grants made in that chat -- no
    /// standing grant reaches it (Hardening 8: no grants beyond the chat).
    public func authorize(path: String, level: FolderAccessLevel, chatID: String, callKey: String,
                          temporaryChat: Bool = false, now: Date = Date()) -> FolderGrant? {
        if temporaryChat, level > .read { return nil }
        lock.lock()
        defer { lock.unlock() }
        dropExpiredLocked(now: now)
        let usable = grants.filter { g in
            guard g.level >= level, g.covers(path) else { return false }
            switch g.lifetime {
            case .always, .until: return !temporaryChat
            case .chat(let id): return id == chatID
            case .once(let key, let id): return key == callKey && id == chatID
            }
        }
        if let lasting = usable.first(where: { if case .once = $0.lifetime { return false }; return true }) {
            return lasting
        }
        guard let once = usable.first else { return nil }
        grants.removeAll { $0.id == once.id }
        consumedOnce.append(once)
        return once
    }

    /// Whether a change grant still covers `path` for `chatID`, without
    /// using anything up: asked again at approval, at execution (both ends
    /// of a move) and before undo, so a grant revoked or expired since the
    /// proposal stops the change (defense in depth: the proposal itself was
    /// authorized with `authorize`). A `once` grant covers only the proposal
    /// it authorized -- the change call `proposal` names, by its call key --
    /// never a later one in the chat, which needs its own grant; nil matches
    /// no `once` grant. Never for a temporary chat.
    public func coversChange(path: String, chatID: String, proposal: String?, temporaryChat: Bool = false,
                             now: Date = Date()) -> Bool {
        if temporaryChat { return false }
        lock.lock()
        defer { lock.unlock() }
        dropExpiredLocked(now: now)
        return (grants + consumedOnce).contains { g in
            guard g.level >= .change, g.covers(path) else { return false }
            switch g.lifetime {
            case .always, .until: return true
            case .chat(let id): return id == chatID
            case .once(let key, let id): return id == chatID && proposal != nil && key == proposal
            }
        }
    }

    /// Whether a read (or wider) grant still covers `path` for the call
    /// `callKey` in `chatID`, without using anything up: asked while a
    /// `files` call reads and before it answers, so a grant revoked or
    /// expired meanwhile stops it. The call's own `once` grant counts (used
    /// up by it, not yet revoked).
    public func coversRead(path: String, chatID: String, callKey: String, temporaryChat: Bool = false,
                           now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        dropExpiredLocked(now: now)
        return (grants + consumedOnce).contains { g in
            guard g.covers(path) else { return false }
            switch g.lifetime {
            case .always, .until: return !temporaryChat
            case .chat(let id): return id == chatID
            case .once(let key, let id): return id == chatID && key == callKey
            }
        }
    }

    /// `coversChange` for one chat, as the planner, executor and undo take it
    /// (each passing the call key of the proposal the item came from).
    public func changeCheck(chatID: String, temporaryChat: Bool = false) -> ChangeGrantCheck {
        { [self] location, proposal in
            coversChange(path: location.displayPath, chatID: chatID, proposal: proposal, temporaryChat: temporaryChat)
        }
    }

    /// Ended grants go, a change grant whose change part ended becomes the
    /// read grant it leaves: the checks after this read `level` and
    /// `lifetime` as they stand.
    private func dropExpiredLocked(now: Date) {
        let updated = grants.compactMap { $0.current(now: now) }
        guard updated != grants else { return }
        grants = updated
        // Ended grants are dropped on load too: a failed save here is harmless.
        try? saveLocked()
    }

    // MARK: Denies and prompts

    /// The user refused access to `root` at `level` in `chatID`: it holds for
    /// the chat, and the model can't prompt again until the user asks.
    public func deny(_ root: FolderRoot, level: FolderAccessLevel, chatID: String, now: Date = Date()) {
        lock.lock()
        denies.append(FolderDeny(chatID: chatID, root: root, level: level, date: now))
        promptsBlocked.insert(chatID)
        lock.unlock()
    }

    /// The user asked for folder access themselves (a button, or their own
    /// words recognized by the app -- never the model's): the model may ask
    /// again. The denies themselves still hold until a grant answers them.
    public func userAskedForAccess(chatID: String) {
        lock.lock()
        promptsBlocked.remove(chatID)
        lock.unlock()
    }

    /// Whether to show the user a grant prompt for `path` (canonical,
    /// `identity` if it exists) at `level`. The user's own requests always
    /// prompt; the model's are refused after a deny in this chat until the
    /// user asks, and always for a target a deny covers.
    public func shouldPrompt(path: String, identity: FileIdentity?, level: FolderAccessLevel, chatID: String,
                             origin: AccessRequestOrigin) -> PromptDecision {
        if origin == .user { return .prompt }
        lock.lock()
        defer { lock.unlock() }
        if denies.contains(where: { $0.chatID == chatID && $0.matches(path: path, identity: identity, level: level) }) {
            return .refuse("The user declined access to this folder in this chat. Don't ask again; "
                + "they can grant it themselves.")
        }
        if promptsBlocked.contains(chatID) {
            return .refuse("The user declined folder access in this chat. Don't ask for access again "
                + "unless the user asks for it.")
        }
        return .prompt
    }

    public func denies(chatID: String) -> [FolderDeny] {
        lock.lock()
        defer { lock.unlock() }
        return denies.filter { $0.chatID == chatID }
    }

    // MARK: Store

    /// Writes the standing grants; called with the lock held, so saves land
    /// in the order the changes were made.
    private func saveLocked() throws {
        guard let storeURL else { return }
        let standing = grants.filter { $0.lifetime.isStanding }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(standing)
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storeURL, options: .atomic)
    }
}
