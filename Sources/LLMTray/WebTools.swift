import Foundation
import LLMTrayCore

// The chat's web tools -- keyless public APIs. Descriptions follow the ones
// tuned for small local models in rromenskyi/mcp-weather-simple. Every
// tool reports failures as {"error": ...} for the model, never throws.

/// `web_search`: the web (DuckDuckGo), news (Google News), Wikipedia and
/// Hacker News as one tool with a `source` -- each still its own switch
/// in Settings, and only the switched-on ones declared.
final class WebSearchTool: SelectableTool {
    static let sources: [(entry: String, value: String, gloss: String)] = [
        ("web_search", "web", "docs, facts, how-tos"),
        ("news", "news", "current events; no query = top headlines"),
        ("get_wikipedia_summary", "wikipedia", "summary of a person, place or topic"),
        ("hackernews", "hackernews", "Hacker News front page"),
    ]

    init() { super.init(name: "web_search", entries: Self.sources.map(\.entry)) }

    override func schema(offering entries: [String]) -> ToolSchema {
        let offered = Self.sources.filter { entries.contains($0.entry) }
        let glosses = offered.enumerated().map { i, s in "\(s.value) (\(i == 0 ? "default; " : "")\(s.gloss))" }
        var params: [ToolSchema.Param] = [
            .init("query", .string, aliases: ["q", "search", "search_query", "search_term", "title", "topic", "term", "keywords", "text"]),
        ]
        if offered.count > 1 {
            params.append(.init("source", .oneOf(offered.map(\.value)), aliases: ["type", "kind", "mode", "engine"], valueAliases: [
                "search": "web", "internet": "web", "duckduckgo": "web", "google": "web", "wiki": "wikipedia", "hn": "hackernews",
                "hacker_news": "hackernews", "hacker news": "hackernews", "headlines": "news",
            ]))
        }
        if offered.contains(where: { $0.value == "news" || $0.value == "wikipedia" }) {
            params.append(.init("lang", .string, "Language code for news and wikipedia.", aliases: ["language", "locale", "hl"]))
        }
        let what = offered.count > 1 ? "Search. source: " + glosses.joined(separator: ", ") + "."
            : "Search: " + (offered.first?.gloss ?? "") + "."
        return ToolSchema(name, what, params)
    }

    override func namesMode(_ arguments: [String: Any]) -> Bool { arguments["source"] != nil }

    override func entry(for arguments: [String: Any]) -> String {
        if let value = arguments["source"] as? String, let s = Self.sources.first(where: { $0.value == value }) { return s.entry }
        return entries[0]
    }

    override func modeLabel(_ entry: String) -> String {
        "source=" + (Self.sources.first { $0.entry == entry }?.value ?? entry)
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let entry = mode(for: arguments, context.settings)
        let query = (arguments["query"] as? String) ?? ""
        switch entry {
        case "news": return await NewsSource.run(query: query, lang: arguments["lang"] as? String)
        case "hackernews": return await HackerNewsSource.run(query: query)
        case "get_wikipedia_summary":
            guard !query.isEmpty else { return Self.error("query is required for source=wikipedia") }
            return await WikipediaSource().run(title: Self.withoutWikipedia(query), lang: arguments["lang"] as? String)
        default:
            guard !query.isEmpty else { return Self.error("query is required for source=web") }
            return await Self.webSearch(query)
        }
    }

    /// "Kyiv Wikipedia" (small models name the source in the query too):
    /// the topic.
    static func withoutWikipedia(_ query: String) -> String {
        let wiki: Set<String> = ["wikipedia", "wiki", "википедия", "википедии", "вікіпедія", "вікіпедії"]
        var words = query.split(separator: " ").map(String.init)
        if let last = words.last, words.count > 1, wiki.contains(last.lowercased()) {
            words.removeLast()
            // "... on Wikipedia", "... в Википедии"
            if let prep = words.last, words.count > 1, ["on", "in", "в", "у"].contains(prep.lowercased()) { words.removeLast() }
        }
        if let first = words.first, words.count > 1, wiki.contains(first.lowercased()) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    static func webSearch(_ query: String, limit: Int = 8) async -> ToolResult {
        do {
            let data = try await WebFetch.data(
                "https://html.duckduckgo.com/html/", method: "POST",
                form: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: "wt-wt")]
            )
            let html = String(decoding: data, as: UTF8.self)
            let results = WebParsing.duckDuckGoResults(html, limit: limit)
            if results.isEmpty, !html.contains("result__a"), !html.contains("no-results") {
                // Neither results nor DDG's "No results" block: its bot check.
                return error("web search is temporarily blocked by DuckDuckGo; try again later or use another source")
            }
            return json(["query": query, "results": results.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet] }])
        } catch {
            return Self.error("search failed: \(error.localizedDescription)")
        }
    }
}

