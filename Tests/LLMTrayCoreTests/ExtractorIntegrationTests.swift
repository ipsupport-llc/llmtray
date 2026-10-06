import CoreGraphics
import CoreText
import XCTest
@testable import LLMTrayCore

/// `LLMTray --extract` itself, run through `DocumentExtraction` the way the
/// app runs it. `swift test` builds the app binary beside the test bundle;
/// LLMTRAY_BINARY points elsewhere (a packaged app's Contents/MacOS/LLMTray).
/// Fixtures are generated here -- textutil writes the Office formats -- except
/// the one RTF that loops Apple's importer forever (18 KB, from the spike).
final class ExtractorIntegrationTests: XCTestCase {
    private var binary: String!
    private var dir: URL!

    override func setUpWithError() throws {
        let beside = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("LLMTray").path
        binary = ProcessInfo.processInfo.environment["LLMTRAY_BINARY"] ?? beside
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary), "no app binary at \(binary!) -- swift build first")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("llmtray-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Fixtures

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func file(_ name: String, _ text: String) throws -> URL { try file(name, Data(text.utf8)) }

    /// `text` converted by textutil into `format` (docx, odt, doc, rtf, html).
    private func office(_ format: String, _ text: String, name: String? = nil) throws -> URL {
        let source = try file("source-\(format).txt", text)
        let out = dir.appendingPathComponent(name ?? "doc.\(format)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", format, "-inputencoding", "UTF-8", "-output", out.path, source.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return out
    }

    /// A PDF with one line of text per page, drawn with CoreText.
    private func pdf(_ pages: [String], name: String = "doc.pdf") throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return try file(name, data as Data)
    }

    private func extract(_ url: URL, caps: ExtractionCaps = ExtractionCaps(), extra: [String] = [],
                         useJetsam: Bool = true) async -> Result<DocumentExtraction.Document, ExtractionError> {
        do {
            return .success(try await DocumentExtraction.run(executable: binary, url: url, caps: caps, extraArguments: extra,
                                                             useJetsam: useJetsam))
        } catch let e as ExtractionError {
            return .failure(e)
        } catch {
            return .failure(.crashed("\(error)"))
        }
    }

    private func text(_ r: Result<DocumentExtraction.Document, ExtractionError>) -> String? {
        (try? r.get())?.pages.map(\.text).joined(separator: "\n")
    }

    private func assertFails(_ url: URL, caps: ExtractionCaps = ExtractionCaps(), extra: [String] = [], _ expected: ExtractionError,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let r = await extract(url, caps: caps, extra: extra)
        XCTAssertEqual(r, .failure(expected), message, file: file, line: line)
    }

    private func assertExtracts(_ url: URL, extra: [String] = [], file: StaticString = #filePath, line: UInt = #line) async {
        let r = await extract(url, extra: extra)
        XCTAssertNotNil(text(r), "\(r)", file: file, line: line)
    }

    // MARK: Formats

    func testEveryV1aFormat() async throws {
        let body = "Договор поставки № 5\nThe agreement text."
        for format in ["docx", "odt", "doc", "rtf", "html"] {
            let r = await extract(try office(format, body))
            XCTAssertEqual((try? r.get())?.kind.rawValue, format, "\(r)")
            XCTAssertTrue(text(r)?.contains("Договор поставки № 5") == true, "\(format): \(r)")
            XCTAssertTrue(text(r)?.contains("The agreement text.") == true, "\(format): \(r)")
        }
        let md = await extract(try file("notes.md", "# Title\n\nSome *markdown* ё\n"))
        XCTAssertEqual(text(md), "# Title\n\nSome *markdown* ё\n")
        let code = await extract(try file("main.swift", "let x = 1 // комментарий\n"))
        XCTAssertEqual((try? code.get())?.kind, .text)

        let doc = try await extract(pdf(["First page текст", "Second page"])).get()
        XCTAssertEqual(doc.kind, .pdf)
        XCTAssertEqual(doc.pages.count, 2)
        XCTAssertTrue(doc.pages[0].text.contains("First page"))
        XCTAssertTrue(doc.pages[1].text.contains("Second page"))
        XCTAssertTrue(doc.pages.allSatisfy { ($0.junk ?? 1) < JunkCheck.threshold })
    }

    func testTypeComesFromContentNotTheExtension() async throws {
        let pdfAsText = try pdf(["Hidden PDF"], name: "looks-like.txt")
        let asText = await extract(pdfAsText)
        XCTAssertEqual((try? asText.get())?.kind, .pdf)
        let docxAsRTF = dir.appendingPathComponent("looks-like.rtf")
        try FileManager.default.moveItem(at: try office("docx", "really docx"), to: docxAsRTF)
        let asRTF = await extract(docxAsRTF)
        XCTAssertEqual((try? asRTF.get())?.kind, .docx)
        let pptx = TestZip()
        pptx.add("ppt/presentation.xml", "<presentation/>")
        let r = await extract(try file("deck.docx", pptx.finish()))
        XCTAssertEqual(r, .failure(.unsupported("pptx")))
        let binary = await extract(try file("x.txt", Data([0x7F, 0x45, 0x4C, 0x46, 0, 0, 1, 0])))
        XCTAssertEqual(binary, .failure(.unsupported("unknown")))
    }

    // MARK: Hostile input

    func testZipBombDocxIsRefusedBeforeTheImporter() async throws {
        let bomb = TestZip.docx(body: TestZip.paragraph("x"), extra: [("word/media/bomb.bin", Data(count: 50 << 20))])
        let r = await extract(try file("bomb.docx", bomb))
        XCTAssertEqual(r, .failure(.tooLarge(.zipRatio)))
        // The same with its sizes lying: stopped while inflating.
        let z = TestZip()
        z.add("word/document.xml", Data(count: 50 << 20), declaredSize: 100)
        await assertFails(try file("liar.docx", z.finish()), .tooLarge(.zipRatio))
    }

    func testDoctypeAndDeepNestingInDocx() async throws {
        let laughs = TestZip.docx(body: "", extra: [("word/settings.xml", Data("<!DOCTYPE x [<!ENTITY a \"aaaa\">]><x>&a;</x>".utf8))])
        let r = await extract(try file("laughs.docx", laughs))
        guard case .failure(.unreadable(let why)) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(why.contains("DOCTYPE"))
        let deep = TestZip.docx(body: String(repeating: "<w:p>", count: 1000) + String(repeating: "</w:p>", count: 1000))
        await assertFails(try file("deep.docx", deep), .tooLarge(.xmlDepth))
    }

    func testTruncatedFiles() async throws {
        let full = try Data(contentsOf: try pdf(["Some text"]))
        let cut = await extract(try file("cut.pdf", full.prefix(full.count / 3)))
        guard case .failure(.unreadable) = cut else { return XCTFail("\(cut)") }
        let docx = try Data(contentsOf: try office("docx", "text"))
        let r = await extract(try file("cut.docx", docx.prefix(docx.count / 2)))
        // A cut zip has no directory: it isn't recognized as docx at all.
        XCTAssertEqual(r, .failure(.unsupported("zip")))
    }

    func testRTFThatHangsTheImporterIsKilledByTheClock() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "rtf_hangs_textkit", withExtension: "rtf", subdirectory: "Fixtures"))
        var caps = ExtractionCaps()
        caps.timeoutSeconds = 3
        let start = Date()
        let r = await extract(fixture, caps: caps)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        // It hangs on every system the spike tried; should a future one
        // parse it, a clean result is fine too.
        if case .failure(let e) = r { XCTAssertEqual(e, .timeout) }
        // The child's own RLIMIT_CPU ends it too, with the clock set far off.
        caps.timeoutSeconds = 60
        caps.cpuSeconds = 1
        let cpu = await extract(fixture, caps: caps)
        if case .failure(let e) = cpu { XCTAssertEqual(e, .timeout) }
    }

    func testMemoryLimit() async throws {
        // A text file becomes one ~1 MB page at a time, but a 60 MB HTML file
        // is one String: over a 40 MB limit.
        let html = "<html><body><p>" + String(repeating: "word ", count: 12_000_000) + "</p></body></html>"
        var caps = ExtractionCaps()
        caps.memoryBytes = 40 << 20
        caps.maxTextBytes = 100 << 20
        let url = try file("big.html", html)
        await assertFails(url, caps: caps, .memory)
        // Without the kernel's limit (its private symbol missing), polling alone.
        let polled = await extract(url, caps: caps, useJetsam: false)
        XCTAssertEqual(polled, .failure(.memory))
    }

    // MARK: Caps and fallbacks

    func testCaps() async throws {
        var caps = ExtractionCaps()
        caps.maxPages = 2
        await assertFails(try pdf(["a", "b", "c"]), caps: caps, .tooLarge(.pages))
        caps = ExtractionCaps()
        caps.maxTextBytes = 1000
        await assertFails(try file("long.txt", String(repeating: "x", count: 5000)), caps: caps, .tooLarge(.text))
        caps = ExtractionCaps()
        caps.maxFileBytes = 100
        await assertFails(try file("file.txt", String(repeating: "x", count: 200)), caps: caps, .tooLarge(.fileBytes))
    }

    func testWithoutTheSandboxOnlyAppleImportersStop() async throws {
        let off = ["--simulate-sandbox-failure"]
        for format in ["docx", "odt", "doc", "rtf"] {
            await assertFails(try office(format, "text"), extra: off, .unavailableOnSystem, "\(format)")
        }
        await assertExtracts(try office("html", "still works"), extra: off)
        await assertExtracts(try pdf(["still works"]), extra: off)
        await assertExtracts(try file("a.txt", "still works"), extra: off)
    }

    func testEmptyAndJunk() async throws {
        await assertFails(try file("empty.txt", ""), .empty)
        await assertFails(try pdf([""]), .empty)
        // cp1251 read as Latin-1: a text layer, but junk.
        await assertFails(try pdf(["Íàñòîÿùèé äîãîâîð çàêëþ÷åí ìåæäó ñòîðîíàìè"]), .junk)
    }

    func testBadInvocations() async throws {
        let missing = await extract(dir.appendingPathComponent("nope.txt"))
        guard case .failure(.unreadable) = missing else { return XCTFail("\(missing)") }
        let folder = await extract(dir)
        guard case .failure(.unreadable) = folder else { return XCTFail("\(folder)") }
    }
}
