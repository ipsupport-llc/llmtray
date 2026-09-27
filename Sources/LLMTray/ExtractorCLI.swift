import AppKit
import Darwin
import Foundation
import LLMTrayCore
import PDFKit

/// `LLMTray --extract <path> [--caps <json>]` (see LLMTrayApp.init): the
/// child `DocumentExtractor` starts for each document. It parses one
/// possibly hostile file and prints its text as `ExtractorMessage` lines --
/// a page per line, then a summary -- and exits 0 whatever it found (the
/// summary carries a failure); anything else means it crashed or was
/// killed. The parent enforces time, memory and output (adr/0012,
/// Extraction); this side limits itself before the file is opened: no
/// network, no core dumps, RLIMIT_CPU, and it exits if the app goes away.
///
/// `--simulate-sandbox-failure` (tests) behaves as if `sandbox_init` failed.
enum ExtractorCLI {
    static func run(arguments: [String]) -> Never {
        // The protocol gets its own descriptor; fd 1 goes to stderr, so
        // nothing a framework prints can land inside a line (as the mflux runner).
        let protocolFD = dup(1)
        dup2(2, 1)
        let started = Date()
        var caps = ExtractionCaps()
        if let i = arguments.firstIndex(of: "--caps"), i + 1 < arguments.count {
            guard let decoded = try? JSONDecoder().decode(ExtractionCaps.self, from: Data(arguments[i + 1].utf8)) else {
                FileHandle.standardError.write(Data("--caps: not valid caps JSON\n".utf8))
                exit(64)
            }
            caps = decoded
        }
        guard let i = arguments.firstIndex(of: "--extract"), i + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: LLMTray --extract <path> [--caps <json>]\n".utf8))
            exit(64)
        }
        let path = arguments[i + 1]

        limitSelf(cpuSeconds: caps.cpuSeconds)
        exitWithParent()
        let sandboxed = !arguments.contains("--simulate-sandbox-failure") && denyNetwork()

        var pages = 0
        func emit(_ message: ExtractorMessage) {
            var line = Data(message.line.utf8)
            line.append(0x0A)
            line.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(protocolFD, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { _exit(0) }   // the parent stopped reading: nothing left to do
                    offset += n
                }
            }
        }
        var kind = DocumentKind.unknown
        var failure: ExtractionError?
        do {
            var extractor = Extractor(caps: caps, sandboxed: sandboxed) { page in
                pages += 1
                emit(.page(page))
            }
            try extractor.extract(path: path, kind: &kind)
        } catch let error as ExtractionError {
            failure = error
        } catch {
            failure = .unreadable(error.localizedDescription)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        emit(.summary(ExtractionSummary(kind: kind, pages: pages, milliseconds: ms, failure: failure)))
        exit(0)
    }

    /// RLIMIT_CPU (SIGXCPU past it; the parent reports it) and no core
    /// dumps. RLIMIT_AS/DATA/RSS are rejected on macOS (EINVAL): memory is
    /// the parent's to watch.
    private static func limitSelf(cpuSeconds: Int) {
        var cpu = rlimit(rlim_cur: rlim_t(max(1, cpuSeconds)), rlim_max: rlim_t(max(1, cpuSeconds)))
        setrlimit(RLIMIT_CPU, &cpu)
        var core = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &core)
    }

    /// A crashed or force-quit app leaves no extractor behind.
    private static func exitWithParent() {
        let parent = getppid()
        Thread.detachNewThread {
            while true {
                sleep(1)
                if getppid() != parent { _exit(0) }
            }
        }
    }

    /// `sandbox_init` with the built-in "no-network" profile: deprecated,
    /// and not in Swift's Darwin module, so resolved at run time. True when
    /// it took.
    private static func denyNetwork() -> Bool {
        typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_init") else { return false }   // RTLD_DEFAULT
        var error: UnsafeMutablePointer<CChar>?
        // kSBXProfileNoNetwork, SANDBOX_NAMED.
        let rc = unsafeBitCast(symbol, to: SandboxInit.self)("no-network", 1, &error)
        if rc != 0 {
            FileHandle.standardError.write(Data("sandbox_init failed: \(error.map { String(cString: $0) } ?? "?")\n".utf8))
        }
        return rc == 0
    }
}

