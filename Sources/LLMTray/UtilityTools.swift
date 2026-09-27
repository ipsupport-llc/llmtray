import Foundation
import LLMTrayCore

/// A tool that's switched on per profile (`enabledTools`). One tool can
/// serve several of ToolCatalog's switches, a mode each (web_search: web,
/// news, wikipedia, hackernews): fewer tools for the model to tell apart
/// and fewer tokens in every request, the same switches for the user. Only
/// the modes switched on are declared.
@MainActor
class SelectableTool: ChatTool {
    let name: String
    /// The ToolCatalog entries this tool serves, the default mode first.
    let entries: [String]

    init(name: String, entries: [String]? = nil) {
        self.name = name
        self.entries = entries ?? [name]
    }

    /// The declaration offering these of `entries` (never empty).
    func schema(offering entries: [String]) -> ToolSchema { ToolSchema(name, "") }

    /// Every mode: what a call is read against.
    var schema: ToolSchema? { schema(offering: entries) }
    var definition: [String: Any] { schema(offering: entries).definition }

    /// The modes switched on in `settings` -- without the ones that reach
    /// the network when `allowGuarded` is false (the trust barrier).
    func offeredEntries(_ settings: ChatSettings, allowGuarded: Bool = true) -> [String] {
        entries.filter { settings.enabledTools.contains($0) && (allowGuarded || !ToolCatalog.usesNetwork($0)) }
    }

    func definition(for settings: ChatSettings, allowGuarded: Bool) -> [String: Any]? {
        let offered = offeredEntries(settings, allowGuarded: allowGuarded)
        return offered.isEmpty ? nil : schema(offering: offered).definition
    }

    func isOffered(_ settings: ChatSettings) -> Bool { !offeredEntries(settings).isEmpty }

    /// The entry (mode) a call is for.
    func entry(for arguments: [String: Any]) -> String { entries[0] }

    /// A call for `entry` may run in `settings`.
    func isModeOn(_ entry: String, _ settings: ChatSettings) -> Bool { settings.enabledTools.contains(entry) }

    /// The call says which mode it wants (source, kind, about) rather than
    /// taking the default.
    func namesMode(_ arguments: [String: Any]) -> Bool { false }

    /// The mode a call runs in: the one it names, else its default -- or,
    /// when that one is switched off, the first that's on.
    func mode(for arguments: [String: Any], _ settings: ChatSettings) -> String {
        let asked = entry(for: arguments)
        if isModeOn(asked, settings) || namesMode(arguments) { return asked }
        return offeredEntries(settings).first ?? asked
    }

    /// How a mode reads in an error ("source=news").
    func modeLabel(_ entry: String) -> String { entry }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult { .text("not implemented") }

    /// A tool result as compact JSON.
    static func json(_ value: Any) -> ToolResult {
        let value = shortestNumbers(value)
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return .text("\(value)")
        }
        return .text(String(decoding: data, as: UTF8.self))
    }

    static func error(_ message: String) -> ToolResult { json(["error": message]) }

    /// A result made by `error(_:)`: counted as a failed call.
    static func isError(_ text: String) -> Bool { text.hasPrefix("{\"error\":") }

    /// JSONSerialization writes a parsed 47.4 as 47.399999999999999: every
    /// fractional number is re-encoded from its shortest form (booleans and
    /// integers stay as they are).
    static func shortestNumbers(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues(shortestNumbers)
        case let array as [Any]:
            return array.map(shortestNumbers)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID() && !(number is NSDecimalNumber):
            let d = number.doubleValue
            guard d.isFinite, d != d.rounded() else { return number }
            let decimal = NSDecimalNumber(string: String(d))
            // Out of Decimal's range (1e-200): as it was.
            return decimal == .notANumber ? number : decimal
        default:
            return value
        }
    }
}

/// The city fields the time and weather tools share.
enum PlaceParams {
    static let city = ToolSchema.Param("city", .string, "Omit for the user's own.", aliases: ["location", "place", "town", "city_name"])
    static let countryCode = ToolSchema.Param("country_code", .string,
                                              aliases: ["country", "cc", "countrycode"])
}

