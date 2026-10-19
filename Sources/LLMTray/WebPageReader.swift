import Foundation
import LLMTrayCore
import WebKit

/// Reads a web page for the model (web_search source=page, adr/0030): a
/// fresh load, never the user's browser session -- no cookies, nothing on
/// disk. Plain HTTP first; a page that's only scripts is rendered in an
/// offscreen WebKit view. Read pages are kept a few minutes, so the next
/// page of one costs nothing.
@MainActor
enum WebPageReader {
    struct Page {
        let url: String
        let title: String?
        let pages: [String]
        let at: Date
    }

    private static var cache: [String: Page] = [:]
    private static let keepFor: TimeInterval = 600
    /// The most a page's HTML may be.
    static let maxBytes = 5 << 20

    enum ReadError: LocalizedError {
        case address(WebPageText.AddressProblem)
        case notText(String)
        case tooBig
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .address(.notWeb): return "only http and https addresses can be read"
            case .address(.credentials): return "an address with a user name or password in it isn't read"
            case .address(.local): return "addresses on this Mac or the local network aren't read"
            case .notText(let type): return "not a web page (\(type))"
            case .tooBig: return "the page is too large (over 5 MB)"
            case .http(let status): return "the site answered HTTP \(status)"
            }
        }
    }

    static func read(_ address: String) async throws -> Page {
        // getaddrinfo blocks: off the main actor.
        let checked = await Task.detached { WebPageText.address(address) }.value
        let url: URL
        switch checked {
        case .success(let u): url = u
        case .failure(let problem): throw ReadError.address(problem)
        }
        let key = url.absoluteString
        cache = cache.filter { Date().timeIntervalSince($0.value.at) < keepFor }
        if let hit = cache[key] { return hit }

        let (html, finalURL) = try await fetch(url)
        var text = WebPageText.mainText(html)
        var title = WebPageText.title(html)
        // Next to nothing but scripts: the page builds itself in a browser.
        if text.count < 400, html.range(of: "<script", options: .caseInsensitive) != nil,
           let rendered = await Renderer.render(finalURL) {
            text = rendered.text
            title = rendered.title ?? title
        }
        let page = Page(url: finalURL.absoluteString, title: title, pages: WebPageText.pages(SharedContext.clean(text)), at: Date())
        cache[key] = page
        if cache.count > 8, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
        return page
    }

    /// The HTML, following redirects only to addresses that may be read.
    private static func fetch(_ url: URL) async throws -> (String, URL) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(WebFetch.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await WebFetch.session.data(for: request, delegate: RedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // A redirect left unfollowed (RedirectGuard): to where it may not go.
        if (300..<400).contains(http.statusCode) { throw ReadError.address(.local) }
        guard (200..<300).contains(http.statusCode) else { throw ReadError.http(http.statusCode) }
        guard data.count <= maxBytes else { throw ReadError.tooBig }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "text/html").lowercased()
        guard type.contains("html") || type.hasPrefix("text/") || type.contains("xml") || type.contains("json") else {
            throw ReadError.notText(type.split(separator: ";").first.map(String.init) ?? type)
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        // Plain text isn't HTML: kept as it is.
        if type.hasPrefix("text/plain") || type.contains("json") {
            return ("<pre>" + html.replacingOccurrences(of: "<", with: "&lt;") + "</pre>", http.url ?? url)
        }
        return (html, http.url ?? url)
    }

    /// Refuses a redirect to an address that may not be read.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, case .success = WebPageText.address(url.absoluteString) else { return nil }
            return request
        }
    }

    /// An offscreen WebKit view: no cookies or storage kept, no downloads
    /// or pop-ups, and nothing on this Mac or the local network loaded --
    /// not the page, not anything it asks for.
    @MainActor final class Renderer: NSObject, WKNavigationDelegate {
        private var view: WKWebView?
        private var continuation: CheckedContinuation<(text: String, title: String?)?, Never>?
        private static var current: Renderer?

        static func render(_ url: URL) async -> (text: String, title: String?)? {
            // One at a time.
            guard current == nil else { return nil }
            let renderer = Renderer()
            current = renderer
            defer { current = nil }
            return await renderer.load(url)
        }

        private func load(_ url: URL) async -> (text: String, title: String?)? {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.mediaTypesRequiringUserActionForPlayback = .all
            // Without the rules, nothing is rendered: a page's scripts
            // could reach the local network.
            guard let rules = await Self.localBlocker() else { return nil }
            config.userContentController.add(rules)
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
            view.customUserAgent = WebFetch.userAgent
            view.navigationDelegate = self
            self.view = view
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                view.load(URLRequest(url: url, timeoutInterval: 15))
                // A page that never finishes still gets read after 15 s.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    self?.extract()
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Scripts that fill the page after load get a moment.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.extract()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == "about" || url.scheme == "data" { return .allow }
            guard action.targetFrame != nil, case .success = await Task.detached(operation: { WebPageText.address(url.absoluteString) }).value else {
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            response.canShowMIMEType ? .allow : .cancel
        }

        private func extract() {
            guard let view, continuation != nil else { return }
            // The main part when it holds the text (not the site's menus).
            let js = "(function(){var m=document.querySelector('article,main,[role=main]');"
                + "var b=document.body?document.body.innerText:'';var t=m?m.innerText:'';"
                + "return [document.title, t.length>=500?t:b];})()"
            view.evaluateJavaScript(js) { [weak self] value, _ in
                let parts = value as? [Any]
                let title = (parts?.first as? String).flatMap { $0.isEmpty ? nil : $0 }
                let text = parts?.count == 2 ? parts?[1] as? String : nil
                self?.finish(text.map { ($0, title) })
            }
        }

        private func finish(_ result: (text: String, title: String?)?) {
            guard let continuation else { return }
            self.continuation = nil
            view?.stopLoading()
            view?.navigationDelegate = nil
            view = nil
            continuation.resume(returning: result)
        }

        /// Content rules: no request to this Mac or a private network, by
        /// address (names that resolve there are caught for navigations,
        /// not for a page's images and scripts).
        private static var compiled: WKContentRuleList?

        static func localBlocker() async -> WKContentRuleList? {
            if let compiled { return compiled }
            let patterns = [
                "^[a-z]+://localhost[:/]", "^[a-z]+://[^/]*\\\\.local[:/.]", "^[a-z]+://127\\\\.", "^[a-z]+://10\\\\.",
                "^[a-z]+://192\\\\.168\\\\.", "^[a-z]+://169\\\\.254\\\\.", "^[a-z]+://172\\\\.1[6-9]\\\\.", "^[a-z]+://172\\\\.2[0-9]\\\\.",
                "^[a-z]+://172\\\\.3[01]\\\\.", "^[a-z]+://0\\\\.",
                // 100.64/10 (no alternation in content rules)
                "^[a-z]+://100\\\\.6[4-9]\\\\.", "^[a-z]+://100\\\\.[7-9][0-9]\\\\.", "^[a-z]+://100\\\\.1[01][0-9]\\\\.",
                "^[a-z]+://100\\\\.12[0-7]\\\\.",
                "^[a-z]+://\\\\[", "^file:",
            ]
            let rules = patterns.map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
            let json = "[" + rules.joined(separator: ",") + "]"
            let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "LLMTray.webPage.local",
                                                                                           encodedContentRuleList: json)
            compiled = list
            return list
        }
    }
}