/// Google News for web_search's source=news.
@MainActor
enum NewsSource {
    static func run(query: String, lang: String?, limit: Int = 10) async -> ToolResult {
        let lang = String((lang ?? "en").lowercased().prefix(2))
        let edition = editions[lang] ?? editions["en"]!
        var items = [URLQueryItem(name: "hl", value: edition.hl), URLQueryItem(name: "gl", value: edition.gl),
                     URLQueryItem(name: "ceid", value: "\(edition.gl):\(edition.ceidLang)")]
        var base = "https://news.google.com/rss"
        if !query.isEmpty {
            base += "/search"
            items.insert(URLQueryItem(name: "q", value: query), at: 0)
        }
        do {
            let found = WebParsing.rssItems(try await WebFetch.data(base, query: items), limit: limit)
            return SelectableTool.json(["articles": found.map {
                ["title": $0.title, "url": $0.url, "source": $0.source ?? "", "published": $0.published ?? ""]
            }])
        } catch {
            return SelectableTool.error("news failed: \(error.localizedDescription)")
        }
    }
}

extension NewsSource {
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

/// Hacker News for web_search's source=hackernews.
@MainActor
enum HackerNewsSource {
    static func run(query: String, limit: Int = 15) async -> ToolResult {
        let categories = ["top", "new", "best", "ask", "show", "job"]
        // A query naming a list picks it (new, best, ask, show, job).
        let category = categories.first { $0 == query.lowercased() } ?? "top"
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
            return SelectableTool.json(["category": category, "posts": items.map { rank, item -> [String: Any] in
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
            return SelectableTool.error("Hacker News failed: \(error.localizedDescription)")
        }
    }
}

/// Wikipedia for web_search's source=wikipedia.
@MainActor
final class WikipediaSource {
    func run(title: String, lang: String?) async -> ToolResult {
        // Goes into the host name: only a real language code (not a value a
        // prompt injection could point elsewhere with).
        let lang: String? = lang?.lowercased()
        let requested: String? = lang.flatMap { code in
            code.range(of: #"^[a-z]{2,3}(-[a-z]{2,8})?$"#, options: .regularExpression) != nil ? code : nil
        }
        // The title's own-script Wikipedias first (a Cyrillic or Japanese
        // title 404s on en.wiki), English last.
        let candidates = [requested].compactMap { $0 } + ScriptLanguage.wikipediaCandidates(for: title)
        // One budget for the whole lookup: a miss over several languages on a
        // stalled network mustn't take minutes.
        let deadline = Date().addingTimeInterval(20)
        let langs = NSOrderedSet(array: candidates).compactMap { $0 as? String }
        for (n, lang) in langs.enumerated() where Date() < deadline {
            if let summary = await summary(title, lang: lang) { return SelectableTool.json(summary) }
            // Not an exact title: a prefix match first (not for a question:
            // "what is 50% of?" prefix-matched "What Is Love")...
            if !Self.looksLikeQuestion(title), Date() < deadline, let best = await prefixMatch(title, lang: lang),
               let summary = await summary(best, lang: lang) {
                return SelectableTool.json(summary)
            }
            // ...then full text (also handles a question: "what is
            // photosynthesis"), in the most likely language only -- it
            // always finds *something*, often unrelated, elsewhere.
            if n == 0, Date() < deadline, let best = await fullTextMatch(title, lang: lang),
               let summary = await summary(best, lang: lang) {
                return SelectableTool.json(summary)
            }
        }
        return SelectableTool.error("no Wikipedia article found for \(title)")
    }

    private func prefixMatch(_ query: String, lang: String) async -> String? {
        guard let found = try? await WebFetch.jsonArray("https://\(lang).wikipedia.org/w/api.php", query: [
            URLQueryItem(name: "action", value: "opensearch"), URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "1"), URLQueryItem(name: "format", value: "json"),
        ]), found.count > 1 else { return nil }
        return (found[1] as? [String])?.first
    }

    private func fullTextMatch(_ query: String, lang: String) async -> String? {
        let found = try? await WebFetch.json("https://\(lang).wikipedia.org/w/api.php", query: [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query), URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "srnamespace", value: "0"), URLQueryItem(name: "format", value: "json"),
        ])
        return ((found?["query"] as? [String: Any])?["search"] as? [[String: Any]])?.first?["title"] as? String
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
            // CC BY-SA asks for attribution and the license (shown under the answer).
            "source": "Wikipedia, CC BY-SA 4.0: \(url ?? "https://\(lang).wikipedia.org/wiki/\(slug)")",
        ]
    }
}

