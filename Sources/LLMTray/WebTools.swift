import Foundation
import LLMTrayCore

// The chat's web tools -- keyless public APIs. Descriptions follow the ones
// tuned for small local models in rromenskyi/mcp-weather-simple. Every
// tool reports failures as {"error": ...} for the model, never throws.

final class WebSearchTool: SelectableTool {
    init() { super.init(name: "web_search") }

    override var definition: [String: Any] {
        Self.function(
            name,
            "General web search (DuckDuckGo) for non-time-sensitive questions: documentation, facts, companies, "
                + "how-tos. Returns titles, URLs and snippets. For current events use `news`; for Hacker News "
                + "use `hackernews`.",
            properties: [
                "query": Self.string("What to search for, in any language."),
                "limit": Self.integer("1-15, default 8."),
            ],
            required: ["query"]
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return Self.error("query is required")
        }
        let limit = min(max(arguments["limit"] as? Int ?? 8, 1), 15)
        do {
            let data = try await WebFetch.data(
                "https://html.duckduckgo.com/html/", method: "POST",
                form: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: "wt-wt")]
            )
            let html = String(decoding: data, as: UTF8.self)
            let results = WebParsing.duckDuckGoResults(html, limit: limit)
            if results.isEmpty, !html.contains("result__a"), !html.contains("no-results") {
                // Neither results nor DDG's "No results" block: its bot check.
                return Self.error("web search is temporarily blocked by DuckDuckGo; try again later or use news / get_wikipedia_summary")
            }
            return Self.json(["query": query, "results": results.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet] }])
        } catch {
            return Self.error("search failed: \(error.localizedDescription)")
        }
    }
}

final class NewsTool: SelectableTool {
    init() { super.init(name: "news") }

    override var definition: [String: Any] {
        Self.function(
            name,
            "Recent news (Google News) -- use for current events, anything \"today\", \"latest\", \"recent\". "
                + "With a query: articles about it; without: top headlines.",
            properties: [
                "query": Self.string("Topic to search news for. Omit for top headlines."),
                "lang": Self.string("Language code for the edition, e.g. \"en\", \"ru\", \"uk\", \"de\". Default \"en\"."),
                "limit": Self.integer("1-20, default 10."),
            ]
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let limit = min(max(arguments["limit"] as? Int ?? 10, 1), 20)
        let lang = String(((arguments["lang"] as? String) ?? "en").lowercased().prefix(2))
        let edition = Self.editions[lang] ?? Self.editions["en"]!
        var query = [URLQueryItem(name: "hl", value: edition.hl), URLQueryItem(name: "gl", value: edition.gl),
                     URLQueryItem(name: "ceid", value: "\(edition.gl):\(edition.ceidLang)")]
        var base = "https://news.google.com/rss"
        if let q = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            base += "/search"
            query.insert(URLQueryItem(name: "q", value: q), at: 0)
        }
        do {
            let items = WebParsing.rssItems(try await WebFetch.data(base, query: query), limit: limit)
            return Self.json(["articles": items.map {
                ["title": $0.title, "url": $0.url, "source": $0.source ?? "", "published": $0.published ?? ""]
            }])
        } catch {
            return Self.error("news failed: \(error.localizedDescription)")
        }
    }
}

extension NewsTool {
    /// Google News editions by language: the country isn't the language
    /// code upper-cased (uk -> UA, ja -> JP, en -> US).
    static let editions: [String: (hl: String, gl: String, ceidLang: String)] = [
        "en": ("en-US", "US", "en"), "ru": ("ru", "RU", "ru"), "uk": ("uk", "UA", "uk"), "de": ("de", "DE", "de"),
        "fr": ("fr", "FR", "fr"), "es": ("es-419", "US", "es-419"), "it": ("it", "IT", "it"), "pt": ("pt-BR", "BR", "pt-419"),
        "pl": ("pl", "PL", "pl"), "tr": ("tr", "TR", "tr"), "ja": ("ja", "JP", "ja"), "ko": ("ko", "KR", "ko"),
        "zh": ("zh-CN", "CN", "zh-Hans"), "hi": ("hi", "IN", "hi"), "he": ("he", "IL", "he"), "ar": ("ar", "EG", "ar"),
        "vi": ("vi", "VN", "vi"), "id": ("id", "ID", "id"), "nl": ("nl", "NL", "nl"), "cs": ("cs", "CZ", "cs"),
        "sv": ("sv", "SE", "sv"), "th": ("th", "TH", "th"),
    ]
}

