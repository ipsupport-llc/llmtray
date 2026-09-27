import AppKit
import ExtractKit
import CoreText
import Foundation

// makesamples <outdir> [--skip-big]
// Builds every sample / hostile file the spike runs against. Nothing here
// touches the network or any user file.

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: makesamples <outdir> [--skip-big]"); exit(64) }
let outDir = URL(fileURLWithPath: args[1])
let skipBig = args.contains("--skip-big")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
func path(_ n: String) -> URL { outDir.appendingPathComponent(n) }
func write(_ n: String, _ d: Data) { try! d.write(to: path(n)); print("wrote \(n) \(d.count) bytes") }
func write(_ n: String, _ s: String) { write(n, Data(s.utf8)) }

// MARK: text corpus

let ruPara = """
Договор поставки № 17/2024 заключён между ООО «Ромашка» и индивидуальным предпринимателем \
Кузнецовым К. К. Поставщик обязуется передать покупателю кирпич керамический, а покупатель — \
принять и оплатить товар в течение десяти календарных дней. Съешь же ещё этих мягких французских булок, да выпей чаю.
"""
let enPara = """
The quick brown fox jumps over the lazy dog. Section 4.2 of the agreement sets the delivery \
schedule; penalties accrue at 0.1% per day of delay, capped at 10% of the contract value.
"""

func corpus(pages: Int, paraPerPage: Int = 6) -> [String] {
    (1...pages).map { p in
        (0..<paraPerPage).map { i in
            "Страница \(p), абзац \(i + 1). " + (i % 2 == 0 ? ruPara : enPara)
        }.joined(separator: "\n\n")
    }
}

// MARK: PDF via CoreText

func makePDF(_ name: String, pages: [String], size: CGSize = CGSize(width: 595, height: 842)) {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
    let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    for text in pages {
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0),
                                             CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    write(name, data as Data)
}

// A hand-written PDF: `pages` are content streams using font /F1, whose
// ToUnicode CMap is `cmap` (nil: none, standard WinAnsi decoding).
func rawPDF(_ name: String, pages: [String], cmap: String?, mediaBox: String = "[0 0 595 842]", countOverride: Int? = nil) {
    var objs: [String] = []
    // 1 catalog, 2 pages, 3 font, 4 cmap, then page/content pairs
    let n = pages.count
    let kids = (0..<n).map { "\(5 + 2 * $0) 0 R" }.joined(separator: " ")
    objs.append("<< /Type /Catalog /Pages 2 0 R >>")
    objs.append("<< /Type /Pages /Kids [\(kids)] /Count \(countOverride ?? n) >>")
    let tu = cmap != nil ? " /ToUnicode 4 0 R" : ""
    objs.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding\(tu) >>")
    let cm = cmap ?? ""
    objs.append("<< /Length \(cm.utf8.count) >>\nstream\n\(cm)\nendstream")
    for (i, p) in pages.enumerated() {
        objs.append("<< /Type /Page /Parent 2 0 R /MediaBox \(mediaBox) /Resources << /Font << /F1 3 0 R >> >> /Contents \(6 + 2 * i) 0 R >>")
        objs.append("<< /Length \(p.utf8.count) >>\nstream\n\(p)\nendstream")
    }
    var out = "%PDF-1.4\n%\u{e2}\u{e3}\u{cf}\u{d3}\n"
    var body = Data(out.utf8)
    var offsets: [Int] = []
    for (i, o) in objs.enumerated() {
        offsets.append(body.count)
        body.append(Data("\(i + 1) 0 obj\n\(o)\nendobj\n".utf8))
    }
    let xref = body.count
    out = "xref\n0 \(objs.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
    out += "trailer\n<< /Size \(objs.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    body.append(Data(out.utf8))
    write(name, body)
}

func textStream(_ bytesLines: [[UInt8]]) -> String {
    var s = "BT /F1 12 Tf 50 780 Td 14 TL\n"
    for l in bytesLines { s += "<" + l.map { String(format: "%02X", $0) }.joined() + "> Tj T*\n" }
    return s + "ET"
}

