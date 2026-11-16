import Foundation

/// A date the model names to the time tool ("Apr 10, 2024", "2024-04-10",
/// "10.04.2024", "10 апреля 2024", "tomorrow"): read into a calendar day,
/// and that day's weekday and distance from today.
public enum DateQuery {
    public struct Day: Equatable, Sendable {
        public let year: Int
        public let month: Int
        public let day: Int
        /// Read in the user's order from a form that fits both
        /// (04/10/2024): the answer says how it was read.
        public let ambiguous: Bool

        public init(year: Int, month: Int, day: Int, ambiguous: Bool = false) {
            self.year = year
            self.month = month
            self.day = day
            self.ambiguous = ambiguous
        }

        public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    }

    /// Calendar arithmetic on days only: no zone, no daylight saving.
    private static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// The day `text` names, nil when it can't be read. `today` is the
    /// user's day (the year when none is given, and the relative words);
    /// `monthFirst` orders an all-numbers slash form that fits both ways.
    public static func parse(_ text: String, today: Day, monthFirst: Bool) -> Day? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if let offset = relative[s] { return shift(today, by: offset) }

        // ISO first: "2024-04-10", "2024-04-10T12:00:00Z".
        if let m = s.range(of: #"^\d{4}-\d{1,2}-\d{1,2}"#, options: .regularExpression) {
            let n = s[m].split(separator: "-").compactMap { Int($0) }
            return valid(n[0], n[1], n[2])
        }

        // Words and numbers; ordinals ("10th") and a weekday dropped.
        var words: [String] = []
        var numbers: [(value: Int, digits: Int)] = []
        var separators = Set<Character>()
        for token in tokens(s) {
            if let n = Int(token) {
                numbers.append((n, token.count))
            } else if let first = token.first, first.isNumber {
                let digits = token.prefix(while: \.isNumber)
                if ["st", "nd", "rd", "th"].contains(String(token.dropFirst(digits.count))),
                   let n = Int(digits) {
                    numbers.append((n, digits.count))
                } else { return nil }
            } else if token.count == 1, let c = token.first, "./-".contains(c) {
                separators.insert(c)
            } else if token != "," {
                words.append(token)
            }
        }
        let months = words.compactMap(month(named:))
        let others = words.filter { month(named: $0) == nil && !isWeekday($0) && !fillers.contains($0) }
        guard others.isEmpty, months.count <= 1 else { return nil }

        if let month = months.first {
            // "Apr 10, 2024", "10 April 2024", "April 10": a day and maybe a year.
            switch numbers.count {
            case 1:
                guard numbers[0].digits <= 2 else { return nil }
                return valid(today.year, month, numbers[0].value)
            case 2:
                let (a, b) = (numbers[0], numbers[1])
                if b.digits == 4 || (a.digits <= 2 && b.value > 31) { return valid(year(b), month, a.value) }
                if a.digits == 4 || a.value > 31 { return valid(year(a), month, b.value) }
                return nil
            default:
                return nil
            }
        }

