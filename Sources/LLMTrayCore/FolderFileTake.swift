import Darwin
import Foundation

/// A whole file out of a granted folder (adr/0014, "Looking at an image,
/// adding to the project"): an image the model asked to look at
/// (`files(view)`), or a copy for the chat's project
/// (`files(add_to_project)`, made only once the user said yes). Read
/// through a descriptor opened from the grant root, like every other read
/// -- never by path -- bounded, and held to the same content guards as
/// `files` info: nothing named like a secret (Hardening 17), nothing with
/// another name (a hard link, Hardening 5), nothing only in iCloud
/// (Hardening 15, reads set not to download).
public enum FolderFileTake {
    /// The most `view` reads: an image bigger than this isn't a photo.
    public static let maxViewBytes = 40 * 1024 * 1024
    /// The most `add_to_project` copies.
    public static let maxProjectBytes: Int64 = 1024 * 1024 * 1024

    public enum TakeError: Error, Equatable, CustomStringConvertible {
        case tooLarge(String, limit: Int64)
        case looksSecret(String)
        case hardLinked(String)
        case notDownloaded(String)
        case cancelled
        case write(String, Int32)

        public var description: String {
            switch self {
            case .tooLarge(let shown, let limit):
                return "\(shown) is larger than \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))"
            case .looksSecret(let shown): return "\(shown) is \(FileClassifier.secretNote)"
            case .hardLinked(let shown):
                return "\(shown) has more than one name (a hard link, maybe to a file outside this folder): contents not read"
            case .notDownloaded(let shown): return "\(shown) is \(FileClassifier.notDownloadedNote)"
            case .cancelled: return "cancelled"
            case .write(let what, let code): return "\(what) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// What a file is before anything of it is read: its size, when the
    /// guards let it be read at all.
    public static func check(_ walker: SafeFolderWalker, _ components: [String], maxBytes: Int64) throws -> (bytes: Int64, identity: FileIdentity) {
        let item = try walker.resolve(components)
        let shown = walker.display(components)
        guard let entry = item.entry else { throw FolderAccessError.notFound(shown) }
        guard entry.kind == .file else { throw FolderAccessError.notARegularFile(shown) }
        try guards(entry.stat, item: item, walker: walker, shown: shown)
        guard entry.stat.size <= maxBytes else { throw TakeError.tooLarge(shown, limit: maxBytes) }
        return (entry.stat.size, entry.identity)
    }

    private static func guards(_ stat: EntryStat, item: ResolvedItem, walker: SafeFolderWalker, shown: String) throws {
        if FolderDenylist.looksSecret(name: item.name, parentName: FileClassifier.parentName(item, walker: walker)) {
            throw TakeError.looksSecret(shown)
        }
        if stat.isDataless { throw TakeError.notDownloaded(shown) }
        if stat.isHardLinked { throw TakeError.hardLinked(shown) }
    }

    /// The whole file, at most `maxBytes`.
    public static func read(_ walker: SafeFolderWalker, _ components: [String], maxBytes: Int,
                            isCancelled: () -> Bool = { false }) throws -> Data {
        try Materialization.off { try reading(walker, components, maxBytes: maxBytes, isCancelled: isCancelled) }
    }

    private static func reading(_ walker: SafeFolderWalker, _ components: [String], maxBytes: Int,
                                isCancelled: () -> Bool) throws -> Data {
        let file = try open(walker, components, maxBytes: Int64(maxBytes))
        var data = Data()
        data.reserveCapacity(Int(file.stat.size))
        try stream(file, maxBytes: Int64(maxBytes), shown: walker.display(components), isCancelled: isCancelled) { chunk in
            data.append(chunk)
        }
        return data
    }

    /// A copy under the file's own name in a new folder of `directory`
    /// (the caller removes that folder once done with it).
    /// `expected`: the file the user said yes to; another one there now
    /// (replaced, or a path that leads elsewhere) isn't copied.
    public static func copy(_ walker: SafeFolderWalker, _ components: [String], into directory: URL, maxBytes: Int64,
                            expected: FileIdentity? = nil, isCancelled: () -> Bool = { false }) throws -> URL {
        try Materialization.off {
            try copying(walker, components, into: directory, maxBytes: maxBytes, expected: expected, isCancelled: isCancelled)
        }
    }

    private static func copying(_ walker: SafeFolderWalker, _ components: [String], into directory: URL, maxBytes: Int64,
                                expected: FileIdentity?, isCancelled: () -> Bool) throws -> URL {
        let file = try open(walker, components, maxBytes: maxBytes)
        if let expected, file.identity != expected { throw FolderAccessError.changed(walker.display(components)) }
        guard let name = components.last else { throw FolderAccessError.invalidPath("the grant root itself") }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        let out = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else {
            let e = errno
            try? FileManager.default.removeItem(at: folder)
            throw TakeError.write("creating the copy", e)
        }
        defer { Darwin.close(out) }
        do {
            try stream(file, maxBytes: maxBytes, shown: walker.display(components), isCancelled: isCancelled) { chunk in
                try chunk.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = Darwin.write(out, raw.baseAddress! + offset, raw.count - offset)
                        if n < 0 {
                            if errno == EINTR { continue }
                            throw TakeError.write("writing the copy", errno)
                        }
                        offset += n
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return target
    }

    private static func open(_ walker: SafeFolderWalker, _ components: [String], maxBytes: Int64) throws -> Descriptor {
        let item = try walker.resolve(components)
        let shown = walker.display(components)
        if let entry = item.entry { try guards(entry.stat, item: item, walker: walker, shown: shown) }
        let file = try walker.openFile(item)
        // Evicted or linked since lstat: the open file's own flags decide.
        try guards(file.stat, item: item, walker: walker, shown: shown)
        guard file.stat.size <= maxBytes else { throw TakeError.tooLarge(shown, limit: maxBytes) }
        return file
    }

    /// The file's bytes in chunks; more than `maxBytes` (it grew) fails.
    private static func stream(_ file: Descriptor, maxBytes: Int64, shown: String, isCancelled: () -> Bool,
                               _ body: (Data) throws -> Void) throws {
        let chunkSize = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var total: Int64 = 0
        while true {
            if isCancelled() { throw TakeError.cancelled }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(file.fd, $0.baseAddress, chunkSize) }
            if n < 0 {
                if errno == EINTR { continue }
                throw FolderAccessError.system("read \(shown)", errno)
            }
            if n == 0 { return }
            total += Int64(n)
            guard total <= maxBytes else { throw TakeError.tooLarge(shown, limit: maxBytes) }
            try body(Data(buffer[0..<n]))
        }
    }
}