/// ToUnicode CMap mapping single bytes to the given code points.
func cmap(_ map: [UInt8: UInt32]) -> String {
    let entries = map.sorted { $0.key < $1.key }.map { String(format: "<%02X> <%04X>", $0.key, $0.value) }
    var chunks: [String] = []
    for i in stride(from: 0, to: entries.count, by: 100) {
        let part = entries[i..<min(i + 100, entries.count)]
        chunks.append("\(part.count) beginbfchar\n" + part.joined(separator: "\n") + "\nendbfchar")
    }
    return """
    /CIDInit /ProcSet findresource begin 12 dict begin begincmap
    /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
    /CMapName /Spike-UCS def /CMapType 2 def
    1 begincodespacerange <00> <FF> endcodespacerange
    \(chunks.joined(separator: "\n"))
    endcmap CMapName currentdict /CMap defineresource pop end end
    """
}

let cp1251 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
let ruLines = ruPara.components(separatedBy: ". ").map { $0 + "." }
let ruBytes = ruLines.map { [UInt8]($0.data(using: cp1251, allowLossyConversion: true)!) }

// Correct map: cp1251 byte -> the Cyrillic it means.
var goodMap: [UInt8: UInt32] = [:]
for b in 0x20...0xFF {
    if let s = String(data: Data([UInt8(b)]), encoding: cp1251), let u = s.unicodeScalars.first { goodMap[UInt8(b)] = u.value }
}
// Broken map #1: "к"/"К" -> U+0138 "ĸ" (what PDFKit returned in the ADR test), "о" -> Latin "o", "е" -> Latin "e".
var lookalike = goodMap
lookalike[0xEA] = 0x0138; lookalike[0xCA] = 0x0138; lookalike[0xEE] = 0x6F; lookalike[0xE5] = 0x65
// Broken map #2: everything above ASCII -> Private Use Area (unmapped glyph ids).
var puaMap = goodMap
for b in 0xC0...0xFF { puaMap[UInt8(b)] = 0xE000 + UInt32(b) }
// Broken map #3: everything above ASCII -> U+FFFD.
var fffdMap = goodMap
for b in 0xC0...0xFF { fffdMap[UInt8(b)] = 0xFFFD }
// Broken map #4: glyph codes mapped to control characters / symbols.
var symMap = goodMap
for b in 0xC0...0xFF { symMap[UInt8(b)] = [0x21, 0x23, 0x25, 0x26, 0x2A, 0x40, 0x5E, 0x7E][b % 8] }

let page = textStream(ruBytes)
rawPDF("pdf_tounicode_good.pdf", pages: [page], cmap: cmap(goodMap))
rawPDF("pdf_tounicode_lookalike.pdf", pages: [page], cmap: cmap(lookalike))
rawPDF("pdf_tounicode_pua.pdf", pages: [page], cmap: cmap(puaMap))
rawPDF("pdf_tounicode_fffd.pdf", pages: [page], cmap: cmap(fffdMap))
rawPDF("pdf_tounicode_symbols.pdf", pages: [page], cmap: cmap(symMap))
// No ToUnicode at all: cp1251 bytes decoded as WinAnsi -> the classic "Äîãîâîð" mojibake.
rawPDF("pdf_no_tounicode_mojibake.pdf", pages: [page], cmap: nil)
// Mixed: page 1 fine English, page 2 mojibake -- the junk check is per page.
rawPDF("pdf_mixed_pages.pdf", pages: [textStream([Array("Plain English page, fine text layer.".utf8)] + [[UInt8]](repeating: Array("The quick brown fox jumps over the lazy dog.".utf8), count: 5)), page], cmap: nil)

// Realistic: 100 pages of Cyrillic + Latin through CoreText.
makePDF("pdf_ru_100p.pdf", pages: corpus(pages: 100))
// Hostile PDFs.
let good = try! Data(contentsOf: path("pdf_ru_100p.pdf"))
write("pdf_truncated.pdf", good.prefix(good.count / 2))
var corrupt = good
for i in stride(from: corrupt.count / 4, to: corrupt.count * 3 / 4, by: 97) { corrupt[i] = UInt8((i * 31) & 0xFF) }
write("pdf_corrupt.pdf", corrupt)
write("pdf_header_only.pdf", Data("%PDF-1.7\n".utf8) + Data((0..<100_000).map { UInt8(($0 * 7919) & 0xFF) }))
rawPDF("pdf_count_lie.pdf", pages: [textStream([Array("One real page.".utf8)])], cmap: nil, countOverride: 2_000_000_000)
rawPDF("pdf_huge_mediabox.pdf", pages: [textStream([Array("Page 1e9 points wide.".utf8)])], cmap: nil, mediaBox: "[0 0 1000000000 1000000000]")
// Real 30k-page PDF (tiny pages) for the page cap.
if !skipBig { makePDF("pdf_30000p.pdf", pages: Array(repeating: "x", count: 30_000), size: CGSize(width: 72, height: 72)) }
// A page-tree loop: /Pages whose Kids include itself.
write("pdf_pagetree_loop.pdf", Data("""
%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [2 0 R 3 0 R] /Count 2 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >> endobj
trailer << /Root 1 0 R >>
%%EOF
""".utf8))

