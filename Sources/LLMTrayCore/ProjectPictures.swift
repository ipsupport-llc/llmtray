import CryptoKit
import Foundation

/// A picture a project keeps for its documents (adr/0020, "Project
/// pictures"): stored and listed, never searched -- a store of its own
/// beside the index, which stays exactly as it is.
public struct ProjectPicture: Codable, Equatable, Sendable {
    /// `p1`, `p2`… never reused in the project.
    public var id: String
    /// The copy's name in `pictures/`.
    public var file: String
    /// Its thumbnail's name in `pictures/`, if one was made.
    public var thumbnail: String?
    /// The name it was added under (file text, like a document's name).
    public var name: String
    public var width: Int
    public var height: Int
    public var bytes: Int
    public var sha256: String
    public var added: Date
}

/// `pictures/pictures.json`: the pictures and the next number.
public struct PictureManifest: Codable, Equatable, Sendable {
    public var next: Int = 1
    public var pictures: [ProjectPicture] = []
    public init() {}
}

/// The store: `<project>/pictures/<uuid>.<ext>` copies (0600), their
/// thumbnails, `staging/` for adds in progress, and the manifest, replaced
/// atomically. Every change runs on the project's writer queue
/// (`ProjectIndexHandle.write`), which holds the project's lock: two tabs or
/// flows never write the manifest at once. Reading the manifest needs no
/// lock (it's replaced whole).
public enum ProjectPictures {
    public static let formats: Set<String> = ["png", "jpg", "jpeg", "jfif", "heic", "heif", "webp", "tif", "tiff", "gif"]
    public static let maxBytes = 50 * 1024 * 1024
    /// A document uses at most this many megapixels of a picture's header
    /// before anything is decoded (the decoder child checks).
    public static let maxMegapixels = 100
    /// The thumbnail the Files window shows, made at add.
    public static let thumbnailSide = 400

    public static func isPicture(_ url: URL) -> Bool { formats.contains(url.pathExtension.lowercased()) }

    static func directory(_ project: URL) -> URL { project.appendingPathComponent("pictures", isDirectory: true) }
    static func staging(_ project: URL) -> URL { directory(project).appendingPathComponent("staging", isDirectory: true) }
    static func manifestURL(_ project: URL) -> URL { directory(project).appendingPathComponent("pictures.json") }

    /// The manifest as on disk, for reading: none yet or unreadable, empty.
    /// Nothing that changes the store uses this (see `load`).
    public static func manifest(in project: URL) -> PictureManifest {
        (try? load(project)) ?? PictureManifest()
    }

    /// The manifest for a change: none yet is empty; one that can't be read
    /// or decoded stops the change -- never taken for empty (reconcile
    /// would delete every picture, and ids would start over).
    static func load(_ project: URL) throws -> PictureManifest {
        let url = manifestURL(project)
        guard FileManager.default.fileExists(atPath: url.path) else { return PictureManifest() }
        do {
            return try JSONDecoder().decode(PictureManifest.self, from: Data(contentsOf: url))
        } catch {
            throw ProjectPictureError.unreadableManifest
        }
    }

    /// A picture's copy, only if the manifest lists it (by id).
    public static func file(of id: String, in project: URL) -> (picture: ProjectPicture, url: URL)? {
        guard let p = manifest(in: project).pictures.first(where: { $0.id == id }) else { return nil }
        return (p, directory(project).appendingPathComponent(p.file))
    }

