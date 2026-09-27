import Darwin
import Foundation
import UniformTypeIdentifiers

/// One entry of a granted folder, as `lstat` and the resource values see it.
public struct FolderEntry: Equatable, Sendable {
    public var name: String
    public var stat: EntryStat
    public var kind: EntryKind

    public var identity: FileIdentity { stat.identity }
}

/// An existing directory reached from the grant root, with the identities of
/// every directory on the way (root first, this one last).
public struct OpenedDirectory {
    public let descriptor: Descriptor
    public let chain: [FileIdentity]
    public let components: [String]
}

/// A path inside a grant, resolved: its parent open, its entry (nil when the
/// name doesn't exist yet).
public struct ResolvedItem {
    public let parent: OpenedDirectory
    public let name: String
    public let entry: FolderEntry?

    public var components: [String] { parent.components + [name] }
}

/// Paths inside a grant, resolved by descriptors (adr/0014, Hardening 1): from
/// an open descriptor of the grant root, one component at a time, with
/// `openat(O_NOFOLLOW | O_DIRECTORY)`. No symlink, alias or package is ever
/// entered, a volume change stops the walk, denied subtrees are invisible, and
/// every step can be held to identities recorded earlier.
public struct SafeFolderWalker {
    public let root: FolderRoot
    public let denylist: FolderDenylist

    public init(root: FolderRoot, denylist: FolderDenylist) {
        self.root = root
        self.denylist = denylist
    }

    // MARK: Paths

    /// A grant-relative path's components. "" and "." are the root; absolute
    /// paths, empty components, ".", "..", NUL and names over 255 bytes are
    /// refused, never normalized.
    public static func components(_ path: String) throws -> [String] {
        if path.utf8.contains(0) { throw FolderAccessError.invalidPath("contains NUL") }
        if path.isEmpty || path == "." { return [] }
        if path.hasPrefix("/") { throw FolderAccessError.invalidPath("absolute: \(path)") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for p in parts { try validateName(p) }
        return parts
    }

    public static func validateName(_ name: String) throws {
        if name.isEmpty { throw FolderAccessError.invalidPath("empty component") }
        if name == "." || name == ".." { throw FolderAccessError.invalidPath("'\(name)' component") }
        if name.utf8.contains(0) { throw FolderAccessError.invalidPath("contains NUL") }
        if name.contains("/") { throw FolderAccessError.invalidPath("'/' in a name") }
        if name.utf8.count > 255 { throw FolderAccessError.invalidPath("name too long") }
    }

    // MARK: Grant roots

    /// A folder the user picked, checked for being grantable: canonicalized,
    /// walked from `/` by descriptors (no symlinks, nothing denied on the way),
    /// not `/`, the home folder or its ancestors, not a package.
    public static func makeRoot(path: String, denylist: FolderDenylist) throws -> FolderRoot {
        guard path.hasPrefix("/"), let canonical = Posix.realpath(path) else {
            throw FolderAccessError.notFound(path)
        }
        if denylist.deniesPath(canonical) { throw FolderAccessError.notGrantable(canonical) }
        let d = try openAbsolute(canonical, denylist: denylist, rejectPackages: true, denied: { .notGrantable($0) })
        if denylist.ungrantable.contains(d.identity) { throw FolderAccessError.notGrantable(canonical) }
        if isPackage(path: canonical) { throw FolderAccessError.notGrantable("\(canonical) is a package") }
        return FolderRoot(path: canonical, identity: d.identity)
    }

    /// Walks an absolute canonical path from `/`. Volume changes are allowed
    /// here (a grant may live on another disk); symlinks and denied
    /// directories are not.
    static func openAbsolute(_ path: String, denylist: FolderDenylist, rejectPackages: Bool = false,
                             denied: (String) -> FolderAccessError) throws -> Descriptor {
        let fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FolderAccessError.system("open /", errno) }
        var current = Descriptor(fd: fd, stat: try Posix.fstat(fd))
        if denylist.isDenied(identity: current.identity) { throw denied("/") }
        var walked = ""
        for name in path.split(separator: "/").map(String.init) {
            try validateName(name)
            walked += "/" + name
            guard let st = try Posix.lstatAt(current.fd, name) else { throw FolderAccessError.notFound(walked) }
            if st.isSymlink { throw FolderAccessError.symlink(walked) }
            if !st.isDirectory { throw FolderAccessError.notADirectory(walked) }
            if denylist.isDenied(identity: st.identity, name: name) { throw denied(walked) }
            // A grant never starts inside a package (packages are one item).
            if rejectPackages, isPackage(path: walked) { throw denied("\(walked) is a package") }
            current = try openChild(current, name, expecting: st, display: walked)
        }
        return current
    }

