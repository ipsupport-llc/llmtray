import XCTest
@testable import LLMTrayCore

final class SpreadsheetTextTests: XCTestCase {
    private func xlsx(rows: String, shared: String? = nil, styles: String? = nil, date1904: Bool = false,
                      secondSheet: String? = nil) -> Data {
        let z = TestZip()
        z.add("[Content_Types].xml", "<Types/>")
        let pr = date1904 ? "<workbookPr date1904=\"1\"/>" : ""
        let second = secondSheet == nil ? "" : "<sheet name=\"Notes\" sheetId=\"2\" r:id=\"rId2\"/>"
        z.add("xl/workbook.xml", """
            <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\(pr)\
            <sheets><sheet name="Budget" sheetId="1" r:id="rId1"/>\(second)</sheets></workbook>
            """)
        z.add("xl/_rels/workbook.xml.rels", """
            <Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rId2" Target="/xl/worksheets/sheet2.xml"/></Relationships>
            """)
        if let shared { z.add("xl/sharedStrings.xml", "<sst>\(shared)</sst>") }
        if let styles { z.add("xl/styles.xml", styles) }
        z.add("xl/worksheets/sheet1.xml", "<worksheet><sheetData>\(rows)</sheetData></worksheet>")
        if let secondSheet { z.add("xl/worksheets/sheet2.xml", "<worksheet><sheetData>\(secondSheet)</sheetData></worksheet>") }
        return z.finish()
    }

    func testXLSXCellsStringsNumbersBooleansAndFormulaResults() throws {
        let data = xlsx(rows: """
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="D1" t="inlineStr"><is><t>Note</t></is></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>0.30000000000000004</v></c><c r="C2" t="b"><v>1</v></c>\
            <c r="D2" t="str"><f>A2&amp;"!"</f><v>Rent!</v></c></row>
            <row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3"><f>B2*2</f><v>1200</v></c></row>
            """, shared: "<si><t>Item</t></si><si><r><t>Am</t></r><r><t>ount</t></r></si><si><t>Rent</t></si><si><t>Food</t><rPh><t>ふーど</t></rPh></si>")
        let pages = try SpreadsheetText.pages(data, kind: .xlsx, caps: ExtractionCaps())
        XCTAssertEqual(pages, ["Sheet \"Budget\", rows 1–3\nItem | Amount |  | Note\nRent | 0.3 | TRUE | Rent!\nFood | 1200"])
    }

    func testXLSXDatesFromDateStyles() throws {
        let styles = """
            <styleSheet><numFmts><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/><numFmt numFmtId="165" formatCode="0.00&quot;d&quot;"/></numFmts>\
            <cellXfs><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="165"/></cellXfs></styleSheet>
            """
        let data = xlsx(rows: """
            <row r="1"><c r="A1" s="1"><v>45000</v></c><c r="B1" s="2"><v>45000.5625</v></c><c r="C1" s="3"><v>3.5</v></c><c r="D1"><v>45000</v></c></row>
            """, styles: styles)
        let text = try SpreadsheetText.pages(data, kind: .xlsx, caps: ExtractionCaps()).joined()
        XCTAssertTrue(text.hasSuffix("2023-03-15 | 2023-03-15 13:30:00 | 3.5 | 45000"), text)
        let mac = xlsx(rows: "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>0</v></c></row>", styles: styles, date1904: true)
        XCTAssertTrue(try SpreadsheetText.pages(mac, kind: .xlsx, caps: ExtractionCaps()).joined().hasSuffix("1904-01-01"))
    }