        guard numbers.count == 3, separators.count <= 1 else { return nil }
        let (a, b, c) = (numbers[0], numbers[1], numbers[2])
        // 2024/04/10, 2024.04.10.
        if a.digits == 4 { return valid(a.value, b.value, c.value) }
        guard a.digits <= 2, b.digits <= 2, c.digits == 4 || c.digits == 2 else { return nil }
        let y = year(c)
        // Dots and dashes are day-first (10.04.2024); a slash fits both
        // orders: a number over 12 settles it, else the user's order.
        if separators.contains("/") {
            if a.value > 12 { return valid(y, b.value, a.value) }
            if b.value > 12 { return valid(y, a.value, b.value) }
            guard let day = monthFirst ? valid(y, a.value, b.value) : valid(y, b.value, a.value) else { return nil }
            return a.value == b.value ? day : Day(year: day.year, month: day.month, day: day.day, ambiguous: true)
        }
        return valid(y, b.value, a.value)
    }

    /// The tool's answer for `day`: ISO date, weekday (English, as the
    /// rest of the tool) and how many days from `today`.
    public static func describe(_ day: Day, today: Day) -> [String: Any] {
        var out: [String: Any] = ["date": day.iso, "weekday": weekday(day), "today": today.iso,
                                  "days_from_today": days(from: today, to: day)]
        if day.ambiguous {
            out["note"] = "read as \(monthName(day.month)) \(day.day); the other order would be \(monthName(day.day)) \(day.month)"
        }
        return out
    }

    public static func days(from a: Day, to b: Day) -> Int {
        guard let da = date(a), let db = date(b) else { return 0 }
        return gregorian.dateComponents([.day], from: da, to: db).day ?? 0
    }

    public static func weekday(_ day: Day) -> String {
        guard let d = date(day) else { return "" }
        return englishFormatter.weekdaySymbols[gregorian.component(.weekday, from: d) - 1]
    }

    /// The user's today in `zone`.
    public static func today(in zone: TimeZone, now: Date = Date()) -> Day {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        let p = c.dateComponents([.year, .month, .day], from: now)
        return Day(year: p.year ?? 1970, month: p.month ?? 1, day: p.day ?? 1)
    }

    /// Whether the locale writes the month before the day (en_US).
    public static func isMonthFirst(_ locale: Locale) -> Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? ""
        guard let m = pattern.firstIndex(of: "M"), let d = pattern.firstIndex(of: "d") else { return false }
        return m < d
    }

    // MARK: - Parts

    private static func date(_ day: Day) -> Date? {
        gregorian.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }

    private static func valid(_ y: Int, _ m: Int, _ d: Int) -> Day? {
        guard (1...9999).contains(y), (1...12).contains(m), d >= 1,
              let start = gregorian.date(from: DateComponents(year: y, month: m, day: 1)),
              let range = gregorian.range(of: .day, in: .month, for: start), range.contains(d) else { return nil }
        return Day(year: y, month: m, day: d)
    }

    /// Two digits are this century ("10.04.24").
    private static func year(_ n: (value: Int, digits: Int)) -> Int { n.digits == 2 ? 2000 + n.value : n.value }

    private static func shift(_ day: Day, by offset: Int) -> Day? {
        guard let d = date(day), let moved = gregorian.date(byAdding: .day, value: offset, to: d) else { return nil }
        let p = gregorian.dateComponents([.year, .month, .day], from: moved)
        return Day(year: p.year!, month: p.month!, day: p.day!)
    }

    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                if !current.isEmpty { out.append(current); current = "" }
                if !ch.isWhitespace { out.append(String(ch)) }
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static let relative: [String: Int] = [
        "today": 0, "now": 0, "tomorrow": 1, "yesterday": -1,
        "сегодня": 0, "завтра": 1, "вчера": -1, "послезавтра": 2, "позавчера": -2,
        "сьогодні": 0, "вчора": -1,
    ]

    /// Words that may stand around a date ("on", "of", "year", "г.", the
    /// ending of "10-го").
    private static let fillers: Set<String> = ["on", "of", "the", "year", "г", "года", "год", "року", "рік", "р", "го", "е"]

    private static let englishFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func monthName(_ m: Int) -> String {
        (1...12).contains(m) ? englishFormatter.monthSymbols[m - 1] : "month \(m)"
    }

    /// Month names in the languages the app speaks most, full and short,
    /// in the forms a date takes ("апреля") and alone ("апрель").
    private static let monthNames: [(name: String, month: Int)] = {
        var out: [(String, Int)] = []
        for id in ["en_US", "ru_RU", "uk_UA", "de_DE", "fr_FR", "es_ES", "it_IT", "pt_PT", "pl_PL"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: id)
            for list in [f.monthSymbols, f.shortMonthSymbols, f.standaloneMonthSymbols, f.shortStandaloneMonthSymbols] {
                for (i, name) in (list ?? []).enumerated() {
                    out.append((name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), i + 1))
                }
            }
        }
        return out
    }()

    private static func month(named word: String) -> Int? {
        let w = word.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let exact = monthNames.first(where: { $0.name == w }) { return exact.month }
        // A short form not in the lists ("sept"): the one month whose name starts so.
        guard w.count >= 3 else { return nil }
        let matches = Set(monthNames.filter { $0.name.hasPrefix(w) }.map(\.month))
        return matches.count == 1 ? matches.first : nil
    }

    private static let weekdayNames: Set<String> = {
        var out = Set<String>()
        for id in ["en_US", "ru_RU", "uk_UA", "de_DE", "fr_FR", "es_ES", "it_IT", "pt_PT", "pl_PL"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: id)
            for list in [f.weekdaySymbols, f.shortWeekdaySymbols, f.standaloneWeekdaySymbols] {
                for name in list ?? [] { out.insert(name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
            }
        }
        return out
    }()

    private static func isWeekday(_ word: String) -> Bool {
        weekdayNames.contains(word.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }
}
