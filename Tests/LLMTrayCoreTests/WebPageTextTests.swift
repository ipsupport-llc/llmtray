import XCTest
@testable import LLMTrayCore

final class WebPageTextTests: XCTestCase {
    func testAddresses() {
        let publicResolve: (String) -> [MCPOAuth.IPAddress] = { _ in [.v4(0x5DB8_D822)] }   // 93.184.216.34
        let lanResolve: (String) -> [MCPOAuth.IPAddress] = { _ in [.v4(0xC0A8_0101)] }      // 192.168.1.1
        XCTAssertEqual(try? WebPageText.address("example.com/docs", resolve: publicResolve).get().absoluteString, "https://example.com/docs")
        XCTAssertEqual(try? WebPageText.address(" http://example.com ", resolve: publicResolve).get().absoluteString, "http://example.com")
        XCTAssertEqual(WebPageText.address("ftp://example.com", resolve: publicResolve), .failure(.notWeb))
        XCTAssertEqual(WebPageText.address("file:///etc/passwd", resolve: publicResolve), .failure(.notWeb))
        XCTAssertEqual(WebPageText.address("https://u:p@example.com", resolve: publicResolve), .failure(.credentials))
        XCTAssertEqual(WebPageText.address("http://192.168.1.1/admin", resolve: publicResolve), .failure(.local))
        XCTAssertEqual(WebPageText.address("http://localhost:8765/v1", resolve: publicResolve), .failure(.local))
        XCTAssertEqual(WebPageText.address("http://router.local", resolve: publicResolve), .failure(.local))
        XCTAssertEqual(WebPageText.address("http://[::1]/", resolve: publicResolve), .failure(.local))
        XCTAssertEqual(WebPageText.address("http://rebind.example", resolve: lanResolve), .failure(.local))
    }

    func testTitle() {
        XCTAssertEqual(WebPageText.title("<html><head><title lang=en>\n  Docs &amp; more </title></head>"), "Docs & more")
        XCTAssertNil(WebPageText.title("<p>no title</p>"))
    }

    func testMainText() {
        let body = String(repeating: "Real content here. ", count: 40)
        let html = "<nav>Menu Home About</nav><main><article><p>\(body)</p></article></main><footer>Footer</footer>"
        let text = WebPageText.mainText(html)
        XCTAssertTrue(text.hasPrefix("Real content"))
        XCTAssertFalse(text.contains("Menu"))
        // Too little in <main>: the whole page.
        XCTAssertTrue(WebPageText.mainText("<nav>Menu</nav><main>tiny</main>").contains("Menu"))
    }

    func testPages() {
        XCTAssertEqual(WebPageText.pages("  "), [])
        XCTAssertEqual(WebPageText.pages("short"), ["short"])
        let para = String(repeating: "word ", count: 150)   // 750 characters
        let text = (0..<12).map { _ in para }.joined(separator: "\n\n")
        let pages = WebPageText.pages(text, size: 2000)
        XCTAssertGreaterThan(pages.count, 3)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 2000 })
        // Cut at paragraphs: every page is whole paragraphs.
        XCTAssertTrue(pages.allSatisfy { $0.hasSuffix("word") })
        // Nothing lost: every word is on a page.
        XCTAssertEqual(pages.joined(separator: " ").split(whereSeparator: \.isWhitespace).count, 12 * 150)
    }

    func testResult() {
        let r = WebPageText.result(url: "https://x.org", title: "X", pages: ["one", "two"], page: 1)
        XCTAssertEqual(r["text"] as? String, "one")
        XCTAssertEqual(r["pages"] as? Int, 2)
        XCTAssertNotNil(r["next"])
        let last = WebPageText.result(url: "https://x.org", title: nil, pages: ["one", "two"], page: 9)
        XCTAssertEqual(last["text"] as? String, "two")
        XCTAssertNil(last["next"])
        XCTAssertNotNil(last["note"])
        XCTAssertNotNil(WebPageText.result(url: "u", title: nil, pages: [], page: 1)["error"])
    }
}
