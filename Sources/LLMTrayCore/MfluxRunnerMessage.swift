import Foundation

/// One line of llmtray_mflux_runner.py's stdout protocol:
/// "@@LLMTRAY STEP <n> <total>" / "PREVIEW <base64 png>" / "IMAGE <base64 png>".
public enum MfluxRunnerMessage: Equatable {
    case step(Int, Int)
    case preview(Data)
    case image(Data)

    public init?(line: String) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "@@LLMTRAY" else { return nil }
        let rest = parts.count > 2 ? String(parts[2]) : ""
        switch parts[1] {
        case "STEP":
            let numbers = rest.split(separator: " ").compactMap { Int($0) }
            guard numbers.count == 2 else { return nil }
            self = .step(numbers[0], numbers[1])
        case "PREVIEW":
            guard let data = Data(base64Encoded: rest) else { return nil }
            self = .preview(data)
        case "IMAGE":
            guard let data = Data(base64Encoded: rest) else { return nil }
            self = .image(data)
        default:
            return nil
        }
    }
}
