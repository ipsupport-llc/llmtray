import Foundation
import LLMTrayCore

/// Where a weather tool's question is about: the `city` asked for, or --
/// without one -- the user's own, from the Mac's time zone (nothing is
/// looked up about the user). The result says which, so the model can ask
/// when the time zone's city isn't where the user is.
@MainActor
enum WeatherPlace {
    struct Resolved {
        let place: Geocoder.Place
        let note: [String: Any]
    }

    enum Failure: Error { case notFound(String) }

    static func resolve(_ arguments: [String: Any]) async throws -> Resolved {
        if let city = (arguments["city"] as? String)?.trimmingCharacters(in: .whitespaces), !city.isEmpty {
            guard let place = try await Geocoder.find(city, countryCode: arguments["country_code"] as? String) else {
                throw Failure.notFound("no city called \(city) found")
            }
            return Resolved(place: place, note: ["location": label(place)])
        }
        let home = Geocoder.homeCity()
        // GMT / UTC / Etc/GMT+3 name no city.
        if home.zone == "GMT" || home.zone == "UTC" || home.zone.hasPrefix("Etc/") || !home.zone.contains("/") {
            throw Failure.notFound("the user's city isn't known (time zone \(home.zone)): ask them which city")
        }
        // The Mac's region may not be the country of its time zone (region
        // Canada, zone Europe/London: not London, Ontario): the place must
        // be in that zone.
        var found = try await Geocoder.find(home.city, countryCode: home.countryCode)
        if found?.timezone != home.zone {
            let anywhere = try await Geocoder.find(home.city, countryCode: nil)
            if anywhere?.timezone == home.zone || found == nil { found = anywhere }
        }
        guard let place = found else {
            throw Failure.notFound("the user's city isn't known (time zone \(home.zone)): ask them which city")
        }
        return Resolved(place: place, note: [
            "location": label(place),
            "location_source": "the Mac's time zone (\(home.zone)); if the user may be elsewhere, say which city this is for",
        ])
    }

    /// "Kyiv, Ukraine"; just the name where the geocoder has no country.
    static func label(_ place: Geocoder.Place) -> String {
        [place.name, place.country].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func message(_ error: Error) -> String {
        if case Failure.notFound(let text) = error { return text }
        return "weather lookup failed: \(error.localizedDescription)"
    }
}

/// Units: the `units` argument, else the Mac's measurement system.
enum WeatherUnits {
    static func imperial(_ arguments: [String: Any]) -> Bool {
        switch (arguments["units"] as? String)?.lowercased() {
        case "imperial", "us", "fahrenheit": return true
        case "metric", "celsius": return false
        default: return Locale.current.measurementSystem == .us
        }
    }

    static func query(_ imperial: Bool) -> [URLQueryItem] {
        imperial ? [URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
                    URLQueryItem(name: "wind_speed_unit", value: "mph"),
                    URLQueryItem(name: "precipitation_unit", value: "inch")]
            : [URLQueryItem(name: "wind_speed_unit", value: "kmh")]
    }

    static func describe(_ imperial: Bool) -> [String: String] {
        imperial ? ["temperature": "°F", "wind": "mph", "precipitation": "inch"]
            : ["temperature": "°C", "wind": "km/h", "precipitation": "mm"]
    }
}

class WeatherTool: SelectableTool {
    nonisolated static let attribution = "Weather data by Open-Meteo (https://open-meteo.com), CC BY 4.0"

    static let placeProperties: [String: Any] = [
        "city": string("A single city name, e.g. \"Kyiv\" -- never a comma-separated address. Omit for the user's own location."),
        "country_code": string("Optional ISO-3166 alpha-2 code, e.g. \"UA\", to pick the right city."),
        "units": string("\"metric\" or \"imperial\". Omit for the user's usual units."),
    ]

    func forecast(_ place: Geocoder.Place, _ query: [URLQueryItem], imperial: Bool) async throws -> [String: Any] {
        try await WebFetch.json("https://api.open-meteo.com/v1/forecast", query: [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "timezone", value: place.timezone),
        ] + query + WeatherUnits.query(imperial))
    }

    /// "today" / "tomorrow" / weekday for a yyyy-MM-dd in the place's zone.
    static func dayLabel(_ ymd: String, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        // Noon: a DST change at midnight (Santiago, Havana) has no 00:00.
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let day = f.date(from: String(ymd.prefix(10)) + " 12:00") else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDateInToday(day) { return "today" }
        if calendar.isDateInTomorrow(day) { return "tomorrow" }
        f.dateFormat = "EEEE"
        return f.string(from: day)
    }
}

final class CurrentWeatherTool: WeatherTool {
    init() { super.init(name: "get_weather") }

