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
}

public struct FolderGrant: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var root: FolderRoot
    public var level: FolderAccessLevel
    public var lifetime: GrantLifetime
    public var created: Date

    public init(id: UUID = UUID(), root: FolderRoot, level: FolderAccessLevel, lifetime: GrantLifetime, created: Date) {
        self.id = id
        self.root = root
        self.level = level
        self.lifetime = lifetime
        self.created = created
    }

    public func isExpired(now: Date) -> Bool {
        if case .until(let d) = lifetime { return now >= d }
        return false
    }

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
    }

    private let lock = NSLock()
    private var grants: [FolderGrant] = []
    private var denies: [FolderDeny] = []
    /// Chats where a deny stopped the model from prompting again, until the
    /// user asks for access themselves.
    private var promptsBlocked: Set<String> = []
    private let storeURL: URL?

    /// Loads the standing grants in `storeURL` (expired ones dropped).
    public init(storeURL: URL?, now: Date = Date()) {
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode([FolderGrant].self, from: data) {
            grants = stored.filter { $0.lifetime.isStanding && !$0.isExpired(now: now) }
        }
    }

    public static func isWithin(_ path: String, _ folder: String) -> Bool {
        if path == folder { return true }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix)
    }

    // MARK: Granting

    /// Adds a grant the user gave. A grant for a folder removes this chat's
    /// denies it answers (the user changed their mind). Temporary chats: read
    /// only, and no grant outlives the chat.
    @discardableResult
    public func grant(_ root: FolderRoot, level: FolderAccessLevel, lifetime: GrantLifetime,
                      chatID: String?, temporaryChat: Bool = false, now: Date = Date()) throws -> FolderGrant {
        if temporaryChat {
            guard level == .read else { throw GrantError.temporaryChat }
            switch lifetime {
            case .once(_, let id) where id == chatID: break
            case .chat(let id) where id == chatID: break
            default: throw GrantError.temporaryChat
            }
        }
        let g = FolderGrant(root: root, level: level, lifetime: lifetime, created: now)
        lock.lock()
        defer { lock.unlock() }
        grants.append(g)
        // A standing grant exists only once it is on disk.
        if lifetime.isStanding {
            do {
                try saveLocked()
            } catch {
                grants.removeAll { $0.id == g.id }
                throw error
            }
        }
        if let chatID {
            denies.removeAll { $0.chatID == chatID && $0.level <= level
                && ($0.root.identity == root.identity || Self.isWithin($0.root.path, root.path)) }
        }
        return g
    }

    /// Removes a grant; a standing one is removed on disk first (a revoke
    /// that didn't stick throws and changes nothing).
    public func revoke(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
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

    /// A chat ended (closed, deleted): its grants and denies go.
    public func endChat(_ chatID: String) {
        lock.lock()
        grants.removeAll {
            switch $0.lifetime {
            case .chat(let id), .once(_, let id): return id == chatID
            case .until, .always: return false
            }
        }
        denies.removeAll { $0.chatID == chatID }
        promptsBlocked.remove(chatID)
        lock.unlock()
    }

    /// The standing grants, for Settings (expired ones left out).
    public func standingGrants(now: Date = Date()) -> [FolderGrant] {
        lock.lock()
        defer { lock.unlock() }
        return grants.filter { $0.lifetime.isStanding && !$0.isExpired(now: now) }
    }

    public func allGrants(now: Date = Date()) -> [FolderGrant] {
        lock.lock()
        defer { lock.unlock() }
        return grants.filter { !$0.isExpired(now: now) }
    }

    // MARK: Checking

    /// The grant that lets `callKey` (one exact tool call) reach `path` (a
    /// canonical absolute path) at `level` in `chatID`, or nil. Standing and
    /// chat grants are preferred; a matching `once` grant is consumed by this
    /// call, atomically -- a second call with the same key finds nothing.
    /// A temporary chat is never authorized to change anything, whatever
    /// grants exist (Hardening 8).
    public func authorize(path: String, level: FolderAccessLevel, chatID: String, callKey: String,
                          temporaryChat: Bool = false, now: Date = Date()) -> FolderGrant? {
        if temporaryChat, level > .read { return nil }
        lock.lock()
        defer { lock.unlock() }
        let expired = grants.contains { $0.isExpired(now: now) }
        grants.removeAll { $0.isExpired(now: now) }
        // Expired grants are dropped on load too: a failed save here is harmless.
        if expired { try? saveLocked() }
        let usable = grants.filter { g in
            guard g.level >= level, g.covers(path) else { return false }
            switch g.lifetime {
            case .always, .until: return true
            case .chat(let id): return id == chatID
            case .once(let key, let id): return key == callKey && id == chatID
            }
        }
        if let lasting = usable.first(where: { if case .once = $0.lifetime { return false }; return true }) {
            return lasting
        }
        guard let once = usable.first else { return nil }
        grants.removeAll { $0.id == once.id }
        return once
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