    /// `openat(O_NOFOLLOW | O_DIRECTORY)`, then the opened directory must be
    /// the one `lstat` saw.
    static func openChild(_ parent: Descriptor, _ name: String, expecting st: EntryStat, display: String) throws -> Descriptor {
        let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let e = errno
            if e == ELOOP { throw FolderAccessError.symlink(display) }
            if e == ENOTDIR { throw FolderAccessError.notADirectory(display) }
            if e == ENOENT { throw FolderAccessError.notFound(display) }
            throw FolderAccessError.system("open \(display)", e)
        }
        let opened: Descriptor
        do {
            opened = Descriptor(fd: fd, stat: try Posix.fstat(fd))
        } catch {
            Darwin.close(fd)
            throw error
        }
        if opened.identity != st.identity { throw FolderAccessError.changed(display) }
        return opened
    }

    // MARK: Inside the grant

    /// The grant root, reopened: it must still be the folder that was granted.
    public func openRoot() throws -> OpenedDirectory {
        let d = try Self.openAbsolute(root.path, denylist: denylist, rejectPackages: true, denied: { .notGrantable($0) })
        if d.identity != root.identity { throw FolderAccessError.changed(root.path) }
        return OpenedDirectory(descriptor: d, chain: [d.identity], components: [])
    }

    /// The rules of one step down inside a grant, on `lstat` values alone.
    public static func checkStep(parent: EntryStat, child: EntryStat, display: String) throws {
        if child.isSymlink { throw FolderAccessError.symlink(display) }
        if !child.isDirectory { throw FolderAccessError.notADirectory(display) }
        if child.identity.device != parent.identity.device { throw FolderAccessError.mountPoint(display) }
    }

    /// Opens a directory inside the grant. `expected[i]`, when given and not
    /// nil, is the identity component `i` (0 = the root) must have.
    public func openDirectory(_ components: [String], expected: [FileIdentity?] = []) throws -> OpenedDirectory {
        var dir = try openRoot()
        if let e = expected.first, let id = e, id != dir.descriptor.identity { throw FolderAccessError.changed(root.path) }
        for (i, name) in components.enumerated() {
            dir = try step(dir, name)
            if i + 1 < expected.count, let id = expected[i + 1], id != dir.descriptor.identity {
                throw FolderAccessError.changed(display(dir.components))
            }
        }
        return dir
    }

    func step(_ parent: OpenedDirectory, _ name: String) throws -> OpenedDirectory {
        try Self.validateName(name)
        let comps = parent.components + [name]
        let shown = display(comps)
        guard let st = try Posix.lstatAt(parent.descriptor.fd, name),
              !denylist.isDenied(identity: st.identity, name: name) else {
            throw FolderAccessError.notFound(shown)
        }
        try Self.checkStep(parent: parent.descriptor.stat, child: st, display: shown)
        guard let p = parent.descriptor.currentPath else { throw FolderAccessError.changed(shown) }
        // By path too: a denied folder made (or remade) after the denylist
        // was built has an identity it doesn't know.
        if denylist.deniesPath(p + "/" + name) { throw FolderAccessError.notFound(shown) }
        if Self.isPackage(path: p + "/" + name) { throw FolderAccessError.insidePackage(shown) }
        let d = try Self.openChild(parent.descriptor, name, expecting: st, display: shown)
        return OpenedDirectory(descriptor: d, chain: parent.chain + [d.identity], components: comps)
    }

    /// A path (at least one component) inside the grant: its parent opened
    /// (held to `expectedParents` as in `openDirectory`), its entry if any.
    public func resolve(_ components: [String], expectedParents: [FileIdentity?] = []) throws -> ResolvedItem {
        guard let name = components.last else { throw FolderAccessError.invalidPath("the grant root itself") }
        let parent = try openDirectory(Array(components.dropLast()), expected: expectedParents)
        return ResolvedItem(parent: parent, name: name, entry: try entry(in: parent, name))
    }

    /// One entry of an open directory; nil when missing or denied.
    public func entry(in dir: OpenedDirectory, _ name: String) throws -> FolderEntry? {
        try Self.validateName(name)
        guard let st = try Posix.lstatAt(dir.descriptor.fd, name),
              !denylist.isDenied(identity: st.identity, name: name) else { return nil }
        var kind = Self.baseKind(st)
        guard let dirPath = dir.descriptor.currentPath else { throw FolderAccessError.changed(display(dir.components)) }
        if denylist.deniesPath(dirPath + "/" + name) { return nil }
        if kind == .directory || kind == .file {
            let path = dirPath + "/" + name
            if kind == .directory, Self.isPackage(path: path) { kind = .package }
            if kind == .file, Self.isAlias(path: path) { kind = .alias }
            // The resource values were looked up by path: it must still name
            // the entry `lstat` saw.
            if Posix.lstatPath(path)?.identity != st.identity { throw FolderAccessError.changed(display(dir.components + [name])) }
        }
        return FolderEntry(name: name, stat: st, kind: kind)
    }

    /// The entries of an open directory, denied ones left out, in the order
    /// the file system returns them.
    public func entries(of dir: OpenedDirectory, limit: Int = .max) throws -> [FolderEntry] {
        let dupFD = dup(dir.descriptor.fd)
        guard dupFD >= 0 else { throw FolderAccessError.system("dup", errno) }
        guard let stream = fdopendir(dupFD) else {
            let e = errno
            Darwin.close(dupFD)
            throw FolderAccessError.system("fdopendir", e)
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var out: [FolderEntry] = []
        while out.count < limit, let ent = readdir(stream) {
            let name = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            // A name that vanished (or turned denied) since readdir is skipped.
            if let e = try? entry(in: dir, name) { out.append(e) }
        }
        return out
    }

    /// Opens a regular file for reading, held to the entry's identity. The
    /// caller closes the descriptor.
    public func openFile(_ item: ResolvedItem) throws -> Descriptor {
        let shown = display(item.components)
        guard let e = item.entry else { throw FolderAccessError.notFound(shown) }
        guard e.kind == .file else { throw FolderAccessError.notARegularFile(shown) }
        // O_NONBLOCK: a FIFO swapped in after lstat can't block the open.
        let fd = openat(item.parent.descriptor.fd, item.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ELOOP { throw FolderAccessError.symlink(shown) }
            throw FolderAccessError.system("open \(shown)", errno)
        }
        let d: Descriptor
        do {
            d = Descriptor(fd: fd, stat: try Posix.fstat(fd))
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard d.stat.isRegularFile, d.identity == e.identity else { throw FolderAccessError.changed(shown) }
        return d
    }

    public func display(_ components: [String]) -> String {
        components.isEmpty ? root.path : root.path + "/" + components.joined(separator: "/")
    }

    // MARK: Kinds

    static func baseKind(_ st: EntryStat) -> EntryKind {
        switch st.mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    /// Bundle extensions treated as packages even where Launch Services
    /// doesn't know them (a test runner, a type no app declares).
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "rtfd", "pages", "numbers", "key",
        "photoslibrary", "musiclibrary", "tvlibrary", "xcodeproj", "xcworkspace", "playground", "mlpackage",
        "mlmodelc", "sparsebundle", "dSYM", "qlgenerator", "mdimporter", "prefPane", "saver", "wdgt", "lpdf"
    ]

    /// A bundle directory, as Finder shows it: the package bit, a package
    /// type's extension, or a known bundle extension.
    public static func isPackage(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return true }
        let ext = url.pathExtension
        guard !ext.isEmpty else { return false }
        if packageExtensions.contains(where: { $0.caseInsensitiveCompare(ext) == .orderedSame }) { return true }
        guard let type = UTType(filenameExtension: ext), !type.isDynamic else { return false }
        return type.conforms(to: .package) || type.conforms(to: .bundle)
    }

    /// A Finder alias file (symlinks, which Foundation also calls aliases, are
    /// told apart by `lstat` before this is asked).
    public static func isAlias(path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
    }

    /// Managed by a file provider (iCloud Drive, others): a delete there
    /// removes it from the user's other devices too (Hardening 6).
    public static func isFileProviderItem(path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }
}
