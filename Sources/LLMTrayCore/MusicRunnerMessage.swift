import Foundation

/// One line of llmtray_music_runner.py's stdout protocol:
/// "@@LLMTRAY STAGE <text>" / "STEP <n> <total>" / "AUDIO <base64 wav>".
public enum MusicRunnerMessage: Equatable {
    case stage(String)
    case step(Int, Int)
    case audio(Data)

    public init?(line: String) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "@@LLMTRAY" else { return nil }
        let rest = parts.count > 2 ? String(parts[2]) : ""
        switch parts[1] {
        case "STAGE":
            self = .stage(rest)
        case "STEP":
            let numbers = rest.split(separator: " ").compactMap { Int($0) }
            guard numbers.count == 2 else { return nil }
            self = .step(numbers[0], numbers[1])
        case "AUDIO":
            guard let data = Data(base64Encoded: rest) else { return nil }
            self = .audio(data)
        default:
            return nil
        }
    }
}