final class HackerNewsTool: SelectableTool {
    init() { super.init(name: "hackernews") }

    override var definition: [String: Any] {
        Self.function(
            name,
            "Hacker News posts -- when the user names HN or asks what the tech community is discussing. "
                + "For mainstream news use `news`.",
            properties: [
                "category": Self.string("One of top (default), new, best, ask, show, job."),
                "limit": Self.integer("1-30, default 15."),
            ]
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let categories = ["top", "new", "best", "ask", "show", "job"]
        let category = (arguments["category"] as? String).flatMap { categories.contains($0) ? $0 : nil } ?? "top"
        let limit = min(max(arguments["limit"] as? Int ?? 15, 1), 30)
        do {
            let ids = try await WebFetch.jsonArray("https://hacker-news.firebaseio.com/v0/\(category)stories.json")
                .compactMap { $0 as? Int }.prefix(limit)
            let items = await withTaskGroup(of: (Int, [String: Any]?).self) { group in
                for (rank, id) in ids.enumerated() {
                    group.addTask { (rank, try? await WebFetch.json("https://hacker-news.firebaseio.com/v0/item/\(id).json")) }
                }
                var out: [(Int, [String: Any])] = []
                for await (rank, item) in group { if let item { out.append((rank, item)) } }
                return out.sorted { $0.0 < $1.0 }
            }
            return Self.json(["category": category, "posts": items.map { rank, item -> [String: Any] in
                let id = item["id"] as? Int ?? 0
                return [
                    "rank": rank + 1,
                    "title": item["title"] as? String ?? "",
                    "url": item["url"] as? String ?? "https://news.ycombinator.com/item?id=\(id)",
                    "points": item["score"] as? Int ?? 0,
                    "comments": item["descendants"] as? Int ?? 0,
                    "hn_url": "https://news.ycombinator.com/item?id=\(id)",
                ]
            }])
        } catch {
            return Self.error("Hacker News failed: \(error.localizedDescription)")
        }
    }
}

final class WikipediaTool: SelectableTool {
    init() { super.init(name: "get_wikipedia_summary") }

