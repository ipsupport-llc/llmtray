import Darwin
import Foundation

// Shared vocabulary of the folder tools (adr/0014): identities, errors, the
// grant root, the denylist. Everything is decided by device + inode, never by
// a path's spelling (Hardening 1, 4).

/// A file system object's identity: `st_dev` + `st_ino`. Two spellings of one
/// folder (`/Users/x` and `/System/Volumes/Data/Users/x`) have one identity.
public struct FileIdentity: Codable, Hashable, Sendable, CustomStringConvertible {
    public var device: Int32
    public var inode: UInt64

    public init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    public var description: String { "\(device):\(inode)" }
}

/// What `lstat` says about an entry, kept small so the traversal rules can be
/// tested with made-up values (mount points can't be made in a test).
public struct EntryStat: Equatable, Sendable {
    public var identity: FileIdentity
    public var mode: mode_t
    public var linkCount: Int
    public var size: Int64
    public var created: Date
    public var modified: Date
    /// `st_flags` (`SF_DATALESS`...).
    public var flags: UInt32

    public init(identity: FileIdentity, mode: mode_t, linkCount: Int = 1, size: Int64 = 0,
                created: Date = Date(timeIntervalSince1970: 0), modified: Date = Date(timeIntervalSince1970: 0),
                flags: UInt32 = 0) {
        self.identity = identity
        self.mode = mode
        self.linkCount = linkCount
        self.size = size
        self.created = created
        self.modified = modified
        self.flags = flags
    }

    init(_ st: stat) {
        func date(_ t: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1_000_000_000)
        }
        let identity = FileIdentity(device: st.st_dev, inode: st.st_ino)
        self.init(identity: identity, mode: st.st_mode,
                  linkCount: Int(st.st_nlink), size: Int64(st.st_size),
                  created: date(st.st_birthtimespec), modified: date(st.st_mtimespec),
                  flags: st.st_flags | StatFlagInjection.shared.flags(for: identity))
    }

    public var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    public var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    public var isSymlink: Bool { mode & S_IFMT == S_IFLNK }
    /// A regular file with more than one name: it can be the same file as one
    /// outside the grant (Hardening 5), so its contents aren't read.
    public var isHardLinked: Bool { isRegularFile && linkCount > 1 }
    /// A file provider's placeholder (iCloud Drive "Optimize Mac Storage"):
    /// the bytes aren't on this Mac, and reading them would download them.
    public var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
}

/// File flags only the kernel can set (`SF_DATALESS`), for tests: added to
/// what `stat` reports for an identity. Empty outside tests.
final class StatFlagInjection: @unchecked Sendable {
    static let shared = StatFlagInjection()
    private let lock = NSLock()
    private var extra: [FileIdentity: UInt32] = [:]

    func flags(for identity: FileIdentity) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return extra.isEmpty ? 0 : extra[identity] ?? 0
    }

    func set(_ flags: UInt32, for identity: FileIdentity) {
        lock.lock()
        extra[identity] = flags
        lock.unlock()
    }

    func clear() {
        lock.lock()
        extra = [:]
        lock.unlock()
    }
}

/// Reads with the thread's policy for dataless files set to "don't
/// materialize" (a read fails instead of downloading from iCloud): a second
/// guard behind the `SF_DATALESS` check, restored afterwards.
enum Materialization {
    static func off<T>(_ body: () throws -> T) rethrows -> T {
        let type = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)
        let old = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        let set = setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if set == 0, old >= 0 { _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, old) } }
        return try body()
    }

    /// The calling thread's policy now (tests).
    static var current: Int32 { getiopolicy_np(Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES), IOPOL_SCOPE_THREAD) }
}

public enum EntryKind: String, Codable, Sendable {
    case file, directory
    /// A bundle directory (`.app`, `.bundle`, `.rtfd`...): one opaque item.
    case package
    /// A symbolic link: listed, never followed.
    case symlink
    /// A Finder alias (a regular file that points elsewhere): never followed.
    case alias
    /// A FIFO, socket or device: listed, never opened.
    case other
}

