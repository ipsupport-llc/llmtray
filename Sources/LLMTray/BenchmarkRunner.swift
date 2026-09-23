import Foundation
import LLMTrayCore

/// One measured request: TTFT approximates prefill time (the server can't
/// stream a token before it finishes prefilling the prompt), so
/// prompt_tokens/TTFT is the standard prefill-throughput proxy used by
/// llama.cpp/exllama-style benchmarks; completion_tokens over the time
/// *after* the first token is the decode throughput.
struct BenchmarkSample {
    var promptTokens: Int
    var completionTokens: Int
    var ttft: TimeInterval
    var decodeElapsed: TimeInterval

    var prefillTokPerSec: Double { ttft > 0.01 ? Double(promptTokens) / ttft : 0 }
    var decodeTokPerSec: Double { decodeElapsed > 0.01 ? Double(completionTokens) / decodeElapsed : 0 }
}

struct BenchmarkResult: Identifiable {
    let id = UUID()
    var label: String
    var timestamp = Date()
    var promptTokens: Int
    var completionTokens: Int
    var ttft: Double
    var prefillTokPerSec: Double
    var decodeTokPerSec: Double

    init(label: String, samples: [BenchmarkSample]) {
        self.label = label
        let n = Double(samples.count)
        self.promptTokens = samples.map(\.promptTokens).reduce(0, +) / max(1, samples.count)
        self.completionTokens = samples.map(\.completionTokens).reduce(0, +) / max(1, samples.count)
        self.ttft = samples.map(\.ttft).reduce(0, +) / n
        self.prefillTokPerSec = samples.map(\.prefillTokPerSec).reduce(0, +) / n
        self.decodeTokPerSec = samples.map(\.decodeTokPerSec).reduce(0, +) / n
    }
}

struct AutoTuneCandidateResult: Identifiable {
    let id = UUID()
    var parameter: String   // "decode-concurrency" | "prefill-step-size"
    var value: Int
    var throughput: Double  // aggregate decode tok/s, or prefill tok/s -- whichever this phase optimizes
    var isWinner: Bool = false
}

/// What auto-tune found vs what's currently applied -- surfaced to the user
/// for an explicit apply/discard decision rather than silently overwriting
/// their settings. The server is already back on `current*` by the time
/// this is published (see autoTune's restore-before-propose step).
struct AutoTuneProposal: Equatable {
    var currentConcurrency: Int
    var proposedConcurrency: Int
    var currentPrefillStep: Int
    var proposedPrefillStep: Int

    var hasChanges: Bool {
        currentConcurrency != proposedConcurrency || currentPrefillStep != proposedPrefillStep
    }
}

enum BenchmarkPreset: Int, CaseIterable, Identifiable {
    case short = 128
    case medium = 512
    case long = 2048
    var id: Int { rawValue }
    var label: String { "\(rawValue) tok" }
}

@MainActor
final class BenchmarkRunner: ObservableObject {
    @Published var isRunning = false
    @Published var statusText: String = ""
    @Published var results: [BenchmarkResult] = []
    @Published var autoTuneLog: [AutoTuneCandidateResult] = []
    // Separate fields (not one shared errorText) -- both sections are
    // always visible on this tab at once, so a single field would either
    // show the same message twice or leave one section's failure invisible
    // depending on which happened to render it.
    @Published var quickBenchmarkError: String?
    @Published var autoTuneError: String?
    @Published var pendingProposal: AutoTuneProposal?

    private var cancelRequested = false
    private let session = URLSession(configuration: .default)

    // Repeated to build an approximately-N-token prompt -- the *real*
    // count (what every ratio below is computed from) always comes back
    // from the server's own usage.prompt_tokens, so approximate word/token
    // ratio here only needs to get the ballpark right.
    private static let fillerWords =
        "The quick brown fox jumps over the lazy dog near the quiet river while the sun sets slowly behind distant hills"
            .split(separator: " ").map(String.init)