// MARK: - Date and time

/// `get_current_time`: the date and time here (local, no network) or in a
/// city (looked up: the "Time in a city" switch).
final class CurrentTimeTool: SelectableTool {
    static let localEntry = "get_current_date"
    static let cityEntry = "get_current_time_in_city"

    init() { super.init(name: "get_current_time", entries: [Self.localEntry, Self.cityEntry]) }

    override func schema(offering entries: [String]) -> ToolSchema {
        var params: [ToolSchema.Param] = []
        if entries.contains(Self.cityEntry) {
            var city = PlaceParams.city
            city.aliases += ["timezone", "tz", "zone", "time_zone"]
            params = [city, PlaceParams.countryCode]
        }
        return ToolSchema(name, "Current date, weekday and time\(params.isEmpty ? "" : ", here or in a city"). "
                          + "Call it for today, tomorrow, a weekday or now: you don't know the date otherwise.", params)
    }

    override func entry(for arguments: [String: Any]) -> String {
        (arguments["city"] as? String).map { !$0.isEmpty && TimeZone(identifier: $0) == nil } == true ? Self.cityEntry : Self.localEntry
    }

    override func modeLabel(_ entry: String) -> String { entry == Self.cityEntry ? "city" : "local time" }

    override func namesMode(_ arguments: [String: Any]) -> Bool { entry(for: arguments) == Self.cityEntry }

    /// The local time needs no switch of its own once the tool is offered.
    override func isModeOn(_ entry: String, _ settings: ChatSettings) -> Bool {
        entry == Self.localEntry ? isOffered(settings) : super.isModeOn(entry, settings)
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let city = arguments["city"] as? String, !city.isEmpty else { return Self.json(Self.describe(Date(), in: .current)) }
        // An IANA zone ("UTC", "Europe/Kyiv"), as the former date tool took.
        if let zone = TimeZone(identifier: city) { return Self.json(Self.describe(Date(), in: zone)) }
        do {
            guard let place = try await Geocoder.find(city, countryCode: arguments["country_code"] as? String),
                  let zone = TimeZone(identifier: place.timezone) else {
                return Self.error("no city called \(city) found")
            }
            var result = Self.describe(Date(), in: zone)
            result["city"] = place.name
            result["country"] = place.country
            // Open-Meteo's data is CC BY 4.0 (shown under the answer).
            result["source"] = Geocoder.attribution
            return Self.json(result)
        } catch {
            return Self.error("city lookup failed: \(error.localizedDescription)")
        }
    }

    static func describe(_ date: Date, in zone: TimeZone) -> [String: Any] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: date)
        f.dateFormat = "EEEE"
        let weekday = f.string(from: date)
        f.dateFormat = "HH:mm"
        let time = f.string(from: date)
        f.dateFormat = "xxx"
        return ["date": day, "weekday": weekday, "time": time, "timezone": zone.identifier, "utc_offset": f.string(from: date)]
    }
}

/// City lookup (Open-Meteo geocoding) for the time and weather tools.
enum Geocoder {
    struct Place {
        let name: String
        let country: String
        let latitude: Double
        let longitude: Double
        let timezone: String
    }

    nonisolated static let attribution = "City lookup by Open-Meteo (https://open-meteo.com), CC BY 4.0, GeoNames"

    /// `city` (one place name) in `countryCode` (ISO alpha-2) if given.
    /// Open-Meteo matches a non-Latin name ("Москва", "Харків") only in its
    /// language: the script's languages first, English last. "Kyiv,
    /// Ukraine" (the geocoder takes one name) is tried as "Kyiv" when the
    /// whole doesn't match.
    static func find(_ city: String, countryCode: String?) async throws -> Place? {
        if let place = try await findName(city, countryCode: countryCode) { return place }
        if let comma = city.firstIndex(of: ",") {
            let first = city[..<comma].trimmingCharacters(in: .whitespaces)
            if !first.isEmpty { return try await findName(first, countryCode: countryCode) }
        }
        return nil
    }

