import Foundation

/// A process an earlier LLMTray started and left running: it crashed or was
/// force-quit (only a normal quit / SIGTERM stops its children), and the
/// process still holds its model's memory -- often 10-25 GB.
public struct OrphanProcess: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case modelServer
        case imageRunner
    }

    public let kind: Kind
    public let pid: Int32
    public let residentBytes: Int64
    /// The model folder's name, when the command line has `--model`.
    public let model: String?

    public init(kind: Kind, pid: Int32, residentBytes: Int64, model: String?) {
        self.kind = kind
        self.pid = pid
        self.residentBytes = residentBytes
        self.model = model
    }
}

/// Finds LLMTray's orphans in `ps` output. Only what is certainly ours
/// counts, so a user's own mlx_lm.server is never touched: the parent is
/// gone (reparented to launchd), the environment carries LLMTray's marker
/// for that kind of process, and the command is that kind of process (a
/// shell that merely inherited the marker isn't one).
public enum OrphanScan {
    /// Set on every mlx_lm.server LLMTray launches (ServerProcess). The
    /// name predates the image runner's marker; older versions' orphans
    /// carry it too.
    public static let serverMarker = "LLMTRAY_SERVER"
    /// Set on every image-generation runner LLMTray launches (MfluxManager).
    public static let imageRunnerMarker = "LLMTRAY_IMAGE_RUNNER"

    /// The arguments for `/bin/ps` whose output `orphans(inPSOutput:)` reads:
    /// every process, full width, with its environment (-E; only the
    /// user's own processes show one, which is all that can be ours).
    public static let psArguments = ["-E", "-axww", "-o", "pid=,ppid=,rss=,command="]

    public static func orphans(inPSOutput output: String) -> [OrphanProcess] {
        output.split(separator: "\n").compactMap { orphan(inLine: String($0)) }
    }

    private static func orphan(inLine line: String) -> OrphanProcess? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 4,
              let pid = Int32(tokens[0]), let ppid = Int32(tokens[1]), let rssKiB = Int64(tokens[2]),
              ppid == 1 else { return nil }
        let kind: OrphanProcess.Kind
        if tokens.contains("mlx_lm.server"), tokens.contains(serverMarker + "=1") {
            kind = .modelServer
        } else if line.contains("llmtray_mflux_runner.py"), tokens.contains(imageRunnerMarker + "=1") {
            kind = .imageRunner
        } else {
            return nil
        }
        let model = tokens.firstIndex(of: "--model")
            .flatMap { tokens.indices.contains($0 + 1) ? tokens[$0 + 1] : nil }
            .map { ($0 as NSString).lastPathComponent }
        return OrphanProcess(kind: kind, pid: pid, residentBytes: rssKiB * 1024, model: model)
    }
}
