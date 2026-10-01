import Foundation

/// One measured run of runtime/feature_memory.json (scripts/measure_memory.py).
public struct FeatureMemoryCase: Codable, Equatable, Sendable {
    /// The harness's case name; "estimate" for a model not measured yet.
    public var name: String
    /// What it gates: "image.gptqMixed", "music.turbo", "chat.<repo>", ...
    public var feature: String
    /// Peak physical footprint of the runner's process tree (GPU memory
    /// included on Apple Silicon).
    public var peakBytes: Int64
    public var seconds: Int?
    /// The measured case it's estimated from.
    public var estimatedFrom: String?

    public init(name: String, feature: String, peakBytes: Int64, seconds: Int? = nil, estimatedFrom: String? = nil) {
        self.name = name
        self.feature = feature
        self.peakBytes = peakBytes
        self.seconds = seconds
        self.estimatedFrom = estimatedFrom
    }

    private enum CodingKeys: String, CodingKey {
        case name = "case", feature, peakBytes, seconds, estimatedFrom
    }
}

/// The measured memory of the models LLMTray runs, by feature id.
public struct FeatureMemory: Equatable, Sendable {
    /// In the app bundle's runtime folder (build_app.sh copies it).
    public static let fileName = "feature_memory.json"

    public var cases: [FeatureMemoryCase]

    public init(cases: [FeatureMemoryCase]) {
        self.cases = cases
    }

    private struct File: Decodable {
        var cases: [Entry]
    }

    /// One broken entry (a hand edit) drops that entry, not the table.
    private struct Entry: Decodable {
        var value: FeatureMemoryCase?
        init(from decoder: Decoder) throws {
            value = try? FeatureMemoryCase(from: decoder)
        }
    }

    public static func parse(_ data: Data) throws -> FeatureMemory {
        let cases = try JSONDecoder().decode(File.self, from: data).cases.compactMap(\.value)
        return FeatureMemory(cases: cases.filter { $0.peakBytes > 0 && !$0.feature.isEmpty })
    }

    public static func load(contentsOf url: URL) throws -> FeatureMemory {
        try parse(Data(contentsOf: url))
    }

    /// The feature's highest peak over its cases; nil when not in the table.
    public func peakBytes(_ feature: String) -> Int64? {
        cases.filter { $0.feature == feature }.map(\.peakBytes).max()
    }

    /// The feature's fit on `hardware`; nil when it isn't in the table
    /// (then it isn't gated).
    public func fit(_ feature: String, on hardware: HardwareInfo) -> FeatureFit? {
        peakBytes(feature).map { FeatureFit(peakBytes: $0, hardware: hardware) }
    }

    // Feature ids, as the table names them.
    public static func image(_ model: String) -> String { "image." + model }
    public static func imageEdit(_ model: String) -> String { "imageEdit." + model }
    public static func music(_ model: String) -> String { "music." + model }
    public static func voice(_ model: String) -> String { "voice." + model }
}

/// Whether a feature's measured peak fits this Mac. It runs alone (the
/// chat model is unloaded for it), so the peak is set against the GPU's
/// limit and the RAM, not against what's free now:
/// - fits: under the GPU limit;
/// - tight: over it, but within what the limit can be raised to (all the
///   RAM less macOS's 4 GB, GPUFit's ceiling) -- it ran on the measuring
///   Mac this way, MLX freeing its cache under pressure, but may run out
///   of memory beside other apps;
/// - doesn't fit: over that too.
/// Without a known GPU limit, only the RAM ceiling counts.
public struct FeatureFit: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case fits, tight, doesNotFit
    }

    /// Kept for macOS beside a raised GPU limit (GPUFit, VoiceMemoryFit).
    public static let macOSReserveBytes: Int64 = 4 << 30

    public var level: Level
    public var peakBytes: Int64
    public var physicalMemoryBytes: UInt64
    public var gpuLimitBytes: UInt64?

    public init(peakBytes: Int64, hardware: HardwareInfo) {
        self.peakBytes = peakBytes
        physicalMemoryBytes = hardware.physicalMemoryBytes
        gpuLimitBytes = hardware.gpuLimitBytes
        let limit = gpuLimitBytes.map { Int64(clamping: $0) }
        let ceiling = max(Int64(clamping: hardware.physicalMemoryBytes) - Self.macOSReserveBytes, limit ?? 0)
        if let limit, peakBytes <= limit {
            level = .fits
        } else if peakBytes <= ceiling {
            level = limit == nil ? .fits : .tight
        } else {
            level = .doesNotFit
        }
    }

    /// Can be turned on: everything but doesn't fit.
    public var isAvailable: Bool { level != .doesNotFit }

    /// One line for the UI; nil when it fits.
    public var reason: String? {
        let peak = String(format: "%.0f", (Double(peakBytes) / Double(1 << 30)).rounded(.up))
        switch level {
        case .fits:
            return nil
        case .tight:
            let limit = String(format: "%.1f", Double(gpuLimitBytes ?? 0) / Double(1 << 30))
            return String(format: NSLocalizedString("Needs about %1$@ GB, more than the %2$@ GB the GPU may use: it may run out of memory with other apps open.", comment: "feature memory: peak GB, GPU limit GB"), peak, limit)
        case .doesNotFit:
            let ram = String(format: "%.0f", (Double(physicalMemoryBytes) / Double(1 << 30)).rounded())
            return String(format: NSLocalizedString("Needs about %1$@ GB; this Mac has %2$@ GB.", comment: "feature memory: peak GB, RAM GB"), peak, ram)
        }
    }
}