extension WikipediaSource {
    /// A question rather than a title ("what is photosynthesis?", "кто такой …").
    static func looksLikeQuestion(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("?") { return true }
        let first = t.split(separator: " ").first.map(String.init) ?? ""
        let words: Set<String> = ["what", "who", "how", "why", "when", "where", "which", "is", "are", "does",
                                  "что", "кто", "как", "почему", "когда", "где", "какой", "какая", "зачем",
                                  "що", "хто", "як", "чому", "коли", "де"]
        return words.contains(first) && t.split(separator: " ").count > 2
    }
}

/// `get_country_info`: a country's facts (Wikidata) or, with
/// about=holidays, its public holidays (Nager.Date) -- two switches, one
/// tool.
final class CountryInfoTool: SelectableTool {
    static let factsEntry = "get_country_info"
    static let holidaysEntry = "get_public_holidays"

    init() { super.init(name: "get_country_info", entries: [Self.factsEntry, Self.holidaysEntry]) }

    override func schema(offering entries: [String]) -> ToolSchema {
        let facts = entries.contains(Self.factsEntry), holidays = entries.contains(Self.holidaysEntry)
        var params: [ToolSchema.Param] = [
            .init("country", .string, "Name in any language or ISO code.", required: true,
                  aliases: ["country_code", "country_name", "name", "code", "iso", "q", "query"]),
        ]
        if facts && holidays {
            params.append(.init("about", .oneOf(["facts", "holidays"]), aliases: ["kind", "type", "mode", "info", "topic"],
                                valueAliases: ["info": "facts", "country": "facts", "holiday": "holidays",
                                               "public_holidays": "holidays", "public holidays": "holidays"]))
        }
        if holidays { params.append(.init("year", .integer, "For holidays; default this year.")) }
        let what = facts && holidays
            ? "Country facts (capital, population, area, currency, languages, calling code, neighbours) or, with about=holidays, its public holidays."
            : facts ? "Country facts: capital, population, area, currency, languages, calling code, neighbours."
            : "A country's public holidays in a year."
        return ToolSchema(name, what, params)
    }

    override func entry(for arguments: [String: Any]) -> String {
        if arguments["about"] as? String == "holidays" { return Self.holidaysEntry }
        if arguments["about"] as? String == "facts" { return Self.factsEntry }
        // A year asks for holidays.
        return arguments["year"] != nil ? Self.holidaysEntry : Self.factsEntry
    }

    override func modeLabel(_ entry: String) -> String { entry == Self.holidaysEntry ? "about=holidays" : "about=facts" }