public enum FolderAccessError: Error, Equatable, CustomStringConvertible {
    case invalidPath(String)
    /// Missing -- or denied inside a grant, which is the same to the caller:
    /// a denied subtree is invisible.
    case notFound(String)
    case notGrantable(String)
    case symlink(String)
    case alias(String)
    case insidePackage(String)
    /// A different volume: it needs its own grant.
    case mountPoint(String)
    case notADirectory(String)
    case notARegularFile(String)
    /// An identity no longer matches what was recorded: fail closed.
    case changed(String)
    case exists(String)
    case notEmpty(String)
    case crossDevice(String)
    /// A folder (or package) with denied items inside (`.ssh`, a keychain):
    /// moving or trashing it would carry them along.
    case containsProtected(String)
    /// Too large (or partly unreadable) to be sure nothing denied is inside.
    case uncheckable(String)
    /// No change grant covers it (any more): revoked, expired, or never given.
    case notGranted(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case .invalidPath(let s): return "invalid path: \(s)"
        case .notFound(let s): return "not found: \(s)"
        case .notGrantable(let s): return "not grantable: \(s)"
        case .symlink(let s): return "a symbolic link (not followed): \(s)"
        case .alias(let s): return "an alias (not followed): \(s)"
        case .insidePackage(let s): return "inside a package (packages are one item): \(s)"
        case .mountPoint(let s): return "another volume (needs its own grant): \(s)"
        case .notADirectory(let s): return "not a folder: \(s)"
        case .notARegularFile(let s): return "not a regular file: \(s)"
        case .changed(let s): return "changed since it was checked: \(s)"
        case .exists(let s): return "already exists: \(s)"
        case .notEmpty(let s): return "not empty: \(s)"
        case .crossDevice(let s): return "on another volume: \(s)"
        case .containsProtected(let s):
            return "contains protected items (like .ssh or keychains) that folder tools never touch, "
                + "so it isn't moved or trashed as a whole: \(s)"
        case .uncheckable(let s): return "too large to check for protected items inside, so it isn't moved or trashed: \(s)"
        case .notGranted(let s): return "no change access (the grant was revoked or has expired): \(s)"
        case .system(let op, let e): return "\(op): \(String(cString: strerror(e)))"
        }
    }
}

/// A granted folder: its canonical path at grant time (for display and to
/// reopen it) and its identity (what it must still be when reopened).
public struct FolderRoot: Codable, Hashable, Sendable {
    public var path: String
    public var identity: FileIdentity

    public init(path: String, identity: FileIdentity) {
        self.path = path
        self.identity = identity
    }
}

/// Where the folder tools never look (Hardening 4): by identity and ancestry,
/// with names and extensions as a second net (a `.ssh` inside any grant is as
/// private as the home folder's).
public struct FolderDenylist: Sendable {
    /// Denied subtrees: no grant at or under them, invisible inside grants.
    public private(set) var identities: Set<FileIdentity>
    /// Canonical spellings of the same, for grant-time prefix checks.
    public private(set) var paths: [String]
    /// Entry names hidden everywhere (compared case- and
    /// normalization-insensitively: over-denying is the safe side).
    public private(set) var names: Set<String>
    public private(set) var extensions: Set<String>
    /// Allowed inside a grant but never a grant themselves: `/`, the home
    /// folder and its ancestors (a grant of `/Users` covers the home folder).
    public private(set) var ungrantable: Set<FileIdentity>

    public init(paths: [String], names: Set<String> = [], extensions: Set<String> = [], ungrantablePaths: [String] = []) {
        var ids = Set<FileIdentity>()
        var canonical: [String] = []
        for p in paths {
            // Both the entry itself and, for a link (`/tmp`), what it points to.
            if let st = Posix.lstatPath(p) { ids.insert(st.identity) }
            if let st = Posix.statPath(p) { ids.insert(st.identity) }
            canonical.append(p)
            if let real = Posix.realpath(p), real != p { canonical.append(real) }
        }
        identities = ids
        self.paths = canonical
        self.names = Set(names.map(Self.fold))
        self.extensions = Set(extensions.map(Self.fold))
        ungrantable = Set(ungrantablePaths.compactMap { Posix.statPath($0)?.identity })
    }