// MARK: docx / doc / rtf / odt / html via textutil from one HTML source

func htmlDoc(_ pages: [String], title: String) -> String {
    var s = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(title)</title><style>p{margin:0}</style><script>var x='<p>not text</p>';</script></head><body>"
    s += "<h1>\(title)</h1><table border=1><tr><th>Товар</th><th>Кол-во</th><th>Цена</th></tr><tr><td>Кирпич</td><td>1&nbsp;000</td><td>12,50&nbsp;₽</td></tr><tr><td>Цемент</td><td>40</td><td>480&nbsp;₽</td></tr></table>"
    for p in pages { for para in p.components(separatedBy: "\n\n") { s += "<p>\(para)</p>" } }
    return s + "<!-- a comment <p>hidden</p> --><ul><li>первый пункт</li><li>second item &amp; more &laquo;quoted&raquo;</li></ul></body></html>"
}
let smallHTML = htmlDoc(corpus(pages: 2), title: "Образец документа")
write("doc_source_small.html", smallHTML)
let bigHTML = htmlDoc(corpus(pages: 100), title: "Большой документ")
write("doc_source_100p.html", bigHTML)

func textutil(_ src: String, _ fmt: String, _ dst: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
    p.arguments = ["-convert", fmt, "-output", path(dst).path, path(src).path]
    try! p.run(); p.waitUntilExit()
    print("textutil \(fmt) -> \(dst): \(p.terminationStatus)")
}
for (fmt, ext) in [("docx", "docx"), ("doc", "doc"), ("rtf", "rtf"), ("odt", "odt"), ("wordml", "xml")] {
    textutil("doc_source_small.html", fmt, "doc_small.\(ext)")
    textutil("doc_source_100p.html", fmt, "doc_100p.\(ext)")
}

// MARK: HTML hostile: remote resources (port from env SPIKE_PORT, default 18777)

let port = ProcessInfo.processInfo.environment["SPIKE_PORT"] ?? "18777"
let remote = "http://127.0.0.1:\(port)"
write("html_remote.html", """
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Remote refs</title>
<link rel="stylesheet" href="\(remote)/style.css"><script src="\(remote)/script.js"></script>
<style>@import url("\(remote)/import.css"); body { background: url(\(remote)/bg.png) }</style>
<meta http-equiv="refresh" content="0; url=\(remote)/refresh">
</head><body><p>Visible text with remote image <img src="\(remote)/img.png"> and iframe.</p>
<iframe src="\(remote)/frame.html"></iframe><object data="\(remote)/obj.swf"></object>
<video src="\(remote)/v.mp4"></video><img srcset="\(remote)/srcset.png 2x"></body></html>
""")

// docx with an external image relationship (TargetMode="External").
func docx(_ bodyXML: String, rels: String = "", extra: [(String, Data)] = []) -> Data {
    let z = ZipWriter()
    z.add("[Content_Types].xml", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
    """)
    z.add("_rels/.rels", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
    """)
    z.add("word/_rels/document.xml.rels", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
    """)
    z.add("word/document.xml", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(bodyXML)</w:body></w:document>
    """)
    for (n, d) in extra { z.add(n, d) }
    return z.finish()
}
let extImage = """
<w:p><w:r><w:t>Docx with an external (linked) image and hyperlink.</w:t></w:r></w:p>
<w:p><w:r><w:drawing><wp:inline><wp:extent cx="952500" cy="952500"/><wp:docPr id="1" name="p"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="p"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:link="rIdImg"/></pic:blipFill><pic:spPr/></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> INCLUDEPICTURE "\(remote)/field.png" \\d </w:instrText></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
"""
write("docx_external_image.docx", docx(extImage, rels: """
<Relationship Id="rIdImg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="\(remote)/docx_img.png" TargetMode="External"/>
"""))
write("rtf_remote.rtf", "{\\rtf1\\ansi RTF with an INCLUDEPICTURE field. {\\field{\\*\\fldinst INCLUDEPICTURE \"\(remote)/rtf.png\" \\\\d}{\\fldrslt }}\\par}")

// MARK: xlsx / pptx by hand

