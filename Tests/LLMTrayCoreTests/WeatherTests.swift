import XCTest
@testable import LLMTrayCore

final class WeatherTests: XCTestCase {
    private func local(_ event: SolarCalculator.Event, _ zone: String) -> String? {
        guard case .time(let date) = event else { return nil }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: zone)
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func minutes(_ hhmm: String?) -> Int {
        let p = (hhmm ?? "").split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : -9999
    }

    private func day(_ ymd: String, _ lat: Double, _ lon: Double, _ zone: String) -> SolarCalculator.Day {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: zone)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return SolarCalculator.day(f.date(from: ymd + " 12:00")!, latitude: lat, longitude: lon, zone: TimeZone(identifier: zone)!)
    }

    /// US Naval Observatory's figures (aa.usno.navy.mil/api/rstt/oneday),
    /// to within 2 minutes: rise, set, civil twilight begin / end.
    func testKnownPlaces() {
        let cases: [(String, Double, Double, String, [String])] = [
            ("2025-06-21", 50.45, 30.52, "Europe/Kyiv", ["04:46", "21:13", "04:01", "21:59"]),
            ("2025-12-21", 40.71, -74.01, "America/New_York", ["07:17", "16:32", "06:46", "17:03"]),
            ("2025-03-20", -33.87, 151.21, "Australia/Sydney", ["06:58", "19:07", "06:33", "19:32"]),
        ]
        for (date, lat, lon, zone, expected) in cases {
            let d = day(date, lat, lon, zone)
            let got = [d.sunrise, d.sunset, d.civilDawn, d.civilDusk].map { local($0, zone) }
            for (g, e) in zip(got, expected) {
                XCTAssertLessThanOrEqual(abs(minutes(g) - minutes(e)), 2, "\(zone): \(got) vs \(expected)")
            }
        }
        let kyiv = day("2025-06-21", 50.45, 30.52, "Europe/Kyiv")
        XCTAssertEqual(kyiv.daylight / 3600, 16.45, accuracy: 0.1)
        guard case .time(let dawn) = kyiv.civilDawn, case .time(let rise) = kyiv.sunrise else { return XCTFail() }
        XCTAssertLessThan(dawn, rise)
    }

    func testPolar() {
        let summer = day("2025-06-21", 69.65, 18.96, "Europe/Oslo")
        XCTAssertEqual(summer.sunrise, .alwaysAbove)
        XCTAssertEqual(summer.daylight, 86400)
        let winter = day("2025-12-21", 69.65, 18.96, "Europe/Oslo")
        XCTAssertEqual(winter.sunset, .alwaysBelow)
        XCTAssertEqual(winter.daylight, 0)
    }

    func testFormat() throws {
        let json = #"{"current":{"time":"2026-09-25T01:30","temperature_2m":10.2,"weather_code":2,"is_day":0,"wind_speed_10m":null},"daily":{"time":["2026-09-25","2026-09-26"],"weather_code":[3,61],"temperature_2m_max":[16.2,19.2],"precipitation_sum":[0.0]}}"#
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let current = OpenMeteoFormat.current(obj, names: ["temperature_2m": "temperature", "weather_code": "conditions", "is_day": "daytime", "wind_speed_10m": "wind"])
        XCTAssertEqual(current["conditions"] as? String, "partly cloudy")
        XCTAssertEqual(current["daytime"] as? Bool, false)
        XCTAssertNil(current["wind"], "nulls are left out")
        let rows = OpenMeteoFormat.rows(obj, section: "daily", names: ["weather_code": "conditions", "temperature_2m_max": "max", "precipitation_sum": "precipitation"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1]["conditions"] as? String, "light rain")
        XCTAssertNil(rows[1]["precipitation"], "short column")
        XCTAssertEqual(OpenMeteoFormat.rows(obj, section: "daily", names: [:], limit: 1).count, 1)
        XCTAssertEqual(OpenMeteoFormat.compass(222), "SW")
        XCTAssertEqual(OpenMeteoFormat.compass(359), "N")
        XCTAssertEqual(OpenMeteoFormat.compass(-45), "NW")
    }
}
