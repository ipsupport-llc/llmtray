import XCTest
@testable import LLMTrayCore

final class WebParsingTests: XCTestCase {
    // Shape captured from html.duckduckgo.com/html (2026-09), trimmed.
    let ddgHTML = """
    <div class="result results_links results_links_deep result--ad">
      <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_domain=codecademy.com&amp;u3=x">Learn Swift - Ad</a></h2>
      <a class="result__snippet" href="https://duckduckgo.com/y.js?x">Sponsored</a>
    </div>
    <div class="result results_links results_links_deep web-result ">
      <h2 class="result__title">
        <a rel="nofollow" class="result__a" href="https://www.swift.org/">Official <b>site</b></a>
      </h2>
      <div class="result__extras"><a class="result__url" href="https://www.swift.org/">www.swift.org</a></div>
      <a class="result__snippet" href="https://www.swift.org/">Swift (programming &amp; language) &#8212; fast &#x2019;safe&#x2019;</a>
    </div>
    <div class="result results_links web-result">
      <h2 class="result__title"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FSwift&amp;rut=abc">Swift - Wikipedia</a></h2>
      <a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">A general-purpose language.</a>
    </div>
    """

    func testDuckDuckGo() {
        let r = WebParsing.duckDuckGoResults(ddgHTML, limit: 10)
        XCTAssertEqual(r.count, 2, "the ad is dropped")
        XCTAssertEqual(r[0], WebResult(title: "Official site", url: "https://www.swift.org/", snippet: "Swift (programming & language) — fast ’safe’"))
        XCTAssertEqual(r[1].url, "https://en.wikipedia.org/wiki/Swift")
        XCTAssertEqual(WebParsing.duckDuckGoResults(ddgHTML, limit: 1).count, 1)
        XCTAssertEqual(WebParsing.duckDuckGoResults("<html>no results</html>", limit: 5), [])
    }

    func testRSS() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Google News</title>
        <item><title>Apple’s tools underperformed - Financial Times</title><link>https://news.google.com/rss/articles/A?oc=5</link>
        <pubDate>Wed, 23 Sep 2026 21:32:53 GMT</pubDate><description>&lt;a href="x"&gt;Apple’s tools&lt;/a&gt;&amp;nbsp;&lt;font&gt;FT&lt;/font&gt;</description>
        <source url="https://www.ft.com">Financial Times</source></item>
        <item><title><![CDATA[Second & more]]></title><link>https://example.com/2</link></item>
        <item><title>Third</title><link>https://example.com/3</link></item>
        </channel></rss>
        """
        let items = WebParsing.rssItems(Data(xml.utf8), limit: 2)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Apple’s tools underperformed - Financial Times")
        XCTAssertEqual(items[0].source, "Financial Times")
        XCTAssertEqual(items[0].published, "Wed, 23 Sep 2026 21:32:53 GMT")
        XCTAssertEqual(items[0].snippet, "Apple’s tools FT")
        XCTAssertEqual(items[1].title, "Second & more")
        XCTAssertEqual(WebParsing.rssItems(Data("not xml".utf8), limit: 5), [])
    }

    func testTextLimit() {
        XCTAssertEqual(WebParsing.text("<p>hello   <b>world</b></p>", limit: 100), "hello world")
        XCTAssertEqual(WebParsing.text("abcdefghij", limit: 5), "abcd…")
    }
}
