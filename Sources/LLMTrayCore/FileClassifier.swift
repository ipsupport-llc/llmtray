import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A text file's encoding, as far as its first bytes tell.
public enum TextEncodingGuess: String, Codable, Sendable {
    case ascii
    case utf8 = "utf-8"
    case utf8BOM = "utf-8-bom"
    case utf16LE = "utf-16le"
    case utf16BE = "utf-16be"
    /// Legacy single-byte, guessed: Cyrillic (the common Russian one)...
    case windows1251 = "windows-1251"
    /// ...or Western European.
    case windows1252 = "windows-1252"

    var stringEncoding: String.Encoding {
        switch self {
        case .ascii, .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .windows1251:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
        case .windows1252: return .windowsCP1252
        }
    }
}

/// What a whole-file hash came to.
public enum HashOutcome: Codable, Equatable, Sendable {
    case sha256(String)
    /// Over the byte cap: not read, so no answer rather than a slow one.
    case tooLarge(limit: Int64)
    case timedOut(seconds: Double)
    /// Contents not read (a hard link, not a regular file).
    case withheld(String)
    case cancelled
}

/// `file_info` (adr/0014): what a file is, from bounded reads through a
/// verified descriptor -- never the whole file, except a hash the caller asks
/// for, which is capped by bytes and time.
public struct FileInfo: Codable, Equatable, Sendable {
    public var name: String
    public var kind: EntryKind
    public var size: Int64
    public var created: Date
    public var modified: Date
    /// More than one name: contents not read (Hardening 5).
    public var hardLinked: Bool
    /// From the content's first bytes when they are decisive, else the name's
    /// extension.
    public var contentType: String?
    public var mimeType: String?
    /// The extension's type, when it differs from the content's.
    public var extensionType: String?
    /// The name claims one type, the bytes are another (a pdf named .txt).
    public var typeMismatch: Bool
    /// `DocumentKind` of the head (text, html, pdf, rtf, image, zip, cfb...).
    public var documentKind: DocumentKind?
    public var isText: Bool?
    public var encoding: TextEncodingGuess?
    public var lineCount: Int?
    /// false: `lineCount` is a lower bound (counted up to the cap).
    public var lineCountComplete: Bool?
    public var head: String?
    public var headTruncated: Bool?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var hash: HashOutcome?
    /// Why contents weren't looked at, when they weren't.
    public var note: String?
    /// In iCloud (or another file provider), not downloaded: not read, as
    /// reading would download it. Set only when true.
    public var notDownloaded: Bool?
    /// Named like a key or credentials file: not read. Set only when true.
    public var looksSecret: Bool?
    /// A folder or package: whether anything denied is inside (it isn't
    /// moved or trashed as a whole then).
    public var protectedInside: ProtectedContents?
}

public struct FileClassifier {
    public struct Caps: Sendable {
        /// git's window for the text/binary heuristic (`FIRST_FEW_BYTES`).
        public var sniffBytes = 8000
        public var lineCountBytes: Int64 = 8 << 20
        public var headLines = 20
        public var headBytes = 2048
        public var imageHeaderBytes = 1 << 20
        public var hashBytes: Int64 = 4 << 30
        public var hashSeconds: Double = 20
        public var chunkBytes = 1 << 20

        public init() {}
    }

    public var caps: Caps
    /// Injectable for the time cap's tests.
    public var clock: () -> Date

    public init(caps: Caps = Caps(), clock: @escaping () -> Date = Date.init) {
        self.caps = caps
        self.clock = clock
    }

    // MARK: file_info

    static let notDownloadedNote = "in iCloud, not downloaded: contents not read (reading would download it)"
    static let secretNote = "named like a key or credentials file: contents not read"

    /// A file's parent folder's name, for `FolderDenylist.looksSecret`.
    static func parentName(_ item: ResolvedItem, walker: SafeFolderWalker) -> String {
        item.parent.components.last ?? (walker.root.path as NSString).lastPathComponent
    }

    public func info(_ item: ResolvedItem, walker: SafeFolderWalker, hash: Bool = false,
                     isCancelled: () -> Bool = { false }) throws -> FileInfo {
        // Reads fail rather than download a dataless file (a second guard
        // behind the SF_DATALESS checks).
        try Materialization.off { try infoReading(item, walker: walker, hash: hash, isCancelled: isCancelled) }
    }