    private static func findName(_ city: String, countryCode: String?) async throws -> Place? {
        for language in ScriptLanguage.wikipediaCandidates(for: city) {
            var query = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1"),
                         URLQueryItem(name: "language", value: language)]
            if let cc = countryCode?.trimmingCharacters(in: .whitespaces), cc.count == 2, cc.allSatisfy({ $0.isASCII && $0.isLetter }) {
                query.append(URLQueryItem(name: "countryCode", value: cc.uppercased()))
            }
            let geo = try await WebFetch.json("https://geocoding-api.open-meteo.com/v1/search", query: query)
            if let first = (geo["results"] as? [[String: Any]])?.first,
               let lat = (first["latitude"] as? NSNumber)?.doubleValue, let lon = (first["longitude"] as? NSNumber)?.doubleValue,
               let tz = first["timezone"] as? String {
                return Place(name: first["name"] as? String ?? city, country: first["country"] as? String ?? "",
                             latitude: lat, longitude: lon, timezone: tz)
            }
        }
        return nil
    }

    /// Where the user is, as far as the Mac's own time zone tells
    /// ("Europe/Kyiv" -> Kyiv): nothing leaves the machine to find out.
    static func homeCity() -> (city: String, countryCode: String?, zone: String) {
        let zone = TimeZone.current.identifier
        let city = (zone.split(separator: "/").last.map(String.init) ?? zone).replacingOccurrences(of: "_", with: " ")
        return (city, Locale.current.region?.identifier, zone)
    }
}

// MARK: - Calculator

final class CalculateTool: SelectableTool {
    init() { super.init(name: "calculate") }

    override func schema(offering entries: [String]) -> ToolSchema {
        // The rest of the functions are named by the error for an unknown one.
        ToolSchema(name, "Evaluate a math expression exactly; use it for any arithmetic instead of computing in your head. "
                   + "+ - * / // % ^, parentheses, pi, e, sqrt, log(x, base), sin, cos, round(x, digits), min, max, "
                   + "factorial, gcd and more; 15% of 2450.", [
                       .init("expression", .string, required: true, aliases: ["expr", "formula", "equation", "math", "query", "calculation"]),
                   ])
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let expression = arguments["expression"] as? String else { return Self.error("expression is required") }
        do {
            return Self.json(["expression": expression, "result": Calculator.format(try Calculator.evaluate(expression))])
        } catch {
            return Self.error(error.localizedDescription)
        }
    }
}

// MARK: - HTTP

/// Fetching for the web tools: a timeout, an honest User-Agent, JSON or text.
enum WebFetch {
    /// Who's asking, with where to find out more -- what Wikimedia's
    /// User-Agent policy asks for, and honest toward every other service
    /// (no browser impersonation). Checked live against each tool's
    /// service when this replaced a Safari-like agent.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "LLMTray/\(version) (https://github.com/ipsupport-llc/llmtray)"
    }()

    /// Ephemeral: no disk cache, no cookies -- the model's queries (and the
    /// answers) must not end up on disk, least of all from a temporary chat.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    struct HTTPError: LocalizedError {
        let status: Int
        let service: String
        var errorDescription: String? { "\(service) answered HTTP \(status)" }
    }

    static func data(_ base: String, query: [URLQueryItem] = [], method: String = "GET", form: [URLQueryItem]? = nil, timeout: TimeInterval = 12) async throws -> Data {
        guard var components = URLComponents(string: base) else { throw URLError(.badURL) }
        // URLComponents leaves "+" as is, which servers read as a space:
        // "C++" would arrive as "C  ".
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let form {
            var body = URLComponents()
            body.queryItems = form
            request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode, service: url.host ?? base)
        }
        return data
    }

    static func json(_ base: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        let data = try await data(base, query: query)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return obj
    }

    static func jsonArray(_ base: String, query: [URLQueryItem] = []) async throws -> [Any] {
        let data = try await data(base, query: query)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw URLError(.cannotParseResponse)
        }
        return obj
    }
}
