import Foundation
import LLMTrayCore

/// A tool that's switched on per profile (`enabledTools`).
@MainActor
class SelectableTool: ChatTool {
    let name: String
    init(name: String) { self.name = name }
    var definition: [String: Any] { [:] }
    func isOffered(_ settings: ChatSettings) -> Bool { settings.enabledTools.contains(name) }
    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult { .text("not implemented") }

    /// The declaration shape every tool uses.
    static func function(_ name: String, _ description: String, properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": ["type": "object", "properties": properties, "required": required],
            ],
        ]
    }

    static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }

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
            return NSDecimalNumber(string: String(d))
        default:
            return value
        }
    }
}

// MARK: - Date and time

final class CurrentDateTool: SelectableTool {
    init() { super.init(name: "get_current_date") }

    override var definition: [String: Any] {
        Self.function(
            name,
            "Today's date, weekday and local time. Call it first whenever the user says today, tomorrow, "
                + "yesterday, a weekday or \"now\" -- you don't know the current date otherwise.",
            properties: ["timezone": Self.string("IANA time zone like \"Europe/Kyiv\" or \"UTC\". Omit for the user's own.")]
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let zone: TimeZone
        if let id = arguments["timezone"] as? String, !id.isEmpty {
            guard let tz = TimeZone(identifier: id) else { return Self.error("unknown time zone \(id)") }
            zone = tz
        } else {
            zone = .current
        }
        return Self.json(Self.describe(Date(), in: zone))
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

final class TimeInCityTool: SelectableTool {
    init() { super.init(name: "get_current_time_in_city") }

    override var definition: [String: Any] {
        Self.function(
            name,
            "The current local date and time in a city (\"what time is it in Tokyo?\"). `city` is a single "
                + "place name, never a comma-separated address; put the country in `country_code`.",
            properties: [
                "city": Self.string("City name, e.g. \"Kyiv\"."),
                "country_code": Self.string("Optional ISO-3166 alpha-2 code, e.g. \"UA\", to pick the right city."),
            ],
            required: ["city"]
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard let city = (arguments["city"] as? String)?.trimmingCharacters(in: .whitespaces), !city.isEmpty else {
            return Self.error("city is required")
        }
        do {
            guard let place = try await Geocoder.find(city, countryCode: arguments["country_code"] as? String),
                  let zone = TimeZone(identifier: place.timezone) else {
                return Self.error("no city called \(city) found")
            }
            var result = CurrentDateTool.describe(Date(), in: zone)
            result["city"] = place.name
            result["country"] = place.country
            // Open-Meteo's data is CC BY 4.0 (shown under the answer).
            result["source"] = Geocoder.attribution
            return Self.json(result)
        } catch {
            return Self.error("city lookup failed: \(error.localizedDescription)")
        }
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
    /// language: the script's languages first, English last.
    static func find(_ city: String, countryCode: String?) async throws -> Place? {
        for language in ScriptLanguage.wikipediaCandidates(for: city) {
            var query = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1"),
                         URLQueryItem(name: "language", value: language)]
            if let cc = countryCode, cc.count == 2, cc.allSatisfy({ $0.isASCII && $0.isLetter }) {
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

    override var definition: [String: Any] {
        Self.function(
            name,
            "Evaluate an arithmetic expression exactly. Use it for ANY numeric answer instead of computing in "
                + "your head (multi-digit multiplication, percentages, powers, rounding). Supports + - * / // % "
                + "^ **, parentheses, pi, e, and sqrt, cbrt, log(x[, base]), log10, log2, exp, sin, cos, tan, "
                + "asin, acos, atan, floor, ceil, round(x[, digits]), abs, min, max, hypot, factorial, gcd, lcm. "
                + "Examples: \"3847 * 29\", \"2450 * 15 / 100\", \"sqrt(2450)\", \"log(8, 2)\".",
            properties: ["expression": Self.string("The expression, e.g. \"(300 + 50) * 1.08 / 2\".")],
            required: ["expression"]
        )
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