    private func infoReading(_ item: ResolvedItem, walker: SafeFolderWalker, hash: Bool,
                             isCancelled: () -> Bool) throws -> FileInfo {
        guard let entry = item.entry else { throw FolderAccessError.notFound(walker.display(item.components)) }
        let ext = (entry.name as NSString).pathExtension
        let extType = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        var info = FileInfo(name: entry.name, kind: entry.kind, size: entry.stat.size, created: entry.stat.created,
                            modified: entry.stat.modified, hardLinked: entry.stat.isHardLinked,
                            contentType: extType?.identifier, mimeType: extType?.preferredMIMEType,
                            extensionType: nil, typeMismatch: false)
        switch entry.kind {
        case .file: break
        case .directory:
            info.contentType = UTType.folder.identifier
            info.protectedInside = walker.protectedContents(in: item.parent, entry.name)
            if info.protectedInside == .found { info.note = "contains protected items: not moved or trashed as a whole" }
            return info
        case .package:
            info.note = "a package: one item, not opened"
            info.protectedInside = walker.protectedContents(in: item.parent, entry.name)
            return info
        case .symlink: info.contentType = UTType.symbolicLink.identifier; info.note = "a symbolic link: not followed"; return info
        case .alias: info.contentType = UTType.aliasFile.identifier; info.note = "an alias: not followed"; return info
        case .other: info.note = "not a regular file: not opened"; return info
        }
        if FolderDenylist.looksSecret(name: entry.name, parentName: Self.parentName(item, walker: walker)) {
            info.looksSecret = true
            info.note = Self.secretNote
            if hash { info.hash = .withheld("looks like a secret") }
            return info
        }
        if entry.stat.isDataless {
            info.notDownloaded = true
            info.note = Self.notDownloadedNote
            if hash { info.hash = .withheld("not downloaded") }
            return info
        }
        if entry.stat.isHardLinked {
            info.note = "has more than one name (a hard link, maybe to a file outside this folder): contents not read"
            if hash { info.hash = .withheld("hard link") }
            return info
        }
        let file = try walker.openFile(item)
        // Evicted since lstat: the open file's own flags decide.
        if file.stat.isDataless {
            info.notDownloaded = true
            info.note = Self.notDownloadedNote
            if hash { info.hash = .withheld("not downloaded") }
            return info
        }
        // A link made since lstat: the open file's own count decides.
        if file.stat.isHardLinked {
            info.hardLinked = true
            info.note = "has more than one name (a hard link, maybe to a file outside this folder): contents not read"
            if hash { info.hash = .withheld("hard link") }
            return info
        }
        let size = file.stat.size
        info.size = size
        let head = try Self.read(file.fd, offset: 0, count: caps.sniffBytes)
        let kind = DocumentKind.detect(head)
        info.documentKind = kind
        let magic = Self.magicType(head)
        if let magic {
            info.contentType = magic.identifier
            info.mimeType = magic.preferredMIMEType
            if let extType, extType != magic {
                info.extensionType = extType.identifier
                info.typeMismatch = Self.mismatch(content: magic, name: extType)
            }
        }
        let bomUTF16 = head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])
        // A decisive signature is binary unless it is a text format (RTF).
        let binary = magic.map { !$0.conforms(to: .text) } ?? (!bomUTF16 && Self.isBinary(head))
        info.isText = !binary
        if !binary {
            let encoding = Self.encoding(head, complete: Int64(head.count) >= size)
            info.encoding = encoding
            if magic == nil, extType.map({ !$0.conforms(to: .text) }) ?? true {
                // Text under an unknown or non-text extension: say it's text.
                if let extType, !extType.isDynamic { info.extensionType = extType.identifier }
                info.contentType = UTType.plainText.identifier
                info.mimeType = UTType.plainText.preferredMIMEType
            }
            let (lines, complete) = try countLines(file.fd, size: size, encoding: encoding)
            info.lineCount = lines
            info.lineCountComplete = complete
            let (text, truncated) = Self.head(head, encoding: encoding, maxLines: caps.headLines, maxBytes: caps.headBytes)
            info.head = text
            info.headTruncated = truncated
        }
        let imageType = magic ?? extType
        if let imageType, imageType.conforms(to: .image), binary {
            let bytes = try Self.read(file.fd, offset: 0, count: caps.imageHeaderBytes)
            if let (w, h) = Self.pixelSize(bytes, complete: Int64(bytes.count) >= size) {
                info.pixelWidth = w
                info.pixelHeight = h
            }
        }
        if hash { info.hash = sha256(file, isCancelled: isCancelled) }
        return info
    }

    // MARK: Text or binary (git)

    /// git's heuristic on a file's first bytes: a NUL means binary
    /// (`buffer_is_binary`), and so do too many non-printables
    /// (`convert.c`'s `gather_stats`: printable / 128 < non-printable, with
    /// \b \t ESC FF printable and a trailing ^Z not counted).
    public static func isBinary(_ head: Data) -> Bool {
        var printable = 0, nonPrintable = 0
        for c in head {
            switch c {
            case 0: return true
            case 0x0A, 0x0D: continue
            case 0x7F: nonPrintable += 1
            case 0x08, 0x09, 0x1B, 0x0C: printable += 1
            case ..<0x20: nonPrintable += 1
            default: printable += 1
            }
        }
        if head.last == 0x1A { nonPrintable -= 1 }
        return (printable >> 7) < nonPrintable
    }

    /// UTF-8 (valid; `complete` false lets a sequence cut by the window
    /// pass), UTF-16 by BOM, else a legacy single-byte guess: Cyrillic
    /// Windows-1251 when high bytes are letters rather than accents on Latin
    /// text, else Windows-1252.
    public static func encoding(_ head: Data, complete: Bool = true) -> TextEncodingGuess {
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if head.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if head.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        if !head.contains(where: { $0 >= 0x80 }) { return .ascii }
        let bytes = complete ? head : utf8Prefix(head)
        if String(data: bytes, encoding: .utf8) != nil { return .utf8 }
        var high = 0, latin = 0
        for c in head {
            if c >= 0xC0 || c == 0xA8 || c == 0xB8 { high += 1 }
            else if (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) { latin += 1 }
        }
        return high * 2 >= latin ? .windows1251 : .windows1252
    }

    /// A type the first bytes decide, or nil (text, or nothing recognized).
    public static func magicType(_ head: Data) -> UTType? {
        let b = [UInt8](head.prefix(64))
        func at(_ o: Int, _ s: [UInt8]) -> Bool { b.count >= o + s.count && Array(b[o..<(o + s.count)]) == s }
        func at(_ o: Int, _ s: String) -> Bool { at(o, Array(s.utf8)) }
        if at(0, "%PDF-") { return .pdf }
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if at(0, [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if at(0, "GIF87a") || at(0, "GIF89a") { return .gif }
        if at(0, [0x49, 0x49, 0x2A, 0x00]) || at(0, [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if at(0, "RIFF"), at(8, "WEBP") { return .webP }
        if at(0, "RIFF"), at(8, "WAVE") { return .wav }
        if at(0, "RIFF"), at(8, "AVI ") { return .avi }
        if at(4, "ftyp"), b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "heim", "heis", "mif1", "msf1"].contains(brand) { return .heic }
            if ["avif", "avis"].contains(brand) { return UTType("public.avif") ?? .image }
            if brand == "qt  " { return .quickTimeMovie }
            if ["M4A ", "M4B "].contains(brand) { return .mpeg4Audio }
            return .mpeg4Movie
        }
        // MPEG layer 3 frame sync (not 0xFF 0xFE, a UTF-16 BOM).
        if at(0, "ID3") || (b.count >= 2 && b[0] == 0xFF && [0xFB, 0xFA, 0xF3, 0xF2, 0xE3, 0xE2].contains(b[1])) { return .mp3 }
        if at(0, "fLaC") { return UTType("org.xiph.flac") ?? .audio }
        if at(0, "OggS") { return UTType("org.xiph.ogg") ?? .audio }
        if at(0, [0x50, 0x4B, 0x03, 0x04]) || at(0, [0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if at(0, [0x1F, 0x8B]) { return .gzip }
        if at(0, "BZh") { return .bz2 }
        if at(0, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return UTType("org.tukaani.xz-archive") ?? .archive }
        if at(0, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return UTType("org.7-zip.7-zip-archive") ?? .archive }
        if at(0, "Rar!") { return UTType("com.rarlab.rar-archive") ?? .archive }
        if at(0, CompoundFile.magic) { return UTType("com.microsoft.ole.structured-storage") ?? .data }
        if at(0, "{\\rtf") { return .rtf }
        if at(0, "SQLite format 3\0") { return UTType("public.database") ?? .database }
        if at(0, [0x7F, 0x45, 0x4C, 0x46]) { return .executable }
        if at(0, [0xCF, 0xFA, 0xED, 0xFE]) || at(0, [0xCE, 0xFA, 0xED, 0xFE]) || at(0, [0xCA, 0xFE, 0xBA, 0xBE]) {
            return .unixExecutable
        }
        return nil
    }

    /// The name and the bytes disagree -- by category, so a container format
    /// (docx is a zip, doc a compound file) isn't flagged under its own name.
    static func mismatch(content: UTType, name: UTType) -> Bool {
        if name.isDynamic || name.conforms(to: content) || content.conforms(to: name) { return false }
        func category(_ t: UTType) -> String? {
            if t.conforms(to: .pdf) { return "pdf" }
            if t.conforms(to: .image) { return "image:" + t.identifier }
            if t.conforms(to: .movie) { return "movie" }
            if t.conforms(to: .audio) { return "audio" }
            if t.conforms(to: .text) { return "text" }
            if t.conforms(to: .archive) || t.conforms(to: .zip) { return "archive" }
            return nil
        }
        guard let c = category(content) else { return false }
        guard let n = category(name) else {
            // Anything can live in an archive or a compound file.
            return !(c == "archive")
        }
        return c != n
    }

    // MARK: Bounded reads

    static func read(_ fd: Int32, offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, count - got, off_t(offset) + off_t(got)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw FolderAccessError.system("read", errno)
            }
            if n == 0 { break }
            got += n
        }
        data.count = got
        return data
    }

    /// Newlines up to `lineCountBytes`, plus an unterminated last line.
    func countLines(_ fd: Int32, size: Int64, encoding: TextEncodingGuess) throws -> (Int, Bool) {
        let limit = min(size, caps.lineCountBytes)
        var offset: Int64 = 0
        var lines = 0
        var last: UInt8 = 0x0A
        let utf16 = encoding == .utf16LE || encoding == .utf16BE
        let chunk = max(2, caps.chunkBytes & ~1)
        while offset < limit {
            let d = try Self.read(fd, offset: offset, count: Int(min(Int64(chunk), limit - offset)))
            if d.isEmpty { break }
            if utf16 {
                var i = d.startIndex
                while i + 1 < d.endIndex {
                    let unit = encoding == .utf16LE ? UInt16(d[i]) | UInt16(d[i + 1]) << 8 : UInt16(d[i]) << 8 | UInt16(d[i + 1])
                    if unit == 0x0A { lines += 1 }
                    last = unit == 0x0A ? 0x0A : 0x20
                    i += 2
                }
            } else {
                lines += d.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                last = d.last ?? last
            }
            offset += Int64(d.count)
        }
        let complete = offset >= size
        if complete, size > 0, last != 0x0A { lines += 1 }
        return (lines, complete)
    }

    /// The first lines, at most `maxBytes` of the file, cut between
    /// characters.
    static func head(_ data: Data, encoding: TextEncodingGuess, maxLines: Int, maxBytes: Int) -> (String, Bool) {
        var bytes = data.prefix(maxBytes)
        var truncated = data.count > maxBytes
        switch encoding {
        case .utf16LE, .utf16BE:
            if bytes.count % 2 == 1 { bytes = bytes.dropLast() }
        case .ascii, .utf8, .utf8BOM:
            if bytes.count < data.count { bytes = utf8Prefix(bytes) }
        case .windows1251, .windows1252: break
        }
        var text = String(data: Data(bytes), encoding: encoding.stringEncoding)
            ?? String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            truncated = true
            text = lines.joined(separator: "\n")
        }
        return (text, truncated)
    }

    /// `data` without a UTF-8 sequence its end cuts short (a complete last
    /// character is kept).
    static func utf8Prefix(_ data: Data) -> Data {
        var lead = data.endIndex
        var back = 0
        while lead > data.startIndex, back < 4, data[lead - 1] & 0xC0 == 0x80 { lead -= 1; back += 1 }
        guard lead > data.startIndex else { return data }
        let first = data[lead - 1]
        let need: Int
        switch first {
        case 0xC0...0xDF: need = 2
        case 0xE0...0xEF: need = 3
        case 0xF0...0xF7: need = 4
        default: return data   // ASCII or invalid: nothing to repair
        }
        return back + 1 < need ? data[..<(lead - 1)] : data
    }

    /// Pixel size from the header bytes, without decoding the image.
    static func pixelSize(_ data: Data, complete: Bool) -> (Int, Int)? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, complete)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (w, h)
    }

    // MARK: Hash

    /// SHA-256 of the whole file, streamed through the verified descriptor in
    /// fixed-size reads; over the byte cap it isn't started, past the time
    /// cap it stops.
    public func sha256(_ file: Descriptor, isCancelled: () -> Bool = { false }) -> HashOutcome {
        guard file.stat.isRegularFile else { return .withheld("not a regular file") }
        if file.stat.isHardLinked { return .withheld("hard link") }
        if file.stat.isDataless { return .withheld("not downloaded") }
        return Materialization.off { hashReading(file, isCancelled: isCancelled) }
    }

    private func hashReading(_ file: Descriptor, isCancelled: () -> Bool) -> HashOutcome {
        if file.stat.size > caps.hashBytes { return .tooLarge(limit: caps.hashBytes) }
        let start = clock()
        var hasher = SHA256()
        var offset: Int64 = 0
        while true {
            if isCancelled() { return .cancelled }
            if clock().timeIntervalSince(start) > caps.hashSeconds { return .timedOut(seconds: caps.hashSeconds) }
            guard let d = try? Self.read(file.fd, offset: offset, count: caps.chunkBytes) else {
                return .withheld("read failed")
            }
            if d.isEmpty { break }
            hasher.update(data: d)
            offset += Int64(d.count)
            // A file that grows while being read is held to the cap too.
            if offset > caps.hashBytes { return .tooLarge(limit: caps.hashBytes) }
        }
        return .sha256(Self.hex(hasher.finalize()))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
