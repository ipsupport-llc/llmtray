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

    /// The HTML without what's never shown: comments, scripts, styles,
    /// templates, svg -- so text hidden there can't pass for the page's.
    static func visibleHTML(_ html: String) -> String {
        var out = html
        for pattern in [#"<!--[\s\S]*?-->"#, #"<script\b[\s\S]*?</script\s*>"#, #"<style\b[\s\S]*?</style\s*>"#,
                        #"<template\b[\s\S]*?</template\s*>"#, #"<svg\b[\s\S]*?</svg\s*>"#, #"<noscript\b[\s\S]*?</noscript\s*>"#] {
            out = out.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// The page's main text: its largest <article>, or its <main>, when that
    /// holds enough to read (not the site's menus around it), else all of
    /// the page's text.
    public static func mainText(_ html: String) -> String {
        let visible = visibleHTML(html)
        for tag in ["article", "main"] {
            var best = ""
            var from = visible.startIndex
            while let open = visible.range(of: "<\(tag)", options: .caseInsensitive, range: from..<visible.endIndex),
                  let close = visible.range(of: "</\(tag)", options: .caseInsensitive, range: open.upperBound..<visible.endIndex) {
                let inner = HTMLText.text(String(visible[open.lowerBound..<close.lowerBound]))
                if inner.count > best.count { best = inner }
                from = close.upperBound
            }
            if best.count >= 500 { return best }
        }
        return HTMLText.text(html)
    }

    /// The page's <title>, if it has one.
    public static func title(_ page: String) -> String? {
        let html = visibleHTML(page)
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
        var start = clean.startIndex
        // Index steps of at most `size` each: linear in the text.
        while let limit = clean.index(start, offsetBy: size, limitedBy: clean.endIndex), limit < clean.endIndex {
            let quarter = clean.index(start, offsetBy: size * 3 / 4)
            let window = clean[quarter..<limit]
            let cut = window.range(of: "\n\n", options: .backwards)?.upperBound
                ?? window.range(of: "\n", options: .backwards)?.upperBound
                ?? window.range(of: " ", options: .backwards)?.upperBound
                ?? limit
            pages.append(clean[start..<cut].trimmingCharacters(in: .whitespacesAndNewlines))
            start = cut
        }
        let last = clean[start...].trimmingCharacters(in: .whitespacesAndNewlines)
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