    override var definition: [String: Any] {
        Self.function(
            name,
            "A short Wikipedia summary and link for a person, place, concept or event (\"tell me about X\", "
                + "\"who is X\", \"what is X\", \"расскажи про X\", \"кто такой X\").",
            properties: [
                "title": Self.string("The topic as the user said it, e.g. \"Kyiv\" or \"Alan Turing\"."),
                "lang": Self.string("Wikipedia language code, e.g. \"en\", \"ru\", \"uk\", \"de\". Default: the title's language."),
            ],
            required: ["title"]
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            return Self.error("title is required")
        }
        // A Cyrillic title on en.wiki 404s: try the languages it could be in.
        let cyrillic = title.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        // Goes into the host name: only a real language code (not a value a
        // prompt injection could point elsewhere with).
        let lang: String? = (arguments["lang"] as? String)?.lowercased()
        let requested: String? = lang.flatMap { code in
            code.range(of: #"^[a-z]{2,3}(-[a-z]{2,8})?$"#, options: .regularExpression) != nil ? code : nil
        }
        var langs = [requested ?? (cyrillic ? "ru" : "en")]
        langs += cyrillic ? ["uk", "ru", "en"] : ["en"]
        for lang in NSOrderedSet(array: langs).compactMap({ $0 as? String }) {
            if let summary = await summary(title, lang: lang) { return Self.json(summary) }
            // Not an exact page: the search's best match.
            if let found = try? await WebFetch.jsonArray(
                "https://\(lang).wikipedia.org/w/api.php",
                query: [URLQueryItem(name: "action", value: "opensearch"), URLQueryItem(name: "search", value: title),
                        URLQueryItem(name: "limit", value: "1"), URLQueryItem(name: "format", value: "json")]
            ), found.count > 1, let best = (found[1] as? [String])?.first,
               let summary = await summary(best, lang: lang) {
                return Self.json(summary)
            }
        }
        return Self.error("no Wikipedia article found for \(title)")
    }

    private func summary(_ title: String, lang: String) async -> [String: Any]? {
        let slug = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? title
        guard let page = try? await WebFetch.json("https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(slug)"),
              let extract = page["extract"] as? String, !extract.isEmpty else { return nil }
        let url = ((page["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
        return [
            "title": page["title"] as? String ?? title,
            "summary": extract.count > 1200 ? String(extract.prefix(1199)) + "…" : extract,
            "url": url ?? "https://\(lang).wikipedia.org/wiki/\(slug)",
            "lang": lang,
        ]
    }
}

final class CountryInfoTool: SelectableTool {
    init() { super.init(name: "get_country_info") }

    override var definition: [String: Any] {
        Self.function(
            name,
            "Country facts from Wikidata: capital, population, area, continent, currency, official languages, "
                + "calling code, neighbours.",
            properties: ["country": Self.string("Country name in any language (\"Ukraine\", \"Украина\") or ISO code (\"UA\", \"UKR\").")],
            required: ["country"]
        )
    }

    private static let api = "https://www.wikidata.org/w/api.php"

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let country = (arguments["country"] as? String)?.trimmingCharacters(in: .whitespaces), !country.isEmpty else {
            return Self.error("country is required")
        }
        do {
            guard let (id, entity) = try await Self.findCountry(country) else { return Self.error("no country \(country)") }
            let claims = WikidataClaims(entity)
            let linked = claims.items("P36", currentOnly: true) + claims.items("P38", currentOnly: true)
                + claims.items("P30") + claims.items("P37")
            async let refsLoad = Self.entities(Array(Set(linked)), props: "labels|claims")
            // Neighbours by name: labels only (their full claims made a
            // country with many borders take ~10 s).
            async let neighbourLoad = Self.entities(claims.items("P47", currentOnly: true), props: "labels")
            let (refs, neighbourEntities) = try await (refsLoad, neighbourLoad)
            func label(_ id: String) -> String? { WikidataClaims.label(refs[id]) }
            let currencies = claims.items("P38", currentOnly: true).compactMap { id -> String? in
                let code = WikidataClaims(refs[id] ?? [:]).strings("P498").first
                return [code, label(id)].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            }
            let borders: [String] = claims.items("P47", currentOnly: true)
                .compactMap { WikidataClaims.label(neighbourEntities[$0]) }.sorted()
            var capitals: [String] = []
            for name in claims.items("P36", currentOnly: true).compactMap(label) where !capitals.contains(name) {
                capitals.append(name)
            }
            let population: Int = claims.latestQuantity("P1082").map { Int($0) } ?? 0
            let area: Int = claims.areaKm2().map { Int($0.rounded()) } ?? 0
            var result: [String: Any] = [:]
            result["name"] = WikidataClaims.label(entity) ?? country
            result["code"] = claims.strings("P297").first ?? ""
            result["capital"] = capitals.joined(separator: ", ")
            result["population"] = population
            result["area_km2"] = area
            result["continent"] = claims.items("P30").compactMap(label).joined(separator: ", ")
            result["currencies"] = currencies
            result["languages"] = claims.items("P37").compactMap(label)
            result["calling_code"] = claims.strings("P474").first ?? ""
            result["borders"] = borders
            result["source"] = "https://www.wikidata.org/wiki/\(id)"
            return Self.json(result)
        } catch {
            return Self.error("country lookup failed: \(error.localizedDescription)")
        }
    }

    /// The country's item: by ISO code (P297 / P298) or by name in any
    /// language -- the first search hit that has an ISO alpha-2 code.
    static func findCountry(_ query: String) async throws -> (String, [String: Any])? {
        var candidates: [String] = []
        if (2...3).contains(query.count), query.allSatisfy({ $0.isASCII && $0.isLetter }), query == query.uppercased() {
            let search = try await WebFetch.json(api, query: [
                URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
                URLQueryItem(name: "srsearch", value: "haswbstatement:\(query.count == 2 ? "P297" : "P298")=\(query)"),
                URLQueryItem(name: "format", value: "json"),
            ])
            candidates = ((search["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        }
        // Not an ISO code after all ("UK", "UAE") or a name: search by label.
        if candidates.isEmpty {
            let cyrillic = query.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            let search = try await WebFetch.json(api, query: [
                URLQueryItem(name: "action", value: "wbsearchentities"), URLQueryItem(name: "search", value: query),
                URLQueryItem(name: "language", value: cyrillic ? "ru" : "en"), URLQueryItem(name: "type", value: "item"),
                URLQueryItem(name: "limit", value: "7"), URLQueryItem(name: "format", value: "json"),
            ])
            candidates = (search["search"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        candidates = candidates.filter { $0.range(of: #"^Q\d+$"#, options: .regularExpression) != nil }
        guard !candidates.isEmpty else { return nil }
        let found = try await entities(candidates, props: "labels|claims")
        for id in candidates {
            if let entity = found[id], !WikidataClaims(entity).strings("P297").isEmpty { return (id, entity) }
        }
        return nil
    }

    static func entities(_ ids: [String], props: String) async throws -> [String: [String: Any]] {
        guard !ids.isEmpty else { return [:] }
        var out: [String: [String: Any]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            let json = try await WebFetch.json(api, query: [
                URLQueryItem(name: "action", value: "wbgetentities"), URLQueryItem(name: "ids", value: chunk.joined(separator: "|")),
                URLQueryItem(name: "props", value: props), URLQueryItem(name: "languages", value: "en"),
                URLQueryItem(name: "format", value: "json"),
            ])
            for (id, entity) in json["entities"] as? [String: [String: Any]] ?? [:] { out[id] = entity }
        }
        return out
    }
}

/// Reading a Wikidata entity's claims: current values only where history
/// is kept (a country's former currencies and neighbours), the preferred
/// or most recent value of a time series (population).
struct WikidataClaims {
    let claims: [String: [[String: Any]]]

    init(_ entity: [String: Any]) {
        claims = entity["claims"] as? [String: [[String: Any]]] ?? [:]
    }

    static func label(_ entity: [String: Any]?) -> String? {
        ((entity?["labels"] as? [String: Any])?["en"] as? [String: Any])?["value"] as? String
    }

    private func statements(_ property: String, currentOnly: Bool = false) -> [[String: Any]] {
        let all = (claims[property] ?? []).filter { $0["rank"] as? String != "deprecated" }
        let current = currentOnly ? all.filter { (($0["qualifiers"] as? [String: Any])?["P582"]) == nil } : all
        let preferred = current.filter { $0["rank"] as? String == "preferred" }
        return preferred.isEmpty ? current : preferred
    }

    private static func value(_ statement: [String: Any]) -> Any? {
        ((statement["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]
    }

    func items(_ property: String, currentOnly: Bool = false) -> [String] {
        statements(property, currentOnly: currentOnly).compactMap { (Self.value($0) as? [String: Any])?["id"] as? String }
    }

    func strings(_ property: String) -> [String] {
        statements(property).compactMap { Self.value($0) as? String }
    }

    /// Area (P2046) in km², converted when stated in another unit.
    func areaKm2() -> Double? {
        let factors = ["Q712226": 1.0, "Q232291": 2.589988, "Q35852": 0.01, "Q25343": 1e-6]   // km², mi², ha, m²
        for statement in statements("P2046") {
            guard let value = Self.value(statement) as? [String: Any],
                  let amount = (value["amount"] as? String).flatMap({ Double($0.replacingOccurrences(of: "+", with: "")) }),
                  let unit = (value["unit"] as? String)?.components(separatedBy: "/").last,
                  let factor = factors[unit] else { continue }
            return amount * factor
        }
        return nil
    }

    /// The preferred value, else the one with the latest point in time (P585).
    func latestQuantity(_ property: String) -> Double? {
        let candidates = statements(property)
        let dated = candidates.map { statement -> (String, Double?) in
            let time = (((statement["qualifiers"] as? [String: Any])?["P585"] as? [[String: Any]])?.first?["datavalue"] as? [String: Any])
                .flatMap { ($0["value"] as? [String: Any])?["time"] as? String } ?? ""
            let amount = (Self.value(statement) as? [String: Any])?["amount"] as? String
            return (time, amount.flatMap { Double($0.replacingOccurrences(of: "+", with: "")) })
        }
        return dated.max { $0.0 < $1.0 }?.1
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

final class HolidaysTool: SelectableTool {
    init() { super.init(name: "get_public_holidays") }

    override var definition: [String: Any] {
        Self.function(
            name,
            "Public holidays of a country in a year.",
            properties: [
                "country_code": Self.string("ISO-3166 alpha-2 code, e.g. \"UA\", \"US\", \"JP\"."),
                "year": Self.integer("Defaults to the current year."),
            ],
            required: ["country_code"]
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let code = (arguments["country_code"] as? String)?.uppercased(), code.count == 2,
              code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return Self.error("country_code must be a 2-letter ISO code")
        }
        let year = arguments["year"] as? Int ?? Calendar.current.component(.year, from: Date())
        do {
            let list = try await WebFetch.jsonArray("https://date.nager.at/api/v3/PublicHolidays/\(year)/\(code)")
            return Self.json(["country_code": code, "year": year, "holidays": list.compactMap { $0 as? [String: Any] }.map {
                ["date": $0["date"] as? String ?? "", "name": $0["name"] as? String ?? "", "local_name": $0["localName"] as? String ?? ""]
            }])
        } catch let error as WebFetch.HTTPError where error.status == 404 {
            return Self.error("no holiday data for \(code)")
        } catch {
            return Self.error("holiday lookup failed: \(error.localizedDescription)")
        }
    }
}

final class CurrencyTool: SelectableTool {
    init() { super.init(name: "convert_currency") }

    override var definition: [String: Any] {
        Self.function(
            name,
            "Convert an amount between currencies at today's rate (\"how much is 50 USD in EUR?\").",
            properties: [
                "amount": Self.number("The amount to convert."),
                "from_currency": Self.string("ISO-4217 code, e.g. \"USD\"."),
                "to_currency": Self.string("ISO-4217 code, e.g. \"EUR\"."),
            ],
            required: ["amount", "from_currency", "to_currency"]
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let amount = (arguments["amount"] as? Double) ?? (arguments["amount"] as? Int).map(Double.init) ?? Double(arguments["amount"] as? String ?? "")
        guard let amount, amount.isFinite, abs(amount) < 1e15,
              let from = (arguments["from_currency"] as? String)?.uppercased(), from.count == 3, from.allSatisfy({ $0.isASCII && $0.isLetter }),
              let to = (arguments["to_currency"] as? String)?.uppercased(), to.count == 3, to.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return Self.error("amount, from_currency and to_currency (3-letter codes) are required")
        }
        do {
            let rates = try await WebFetch.json("https://open.er-api.com/v6/latest/\(from)")
            guard rates["result"] as? String == "success" else { return Self.error("unknown currency \(from)") }
            guard let rate = (rates["rates"] as? [String: Any])?[to] as? Double else { return Self.error("unknown currency \(to)") }
            // Decimal: a Double like 0.877372 prints as 0.87737200000000004.
            // Significant digits, so tiny rates (IRR -> USD) don't round to 0.
            let exactRate = NSDecimalNumber(string: String(format: "%.6g", rate))
            let value = amount * rate
            let converted = NSDecimalNumber(string: abs(value) >= 1 ? String(format: "%.2f", value) : String(format: "%.4g", value))
            return Self.json([
                "amount": amount, "from": from, "to": to, "rate": exactRate,
                "result": converted,
                "rate_date": rates["time_last_update_utc"] as? String ?? "",
            ])
        } catch {
            return Self.error("rate lookup failed: \(error.localizedDescription)")
        }
    }
}

/// The selectable tools, for the toolbox and the Settings / popover lists.
enum ToolCatalog {
    struct Entry: Identifiable {
        let name: String
        let title: String
        let usesNetwork: Bool
        var id: String { name }
    }

    static let entries: [Entry] = [
        Entry(name: "get_current_date", title: NSLocalizedString("Date & time", comment: "chat tool"), usesNetwork: false),
        Entry(name: "get_current_time_in_city", title: NSLocalizedString("Time in a city", comment: "chat tool"), usesNetwork: true),
        Entry(name: "calculate", title: NSLocalizedString("Calculator", comment: "chat tool"), usesNetwork: false),
        Entry(name: "web_search", title: NSLocalizedString("Web search", comment: "chat tool"), usesNetwork: true),
        Entry(name: "news", title: NSLocalizedString("News", comment: "chat tool"), usesNetwork: true),
        Entry(name: "hackernews", title: NSLocalizedString("Hacker News", comment: "chat tool"), usesNetwork: true),
        Entry(name: "get_wikipedia_summary", title: NSLocalizedString("Wikipedia", comment: "chat tool"), usesNetwork: true),
        Entry(name: "get_country_info", title: NSLocalizedString("Country facts", comment: "chat tool"), usesNetwork: true),
        Entry(name: "get_public_holidays", title: NSLocalizedString("Public holidays", comment: "chat tool"), usesNetwork: true),
        Entry(name: "convert_currency", title: NSLocalizedString("Currency rates", comment: "chat tool"), usesNetwork: true),
    ]

    @MainActor
    static func makeTools() -> [ChatTool] {
        [CurrentDateTool(), TimeInCityTool(), CalculateTool(), WebSearchTool(), NewsTool(), HackerNewsTool(),
         WikipediaTool(), CountryInfoTool(), HolidaysTool(), CurrencyTool()]
    }
}
