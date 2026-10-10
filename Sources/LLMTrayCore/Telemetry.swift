import Darwin
import Foundation

// Usage telemetry (adr/0015; on for a new install, never turned on by an
// update, off with one switch): one anonymous report per day covering
// one local day, POST https://ipsupport.us/api/telemetry. The rules mirror
// the server's (ipsupport-api internal/telemetry/report.go), so what passes
// here passes there. Never prompts, content, file names, paths or model
// names: only counts and coarse model families.

/// What the report counts, as the server's feature keys.
public enum TelemetryFeature: String, CaseIterable, Codable, Sendable {
    case chat
    case toolCalls = "tool_calls"
    case apiServer = "api_server"
    case imageGenerate = "image_generate"
    case imageEdit = "image_edit"
    case music
    case lora
    case modelDownload = "model_download"
}

/// A model's coarse family, as the server's enum; anything else is "other".
public enum TelemetryModelFamily: String, CaseIterable, Codable, Sendable {
    case gemma, qwen, llama, mistral, phi, deepseek
    case gptOSS = "gpt-oss"
    case glm, nemotron, flux
    case zImage = "z-image"
    case aceStep = "ace-step"
    case other

    /// The family of a model path ("…/mlx-community/Qwen3-8B-4bit") or
    /// repo ("roman220220/flux2-klein-4b-mlx-mixed"). Only the last two
    /// path components are looked at: a folder the user keeps models in
    /// says nothing about the model. The name itself is never sent.
    public static func of(model: String) -> TelemetryModelFamily {
        let parts = model.split(separator: "/").suffix(2)
        let name = parts.joined(separator: "/").lowercased()
        guard !name.isEmpty else { return .other }
        func has(_ needles: String...) -> Bool { needles.contains { name.contains($0) } }
        // Most specific first: a distill names both ("DeepSeek-R1-Distill-
        // Qwen"), and is the distiller's.
        if has("gpt-oss", "gpt_oss", "gptoss") { return .gptOSS }
        if has("deepseek") { return .deepseek }
        // Nemotron-based ("Llama-3.1-Nemotron", our NemotronLabs VoiceChat).
        if has("nemotron") { return .nemotron }
        if has("z-image", "z_image", "zimage") { return .zImage }
        if has("ace-step", "ace_step", "acestep") { return .aceStep }
        if has("flux") { return .flux }
        if has("gemma") { return .gemma }
        // FrogNano and Ornith: Qwen3.5 fine-tunes whose names don't say so
        // ("Ornith" as a word: not "ornithology").
        if has("qwen", "qwq", "frognano")
            || name.range(of: #"(?<![a-z])ornith(?![a-z])"#, options: .regularExpression) != nil { return .qwen }
        if has("llama") { return .llama }
        if has("mistral", "mixtral", "ministral", "devstral", "magistral", "codestral", "pixtral") { return .mistral }
        if has("glm") { return .glm }
        // "phi-4", "Phi-3.5-mini", "phi4" -- not "dolphin" or "graphic".
        if name.range(of: #"(?<![a-z])phi(?![a-z])"#, options: .regularExpression) != nil { return .phi }
        return .other
    }
}

/// Local days as the report's `day` (yyyy-MM-dd).
public enum TelemetryDay {
    /// Gregorian in the Mac's time zone, whatever calendar the user picked:
    /// the server parses the ISO date.
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// The oldest day the server takes now: maxDaysBack before the local
    /// day, and before the UTC day too (it counts from that; a Mac behind
    /// UTC is a day behind it for hours).
    public static func oldestAccepted(today: String, now: Date?, calendar: Calendar = TelemetryDay.calendar) -> String? {
        guard let local = adding(-TelemetryCounters.maxDaysBack, to: today, calendar: calendar) else { return nil }
        guard let now, let server = adding(-TelemetryCounters.maxDaysBack, to: string(for: now, calendar: utc), calendar: utc) else {
            return local
        }
        return max(local, server)
    }

    public static func string(for date: Date, calendar: Calendar = TelemetryDay.calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The day `days` before (negative: after) `day`; nil for a malformed one.
    public static func adding(_ days: Int, to day: String, calendar: Calendar = TelemetryDay.calendar) -> String? {
        guard let date = date(day, calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return string(for: shifted, calendar: calendar)
    }

    /// Noon of the day (clear of DST edges); nil unless exactly yyyy-MM-dd.
    public static func date(_ day: String, calendar: Calendar = TelemetryDay.calendar) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              day.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let components = DateComponents(year: y, month: m, day: d, hour: 12)
        guard let date = calendar.date(from: components),
              string(for: date, calendar: calendar) == day else { return nil }   // 2026-02-30
        return date
    }
}

/// One day's counts.
public struct TelemetryUsage: Codable, Equatable, Sendable {
    /// Server feature keys → uses.
    public var features: [String: Int]
    /// Family raw values, sorted, each once.
    public var families: [String]

    public init(features: [String: Int] = [:], families: [String] = []) {
        self.features = features
        self.families = families
    }

    public mutating func add(_ feature: TelemetryFeature, _ count: Int = 1) {
        let now = features[feature.rawValue] ?? 0
        features[feature.rawValue] = min(now + max(count, 0), TelemetryReport.maxFeatureCount)
    }

    public mutating func add(_ family: TelemetryModelFamily) {
        guard !families.contains(family.rawValue) else { return }
        families.append(family.rawValue)
        families.sort()
    }
}

/// The unsent days, kept per local day, at most `maxDaysBack` days back
/// (the server takes no older ones). Today's is only sent once it's over.
public struct TelemetryCounters: Codable, Equatable, Sendable {
    public static let maxDaysBack = 7
    /// The longest wait `notBefore` holds sending back (a Retry-After, a
    /// backoff); a longer one was written by a clock ahead of time.
    public static let maxWait: TimeInterval = 2 * 86400

    public var days: [String: TelemetryUsage]
    /// 429's Retry-After, or a backoff after a failure: no send before it.
    public var notBefore: Date?

    public init(days: [String: TelemetryUsage] = [:], notBefore: Date? = nil) {
        self.days = days
        self.notBefore = notBefore
    }

    /// The app ran today: a report for today, even with nothing counted.
    public mutating func touch(_ day: String) {
        if days[day] == nil { days[day] = TelemetryUsage() }
    }

    public mutating func record(_ feature: TelemetryFeature?, family: TelemetryModelFamily?, on day: String) {
        var usage = days[day] ?? TelemetryUsage()
        if let feature { usage.add(feature) }
        if let family { usage.add(family) }
        days[day] = usage
    }

    /// Drops days more than maxDaysBack before today (the server takes no
    /// older ones), and days more than one after it (a clock set back).
    /// Tomorrow stays: a Mac moved west of where it counted ("Oct 11" in
    /// Tokyo is still Oct 10 in Hawaii) sends it once it's over here.
    /// `now`: also by the server's UTC day (TelemetryDay.oldestAccepted).
    public mutating func prune(today: String, now: Date? = nil, calendar: Calendar = TelemetryDay.calendar) {
        guard let oldest = TelemetryDay.oldestAccepted(today: today, now: now, calendar: calendar),
              let newest = TelemetryDay.adding(1, to: today, calendar: calendar) else { return }
        days = days.filter { $0.key >= oldest && $0.key <= newest && TelemetryDay.date($0.key, calendar: calendar) != nil }
    }

    /// The finished days to send, oldest first: every kept day before today.
    public func pending(today: String) -> [String] {
        days.keys.filter { $0 < today }.sorted()
    }

    /// What an answer means for the day sent. Returns whether to go on to
    /// the next day.
    @discardableResult
    public mutating func apply(_ outcome: TelemetryOutcome, day: String, now: Date) -> Bool {
        switch outcome {
        case .sent, .dropped:
            days[day] = nil
            notBefore = nil
            return true
        case .retryLater(let seconds):
            notBefore = now.addingTimeInterval(TimeInterval(seconds ?? TelemetryOutcome.defaultBackoff))
            return false
        }
    }
}

/// What the app puts in a report besides the counts.
public struct TelemetryEnvironment: Equatable, Sendable {
    public var appVersion: String
    public var osVersion: String
    public var chip: String
    public var memoryGB: Int
    public var locale: String

    public init(appVersion: String, osVersion: String, chip: String, memoryGB: Int, locale: String) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.chip = chip
        self.memoryGB = memoryGB
        self.locale = locale
    }

    /// This Mac and this build. `language`: the UI's (the bundle's
    /// preferred localization).
    public static func current(bundle: Bundle = .main) -> TelemetryEnvironment {
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return TelemetryEnvironment(
            appVersion: version,
            osVersion: TelemetryReport.osVersion(os),
            chip: TelemetryReport.chip(brand: sysctlString("machdep.cpu.brand_string") ?? ""),
            memoryGB: TelemetryReport.memoryGB(bytes: ProcessInfo.processInfo.physicalMemory),
            locale: TelemetryReport.language(bundle.preferredLocalizations.first ?? Locale.current.identifier)
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// POST /api/telemetry's body. Validated and normalized as the server
/// does it: what's sent is what it stores.
public struct TelemetryReport: Codable, Equatable, Sendable {
    public static let product = "llmtray"
    public static let maxFeatureCount = 10_000_000
    public static let maxMemoryGB = 4096
    public static let maxBodyBytes = 16 * 1024

    public let product: String
    public let installID: String
    public let day: String
    public let appVersion: String
    public let osVersion: String
    public let chip: String
    public let memoryGB: Int
    public let locale: String
    public let features: [String: Int]
    public let modelFamilies: [String]

    enum CodingKeys: String, CodingKey {
        case product
        case installID = "install_id"
        case day
        case appVersion = "app_version"
        case osVersion = "os_version"
        case chip
        case memoryGB = "memory_gb"
        case locale
        case features
        case modelFamilies = "model_families"
    }

    /// `today`: the local day now; `day` must be one of the maxDaysBack
    /// days before it, or it (and, given `now`, no older than the server
    /// takes: TelemetryDay.oldestAccepted).
    public init(installID: UUID, day: String, today: String, now: Date? = nil, environment env: TelemetryEnvironment,
                usage: TelemetryUsage, calendar: Calendar = TelemetryDay.calendar) throws {
        guard TelemetryDay.date(day, calendar: calendar) != nil,
              let oldest = TelemetryDay.oldestAccepted(today: today, now: now, calendar: calendar),
              day >= oldest, day <= today else { throw TelemetryValidationError(code: "invalid_day") }
        let appVersion = ReviewSubmission.trimmed(env.appVersion)
        guard !appVersion.isEmpty, ReviewSubmission.sanitizedVersion(appVersion) == appVersion else {
            throw TelemetryValidationError(code: "invalid_app_version")
        }
        let osVersion = ReviewSubmission.trimmed(env.osVersion)
        guard osVersion.isEmpty || Self.isOSVersion(osVersion) else { throw TelemetryValidationError(code: "invalid_os_version") }
        guard (0...Self.maxMemoryGB).contains(env.memoryGB) else { throw TelemetryValidationError(code: "invalid_memory") }
        var features: [String: Int] = [:]
        for (key, count) in usage.features {
            guard TelemetryFeature(rawValue: key) != nil else { continue }   // the server ignores it too
            guard (0...Self.maxFeatureCount).contains(count) else { throw TelemetryValidationError(code: "invalid_features") }
            if count > 0 { features[key] = count }
        }
        let families = Set(usage.families.map { TelemetryModelFamily(rawValue: $0.lowercased()) ?? .other })
        product = Self.product
        self.installID = installID.uuidString.lowercased()
        self.day = day
        self.appVersion = appVersion
        self.osVersion = osVersion
        chip = Self.chip(brand: env.chip)
        memoryGB = env.memoryGB
        locale = Self.language(env.locale)
        self.features = features
        modelFamilies = families.map(\.rawValue).sorted()
    }

    /// The body pretty-printed, for showing the user (same keys and values).
    public func readableBody() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// The JSON body: these fields, nothing else.
    public func body() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBodyBytes else { throw TelemetryValidationError(code: "payload_too_large") }
        return data
    }

    /// "15.1.1" (the server's `^\d{1,2}(\.\d{1,3}){0,2}$`).
    public static func osVersion(_ v: OperatingSystemVersion) -> String {
        "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func isOSVersion(_ s: String) -> Bool {
        s.range(of: #"^[0-9]{1,2}(\.[0-9]{1,3}){0,2}$"#, options: .regularExpression) != nil
    }

    /// "Apple M5 Pro" as the brand string says it, when it's an Apple M
    /// chip; "other" for anything else (the server folds it the same way).
    public static func chip(brand: String) -> String {
        let brand = ReviewSubmission.trimmed(brand)
        guard let match = brand.range(of: #"^(Apple )?M[0-9]{1,2}( (Pro|Max|Ultra))?$"#, options: .regularExpression) else {
            return "other"
        }
        return String(brand[match])
    }

    /// Unified memory in GB, rounded (36 GB reads as 36).
    public static func memoryGB(bytes: UInt64) -> Int {
        Int((Double(bytes) / 1_073_741_824).rounded())
    }

    /// The language subtag only ("de-DE", "de_DE", "DE" → "de"); "" when
    /// there's none. The server keeps no more.
    public static func language(_ identifier: String) -> String {
        var s = ReviewSubmission.trimmed(identifier).lowercased()
        if let i = s.firstIndex(where: { $0 == "-" || $0 == "_" }) { s = String(s[..<i]) }
        let letters = s.unicodeScalars.allSatisfy { $0.value >= 0x61 && $0.value <= 0x7A }
        return letters && (2...3).contains(s.count) ? s : ""
    }
}

public struct TelemetryValidationError: Error, Equatable {
    /// The server's code for the same rejection.
    public let code: String
}

/// What an answer means for the day that was sent.
public enum TelemetryOutcome: Equatable, Sendable {
    /// Seconds before trying again when nothing better is known.
    public static let defaultBackoff = 3600

    /// 204: stored.
    case sent
    /// A 4xx sending again won't fix (400 invalid_*, 413, 415): that day's
    /// report is dropped, not retried.
    case dropped(code: String)
    /// 429 (Retry-After, when given), 408, 5xx, no answer: later, the same
    /// day again -- the server replaces a day it already has.
    case retryLater(seconds: Int?)

    /// `status` nil: no answer (a timeout, no network).
    public static func classify(status: Int?, body: Data?, retryAfter: String?) -> TelemetryOutcome {
        guard let status else { return .retryLater(seconds: nil) }
        let code = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["error"] as? String
        switch status {
        case 204:
            return .sent
        case 429:
            // At most maxWait: a longer wait than that is taken for a clock
            // that was ahead (TelemetryUploader.run).
            let seconds = retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
                .map { min($0, Int(TelemetryCounters.maxWait)) }
            return .retryLater(seconds: seconds)
        case 408, 500...599:
            return .retryLater(seconds: nil)
        case 400..<500:
            if let code, !code.isEmpty { return .dropped(code: code) }
            switch status {
            case 413: return .dropped(code: "payload_too_large")
            case 415: return .dropped(code: "unsupported_media_type")
            default: return .dropped(code: "http_\(status)")
            }
        default:
            return .retryLater(seconds: nil)
        }
    }
}

/// Sends one report. A session of its own: no cookies, no cache, a 15 s
/// timeout.
public struct TelemetryClient {
    public static let endpoint = URL(string: "https://ipsupport.us/api/telemetry")!

    public var endpoint: URL
    public var session: URLSession
    /// "LLMTray/<version>", not the system's.
    public var userAgent: String

    public init(endpoint: URL = TelemetryClient.endpoint, session: URLSession = ReviewClient.makeSession(),
                userAgent: String = "LLMTray") {
        self.endpoint = endpoint
        self.session = session
        self.userAgent = userAgent
    }

    public func request(_ report: TelemetryReport) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try report.body()
        return request
    }

    public func send(_ report: TelemetryReport) async -> TelemetryOutcome {
        guard let request = try? request(report) else { return .dropped(code: "payload_too_large") }
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return TelemetryOutcome.classify(status: http?.statusCode, body: data, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return .retryLater(seconds: nil)
        }
    }
}

/// The counters on disk (Application Support/LLMTray/telemetry.json), and
/// in memory between writes. Main-thread only.
@MainActor
public final class TelemetryCounterStore {
    public let url: URL
    public private(set) var counters: TelemetryCounters

    public init(url: URL) {
        self.url = url
        counters = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TelemetryCounters.self, from: $0) }
            ?? TelemetryCounters()
    }

    public func update(_ change: (inout TelemetryCounters) -> Void) {
        var next = counters
        change(&next)
        guard next != counters else { return }
        counters = next
        save()
    }

    /// Everything unsent, gone (telemetry turned off).
    public func erase() {
        counters = TelemetryCounters()
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(counters) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Sends the finished days, oldest first, stopping at the first "later".
@MainActor
public struct TelemetryUploader {
    public var client: TelemetryClient
    /// Called with each report the server stored (its day and exact body),
    /// so the app can show what was sent.
    public var onSent: (@Sendable (String, Data) -> Void)?
    /// nil: TelemetryDay.calendar as of each run -- the time zone the
    /// counters are dated in now, even after it changed.
    public var calendar: Calendar?

    public init(client: TelemetryClient, calendar: Calendar? = nil) {
        self.client = client
        self.calendar = calendar
    }

    /// `installID` is asked for before each send and after each answer:
    /// nil (turned off meanwhile) stops at once and leaves the store alone
    /// -- it was erased. Returns the days sent or dropped.
    @discardableResult
    public func run(store: TelemetryCounterStore, now: () -> Date = Date.init,
                    installID: () -> UUID?, environment: () -> TelemetryEnvironment) async -> [String] {
        var done: [String] = []
        let calendar = self.calendar ?? TelemetryDay.calendar
        let started = now()
        let today = TelemetryDay.string(for: started, calendar: calendar)
        store.update { $0.prune(today: today, now: started, calendar: calendar) }
        if let notBefore = store.counters.notBefore, started < notBefore {
            // A wait longer than any it takes was set by a clock that was
            // ahead then: no wait, and not kept.
            guard notBefore.timeIntervalSince(started) > TelemetryCounters.maxWait else { return done }
            store.update { $0.notBefore = nil }
        }
        for day in store.counters.pending(today: today) {
            guard !Task.isCancelled, let id = installID(), let usage = store.counters.days[day] else { break }
            let outcome: TelemetryOutcome
            do {
                let report = try TelemetryReport(installID: id, day: day, today: today, now: started, environment: environment(),
                                                 usage: usage, calendar: calendar)
                outcome = await client.send(report)
                if outcome == .sent, let body = try? report.body() { onSent?(day, body) }
            } catch let error as TelemetryValidationError {
                outcome = .dropped(code: error.code)   // would be refused just the same
            } catch {
                outcome = .dropped(code: "invalid_request")
            }
            guard !Task.isCancelled, installID() != nil else { break }
            var goOn = false
            store.update { goOn = $0.apply(outcome, day: day, now: now()) }
            if case .retryLater = outcome {} else { done.append(day) }
            if !goOn { break }
        }
        return done
    }
}

/// Usage statistics are on by default for a new install and never turned
/// on by an update (adr/0015). An install that never chose gets its value
/// written once, at launch, before anything else touches the settings: on
/// when this is the first run (no data folder yet), off when LLMTray ran
/// here before -- the default it had then. A choice already made is kept.
public enum TelemetryDefault {
    /// Returns what was written, nil when the user had chosen already.
    @discardableResult
    public static func settle(defaults: UserDefaults, dataFolderExists: Bool) -> Bool? {
        guard defaults.object(forKey: Pref.telemetryEnabled.name) == nil else { return nil }
        let on = !dataFolderExists
        defaults.set(on, forKey: Pref.telemetryEnabled.name)
        return on
    }
}
