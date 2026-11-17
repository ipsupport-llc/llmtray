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


    /// The day `text` names, nil when it can't be read. `today` is the
    /// user's day (the year when none is given, and the relative words);
    /// `monthFirst` orders an all-numbers slash form that fits both ways.
    public static func parse(_ text: String, today: Day, monthFirst: Bool) -> Day? {
        let s = apostrophes(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard !s.isEmpty else { return nil }
        if let offset = relative[s] { return shift(today, by: offset) }

        // ISO first: "2024-04-10", "2024-04-10T12:00:00Z" -- the whole
        // of it, so "2024-04-100" isn't read as the 10th.
        if s.range(of: #"^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}([t ][0-9]{1,2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(z|[+-][0-9]{2}:?[0-9]{2})?)?$"#,
                   options: .regularExpression) != nil {
            let n = s.prefix(while: { $0 != "t" && $0 != " " }).split(separator: "-").compactMap { Int($0) }
            return n.count == 3 ? valid(n[0], n[1], n[2]) : nil
        }

        // Words and numbers; ordinals ("10th") and a weekday dropped.
        var words: [String] = []
        var numbers: [(value: Int, digits: Int)] = []
        // An ordinal ("12th") is a day, never a year.
        var ordinals = Set<Int>()
        // What stands between consecutive numbers: a separator (". / -"),
        // a comma, or nothing but space (" "). One after the last number
        // ("04/05/2024.") or after a word ("Wed.") doesn't count.
        var between: [Character] = []
        var pending: Character?
        var afterNumber = false
        func addNumber(_ n: Int, digits: Int) {
            if !numbers.isEmpty { between.append(afterNumber ? (pending ?? " ") : "w") }
            numbers.append((n, digits))
            pending = nil
            afterNumber = true
        }
        for token in tokens(s) {
            if let n = Int(token) {
                addNumber(n, digits: token.count)
            } else if let first = token.first, first.isNumber {
                let digits = token.prefix(while: \.isNumber)
                if ["st", "nd", "rd", "th"].contains(String(token.dropFirst(digits.count))),
                   let n = Int(digits) {
                    ordinals.insert(numbers.count)
                    addNumber(n, digits: digits.count)
                } else { return nil }
            } else if token.count == 1, let c = token.first, "./-,".contains(c) {
                // Two in a row ("10..04") make no date of the numbers
                // around them; after the last number they don't matter.
                if afterNumber { pending = pending == nil ? c : "x" }
            } else {
                words.append(token)
                afterNumber = false
            }
        }
        // All numbers ("10.04.2024", "04/10/2024"): one separator, the same
        // twice, right after each of the first two.
        let numeric = numbers.count == 3 && between.count == 2 && between[0] == between[1] && "./-".contains(between[0])
        // A weekday's short form may also be a month's ("mar." is Tuesday
        // in French): with two months named, or before an all-numbers
        // date, the weekday ones are dropped.
        var months = Set(words.compactMap(month(named:)))
        if months.count > 1 || numeric { months = Set(words.filter { !isWeekday($0) }.compactMap(month(named:))) }
        let others = words.filter { month(named: $0) == nil && !isWeekday($0) && !fillers.contains($0) }
        guard others.isEmpty, months.count <= 1 else { return nil }

        if let month = months.first {
            // "Apr 10, 2024", "10 April 2024", "April 10": a day and maybe a year.
            switch numbers.count {
            case 1:
                guard numbers[0].digits <= 2 else { return nil }
                return valid(today.year, month, numbers[0].value)
            case 2:
                // The year last ("Apr 10, 2024", "10-Apr-24") or first
                // with four digits ("2024 Apr 10").
                let (a, b) = (numbers[0], numbers[1])
                if a.digits <= 2, b.digits == 4 || b.digits == 2, !ordinals.contains(1) { return valid(year(b, today), month, a.value) }
                if a.digits == 4, b.digits <= 2, !ordinals.contains(0) { return valid(a.value, month, b.value) }
                return nil
            default:
                return nil
            }
        }

        guard numeric else { return nil }
        let (a, b, c) = (numbers[0], numbers[1], numbers[2])
        // 2024/04/10, 2024.04.10.
        if a.digits == 4 { return ordinals.contains(0) ? nil : valid(a.value, b.value, c.value) }
        guard !ordinals.contains(2) else { return nil }
        guard a.digits <= 2, b.digits <= 2, c.digits == 4 || c.digits == 2 else { return nil }
        let y = year(c, today)
        // Dots are day-first (10.04.2024); a slash or a dash fits both
        // orders: a number over 12 settles it, else the user's order.
        if between[0] != "." {
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

    public static func days(from a: Day, to b: Day) -> Int { dayNumber(b) - dayNumber(a) }

    public static func weekday(_ day: Day) -> String {
        // Day 0 (1970-01-01) was a Thursday; weekdaySymbols start on Sunday.
        let index = ((dayNumber(day) + 4) % 7 + 7) % 7
        return englishFormatter.weekdaySymbols[index]
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
        // The locale's own short date: a yMd template puts the month
        // first for en_TR, mt_MT and zh_SG, which write the day first.
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .short
        var pattern = f.dateFormat ?? ""
        // A year-first short date (y-MM-dd) is ISO, not the order a
        // day-and-month date is read in there: the template's then.
        if pattern.trimmingCharacters(in: .whitespaces).hasPrefix("y") {
            pattern = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? pattern
        }
        guard let m = pattern.firstIndex(of: "M"), let d = pattern.firstIndex(of: "d") else { return false }
        return m < d
    }

    // MARK: - Parts

    // The calendar in whole days, proleptic Gregorian (no switch from the
    // Julian in 1582 as Foundation's has, no zones): days since 1970-01-01.

    private static func dayNumber(_ d: Day) -> Int {
        let y = d.month <= 2 ? d.year - 1 : d.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (d.month + (d.month > 2 ? -3 : 9)) + 2) / 5 + d.day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func fromDayNumber(_ n: Int) -> Day {
        let z = n + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return Day(year: yoe + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    private static func daysIn(_ m: Int, _ y: Int) -> Int {
        switch m {
        case 2: return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func valid(_ y: Int, _ m: Int, _ d: Int) -> Day? {
        guard (1...9999).contains(y), (1...12).contains(m), (1...daysIn(m, y)).contains(d) else { return nil }
        return Day(year: y, month: m, day: d)
    }

    /// Two digits: the century that puts it at most 20 years ahead of
    /// today ("10.04.24" is 2024, "Apr 10, 99" 1999).
    private static func year(_ n: (value: Int, digits: Int), _ today: Day) -> Int {
        guard n.digits == 2 else { return n.value }
        var y = today.year / 100 * 100 + n.value
        if y > today.year + 20 { y -= 100 } else if y + 100 <= today.year + 20 { y += 100 }
        return y
    }

    private static func shift(_ day: Day, by offset: Int) -> Day? { fromDayNumber(dayNumber(day) + offset) }

    /// Runs of letters or digits; a hyphen or an apostrophe between two
    /// letters stays in the word ("quarta-feira", "п'ятниця").
    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(s)
        // A hyphenated word that isn't a known name ("10th-apr",
        // "wednesday-april") goes back to its parts.
        func flush() {
            guard !current.isEmpty else { return }
            if current.contains("-"), month(named: current) == nil, !isWeekday(current) {
                for (k, part) in current.split(separator: "-", omittingEmptySubsequences: false).enumerated() {
                    if k > 0 { out.append("-") }
                    if !part.isEmpty { out.append(String(part)) }
                }
            } else {
                out.append(current)
            }
            current = ""
        }
        for (i, ch) in chars.enumerated() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if ch == "-" || ch == "'", current.last?.isLetter == true, i + 1 < chars.count, chars[i + 1].isLetter {
                current.append(ch)
            } else {
                flush()
                if !ch.isWhitespace { out.append(String(ch)) }
            }
        }
        flush()
        return out
    }

    /// ’ and ʼ written as ' (Ukrainian "п’ятниця" comes in all three).
    private static func apostrophes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{02BC}", with: "'")
    }

    private static let relative: [String: Int] = [
        "today": 0, "now": 0, "tomorrow": 1, "yesterday": -1,
        "сегодня": 0, "завтра": 1, "вчера": -1, "послезавтра": 2, "позавчера": -2,
        "сьогодні": 0, "вчора": -1, "післязавтра": 2,
    ]

    /// Words that may stand around a date ("on", "of", "year", "г.", the
    /// ending of "10-го").
    private static let fillers: Set<String> = ["on", "of", "the", "year", "г", "года", "год", "року", "рік", "р", "го", "е",
                                               "de", "del", "le", "am", "den"]

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
                    out.append((apostrophes(name.lowercased()).trimmingCharacters(in: CharacterSet(charactersIn: ".")), i + 1))
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
            for list in [f.weekdaySymbols, f.shortWeekdaySymbols, f.standaloneWeekdaySymbols, f.shortStandaloneWeekdaySymbols,
                         f.veryShortWeekdaySymbols].compactMap({ $0 }) {
                // Single letters ("m", "t") are left out: too easily something else.
                for name in list {
                    let w = apostrophes(name.lowercased()).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if w.count > 1 { out.insert(w) }
                }
            }
        }
        return out
    }()

    private static func isWeekday(_ word: String) -> Bool {
        weekdayNames.contains(word.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }
}
