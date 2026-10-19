import Foundation

/// A web page for the model to read (web_search's source=page, adr/0030):
/// which addresses it may load, and its text cut into pages a small model's
/// context holds.
public enum WebPageText {
    /// About a thousand tokens of text per page.
    public static let pageCharacters = 4000

    public enum AddressProblem: Error, Equatable {
        case notWeb, credentials, local
    }

    /// The address the model gave, made whole ("example.com/x" →
    /// "https://example.com/x"), or why it can't be loaded: only http(s), no
    /// user and password in it, nothing on this Mac or the local network
    /// (a page must not reach the user's router or other devices).
    public static func address(_ text: String,
                               resolve: (String) -> [MCPOAuth.IPAddress] = MCPOAuth.IPAddress.resolve) -> Result<URL, AddressProblem> {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return .failure(.notWeb) }
        if url.user != nil || url.password != nil { return .failure(.credentials) }
        if MCPOAuth.isLocal(host, resolve: resolve) { return .failure(.local) }
        return .success(url)
    }

    /// The page's main text: its <article> or <main> when one holds most of
    /// what there is to read (not the site's menus around it), else all.
    public static func mainText(_ html: String) -> String {
        let all = HTMLText.text(html)
        for tag in ["article", "main"] {
            guard let open = html.range(of: "<\(tag)", options: .caseInsensitive),
                  let close = html.range(of: "</\(tag)>", options: [.caseInsensitive, .backwards]),
                  open.lowerBound < close.lowerBound else { continue }
            let inner = HTMLText.text(String(html[open.lowerBound..<close.upperBound]))
            if inner.count >= 500 { return inner }
        }
        return all
    }

    /// The page's <title>, if it has one.
    public static func title(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let close = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: close.upperBound..<html.endIndex) else { return nil }
        let title = WebParsing.decodeEntities(String(html[close.upperBound..<end.lowerBound]))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return title.isEmpty ? nil : title
    }

    /// The text in pages of about `size` characters, cut at a paragraph or
    /// line break where there is one in the page's last quarter, else at a
    /// space.
    public static func pages(_ text: String, size: Int = pageCharacters) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        var pages: [String] = []
        var rest = Substring(clean)
        while rest.count > size {
            let limit = rest.index(rest.startIndex, offsetBy: size)
            let window = rest[rest.index(rest.startIndex, offsetBy: size * 3 / 4)..<limit]
            let cut = window.range(of: "\n\n", options: .backwards)?.upperBound
                ?? window.range(of: "\n", options: .backwards)?.upperBound
                ?? window.range(of: " ", options: .backwards)?.upperBound
                ?? limit
            pages.append(rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[cut...]
        }
        let last = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { pages.append(last) }
        return pages
    }

    /// What the model gets for page `page` (1-based) of a read page.
    public static func result(url: String, title: String?, pages: [String], page: Int) -> [String: Any] {
        guard !pages.isEmpty else {
            return ["url": url, "title": title ?? "", "error": "the page has no readable text"]
        }
        let n = min(max(page, 1), pages.count)
        var out: [String: Any] = ["url": url, "page": n, "pages": pages.count, "text": pages[n - 1]]
        if let title { out["title"] = title }
        if n < pages.count { out["next"] = "more: call again with the same url and page=\(n + 1)" }
        if page > pages.count { out["note"] = "the page has only \(pages.count) pages; this is the last" }
        return out
    }
}