    func testEveryPageCarriesTheSheetAndItsHeader() throws {
        var rows = "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Name</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Score</t></is></c></row>"
        for r in 2...150 { rows += "<row r=\"\(r)\"><c r=\"A\(r)\" t=\"inlineStr\"><is><t>p\(r)</t></is></c><c r=\"B\(r)\"><v>\(r)</v></c></row>" }
        let pages = try SpreadsheetText.pages(xlsx(rows: rows, secondSheet: "<row r=\"5\"><c r=\"C5\"><v>7</v></c></row>"),
                                              kind: .xlsx, caps: ExtractionCaps())
        XCTAssertEqual(pages.count, 4)
        XCTAssertTrue(pages[0].hasPrefix("Sheet \"Budget\", rows 1–60\nName | Score\np2 | 2"))
        XCTAssertTrue(pages[1].hasPrefix("Sheet \"Budget\", rows 61–120\nName | Score\np61 | 61"))
        XCTAssertTrue(pages[2].hasPrefix("Sheet \"Budget\", rows 121–150\nName | Score\np121"))
        XCTAssertEqual(pages[3], "Sheet \"Notes\", rows 5–5\n |  | 7")
    }

    func testCellCapStopsAHugeSheet() {
        var rows = ""
        for r in 1...3 { rows += "<row r=\"\(r)\">" + (0..<10).map { "<c><v>\($0)</v></c>" }.joined() + "</row>" }
        let data = xlsx(rows: rows)
        XCTAssertNoThrow(try SpreadsheetText.pages(data, kind: .xlsx, caps: ExtractionCaps()))
        var caps = ExtractionCaps()
        caps.maxTextBytes = 10
        XCTAssertThrowsError(try SpreadsheetText.pages(data, kind: .xlsx, caps: caps))
    }

    func testHostileXMLIsRefused() {
        let z = TestZip()
        z.add("xl/workbook.xml", "<!DOCTYPE x [<!ENTITY a \"aaaa\">]><workbook><sheets/></workbook>")
        XCTAssertThrowsError(try SpreadsheetText.pages(z.finish(), kind: .xlsx, caps: ExtractionCaps()))
    }

    func testODS() throws {
        let z = TestZip()
        z.add("mimetype", "application/vnd.oasis.opendocument.spreadsheet", store: true)
        z.add("content.xml", """
            <office:document-content xmlns:office="o" xmlns:table="t" xmlns:text="x"><office:body><office:spreadsheet>
            <table:table table:name="Stock">
            <table:table-row><table:table-cell office:value-type="string"><text:p>Part</text:p></table:table-cell>\
            <table:table-cell office:value-type="string"><text:p>Qty</text:p></table:table-cell>\
            <table:table-cell office:value-type="string"><text:p>Since</text:p></table:table-cell></table:table-row>
            <table:table-row><table:table-cell office:value-type="string"><text:p>Bolt<text:s text:c="2"/>M6</text:p></table:table-cell>\
            <table:table-cell office:value-type="float" office:value="40"><text:p>40</text:p></table:table-cell>\
            <table:table-cell office:value-type="date" office:date-value="2026-01-02"><text:p>02.01.26</text:p></table:table-cell>\
            <table:table-cell table:number-columns-repeated="16380"/></table:table-row>
            <table:table-row table:number-rows-repeated="1048574"><table:table-cell table:number-columns-repeated="16384"/></table:table-row>
            </table:table></office:spreadsheet></office:body></office:document-content>
            """)
        let pages = try SpreadsheetText.pages(z.finish(), kind: .ods, caps: ExtractionCaps())
        XCTAssertEqual(pages, ["Sheet \"Stock\", rows 1–2\nPart | Qty | Since\nBolt  M6 | 40 | 2026-01-02"])
    }

    func testColumnLetters() {
        XCTAssertEqual(XLSX.column("A1"), 0)
        XCTAssertEqual(XLSX.column("Z9"), 25)
        XCTAssertEqual(XLSX.column("AB12"), 27)
        XCTAssertEqual(XLSX.column("$C$5"), 2)
        XCTAssertEqual(XLSX.column("XFD1"), 16383)
        XCTAssertNil(XLSX.column("12"))
        // No overflow on a malformed reference.
        XCTAssertNil(XLSX.column(String(repeating: "Z", count: 40) + "1"))
    }

