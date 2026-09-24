import Foundation

/// Sunrise, sunset, solar noon and civil twilight for any date and place,
/// computed locally (the NOAA / "sunrise equation" formulas: good to about
/// a minute outside the polar circles), so it needs no network.
public enum SolarCalculator {
    public enum Event: Equatable {
        case time(Date)
        /// The sun doesn't cross that altitude that day.
        case alwaysAbove, alwaysBelow
    }

    public struct Day: Equatable {
        public var sunrise: Event
        public var sunset: Event
        public var solarNoon: Date
        public var civilDawn: Event
        public var civilDusk: Event
        /// Seconds of sun above the horizon (0 in polar night, 86400 in polar day).
        public var daylight: TimeInterval
    }

    /// The day `date` falls on in `zone`, at latitude/longitude (east positive).
    public static func day(_ date: Date, latitude: Double, longitude: Double, zone: TimeZone) -> Day {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.date(from: parts)!   // that calendar day, 00:00 UTC
        let julianDate = midnight.timeIntervalSince1970 / 86400 + 2440587.5
        let n0 = (julianDate - 2451545.0 + 0.0008).rounded(.up)
        // The cycle whose solar noon falls on that local date: where a zone
        // is far from its longitude's solar time (Kiritimati, UTC+14 at
        // -157°), the plain formula picks the neighbouring day.
        func transitJD(_ n: Double) -> Double {
            let j = n - longitude / 360
            let m = (357.5291 + 0.98560028 * j).truncatingRemainder(dividingBy: 360) * .pi / 180
            let c = 1.9148 * sin(m) + 0.02 * sin(2 * m) + 0.0003 * sin(3 * m)
            let l = (m * 180 / .pi + c + 180 + 102.9372).truncatingRemainder(dividingBy: 360) * .pi / 180
            return 2451545.0 + j + 0.0053 * sin(m) - 0.0069 * sin(2 * l)
        }
        let n = [n0, n0 - 1, n0 + 1].first { candidate in
            let noon = Date(timeIntervalSince1970: (transitJD(candidate) - 2440587.5) * 86400)
            return calendar.dateComponents([.year, .month, .day], from: noon) == parts
        } ?? n0
        let meanSolarNoon = n - longitude / 360
        let m = (357.5291 + 0.98560028 * meanSolarNoon).truncatingRemainder(dividingBy: 360)
        let mr = m * .pi / 180
        let center = 1.9148 * sin(mr) + 0.02 * sin(2 * mr) + 0.0003 * sin(3 * mr)
        let lambda = (m + center + 180 + 102.9372).truncatingRemainder(dividingBy: 360) * .pi / 180
        let transit = 2451545.0 + meanSolarNoon + 0.0053 * sin(mr) - 0.0069 * sin(2 * lambda)
        let declination = asin(sin(lambda) * sin(23.4397 * .pi / 180))
        let phi = latitude * .pi / 180

        func toDate(_ jd: Double) -> Date { Date(timeIntervalSince1970: (jd - 2440587.5) * 86400) }
        /// Rise and set for the sun's center at `altitude` degrees.
        func crossing(_ altitude: Double) -> (Event, Event, Double) {
            let cosOmega = (sin(altitude * .pi / 180) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination))
            if cosOmega < -1 { return (.alwaysAbove, .alwaysAbove, 1) }
            if cosOmega > 1 { return (.alwaysBelow, .alwaysBelow, 0) }
            let omega = acos(cosOmega) * 180 / .pi
            return (.time(toDate(transit - omega / 360)), .time(toDate(transit + omega / 360)), omega / 180)
        }
        // -0.833°: refraction plus the sun's radius; -6°: civil twilight.
        let (rise, set, fraction) = crossing(-0.833)
        let (dawn, dusk, _) = crossing(-6)
        return Day(sunrise: rise, sunset: set, solarNoon: toDate(transit), civilDawn: dawn, civilDusk: dusk,
                   daylight: fraction * 86400)
    }
}

/// WMO weather interpretation codes (what Open-Meteo reports) in words.
public enum WeatherCode {
    public static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mainly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45: return "fog"
        case 48: return "depositing rime fog"
        case 51: return "light drizzle"
        case 53: return "drizzle"
        case 55: return "dense drizzle"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71: return "light snow"
        case 73: return "snow"
        case 75: return "heavy snow"
        case 77: return "snow grains"
        case 80: return "light rain showers"
        case 81: return "rain showers"
        case 82: return "violent rain showers"
        case 85: return "light snow showers"
        case 86: return "heavy snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return "unknown (code \(code))"
        }
    }
}

/// Open-Meteo's column-per-field responses as rows, for the weather tools.
public enum OpenMeteoFormat {
    /// `section` ("daily", "hourly") of a response as one dictionary per
    /// time step: each requested field under a friendlier name (`names`),
    /// weather codes as words, at most `limit` rows.
    public static func rows(_ response: [String: Any], section: String, names: [String: String], limit: Int = .max) -> [[String: Any]] {
        guard let columns = response[section] as? [String: Any], let times = columns["time"] as? [Any] else { return [] }
        return times.prefix(limit).indices.map { i in
            var row: [String: Any] = ["time": times[i]]
            for (field, name) in names {
                guard let values = columns[field] as? [Any], i < values.count, !(values[i] is NSNull) else { continue }
                if field == "weather_code", let code = (values[i] as? NSNumber)?.intValue {
                    row[name] = WeatherCode.describe(code)
                } else {
                    row[name] = values[i]
                }
            }
            return row
        }
    }

    /// `current` with the same renaming.
    public static func current(_ response: [String: Any], names: [String: String]) -> [String: Any] {
        guard let current = response["current"] as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for (field, name) in names {
            guard let value = current[field], !(value is NSNull) else { continue }
            if field == "weather_code", let code = (value as? NSNumber)?.intValue {
                out[name] = WeatherCode.describe(code)
            } else if field == "is_day", let flag = (value as? NSNumber)?.intValue {
                out[name] = flag == 1
            } else {
                out[name] = value
            }
        }
        return out
    }

    /// Compass point of a wind direction in degrees ("NE").
    public static func compass(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let i = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 22.5).rounded()) % 16
        return points[i]
    }
}
