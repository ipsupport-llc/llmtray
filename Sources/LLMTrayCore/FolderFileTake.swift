import Darwin
import Foundation

/// A whole file out of a granted folder (adr/0014, "Looking at an image,
/// adding to the project"): an image the model asked to look at
/// (`files(view)`), or a copy for the chat's project
/// (`files(add_to_project)`). Read through a descriptor opened from the
/// grant root, like every other read -- never by path -- and bounded.
public enum FolderFileTake {
    /// The most `view` reads: an image bigger than this isn't a photo.
    public static let maxViewBytes = 40 * 1024 * 1024
    /// The most `add_to_project` copies.
    public static let maxProjectBytes: Int64 = 1024 * 1024 * 1024

    public enum TakeError: Error, Equatable, CustomStringConvertible {
        case tooLarge(String, limit: Int64)
        case cancelled
        case write(String, Int32)

        public var description: String {
            switch self {
            case .tooLarge(let shown, let limit):
                return "\(shown) is larger than \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))"
            case .cancelled: return "cancelled"
            case .write(let what, let code): return "\(what) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// The whole file, at most `maxBytes`.
    public static func read(_ walker: SafeFolderWalker, _ components: [String], maxBytes: Int,
                            isCancelled: () -> Bool = { false }) throws -> Data {
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
    public static func copy(_ walker: SafeFolderWalker, _ components: [String], into directory: URL, maxBytes: Int64,
                            isCancelled: () -> Bool = { false }) throws -> URL {
        let file = try open(walker, components, maxBytes: maxBytes)
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
        let file = try walker.openFile(item)
        guard file.stat.size <= maxBytes else { throw TakeError.tooLarge(walker.display(components), limit: maxBytes) }
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