    override var definition: [String: Any] {
        var properties = Self.placeProperties
        properties["days"] = Self.integer("Days of daily forecast, 1-16 (default 3; 1 = just today, 7 for \"this weekend\" or \"this week\").")
        return Self.function(
            name,
            "Current weather and the daily forecast for a city (\"what's the weather in Lviv?\", \"will it rain "
                + "tomorrow?\", \"weather this weekend\"). Without `city` it's for the user's own location. Days come "
                + "labelled today / tomorrow / weekday in the city's time zone: no need to get the date first.",
            properties: properties
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let days = max(1, min(16, (arguments["days"] as? Int) ?? Int(arguments["days"] as? String ?? "") ?? 3))
        let imperial = WeatherUnits.imperial(arguments)
        do {
            let resolved = try await WeatherPlace.resolve(arguments)
            let data = try await forecast(resolved.place, [
                URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,is_day"),
                URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,uv_index_max,sunrise,sunset"),
                URLQueryItem(name: "forecast_days", value: String(days)),
            ], imperial: imperial)
            var current = OpenMeteoFormat.current(data, names: [
                "time": "time", "temperature_2m": "temperature", "apparent_temperature": "feels_like",
                "relative_humidity_2m": "humidity_percent", "precipitation": "precipitation", "weather_code": "conditions",
                "wind_speed_10m": "wind_speed", "wind_gusts_10m": "wind_gusts", "is_day": "daytime",
            ])
            if let direction = ((data["current"] as? [String: Any])?["wind_direction_10m"] as? NSNumber)?.doubleValue {
                current["wind_from"] = OpenMeteoFormat.compass(direction)
            }
            let zone = TimeZone(identifier: resolved.place.timezone) ?? .current
            let daily = OpenMeteoFormat.rows(data, section: "daily", names: [
                "weather_code": "conditions", "temperature_2m_max": "max", "temperature_2m_min": "min",
                "precipitation_sum": "precipitation", "precipitation_probability_max": "precipitation_chance_percent",
                "wind_speed_10m_max": "wind_max", "uv_index_max": "uv_index_max", "sunrise": "sunrise", "sunset": "sunset",
            ]).map { row -> [String: Any] in
                var row = row
                if let ymd = row.removeValue(forKey: "time") as? String {
                    row["date"] = ymd
                    row["day"] = Self.dayLabel(ymd, zone: zone)
                }
                return row
            }
            var result = resolved.note
            result["timezone"] = resolved.place.timezone
            result["units"] = WeatherUnits.describe(imperial)
            result["current"] = current
            result["daily"] = daily
            result["source"] = Self.attribution
            return Self.json(result)
        } catch {
            return Self.error(WeatherPlace.message(error))
        }
    }
}

final class HourlyForecastTool: WeatherTool {
    init() { super.init(name: "get_hourly_forecast") }

    override var definition: [String: Any] {
        var properties = Self.placeProperties
        properties["hours"] = Self.integer("Hours ahead, 1-48 (default 12).")
        return Self.function(
            name,
            "Hour-by-hour forecast for the next hours (\"will it rain this evening?\", \"when does the rain stop?\"). "
                + "Without `city` it's for the user's own location. Hours come labelled with their day (today / tomorrow) in "
                + "the city's time zone.",
            properties: properties
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        let hours = max(1, min(48, (arguments["hours"] as? Int) ?? Int(arguments["hours"] as? String ?? "") ?? 12))
        let imperial = WeatherUnits.imperial(arguments)
        do {
            let resolved = try await WeatherPlace.resolve(arguments)
            let data = try await forecast(resolved.place, [
                URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m"),
                URLQueryItem(name: "forecast_hours", value: String(hours)),
            ], imperial: imperial)
            var result = resolved.note
            result["timezone"] = resolved.place.timezone
            result["units"] = WeatherUnits.describe(imperial)
            let zone = TimeZone(identifier: resolved.place.timezone) ?? .current
            result["hourly"] = OpenMeteoFormat.rows(data, section: "hourly", names: [
                "temperature_2m": "temperature", "precipitation_probability": "precipitation_chance_percent",
                "precipitation": "precipitation", "weather_code": "conditions", "wind_speed_10m": "wind_speed",
            ], limit: hours).map { row -> [String: Any] in
                var row = row
                if let time = row["time"] as? String { row["day"] = Self.dayLabel(time, zone: zone) }
                return row
            }
            result["source"] = Self.attribution
            return Self.json(result)
        } catch {
            return Self.error(WeatherPlace.message(error))
        }
    }
}

final class AirQualityTool: WeatherTool {
    init() { super.init(name: "get_air_quality") }

    nonisolated static let airAttribution = "Air quality by Open-Meteo (https://open-meteo.com), CAMS, CC BY 4.0"

