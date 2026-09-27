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

    public init(identity: FileIdentity, mode: mode_t, linkCount: Int = 1, size: Int64 = 0,
                created: Date = Date(timeIntervalSince1970: 0), modified: Date = Date(timeIntervalSince1970: 0)) {
        self.identity = identity
        self.mode = mode
        self.linkCount = linkCount
        self.size = size
        self.created = created
        self.modified = modified
    }

    init(_ st: stat) {
        func date(_ t: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1_000_000_000)
        }
        self.init(identity: FileIdentity(device: st.st_dev, inode: st.st_ino), mode: st.st_mode,
                  linkCount: Int(st.st_nlink), size: Int64(st.st_size),
                  created: date(st.st_birthtimespec), modified: date(st.st_mtimespec))
    }

    public var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    public var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    public var isSymlink: Bool { mode & S_IFMT == S_IFLNK }
    /// A regular file with more than one name: it can be the same file as one
    /// outside the grant (Hardening 5), so its contents aren't read.
    public var isHardLinked: Bool { isRegularFile && linkCount > 1 }
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
            "/etc", "/var", "/tmp", "/dev", "/cores",
            h + "/Library", h + "/.ssh", h + "/.gnupg", h + "/.Trash",
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
