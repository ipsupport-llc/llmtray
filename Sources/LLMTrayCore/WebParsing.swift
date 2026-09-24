import Foundation

/// A web search or news hit, as the chat's tools report it.
public struct WebResult: Equatable, Codable {
    public var title: String
    public var url: String
    public var snippet: String
    public var source: String?
    public var published: String?

    public init(title: String, url: String, snippet: String, source: String? = nil, published: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.source = source
        self.published = published
    }
}

/// Parsing for the web tools' responses -- pure, so it's tested against
/// captured fixtures instead of the live services.
public enum WebParsing {
    private static let ddgResult = try! NSRegularExpression(
        pattern: #"<a\s+[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>.*?<a\s+[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )

    /// Results from DuckDuckGo's HTML endpoint (html.duckduckgo.com/html),
    /// without its ads (links through duckduckgo.com/y.js).
    public static func duckDuckGoResults(_ html: String, limit: Int) -> [WebResult] {
        let range = NSRange(html.startIndex..., in: html)
        var results: [WebResult] = []
        for match in ddgResult.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let snippetRange = Range(match.range(at: 3), in: html) else { continue }
            let href = decodeEntities(String(html[hrefRange]))
            if href.contains("duckduckgo.com/y.js") { continue }   // ad
            guard let url = unwrapDuckDuckGoLink(href) else { continue }
            results.append(WebResult(
                title: text(String(html[titleRange]), limit: 150),
                url: url,
                snippet: text(String(html[snippetRange]), limit: 250)
            ))
            if results.count >= limit { break }
        }
        return results
    }

    /// DDG may wrap outbound links as //duckduckgo.com/l/?uddg=<encoded url>.
    public static func unwrapDuckDuckGoLink(_ href: String) -> String? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let components = URLComponents(string: absolute) else { return nil }
        if components.path.hasSuffix("/l/"),
           let target = components.queryItems?.first(where: { $0.name == "uddg" || $0.name == "u" })?.value {
            return target
        }
        return absolute.hasPrefix("http") ? absolute : nil
    }

    /// Items of an RSS 2.0 feed (Google News), up to `limit`.
    public static func rssItems(_ xml: Data, limit: Int) -> [WebResult] {
        let delegate = RSSDelegate(limit: limit)
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// Visible text of an HTML fragment: tags removed, entities decoded,
    /// whitespace collapsed, cut to `limit` characters.
    public static func text(_ html: String, limit: Int) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsed = decodeEntities(noTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        // numeric: &#8217; &#x2019;
        let pattern = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in pattern.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let digits = ns.substring(with: m.range(at: 2))
            if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

private final class RSSDelegate: NSObject, XMLParserDelegate {
    let limit: Int
    var items: [WebResult] = []
    private var current: [String: String]?
    private var text = ""

    init(limit: Int) { self.limit = limit }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" { current = [:] }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        text += String(decoding: data, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard current != nil else { return }
        if name == "item" {
            let c = current ?? [:]
            items.append(WebResult(
                title: WebParsing.text(c["title"] ?? "", limit: 200),
                url: c["link"] ?? "",
                snippet: WebParsing.text(c["description"] ?? "", limit: 200),
                source: c["source"].map { WebParsing.text($0, limit: 80) },
                published: c["pubDate"]
            ))
            current = nil
            if items.count >= limit { parser.abortParsing() }
        } else if ["title", "link", "description", "source", "pubDate"].contains(name) {
            current?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = ""
    }
}