    override var definition: [String: Any] {
        var properties = Self.placeProperties
        properties.removeValue(forKey: "units")
        return Self.function(
            name,
            "Current air quality (AQI, PM2.5, PM10, ozone, NO2) and UV index for a city (\"is the air ok in Delhi?\"). "
                + "Without `city` it's for the user's own location.",
            properties: properties
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        do {
            let resolved = try await WeatherPlace.resolve(arguments)
            let data = try await WebFetch.json("https://air-quality-api.open-meteo.com/v1/air-quality", query: [
                URLQueryItem(name: "latitude", value: String(resolved.place.latitude)),
                URLQueryItem(name: "longitude", value: String(resolved.place.longitude)),
                URLQueryItem(name: "timezone", value: resolved.place.timezone),
                URLQueryItem(name: "current", value: "european_aqi,us_aqi,pm2_5,pm10,ozone,nitrogen_dioxide,uv_index"),
            ])
            var result = resolved.note
            result["timezone"] = resolved.place.timezone
            result["current"] = OpenMeteoFormat.current(data, names: [
                "time": "time", "european_aqi": "european_aqi", "us_aqi": "us_aqi", "pm2_5": "pm2_5_ug_m3",
                "pm10": "pm10_ug_m3", "ozone": "ozone_ug_m3", "nitrogen_dioxide": "no2_ug_m3", "uv_index": "uv_index",
            ])
            result["scale"] = "European AQI: 0-20 good, 20-40 fair, 40-60 moderate, 60-80 poor, 80-100 very poor, 100+ extremely poor. "
                + "US AQI: 0-50 good, 51-100 moderate, 101-150 unhealthy for sensitive groups, 151-200 unhealthy, 201-300 very unhealthy, 301+ hazardous."
            result["source"] = Self.airAttribution
            return Self.json(result)
        } catch {
            return Self.error(WeatherPlace.message(error))
        }
    }
}

final class SunTool: WeatherTool {
    init() { super.init(name: "get_sunrise_sunset") }

    override var definition: [String: Any] {
        var properties = Self.placeProperties
        properties.removeValue(forKey: "units")
        properties["date"] = Self.string("yyyy-MM-dd. Omit for today (in that city).")
        return Self.function(
            name,
            "Sunrise, sunset, solar noon, civil twilight and day length for a city on a date (\"when is sunset in "
                + "Rome?\", \"how long is the day on December 21 in Oslo?\"). Without `city` it's for the user's own location; "
                + "without `date`, today there (no need to get the date first). Years 1900-2100.",
            properties: properties
        )
    }

    override func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        do {
            let resolved = try await WeatherPlace.resolve(arguments)
            let zone = TimeZone(identifier: resolved.place.timezone) ?? .current
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = "yyyy-MM-dd HH:mm"
            var date = Date()
            if let text = (arguments["date"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                // Strict: "26-09-24" isn't year 26, and the formulas drift
                // far from the present (a 14 h December day in Rome in 9999).
                let check = DateFormatter()
                check.locale = Locale(identifier: "en_US_POSIX")
                check.timeZone = zone
                check.dateFormat = "yyyy-MM-dd"
                guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                      let year = Int(text.prefix(4)), (1900...2100).contains(year),
                      let parsed = f.date(from: text + " 12:00"), check.string(from: parsed) == text else {
                    return Self.error("date must be yyyy-MM-dd, years 1900-2100")
                }
                date = parsed
            }
            let day = SolarCalculator.day(date, latitude: resolved.place.latitude, longitude: resolved.place.longitude, zone: zone)
            f.dateFormat = "yyyy-MM-dd"
            let asked = f.string(from: date)
            /// HH:mm, with the date when it falls on another day (a sunset
            /// after midnight in Reykjavik in June).
            func time(_ t: Date) -> String {
                f.dateFormat = "yyyy-MM-dd"
                let day = f.string(from: t)
                f.dateFormat = "HH:mm"
                return day == asked ? f.string(from: t) : "\(f.string(from: t)) (\(day))"
            }
            func text(_ event: SolarCalculator.Event) -> String {
                switch event {
                case .time(let t): return time(t)
                case .alwaysAbove: return "none (the sun stays up all day)"
                case .alwaysBelow: return "none (the sun stays down all day)"
                }
            }
            func twilight(_ event: SolarCalculator.Event) -> String {
                switch event {
                case .time(let t): return time(t)
                case .alwaysAbove: return "none (it never gets darker than civil twilight)"
                case .alwaysBelow: return "none (it stays darker than civil twilight all day)"
                }
            }
            var result = resolved.note
            result["date"] = asked
            result["timezone"] = resolved.place.timezone
            result["sunrise"] = text(day.sunrise)
            result["sunset"] = text(day.sunset)
            result["solar_noon"] = time(day.solarNoon)
            result["civil_dawn"] = twilight(day.civilDawn)
            result["civil_dusk"] = twilight(day.civilDusk)
            let minutes = Int((day.daylight / 60).rounded())
            result["day_length"] = "\(minutes / 60)h \(minutes % 60)m"
            result["source"] = Geocoder.attribution
            return Self.json(result)
        } catch {
            return Self.error(WeatherPlace.message(error))
        }
    }
}