    func testEarly1900Dates() {
        XCTAssertEqual(XLSX.date(1, date1904: false), "1900-01-01")
        XCTAssertEqual(XLSX.date(59, date1904: false), "1900-02-28")
        XCTAssertEqual(XLSX.date(60, date1904: false), "1900-02-29")
        XCTAssertEqual(XLSX.date(60.5, date1904: false), "1900-02-29 12:00:00")
        XCTAssertEqual(XLSX.date(61, date1904: false), "1900-03-01")
        XCTAssertEqual(XLSX.date(45000.5625, date1904: false), "2023-03-15 13:30:00")
        XCTAssertEqual(XLSX.date(0.25, date1904: false), "06:00:00")
    }

    func testRelationshipTargets() {
        XCTAssertEqual(XLSX.partPath("worksheets/sheet1.xml"), "xl/worksheets/sheet1.xml")
        XCTAssertEqual(XLSX.partPath("/xl/worksheets/sheet2.xml"), "xl/worksheets/sheet2.xml")
        XCTAssertEqual(XLSX.partPath("../xl/worksheets/./sheet3.xml"), "xl/worksheets/sheet3.xml")
    }

    func testInlinePhoneticsLeftOut() throws {
        let data = xlsx(rows: "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Food</t><rPh><t>ふーど</t></rPh></is></c></row>")
        XCTAssertEqual(try SpreadsheetText.pages(data, kind: .xlsx, caps: ExtractionCaps()), ["Sheet \"Budget\", rows 1–1\nFood"])
    }

    private func ods(_ rows: String) -> Data {
        let z = TestZip()
        z.add("mimetype", "application/vnd.oasis.opendocument.spreadsheet", store: true)
        z.add("content.xml", """
            <office:document-content xmlns:office="o" xmlns:table="t" xmlns:text="x"><office:body><office:spreadsheet>\
            <table:table table:name="S">\(rows)</table:table></office:spreadsheet></office:body></office:document-content>
            """)
        return z.finish()
    }

    func testODSRepeatedContentRowsStopAtTheTextCap() {
        let row = "<table:table-row table:number-rows-repeated=\"10000\"><table:table-cell office:value-type=\"string\"><text:p>\(String(repeating: "x", count: 200))</text:p></table:table-cell></table:table-row>"
        var caps = ExtractionCaps()
        caps.maxTextBytes = 1_000_000
        XCTAssertThrowsError(try SpreadsheetText.pages(ods(String(repeating: row, count: 5)), kind: .ods, caps: caps)) {
            XCTAssertEqual($0 as? ExtractionError, .tooLarge(.text))
        }
    }

    func testLineBytesMatchesTheLine() {
        for cells in [["a", "", "bc", "", ""], ["x"], ["", "y"], []] {
            XCTAssertEqual(SpreadsheetText.lineBytes(cells), SpreadsheetText.line(cells).utf8.count, "\(cells)")
        }
    }

    func testODSContentRowWithTrailingEmptyRepeatsIsKept() throws {
        let row = "<table:table-row table:number-rows-repeated=\"3\"><table:table-cell office:value-type=\"string\"><text:p>v</text:p></table:table-cell><table:table-cell table:number-columns-repeated=\"16383\"/></table:table-row>"
        XCTAssertEqual(try SpreadsheetText.pages(ods(row), kind: .ods, caps: ExtractionCaps()), ["Sheet \"S\", rows 1–3\nv\nv\nv"])
    }

    func testODSSpaceCountIsBounded() throws {
        let data = ods("<table:table-row><table:table-cell><text:p>a<text:s text:c=\"999999999\"/>b</text:p></table:table-cell></table:table-row>")
        let page = try SpreadsheetText.pages(data, kind: .ods, caps: ExtractionCaps()).joined()
        XCTAssertTrue(page.hasSuffix("a" + String(repeating: " ", count: ODS.maxSpaces) + "b"), page)
    }

    func testODSNumberWithoutText() throws {
        let data = ods("<table:table-row><table:table-cell office:value-type=\"float\" office:value=\"2.50\"/></table:table-row>")
        XCTAssertEqual(try SpreadsheetText.pages(data, kind: .ods, caps: ExtractionCaps()), ["Sheet \"S\", rows 1–1\n2.5"])
    }
}