    /// A year asks for holidays as plainly as about=holidays.
    override func namesMode(_ arguments: [String: Any]) -> Bool { arguments["about"] != nil || arguments["year"] != nil }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let country = (arguments["country"] as? String)?.trimmingCharacters(in: .whitespaces), !country.isEmpty else {
            return Self.error("country is required")
        }
        if mode(for: arguments, context.settings) == Self.holidaysEntry {
            return await HolidaysSource.run(country: country, year: arguments["year"] as? Int)
        }
        return await facts(country)
    }

    private static let api = "https://www.wikidata.org/w/api.php"

    private func facts(_ country: String) async -> ToolResult {
        do {
            guard let (id, entity) = try await Self.findCountry(country) else { return Self.error("no country \(country)") }
            let claims = WikidataClaims(entity)
            let linked = claims.items("P36", currentOnly: true) + claims.items("P38", currentOnly: true)
                + claims.items("P30") + claims.items("P37")
            async let refsLoad = Self.entities(Array(Set(linked)), props: "labels|claims")
            // Neighbours by name: labels only (their full claims made a
            // country with many borders take ~10 s).
            async let neighbourLoad = Self.entities(claims.items("P47", currentOnly: true), props: "labels")
            // Only neighbours that are countries (have an ISO code): P47 also
            // lists the EU, and the search alone includes historical states.
            async let countryNeighbours = Self.countriesBordering(id)
            let (refs, neighbourEntities, countries) = try await (refsLoad, neighbourLoad, countryNeighbours)
            func label(_ id: String) -> String? { WikidataClaims.label(refs[id]) }
            let currencies = claims.items("P38", currentOnly: true).compactMap { id -> String? in
                let code = WikidataClaims(refs[id] ?? [:]).strings("P498").first
                return [code, label(id)].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            }
            let borders: [String] = claims.items("P47", currentOnly: true)
                .filter { countries.contains($0) }
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

    /// Items that have an ISO alpha-2 code and list `id` as a neighbour.
    static func countriesBordering(_ id: String) async throws -> Set<String> {
        let search = try await WebFetch.json(api, query: [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: "haswbstatement:P297 haswbstatement:P47=\(id)"),
            URLQueryItem(name: "srlimit", value: "50"), URLQueryItem(name: "format", value: "json"),
        ])
        return Set(((search["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String })
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

/// Public holidays (Nager.Date) for get_country_info's about=holidays.
enum HolidaysSource {
    /// `country`: an ISO alpha-2 code, else a name looked up on Wikidata.
    @MainActor
    static func run(country: String, year: Int?) async -> ToolResult {
        var code = country.uppercased()
        if !(code.count == 2 && code.allSatisfy({ $0.isASCII && $0.isLetter })) {
            guard let found = try? await CountryInfoTool.findCountry(country),
                  let alpha2 = WikidataClaims(found.1).strings("P297").first else {
                return SelectableTool.error("no country \(country)")
            }
            code = alpha2
        }
        let year = year ?? Calendar.current.component(.year, from: Date())
        do {
            let list = try await WebFetch.jsonArray("https://date.nager.at/api/v3/PublicHolidays/\(year)/\(code)")
            return SelectableTool.json(["country_code": code, "year": year, "holidays": list.compactMap { $0 as? [String: Any] }.map {
                ["date": $0["date"] as? String ?? "", "name": $0["name"] as? String ?? "", "local_name": $0["localName"] as? String ?? ""]
            }])
        } catch let error as WebFetch.HTTPError where error.status == 404 {
            return SelectableTool.error("no holiday data for \(code)")
        } catch {
            return SelectableTool.error("holiday lookup failed: \(error.localizedDescription)")
        }
    }
}

final class CurrencyTool: SelectableTool {
    init() { super.init(name: "convert_currency") }

    /// ExchangeRate-API's open access asks for this credit wherever its
    /// rates are shown.
    nonisolated static let attribution = "Rates By Exchange Rate API (https://www.exchangerate-api.com)"

    /// Rates per base currency until the service's next update (daily):
    /// in memory only, and it keeps repeated questions off their rate limit.
    private static var cache: [String: (rates: [String: Any], until: Date)] = [:]

    private static func rates(for base: String) async throws -> [String: Any] {
        if let hit = cache[base], hit.until > Date() { return hit.rates }
        let rates = try await WebFetch.json("https://open.er-api.com/v6/latest/\(base)")
        if rates["result"] as? String == "success" {
            let next = (rates["time_next_update_unix"] as? Double).map(Date.init(timeIntervalSince1970:))
            cache[base] = (rates, min(next ?? .distantPast, Date().addingTimeInterval(24 * 3600)))
        }
        return rates
    }

    override func schema(offering entries: [String]) -> ToolSchema {
        ToolSchema(name, "Convert money at today's exchange rate. Rates change daily: always call this for a conversion, "
                   + "never assume a rate or use calculate.", [
                       .init("amount", .number, required: true, aliases: ["value", "sum", "quantity"]),
                       .init("from", .string, "ISO 4217 code.", required: true, aliases: ["from_currency", "base", "source", "currency_from", "src"]),
                       .init("to", .string, required: true, aliases: ["to_currency", "target", "currency_to", "dest", "destination"]),
                   ])
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let amount = arguments["amount"] as? Double, amount.isFinite, abs(amount) < 1e15 else {
            return Self.error("amount must be a number")
        }
        guard let from = (arguments["from"] as? String)?.uppercased(), from.count == 3, from.allSatisfy({ $0.isASCII && $0.isLetter }),
              let to = (arguments["to"] as? String)?.uppercased(), to.count == 3, to.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return Self.error("from and to must be 3-letter ISO 4217 codes, like USD")
        }
        do {
            let rates = try await Self.rates(for: from)
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
                "source": Self.attribution,
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
        /// Credit its data source asks for, shown next to the tool.
        var credit: String? = nil
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
        Entry(name: "convert_currency", title: NSLocalizedString("Currency rates", comment: "chat tool"), usesNetwork: true,
              credit: CurrencyTool.attribution),
        Entry(name: "get_weather", title: NSLocalizedString("Weather", comment: "chat tool"), usesNetwork: true,
              credit: WeatherTool.attribution),
        Entry(name: "get_hourly_forecast", title: NSLocalizedString("Hourly forecast", comment: "chat tool"), usesNetwork: true,
              credit: WeatherTool.attribution),
        Entry(name: "get_air_quality", title: NSLocalizedString("Air quality", comment: "chat tool"), usesNetwork: true,
              credit: WeatherTool.airAttribution),
        Entry(name: "get_sunrise_sunset", title: NSLocalizedString("Sunrise & sunset", comment: "chat tool"), usesNetwork: true,
              credit: Geocoder.attribution),
    ]

    /// Whether a switch's tool (or mode) reaches the network.
    static func usesNetwork(_ name: String) -> Bool {
        entries.first { $0.name == name }?.usesNetwork ?? false
    }

    /// The selectable tools: several switches can be one tool's modes
    /// (SelectableTool.entries), so the model sees fewer tools than
    /// Settings lists.
    @MainActor
    static func makeTools() -> [ChatTool] {
        [CurrentTimeTool(), CalculateTool(), WebSearchTool(), CountryInfoTool(), CurrencyTool(), WeatherTool()]
    }
}
