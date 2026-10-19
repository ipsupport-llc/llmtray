import Foundation
import LLMTrayCore
import Network
import WebKit

/// Reads a web page for the model (web_search source=page, adr/0030): a
/// fresh load, never the user's browser session -- no cookies, nothing on
/// disk. Everything a read loads goes through its own WebPageProxy, which
/// keeps it off this Mac and the local network and caps its size and time.
/// Plain HTTP first; a page that's only scripts is rendered in an offscreen
/// WebKit view. Read pages are kept a few minutes, so the next page of one
/// costs nothing.
@MainActor
enum WebPageReader {
    struct Page: Sendable {
        let url: String
        let title: String?
        let pages: [String]
        let at: Date
    }

    private static var cache: [String: Page] = [:]
    private static let keepFor: TimeInterval = 600
    /// The most a page's HTML may be.
    nonisolated static let maxBytes = 5 << 20
    /// The most rendered text kept (a page can make any amount).
    static let maxRenderedCharacters = 400_000

    /// One read at a time; the next ones wait their turn.
    private static var busy = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    private static func takeTurn() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private static func endTurn() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

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
        // getaddrinfo blocks: off the main actor. A quick, friendly refusal;
        // the proxy is what really keeps reads off the local network.
        let checked = await Task.detached { WebPageText.address(address) }.value
        let url: URL
        switch checked {
        case .success(let u): url = u
        case .failure(let problem): throw ReadError.address(problem)
        }
        let key = url.absoluteString
        cache = cache.filter { Date().timeIntervalSince($0.value.at) < keepFor }
        if let hit = cache[key] { return hit }

        await takeTurn()
        defer { endTurn() }
        // Given up on while it waited: no network for it.
        try Task.checkCancellation()
        if let hit = cache[key] { return hit }

        let proxy = WebPageProxy()
        try await proxy.start()
        defer { proxy.stop() }