/// Type detection and the per-format parsers, emitting pages as they come.
private struct Extractor {
    let caps: ExtractionCaps
    /// Whether the no-network sandbox is on: Apple's importers run only then.
    let sandboxed: Bool
    let emit: (ExtractedPage) -> Void
    private var textBytes = 0
    private var count = 0

    init(caps: ExtractionCaps, sandboxed: Bool, emit: @escaping (ExtractedPage) -> Void) {
        self.caps = caps
        self.sandboxed = sandboxed
        self.emit = emit
    }

    mutating func extract(path: String, kind: inout DocumentKind) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ExtractionError.unreadable("not a regular file") }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if size > caps.maxFileBytes { throw ExtractionError.tooLarge(.fileBytes) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        kind = DocumentKind.detect(data, caps: caps)
        if kind == .encryptedOffice { throw ExtractionError.encrypted }
        guard kind.isSupported else { throw ExtractionError.unsupported(kind.rawValue) }
        if kind.needsAppleImporter && !sandboxed { throw ExtractionError.unavailableOnSystem }
        switch kind {
        case .pdf:
            try pdf(data)
        case .docx, .odt:
            // NSAttributedString unzips by itself, uncapped: every part goes
            // through the capped reader (and XML parts its checks) first.
            try CappedZip(data: data, caps: caps).checkAll(allowExternalDoctype: kind == .odt)
            try attributed(data, kind: kind)
        case .doc, .rtf:
            try attributed(data, kind: kind)
        case .html:
            // Markup around little text is fine; a file this far past the
            // text cap is not a document.
            if data.count > caps.maxTextBytes * 4 { throw ExtractionError.tooLarge(.fileBytes) }
            try page(HTMLText.text(PlainText.decode(data)))
        case .text:
            for text in try PlainText.pages(data, caps: caps) { try page(text) }
        default:
            throw ExtractionError.unsupported(kind.rawValue)
        }
    }

    private mutating func page(_ text: String, junk: Double? = nil, error: String? = nil) throws {
        textBytes += text.utf8.count
        if textBytes > caps.maxTextBytes { throw ExtractionError.tooLarge(.text) }
        count += 1
        if count > caps.maxPages { throw ExtractionError.tooLarge(.pages) }
        emit(ExtractedPage(page: count, text: text, tier: 1, junk: junk, error: error))
    }

    private mutating func pdf(_ data: Data) throws {
        guard let document = PDFDocument(data: data) else { throw ExtractionError.unreadable("pdf: can't be opened (corrupt or truncated)") }
        if document.isLocked { throw ExtractionError.encrypted }
        let n = document.pageCount
        if n == 0 { throw ExtractionError.unreadable("pdf: no pages") }
        // Refused whole rather than cut at the cap: never a truncated document.
        if n > caps.maxPages { throw ExtractionError.tooLarge(.pages) }
        for i in 0..<n {
            let (text, failed): (String, Bool) = autoreleasepool {
                guard let page = document.page(at: i) else { return ("", true) }
                return (page.string ?? "", false)
            }
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // The junk check only where a next tier exists: PDF pages with a text layer.
            try page(text, junk: hasText ? JunkCheck.score(text) : nil, error: failed ? "page unreadable" : nil)
        }
    }

    /// docx / doc / odt / rtf through Apple's importer: one flowing page.
    private mutating func attributed(_ data: Data, kind: DocumentKind) throws {
        let type: NSAttributedString.DocumentType
        switch kind {
        case .docx: type = .officeOpenXML
        case .odt: type = .openDocument
        case .doc: type = .docFormat
        default: type = .rtf
        }
        let text: String
        do {
            text = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string
        } catch {
            throw ExtractionError.unreadable("\(kind.rawValue): \(error.localizedDescription)")
        }
        try page(text)
    }
}