    /// A leading UUID makes every call's full token sequence unique, even
    /// across repeated trials of the same preset -- without it, the server's
    /// own cross-request prompt cache (--prompt-cache-bytes, on by default)
    /// recognizes the identical filler text on the 2nd+ call and skips
    /// re-prefilling almost entirely, returning near-instantly. Confirmed
    /// live: TTFT was ~0.08s for BOTH a 512-tok and a 2048-tok prompt --
    /// identical latency regardless of length is the signature of a cache
    /// hit, not real prefill work, and was inflating "prefill tok/s" by
    /// roughly 4x on the longer preset alone.
    private func makePrompt(approxTokens: Int) -> String {
        var words: [String] = [UUID().uuidString]
        while words.count < approxTokens {
            words.append(contentsOf: Self.fillerWords)
        }
        return words.prefix(approxTokens).joined(separator: " ")
    }

    func cancel() {
        cancelRequested = true
    }

    // MARK: - Single-request measurement

    /// Fires one non-chat-visible completion request and measures it.
    /// `concurrencyTag` only affects the request's own bookkeeping (none
    /// today) -- concurrent load is created by the *caller* firing several
    /// of these in a TaskGroup, not by anything in here.
    private func measureOnce(port: Int, modelAlias: String, promptTokens: Int, maxTokens: Int) async throws -> BenchmarkSample {
        let prompt = makePrompt(approxTokens: promptTokens)
        let body: [String: Any] = [
            "model": modelAlias,
            "messages": [["role": "user", "content": prompt]],
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": 0,
            "max_tokens": maxTokens,
        ]
        guard let url = URL(string: "http://localhost:\(port)/v1/chat/completions"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw NSError(domain: "BenchmarkRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to build request"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 300

        let sendDate = Date()
        var firstByteDate: Date?
        var usagePromptTokens: Int?
        var usageCompletionTokens: Int?

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "BenchmarkRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: "server returned status \(code)"])
        }
        for try await line in bytes.lines {
            // mlx_lm.server sends ": keepalive N/M" SSE comment lines while
            // still prefilling a long prompt, to hold the connection open --
            // those arrive well before the real first token. Stamping
            // firstByteDate on the first *line of any kind* (as ChatClient
            // does, where it doesn't matter for a live chat) would capture
            // the keepalive instead and silently deflate TTFT/prefill
            // tok/s, which is the one number this benchmark exists to get
            // right. Only a genuine "data: " payload counts.
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if firstByteDate == nil { firstByteDate = Date() }
            if let usage = obj["usage"] as? [String: Any] {
                usagePromptTokens = usage["prompt_tokens"] as? Int
                usageCompletionTokens = usage["completion_tokens"] as? Int
            }
        }
        let endDate = Date()
        guard let firstByte = firstByteDate else {
            throw NSError(domain: "BenchmarkRunner", code: 3, userInfo: [NSLocalizedDescriptionKey: "no response received"])
        }
        guard let promptTok = usagePromptTokens, let completionTok = usageCompletionTokens, completionTok > 0 else {
            throw NSError(domain: "BenchmarkRunner", code: 4, userInfo: [NSLocalizedDescriptionKey: "server didn't report token usage"])
        }
        return BenchmarkSample(
            promptTokens: promptTok,
            completionTokens: completionTok,
            ttft: firstByte.timeIntervalSince(sendDate),
            decodeElapsed: endDate.timeIntervalSince(firstByte)
        )
    }

    // MARK: - Manual benchmark (current live settings, no restarts)

    func runBenchmark(port: Int, modelAlias: String, promptTokens: Int, maxTokens: Int, trials: Int) async {
        guard !isRunning else { return }
        isRunning = true
        cancelRequested = false
        quickBenchmarkError = nil
        defer { isRunning = false; statusText = "" }

        // A fresh (prompt-size, kv-bits, ...) combination pays a one-time
        // Metal kernel compile cost on its first call -- confirmed live
        // against the real 30B model at up to 5x the warm decode time.
        // Thrown away rather than shown, so it can't be mistaken for a
        // real (much worse) measurement.
        statusText = "Warming up…"
        do {
            _ = try await measureOnce(port: port, modelAlias: modelAlias, promptTokens: promptTokens, maxTokens: maxTokens)
        } catch {
            quickBenchmarkError = error.localizedDescription
            return
        }

        var samples: [BenchmarkSample] = []
        for i in 0..<trials {
            if cancelRequested { break }
            statusText = "Running trial \(i + 1)/\(trials)…"
            do {
                samples.append(try await measureOnce(port: port, modelAlias: modelAlias, promptTokens: promptTokens, maxTokens: maxTokens))
            } catch {
                quickBenchmarkError = error.localizedDescription
                return
            }
        }
        guard !samples.isEmpty else { return }
        let label = "\(promptTokens)→\(maxTokens) tok, \(samples.count)x"
        results.insert(BenchmarkResult(label: label, samples: samples), at: 0)
    }

    // MARK: - Auto-tune (restarts the server between candidates)

    /// Sweeps decode-concurrency (aggregate throughput under simultaneous
    /// requests) and prefill-step-size (single-request prefill speed on a
    /// long prompt) independently rather than as a full cross product --
    /// the two barely interact, and a 4x4 grid would roughly double the
    /// number of restarts (each a full model reload) for little extra
    /// signal. Restores the pre-sweep settings before returning and
    /// publishes the result as `pendingProposal` -- the winning combination
    /// is only ever written and applied via applyAutoTuneProposal(), never
    /// automatically.
    func autoTune(
        server: ServerManager,
        port: Int,
        modelAlias: String,
        decodeConcurrencyCandidates: [Int] = [1, 2, 4, 8],
        prefillStepSizeCandidates: [Int] = [64, 128, 256, 512]
    ) async {
        guard !isRunning else { return }
        isRunning = true
        cancelRequested = false
        autoTuneError = nil
        autoTuneLog = []
        defer { isRunning = false; statusText = "" }

        // Candidates are written into the running model's profile (the
        // server reads launch settings from it at every restart), and the
        // profile's own values are restored afterwards -- including
        // "not set here, inherited from Default" for an overlay profile.
        let profiles = ProfileManager.shared
        let modelPath = server.loadedModelPath
        let originalConcurrencyField = profiles.profile(for: modelPath).launch.decodeConcurrency
        let originalPrefillField = profiles.profile(for: modelPath).launch.prefillStepSize
        let originalConcurrency = profiles.value(\.launch.decodeConcurrency, for: modelPath)
        let originalPrefillStep = profiles.value(\.launch.prefillStepSize, for: modelPath)

        func restart() async -> Bool {
            do {
                try await server.restartToApplyLaunchSettings()
                return true
            } catch {
                autoTuneError = "restart failed: \(error.localizedDescription)"
                return false
            }
        }

        // Phase 1: decode-concurrency, measured by firing N concurrent
        // requests (N = the candidate value) and summing their tokens over
        // the batch's wall-clock time -- with only one request in flight,
        // higher decode-concurrency has nothing to batch against and would
        // look identical to 1, which is why this fires real concurrent load
        // instead of a single request per candidate.
        var bestConcurrency = originalConcurrency
        var bestConcurrencyThroughput = -1.0
        for value in decodeConcurrencyCandidates {
            if cancelRequested { break }
            statusText = "Testing decode-concurrency=\(value)…"
            profiles.set(\.launch.decodeConcurrency, value, for: modelPath)
            guard await restart() else { break }

            let batchStart = Date()
            let results: [BenchmarkSample?] = await withTaskGroup(of: BenchmarkSample?.self) { group in
                for _ in 0..<value {
                    group.addTask { [self] in
                        try? await measureOnce(port: port, modelAlias: modelAlias, promptTokens: 512, maxTokens: 128)
                    }
                }
                var collected: [BenchmarkSample?] = []
                for await sample in group { collected.append(sample) }
                return collected
            }
            let elapsed = Date().timeIntervalSince(batchStart)
            let failures = results.filter { $0 == nil }.count
            let totalTokens = results.compactMap { $0?.completionTokens }.reduce(0, +)
            guard failures == 0, elapsed > 0.05, totalTokens > 0 else {
                // Higher concurrency needs proportionally more KV-cache
                // memory for the SAME model already sitting close to this
                // Mac's Metal working-set ceiling (see docs/FINDINGS.md) --
                // once one candidate's concurrent requests fail outright,
                // every larger value is just as likely to, so stop instead
                // of burning more restart cycles on doomed candidates.
                // Surfaced via autoTuneError so "why did it skip N" is never a
                // silent gap in the results table.
                autoTuneError = "decode-concurrency=\(value): \(failures)/\(value) requests failed "
                    + "(likely out of memory at this concurrency) -- stopped sweeping higher values."
                break
            }
            let throughput = Double(totalTokens) / elapsed
            autoTuneLog.append(AutoTuneCandidateResult(parameter: "decode-concurrency", value: value, throughput: throughput))
            if throughput > bestConcurrencyThroughput {
                bestConcurrencyThroughput = throughput
                bestConcurrency = value
            }
        }
        profiles.set(\.launch.decodeConcurrency, bestConcurrency, for: modelPath)
        if let idx = autoTuneLog.lastIndex(where: { $0.parameter == "decode-concurrency" && $0.value == bestConcurrency }) {
            autoTuneLog[idx].isWinner = true
        }

        // Phase 2: prefill-step-size, measured on a single long-prompt
        // request (prefill chunking doesn't depend on concurrent load).
        var bestPrefillStep = originalPrefillStep
        var bestPrefillThroughput = -1.0
        for value in prefillStepSizeCandidates {
            if cancelRequested { break }
            statusText = "Testing prefill-step-size=\(value)…"
            profiles.set(\.launch.prefillStepSize, value, for: modelPath)
            guard await restart() else { break }

            guard let sample = try? await measureOnce(port: port, modelAlias: modelAlias, promptTokens: 2048, maxTokens: 8) else { continue }
            autoTuneLog.append(AutoTuneCandidateResult(parameter: "prefill-step-size", value: value, throughput: sample.prefillTokPerSec))
            if sample.prefillTokPerSec > bestPrefillThroughput {
                bestPrefillThroughput = sample.prefillTokPerSec
                bestPrefillStep = value
            }
        }
        if let idx = autoTuneLog.lastIndex(where: { $0.parameter == "prefill-step-size" && $0.value == bestPrefillStep }) {
            autoTuneLog[idx].isWinner = true
        }

        // Restore the settings that were live before this sweep started --
        // every candidate above ran with a real config change + restart, so
        // without this the server would be left mid-sweep on the *last*
        // prefill-step-size candidate tried, not necessarily the winner and
        // not necessarily what the user had running before. The winning
        // combination is only ever applied if the user confirms it via
        // applyAutoTuneProposal(), never automatically.
        profiles.set(\.launch.decodeConcurrency, originalConcurrencyField, for: modelPath)
        profiles.set(\.launch.prefillStepSize, originalPrefillField, for: modelPath)
        if !cancelRequested {
            statusText = "Restoring original settings…"
            _ = await restart()
            pendingProposal = AutoTuneProposal(
                currentConcurrency: originalConcurrency,
                proposedConcurrency: bestConcurrency,
                currentPrefillStep: originalPrefillStep,
                proposedPrefillStep: bestPrefillStep
            )
        } else {
            statusText = "Cancelled -- restoring original settings…"
            _ = await restart()
        }
    }

    /// Applies a proposal the user confirmed: writes the winning values and
    /// restarts once to pick them up. No-op if the proposal was already
    /// cleared (e.g. a second tap while a restart is in flight).
    func applyAutoTuneProposal(server: ServerManager) async {
        guard let proposal = pendingProposal, !isRunning else { return }
        isRunning = true
        defer { isRunning = false; statusText = "" }
        let modelPath = server.loadedModelPath
        ProfileManager.shared.set(\.launch.decodeConcurrency, proposal.proposedConcurrency, for: modelPath)
        ProfileManager.shared.set(\.launch.prefillStepSize, proposal.proposedPrefillStep, for: modelPath)
        statusText = "Applying new settings…"
        do {
            try await server.restartToApplyLaunchSettings()
        } catch {
            autoTuneError = "restart failed: \(error.localizedDescription)"
        }
        pendingProposal = nil
    }

    /// Discards a proposal -- the server is already back on its original
    /// settings (autoTune restores them before publishing the proposal), so
    /// this only needs to clear the pending state, no further restart.
    func discardAutoTuneProposal() {
        pendingProposal = nil
    }
}
