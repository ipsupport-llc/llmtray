import Foundation

/// A speech-to-speech model Voice Lab can run (adr/0016).
public struct VoiceLabModel: Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var repo: String
    /// Its folder under voice_models/.
    public var folderName: String
    /// The repo's files together (what the download takes on disk).
    public var downloadBytes: Int64
    /// What it takes in memory while it runs: the published physical
    /// footprint, well above the weights (caches, the codec, Metal's own).
    public var footprintBytes: Int64
    public var licenseName: String
    /// The model card, which carries the licence text and NVIDIA's notices.
    public var cardURL: URL

    /// NVIDIA NemotronLabs VoiceChat 11B, mlx-community's 4-bit: full
    /// duplex, English; 9.18 GB of files, ~15.6 GB footprint published on an
    /// M5 Pro (adr/0016). OpenMDW 1.1, not gated.
    public static let voiceChat11B4bit = VoiceLabModel(
        id: "nemotron-voicechat-11b-4bit",
        displayName: "NVIDIA NemotronLabs VoiceChat 11B (4-bit)",
        repo: "mlx-community/NemotronLabs-VoiceChat-11B-4bit",
        folderName: "nemotron-voicechat-11b-4bit",
        downloadBytes: 9_184_356_448,
        footprintBytes: 15_600_000_000,
        licenseName: "OpenMDW 1.1",
        cardURL: URL(string: "https://huggingface.co/mlx-community/NemotronLabs-VoiceChat-11B-4bit")!
    )

    public static let all: [VoiceLabModel] = [.voiceChat11B4bit]
    public static let `default` = voiceChat11B4bit

    /// A download's progress from what's on disk so far (0...1).
    public func downloadFraction(bytesOnDisk: Int64) -> Double {
        guard downloadBytes > 0 else { return 0 }
        return min(max(Double(bytesOnDisk) / Double(downloadBytes), 0), 1)
    }
}

/// What the Voice pane says about memory: whether the voice model fits the
/// GPU limit, and whether it would fit next to the chat model's weights.
/// The chat model is unloaded while Voice Lab runs either way (adr/0016);
/// this says why, and when even the voice model alone needs a raised limit.
public struct VoiceMemoryFit: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// No GPU limit known.
        case unknown
        /// Both fit, with the margin to spare.
        case fitsBesideChat
        /// The voice model fits alone: the chat model has to make room.
        case fitsAlone
        /// Not even alone; `suggestedWiredLimitMB` says what would.
        case tooBig
    }

    /// Kept free beside the models (Metal, the app, macOS's own): the
    /// server's margin (ServerLaunch.memoryMargin).
    public static let marginBytes: Int64 = 3 << 29   // 1.5 GB

    public var verdict: Verdict
    public var voiceBytes: Int64
    /// The chat model's weights (nil: none picked or loaded).
    public var chatBytes: Int64?
    public var gpuLimitBytes: UInt64?
    /// `iogpu.wired_limit_mb` that would fit the voice model alone, within
    /// RAM less 4 GB; nil unless `.tooBig` and a raise can help.
    public var suggestedWiredLimitMB: Int?

    public init(voiceBytes: Int64, chatBytes: Int64?, gpuLimitBytes: UInt64?, physicalMemoryBytes: UInt64) {
        self.voiceBytes = voiceBytes
        self.chatBytes = chatBytes.flatMap { $0 > 0 ? $0 : nil }
        self.gpuLimitBytes = gpuLimitBytes
        guard let limit = gpuLimitBytes.map({ Int64(clamping: $0) }) else {
            verdict = .unknown
            return
        }
        let alone = voiceBytes + Self.marginBytes
        if let chat = self.chatBytes, alone + chat <= limit {
            verdict = .fitsBesideChat
        } else if alone <= limit {
            verdict = self.chatBytes == nil ? .fitsBesideChat : .fitsAlone
        } else {
            verdict = .tooBig
            let mb: Int64 = 1_048_576
            let wanted = (alone + mb - 1) / mb
            let ceiling = Int64(clamping: physicalMemoryBytes) / mb - 4096
            if wanted <= ceiling, wanted > limit / mb { suggestedWiredLimitMB = Int(wanted) }
        }
    }

    public var sysctlCommand: String? {
        suggestedWiredLimitMB.map { "sudo sysctl iogpu.wired_limit_mb=\($0)" }
    }
}
