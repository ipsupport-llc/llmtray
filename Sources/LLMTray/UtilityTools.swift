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
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return .text("\(value)")
        }
        return .text(String(decoding: data, as: UTF8.self))
    }

    static func error(_ message: String) -> ToolResult { json(["error": message]) }
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
        var query = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        if let cc = arguments["country_code"] as? String, !cc.isEmpty { query.append(URLQueryItem(name: "countryCode", value: cc.uppercased())) }
        do {
            let geo = try await WebFetch.json("https://geocoding-api.open-meteo.com/v1/search", query: query)
            guard let place = (geo["results"] as? [[String: Any]])?.first,
                  let tzID = place["timezone"] as? String, let zone = TimeZone(identifier: tzID) else {
                return Self.error("no city called \(city) found")
            }
            var result = CurrentDateTool.describe(Date(), in: zone)
            result["city"] = place["name"] as? String ?? city
            result["country"] = place["country"] as? String ?? ""
            return Self.json(result)
        } catch {
            return Self.error("city lookup failed: \(error.localizedDescription)")
        }
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

/// Fetching for the web tools: a timeout, a browser-like User-Agent (some
/// services refuse a bare one), JSON or text.
enum WebFetch {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 LLMTray"

    /// Wikimedia asks API clients for a descriptive agent with a contact
    /// and throttles browser-like ones (HTTP 429); other services refuse a
    /// bare one.
    static func userAgent(for url: URL) -> String {
        let host = url.host ?? ""
        if host.hasSuffix("wikipedia.org") || host.hasSuffix("wikidata.org") {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            return "LLMTray/\(version) (https://github.com/ipsupport-llc/llmtray)"
        }
        return userAgent
    }

    struct HTTPError: LocalizedError {
        let status: Int
        let service: String
        var errorDescription: String? { "\(service) answered HTTP \(status)" }
    }

    static func data(_ base: String, query: [URLQueryItem] = [], method: String = "GET", form: [URLQueryItem]? = nil, timeout: TimeInterval = 12) async throws -> Data {
        guard var components = URLComponents(string: base) else { throw URLError(.badURL) }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(Self.userAgent(for: url), forHTTPHeaderField: "User-Agent")
        if let form {
            var body = URLComponents()
            body.queryItems = form
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
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