        let (html, finalURL) = try await fetch(url, proxy: proxy)
        var (title, text) = await Task.detached { (WebPageText.title(html), WebPageText.mainText(html)) }.value
        // Next to nothing but scripts: the page builds itself in a browser.
        if text.count < 400, html.range(of: "<script", options: .caseInsensitive) != nil,
           let rendered = await Renderer.render(finalURL, proxy: proxy) {
            text = rendered.text
            title = rendered.title ?? title
        }
        let pages = await Task.detached { WebPageText.pages(SharedContext.clean(text)) }.value
        let page = Page(url: finalURL.absoluteString, title: title, pages: pages, at: Date())
        cache[key] = page
        if cache.count > 8, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
        return page
    }

    /// A session that reaches the network only through `proxy`: ephemeral,
    /// no cookies, a deadline for the whole request.
    private static func session(_ proxy: WebPageProxy) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = WebPageProxy.deadline
        config.proxyConfigurations = [Self.proxyConfiguration(proxy)]
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    nonisolated static func proxyConfiguration(_ proxy: WebPageProxy) -> ProxyConfiguration {
        var config = ProxyConfiguration(httpCONNECTProxy: NWEndpoint.hostPort(host: "127.0.0.1",
                                                                              port: NWEndpoint.Port(rawValue: proxy.port) ?? .any))
        config.applyCredential(username: proxy.user, password: proxy.password)
        // Never around it: no direct connection if the proxy says no.
        config.allowFailover = false
        return config
    }

    /// The HTML (at most maxBytes, read as it comes), in its own encoding.
    private static func fetch(_ url: URL, proxy: WebPageProxy) async throws -> (String, URL) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(WebFetch.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let session = session(proxy)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // A redirect left unfollowed (RedirectGuard): to where it may not go.
        if (300..<400).contains(http.statusCode) { throw ReadError.address(.local) }
        guard (200..<300).contains(http.statusCode) else { throw ReadError.http(http.statusCode) }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "text/html").lowercased()
        guard type.contains("html") || type.hasPrefix("text/") || type.contains("xml") || type.contains("json") else {
            throw ReadError.notText(type.split(separator: ";").first.map(String.init) ?? type)
        }
        if http.expectedContentLength > maxBytes { throw ReadError.tooBig }
        let data = try await collect(bytes)
        let text = await Task.detached { decode(data, encodingName: http.textEncodingName) }.value
        // Plain text isn't HTML: kept as it is.
        if type.hasPrefix("text/plain") || type.contains("json") {
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            return ("<pre>" + escaped + "</pre>", http.url ?? url)
        }
        return (text, http.url ?? url)
    }

    /// The body, at most maxBytes, gathered off the main actor (a
    /// nonisolated async function runs there) and stopped when the read is
    /// cancelled.
    nonisolated private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        do {
            var data = Data()
            var chunk = [UInt8]()
            chunk.reserveCapacity(65536)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 65536 {
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    if data.count > maxBytes { throw ReadError.tooBig }
                    try Task.checkCancellation()
                }
            }
            data.append(contentsOf: chunk)
            if data.count > maxBytes { throw ReadError.tooBig }
            try Task.checkCancellation()
            return data
        }
    }

    /// The bytes in the encoding the server or the page names (a
    /// windows-1251 page isn't UTF-8), else UTF-8, else Latin-1.
    nonisolated static func decode(_ data: Data, encodingName: String?) -> String {
        func encoding(_ name: String) -> String.Encoding? {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        if let name = encodingName, let e = encoding(name), let s = String(data: data, encoding: e) { return s }
        // <meta charset="..."> or http-equiv in the first 2 KB.
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if let r = head.range(of: #"charset\s*=\s*["']?[a-z0-9_\-]+"#, options: .regularExpression) {
            let name = head[r].split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) } ?? ""
            if let e = encoding(name), let s = String(data: data, encoding: e) { return s }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Refuses a redirect to an address that may not be read (the proxy
    /// would refuse to connect anyway).
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, case .success = WebPageText.address(url.absoluteString) else { return nil }
            return request
        }
    }

    /// An offscreen WebKit view whose every load goes through the read's
    /// proxy: no cookies or storage kept, no pop-ups or downloads. Ends by
    /// itself after 20 s, whatever the page does.
    @MainActor final class Renderer: NSObject, WKNavigationDelegate {
        private var view: WKWebView?
        private var continuation: CheckedContinuation<(text: String, title: String?)?, Never>?

        static func render(_ url: URL, proxy: WebPageProxy) async -> (text: String, title: String?)? {
            await Renderer().load(url, proxy: proxy)
        }

        private func load(_ url: URL, proxy: WebPageProxy) async -> (text: String, title: String?)? {
            let store = WKWebsiteDataStore.nonPersistent()
            store.proxyConfigurations = [WebPageReader.proxyConfiguration(proxy)]
            let config = WKWebViewConfiguration()
            config.websiteDataStore = store
            // Loopback and other address literals don't go through a proxy:
            // content rules block them. Without the rules, nothing is
            // rendered.
            guard let rules = await Self.literalBlocker() else { return nil }
            config.userContentController.add(rules)
            // Lockdown Mode: no WebRTC (its sockets go around any proxy) in
            // any frame, an empty iframe's too; no WebAssembly, no JIT.
            // Checked: RTCPeerConnection is undefined in the page and in a
            // new iframe, fetch and scripts still run.
            config.defaultWebpagePreferences.isLockdownModeEnabled = true
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.mediaTypesRequiringUserActionForPlayback = .all
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
            view.customUserAgent = WebFetch.userAgent
            view.navigationDelegate = self
            self.view = view
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                view.load(URLRequest(url: url, timeoutInterval: 15))
                // Read what's there at 15 s; give up at 20 s, even if the
                // page's scripts never let the read finish.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    self?.extract()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self?.finish(nil)
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
            // Only the web: no other schemes, no new windows. Where it may
            // connect is the proxy's to decide.
            guard let scheme = action.request.url?.scheme?.lowercased(), action.targetFrame != nil else { return .cancel }
            return ["http", "https", "about"].contains(scheme) ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            response.canShowMIMEType ? .allow : .cancel
        }

        private func extract() {
            guard let view, continuation != nil else { return }
            // The main part when it holds the text (not the site's menus);
            // cut in the page, not after.
            let js = "(function(){var m=document.querySelector('article,main,[role=main]');"
                + "var b=document.body?document.body.innerText:'';var t=m?m.innerText:'';"
                + "return [document.title, (t.length>=500?t:b).slice(0,\(WebPageReader.maxRenderedCharacters))];})()"
            view.evaluateJavaScript(js) { [weak self] value, _ in
                let parts = value as? [Any]
                let title = (parts?.first as? String).flatMap { $0.isEmpty ? nil : $0 }
                let text = parts?.count == 2 ? parts?[1] as? String : nil
                self?.finish(text.map { ($0, title) })
            }
        }

        /// Requests to an address written as this Mac or a private network
        /// (WebKit writes 2130706433 or 0x7f000001 as 127.0.0.1 before the
        /// rules see it), to "localhost", with a user name in it, or any IPv6
        /// literal. Names are the proxy's.
        private static var compiled: WKContentRuleList?

        static func literalBlocker() async -> WKContentRuleList? {
            if let compiled { return compiled }
            // No alternation in content rules: one pattern each.
            let patterns = [
                "^[a-z]+://[^/]*@", "^[a-z]+://localhost[:/.]", "^[a-z]+://localhost$", "^[a-z]+://\\[",
                "^[a-z]+://0\\.", "^[a-z]+://127\\.", "^[a-z]+://10\\.", "^[a-z]+://192\\.168\\.", "^[a-z]+://169\\.254\\.",
                "^[a-z]+://172\\.1[6-9]\\.", "^[a-z]+://172\\.2[0-9]\\.", "^[a-z]+://172\\.3[01]\\.",
                "^[a-z]+://100\\.6[4-9]\\.", "^[a-z]+://100\\.[7-9][0-9]\\.", "^[a-z]+://100\\.1[01][0-9]\\.", "^[a-z]+://100\\.12[0-7]\\.",
                "^[a-z]+://22[4-9]\\.", "^[a-z]+://2[3-5][0-9]\\.", "^file:",
            ]
            // JSON-escaped: a regex's backslashes are JSON's too.
            let rules = patterns.map { #"{"trigger":{"url-filter":"\#($0.replacingOccurrences(of: "\\", with: "\\\\"))"},"action":{"type":"block"}}"# }
            let json = "[" + rules.joined(separator: ",") + "]"
            let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "LLMTray.webPage.literals",
                                                                                           encodedContentRuleList: json)
            compiled = list
            return list
        }

        private func finish(_ result: (text: String, title: String?)?) {
            guard let continuation else { return }
            self.continuation = nil
            view?.stopLoading()
            view?.navigationDelegate = nil
            view = nil
            continuation.resume(returning: result)
        }
    }
}