    static func fold(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    public func isDenied(identity: FileIdentity) -> Bool { identities.contains(identity) }

    public func isDenied(name: String) -> Bool {
        let f = Self.fold(name)
        if names.contains(f) { return true }
        let ext = (f as NSString).pathExtension
        return !ext.isEmpty && extensions.contains(ext)
    }

    public func isDenied(identity: FileIdentity, name: String) -> Bool {
        isDenied(identity: identity) || isDenied(name: name)
    }

    /// A canonical path at or under a denied path (string check; the identity
    /// check during the walk is the one that counts).
    public func deniesPath(_ path: String) -> Bool {
        paths.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// The system's and the user's private places.
    public static func standard(home: String = NSHomeDirectory(), appData: String? = nil) -> FolderDenylist {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        let appSupport = h + "/Library/Application Support"
        var paths = [
            "/System", "/System/Volumes/Data", "/Library", "/usr", "/bin", "/sbin", "/private",
            "/etc", "/var", "/tmp", "/dev", "/cores", "/Applications",
            h + "/Library", h + "/.ssh", h + "/.gnupg", h + "/.Trash",
            // Credentials and tool configuration in the home folder.
            h + "/.aws", h + "/.config", h + "/.kube", h + "/.docker", h + "/.netrc", h + "/.git-credentials",
            h + "/.password-store", h + "/.npmrc", h + "/.pypirc", h + "/.gem/credentials",
            h + "/.cargo/credentials", h + "/.cargo/credentials.toml", h + "/.terraform.d",
            h + "/Library/Keychains", h + "/Library/Containers", h + "/Library/Group Containers",
            h + "/Library/Safari", appSupport + "/Google/Chrome", appSupport + "/Firefox",
            appSupport + "/BraveSoftware", appSupport + "/Microsoft Edge", appSupport + "/Arc",
            appSupport + "/LLMTray"
        ]
        if let appData { paths.append(appData) }
        // Home's ancestors and the home folder itself: whole-home grants.
        var ungrantable = ["/", "/Volumes", h]
        var up = (h as NSString).deletingLastPathComponent
        while up != "/" && !up.isEmpty {
            ungrantable.append(up)
            up = (up as NSString).deletingLastPathComponent
        }
        return FolderDenylist(paths: paths, names: [".ssh", ".gnupg", "Keychains", ".Trash", ".Trashes"],
                              extensions: ["keychain", "keychain-db"], ungrantablePaths: ungrantable)
    }

    // MARK: Secret-looking files

    /// Names whose contents are never read inside any grant (keys,
    /// credentials, environment files): listed, movable, never opened for a
    /// head, a hash or a duplicate check. Compared folded, like denied names.
    static let secretNames: Set<String> = [".env", ".envrc", ".npmrc", ".netrc", ".git-credentials", ".pypirc"]
    static let secretExtensions: Set<String> = ["pem", "key", "p12", "pfx"]
    static let secretPrefixes = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env."]

    /// Whether a file looks like a secret by its name (and, for `config`,
    /// its folder's: `.git/config` can hold credentials in remote URLs).
    public static func looksSecret(name: String, parentName: String?) -> Bool {
        let f = fold(name)
        if secretNames.contains(f) { return true }
        if secretPrefixes.contains(where: { f.hasPrefix($0) }) { return true }
        let ext = (f as NSString).pathExtension
        if !ext.isEmpty, secretExtensions.contains(ext) { return true }
        if f == "config", let parentName, fold(parentName) == ".git" { return true }
        return false
    }
}

/// Thin wrappers over the system calls, errno kept.
enum Posix {
    static func lstatPath(_ path: String) -> EntryStat? {
        var st = Darwin.stat()
        return Darwin.lstat(path, &st) == 0 ? EntryStat(st) : nil
    }

    static func statPath(_ path: String) -> EntryStat? {
        var st = Darwin.stat()
        return stat(path, &st) == 0 ? EntryStat(st) : nil
    }

    static func realpath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    static func fstat(_ fd: Int32) throws -> EntryStat {
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0 else { throw FolderAccessError.system("fstat", errno) }
        return EntryStat(st)
    }

    /// nil when the name doesn't exist.
    static func lstatAt(_ fd: Int32, _ name: String) throws -> EntryStat? {
        var st = Darwin.stat()
        if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { return EntryStat(st) }
        if errno == ENOENT { return nil }
        throw FolderAccessError.system("fstatat \(name)", errno)
    }

    static func path(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// An open descriptor, closed when released. Keep the owner in a named
/// local while its `fd` is used: a temporary (`try open(...).fd`) is released
/// -- and the descriptor closed -- before the call that takes the number.
public final class Descriptor {
    public let fd: Int32
    public let stat: EntryStat

    init(fd: Int32, stat: EntryStat) {
        self.fd = fd
        self.stat = stat
    }

    deinit { Darwin.close(fd) }

    public var identity: FileIdentity { stat.identity }
    /// Where the object is now (`F_GETPATH`): for Foundation calls only, after
    /// which the identity is checked again.
    public var currentPath: String? { Posix.path(of: fd) }
}