    static func save(_ manifest: PictureManifest, in project: URL) throws {
        let dir = directory(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".pictures-\(UUID().uuidString).json")
        try JSONEncoder().encode(manifest).write(to: temp, options: .withoutOverwriting)
        guard rename(temp.path, manifestURL(project).path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// A private copy of `source` in `folder` -- its bytes (a link's
    /// target's), read with a cap: never a link, never past `maxBytes`.
    public static func privateCopy(of source: URL, into folder: URL) throws -> URL {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        let fd = open(copy.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var total = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            total += chunk.count
            guard total <= maxBytes else {
                try? output.close()
                try? FileManager.default.removeItem(at: copy)
                throw ProjectPictureError.tooLarge
            }
            try output.write(contentsOf: chunk)
        }
        try output.close()
        return copy
    }

    /// SHA-256 of a file, streamed.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A picture checked and measured outside the lock: the private copy
    /// that was decoded (so what's stored is what was checked), its size
    /// and hash, and the thumbnail the decoder made.
    public struct Checked: Sendable {
        public var copy: URL
        public var name: String
        public var width: Int
        public var height: Int
        public var thumbnail: Data?
        public init(copy: URL, name: String, width: Int, height: Int, thumbnail: Data?) {
            self.copy = copy
            self.name = name
            self.width = width
            self.height = height
            self.thumbnail = thumbnail
        }
    }

    public enum Added: Equatable, Sendable {
        case added(ProjectPicture)
        case duplicate(ProjectPicture)
    }

    /// On the writer queue: the checked copy into `staging/`, renamed into
    /// place, then the manifest records it. The same file twice (SHA-256)
    /// is "already in the project". The caller deletes `checked.copy`.
    public static func add(_ checked: Checked, to project: URL) throws -> Added {
        let attrs = try FileManager.default.attributesOfItem(atPath: checked.copy.path)
        let bytes = (attrs[.size] as? Int) ?? 0
        guard bytes > 0, bytes <= maxBytes else { throw ProjectPictureError.tooLarge }
        // A regular file only: a link would keep pointing at its original.
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw ProjectPictureError.notAPicture }
        let hash = try sha256(of: checked.copy)
        var m = try load(project)
        if let same = m.pictures.first(where: { $0.sha256 == hash }) { return .duplicate(same) }
        let stage = staging(project)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let ext = checked.copy.pathExtension.lowercased()
        let file = "\(UUID().uuidString).\(formats.contains(ext) ? ext : "img")"
        let staged = stage.appendingPathComponent(file)
        try FileManager.default.copyItem(at: checked.copy, to: staged)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let final = directory(project).appendingPathComponent(file)
        guard rename(staged.path, final.path) == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var thumbnail: String?
        if let thumb = checked.thumbnail, thumb.count <= 512 * 1024 {
            let name = file + ".thumb.png"
            if (try? thumb.write(to: directory(project).appendingPathComponent(name), options: .withoutOverwriting)) != nil { thumbnail = name }
        }
        let picture = ProjectPicture(id: "p\(m.next)", file: file, thumbnail: thumbnail, name: String(checked.name.prefix(255)),
                                     width: checked.width, height: checked.height, bytes: bytes, sha256: hash, added: Date())
        m.next += 1
        m.pictures.append(picture)
        do {
            try save(m, in: project)
        } catch {
            try? FileManager.default.removeItem(at: final)
            if let thumbnail { try? FileManager.default.removeItem(at: directory(project).appendingPathComponent(thumbnail)) }
            throw error
        }
        return .added(picture)
    }

    /// On the writer queue: out of the manifest first, then its files.
    public static func remove(_ id: String, from project: URL) throws {
        var m = try load(project)
        guard let i = m.pictures.firstIndex(where: { $0.id == id }) else { return }
        let picture = m.pictures.remove(at: i)
        try save(m, in: project)
        try? FileManager.default.removeItem(at: directory(project).appendingPathComponent(picture.file))
        if let t = picture.thumbnail { try? FileManager.default.removeItem(at: directory(project).appendingPathComponent(t)) }
    }

    /// At open (on the writer queue): staging leftovers and files the
    /// manifest doesn't name deleted, entries whose copy is gone dropped.
    @discardableResult
    public static func reconcile(_ project: URL) throws -> (deleted: Int, dropped: Int) {
        let dir = directory(project)
        guard FileManager.default.fileExists(atPath: dir.path) else { return (0, 0) }
        try? FileManager.default.removeItem(at: staging(project))
        var m = try load(project)
        // Entries whose copy is gone first: their thumbnails are then
        // unlisted files like any other.
        let before = m.pictures.count
        m.pictures.removeAll { !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) }
        let dropped = before - m.pictures.count
        if dropped > 0 { try save(m, in: project) }
        let known = Set(m.pictures.flatMap { [$0.file] + ($0.thumbnail.map { [$0] } ?? []) } + ["pictures.json"])
        var deleted = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !known.contains(name) {
            if (try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))) != nil { deleted += 1 }
        }
        return (deleted, dropped)
    }

    /// The bytes the project's pictures take (for its disk limits and usage).
    public static func usage(_ project: URL) -> Int64 {
        manifest(in: project).pictures.reduce(0) { $0 + Int64($1.bytes) }
    }

    /// `project_files`' listing part: one line per picture; with documents
    /// on, how to use one first.
    public static func listing(_ m: PictureManifest, picturesUsable: Bool) -> String {
        guard !m.pictures.isEmpty else { return "" }
        var lines = ["Pictures:" + (picturesUsable ? " use one in a document as ![caption](project:<id>)" : "")]
        for p in m.pictures { lines.append("\(p.id). \(p.name) -- \(p.width)×\(p.height)") }
        return lines.joined(separator: "\n")
    }
}

public enum ProjectPictureError: Error, Equatable {
    case tooLarge
    case notAPicture
    case unreadableManifest
}