func xlsx(sheets: [(name: String, xml: String, hidden: Bool)], shared: [String], sharedXMLOverride: String? = nil) -> Data {
    let z = ZipWriter()
    let overrides = sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined()
    z.add("[Content_Types].xml", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\(overrides)<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
    """)
    z.add("_rels/.rels", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
    """)
    let sheetEls = sheets.enumerated().map { "<sheet name=\"\($1.name)\" sheetId=\"\($0 + 1)\"\($1.hidden ? " state=\"hidden\"" : "") r:id=\"rId\($0 + 1)\"/>" }.joined()
    z.add("xl/workbook.xml", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><workbookPr/><sheets>\(sheetEls)</sheets></workbook>
    """)
    let rels = sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined()
    z.add("xl/_rels/workbook.xml.rels", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)<Relationship Id="rIdS" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/><Relationship Id="rIdT" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
    """)
    let esc: (String) -> String = { $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
    z.add("xl/sharedStrings.xml", sharedXMLOverride ?? """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(shared.count)" uniqueCount="\(shared.count)">\(shared.map { "<si><t xml:space=\"preserve\">\(esc($0))</t></si>" }.joined())<si><r><t>Rich </t></r><r><rPr><b/></rPr><t>text</t></r><rPh><t>ignored-phonetic</t></rPh></si></sst>
    """)
    // xf 0 general, 1 builtin date (14), 2 custom date (dd.mm.yyyy), 3 custom number, 4 datetime (22)
    z.add("xl/styles.xml", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="2"><numFmt numFmtId="164" formatCode="dd\\.mm\\.yyyy"/><numFmt numFmtId="165" formatCode="#,##0.00\\ &quot;₽&quot;"/></numFmts><cellXfs count="5"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="165"/><xf numFmtId="22"/></cellXfs></styleSheet>
    """)
    for (i, s) in sheets.enumerated() { z.add("xl/worksheets/sheet\(i + 1).xml", s.xml) }
    return z.finish()
}

func sheetXML(_ rowsXML: String) -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rowsXML)</sheetData></worksheet>"
}

// 5k-row sheet: header in shared strings; columns: id, product (shared), city (inline), qty, price (custom fmt), date (builtin 14), date (custom), timestamp, bool
let products = ["Кирпич керамический", "Цемент М500", "Песок речной", "Щебень гранитный", "Brick, red", "Sand & gravel", "Арматура А500С", "Доска обрезная"]
let cities = ["Москва", "Санкт-Петербург", "Казань", "Новосибирск", "London", "Екатеринбург"]
var shared = ["№", "Товар", "Город", "Количество", "Цена", "Дата поставки", "Дата оплаты", "Отметка времени", "Оплачено"]
let prodBase = shared.count
shared += products
var rows = "<row r=\"1\">" + (0..<9).map { "<c r=\"\(["A", "B", "C", "D", "E", "F", "G", "H", "I"][$0])1\" t=\"s\"><v>\($0)</v></c>" }.joined() + "</row>"
for r in 2...5001 {
    let serial = 45_000 + (r % 700)
    rows += "<row r=\"\(r)\"><c r=\"A\(r)\"><v>\(r - 1)</v></c><c r=\"B\(r)\" t=\"s\"><v>\(prodBase + r % products.count)</v></c>"
    rows += "<c r=\"C\(r)\" t=\"inlineStr\"><is><t>\(cities[r % cities.count])</t></is></c><c r=\"D\(r)\"><v>\(r * 3 % 997)</v></c>"
    rows += "<c r=\"E\(r)\" s=\"3\"><v>\(Double(r % 1000) * 1.25 + 0.5)</v></c><c r=\"F\(r)\" s=\"1\"><v>\(serial)</v></c><c r=\"G\(r)\" s=\"2\"><v>\(serial + 10)</v></c>"
    // skip column H on odd rows (sparse cells), bool in I
    if r % 2 == 0 { rows += "<c r=\"H\(r)\" s=\"4\"><v>\(Double(serial) + 0.5)</v></c>" }
    rows += "<c r=\"I\(r)\" t=\"b\"><v>\(r % 3 == 0 ? 1 : 0)</v></c></row>"
}
let second = sheetXML("<row r=\"1\"><c r=\"A1\" t=\"s\"><v>\(shared.count)</v></c><c r=\"C1\" t=\"str\"><v>formula text</v></c></row><row r=\"3\"><c r=\"B3\" t=\"e\"><v>#DIV/0!</v></c></row>")
write("xlsx_5000rows.xlsx", xlsx(sheets: [("Поставки", sheetXML(rows), false), ("Прочее", second, true)], shared: shared))

// Billion laughs in sharedStrings.xml.
var lol = "<?xml version=\"1.0\"?>\n<!DOCTYPE sst [\n<!ENTITY lol \"lollollollollollollollollollol\">\n"
for i in 1...9 { lol += "<!ENTITY lol\(i) \"" + String(repeating: "&lol\(i == 1 ? "" : String(i - 1));", count: 10) + "\">\n" }
lol += "]>\n<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>&lol9;</t></si></sst>"
write("xlsx_billion_laughs.xlsx", xlsx(sheets: [("S", sheetXML("<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row>"), false)], shared: [], sharedXMLOverride: lol))
write("xml_billion_laughs.xml", lol)
// External entity (XXE) pointing at a local file and the listener.
let xxe = "<?xml version=\"1.0\"?>\n<!DOCTYPE sst [<!ENTITY x SYSTEM \"file:///etc/hosts\"><!ENTITY y SYSTEM \"\(remote)/xxe\">]>\n<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>&x;&y;</t></si></sst>"
write("xlsx_xxe.xlsx", xlsx(sheets: [("S", sheetXML("<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row>"), false)], shared: [], sharedXMLOverride: xxe))
write("xml_xxe.xml", xxe)
// Deeply nested XML in a sheet (and as plain XML for the raw-parser probe).
let depth = 200_000
let deep = sheetXML("<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is>" + String(repeating: "<r>", count: depth) + "<t>deep</t>" + String(repeating: "</r>", count: depth) + "</is></c></row>")
write("xlsx_deep_nesting.xlsx", xlsx(sheets: [("Deep", deep, false)], shared: []))
write("xml_deep.xml", String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth))

// MARK: zip bombs

func zeros(_ total: Int, prefix: String = "", suffix: String = "") -> () -> Data? {
    var left = total
    var pre: Data? = Data(prefix.utf8)
    var suf: Data? = Data(suffix.utf8)
    let block = Data(repeating: 0x41, count: 1 << 20)   // "AAAA..." -- valid XML text
    return {
        if let p = pre { pre = nil; return p }
        if left > 0 { let n = min(left, block.count); left -= n; return n == block.count ? block : block.prefix(n) }
        if let s = suf { suf = nil; return s }
        return nil
    }
}

let bombBytes = skipBig ? 64 << 20 : 2_000_000_000   // < 4 GiB so no zip64 is needed
do {
    // docx whose document.xml inflates to ~2 GB of "A" (honest sizes).
    let d = ZipWriter.deflate(zeros(bombBytes, prefix: "<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>", suffix: "</w:t></w:r></w:p></w:body></w:document>"))
    for (name, lie) in [("zipbomb_honest.docx", false), ("zipbomb_lying_size.docx", true)] {
        let z = ZipWriter()
        z.add("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>")
        z.add("_rels/.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>")
        z.addRaw("word/document.xml", method: 8, payload: d.data, size: d.size, crc: d.crc, declaredSize: lie ? 4096 : nil)
        write(name, z.finish())
    }
    // xlsx whose sheet1.xml is the bomb.
    let s = ZipWriter.deflate(zeros(bombBytes, prefix: "<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>", suffix: "</t></is></c></row></sheetData></worksheet>"))
    let base = xlsx(sheets: [("Bomb", "PLACEHOLDER", false)], shared: [])
    // rebuild with the bomb member
    let z = ZipWriter()
    let za = try! ZipArchive(data: base, limits: Limits())
    for n in za.order where n != "xl/worksheets/sheet1.xml" { z.add(n, try! za.read(n)) }
    z.addRaw("xl/worksheets/sheet1.xml", method: 8, payload: s.data, size: s.size, crc: s.crc)
    write("zipbomb.xlsx", z.finish())
    // Nested: a docx whose embeddings hold zips of zips (42.zip style), 10 x 10 x 100 MB.
    let leaf = ZipWriter.deflate(zeros(100 << 20))
    let l1 = ZipWriter(); for i in 0..<10 { l1.addRaw("leaf\(i).bin", method: 8, payload: leaf.data, size: leaf.size, crc: leaf.crc) }
    let l1d = l1.finish()
    let l2 = ZipWriter(); for i in 0..<10 { l2.add("l1_\(i).zip", l1d, store: true) }
    let l2d = l2.finish()
    write("zipbomb_nested.docx", docx("<w:p><w:r><w:t>Nested bomb in word/embeddings.</w:t></w:r></w:p>", extra: [("word/embeddings/oleObject1.zip", l2d)]))
    // Many entries (entry-count cap).
    let many = ZipWriter()
    many.add("[Content_Types].xml", "<Types/>"); many.add("word/document.xml", "<w:document xmlns:w=\"x\"/>")
    for i in 0..<100_000 { many.add("f/\(i)", Data(), store: true) }
    write("zip_100k_entries.docx", many.finish())
}

// pptx: 3 slides, notes, a table
func pptx() -> Data {
    let z = ZipWriter()
    z.add("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/></Types>")
    z.add("_rels/.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
    let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    // slide order deliberately differs from file names: slide3.xml is shown first
    z.add("ppt/presentation.xml", "<?xml version=\"1.0\"?><p:presentation \(ns)><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId3\"/><p:sldId id=\"257\" r:id=\"rId1\"/><p:sldId id=\"258\" r:id=\"rId2\"/></p:sldIdLst></p:presentation>")
    z.add("ppt/_rels/presentation.xml.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + (1...3).map { "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\($0).xml\"/>" }.joined() + "</Relationships>")
    func sp(_ paras: [String], ph: String? = nil) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"s\"/><p:cNvSpPr/><p:nvPr>\(ph.map { "<p:ph type=\"\($0)\"/>" } ?? "")</p:nvPr></p:nvSpPr><p:txBody>" + paras.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined() + "</p:txBody></p:sp>"
    }
    let slides = [
        sp(["Итоги квартала"], ph: "title") + sp(["Выручка выросла на 12%", "Новых клиентов: 48"]),
        sp(["Second slide title"], ph: "title") + "<p:graphicFrame><a:graphic><a:graphicData><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Регион</a:t></a:r></a:p></a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>Продажи</a:t></a:r></a:p></a:txBody></a:tc></a:tr><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Север</a:t></a:r></a:p></a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>1 200</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>",
        sp(["Первый слайд (slide3.xml)"], ph: "ctrTitle") + sp(["Line one<", "Line two with a break"]).replacingOccurrences(of: "Line one<", with: "Line one</a:t></a:r><a:br/><a:r><a:t>after break"),
    ]
    for (i, s) in slides.enumerated() {
        z.add("ppt/slides/slide\(i + 1).xml", "<?xml version=\"1.0\"?><p:sld \(ns)><p:cSld><p:spTree>\(s)</p:spTree></p:cSld></p:sld>")
        z.add("ppt/slides/_rels/slide\(i + 1).xml.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId9\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide\" Target=\"../notesSlides/notesSlide\(i + 1).xml\"/></Relationships>")
        z.add("ppt/notesSlides/notesSlide\(i + 1).xml", "<?xml version=\"1.0\"?><p:notes \(ns)><p:cSld><p:spTree>" + sp([], ph: "sldImg") + sp(["Заметки докладчика к слайду \(i + 1)"], ph: "body") + sp(["\(i + 1)"], ph: "sldNum") + "</p:spTree></p:cSld></p:notes>")
    }
    return z.finish()
}
write("pptx_3slides.pptx", pptx())

// MARK: detection: content vs extension

try? FileManager.default.removeItem(at: path("misnamed_xlsx.docx"))
try! FileManager.default.copyItem(at: path("xlsx_5000rows.xlsx"), to: path("misnamed_xlsx.docx"))
try? FileManager.default.removeItem(at: path("misnamed_pdf.txt"))
try! FileManager.default.copyItem(at: path("pdf_tounicode_good.pdf"), to: path("misnamed_pdf.txt"))
try? FileManager.default.removeItem(at: path("misnamed_doc.xls"))
try! FileManager.default.copyItem(at: path("doc_small.doc"), to: path("misnamed_doc.xls"))
write("text_cp1251.txt", ruPara.data(using: cp1251)!)
write("text_utf16.txt", Data([0xFF, 0xFE]) + ruPara.data(using: .utf16LittleEndian)!)
write("binary_random.bin", Data((0..<65_536).map { UInt8(($0 * 2_654_435_761 >> 7) & 0xFF) }))

// MARK: 1 GB text

if !skipBig {
    let fh = FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: path("text_1gb.txt").path, contents: nil); return path("text_1gb.txt").path }())!
    let block = Data(String(repeating: ruPara + "\n" + enPara + "\n", count: 1500).utf8)
    var written = 0
    while written < 1_000_000_000 { fh.write(block); written += block.count }
    fh.closeFile()
    print("wrote text_1gb.txt \(written) bytes")
}
print("done")
