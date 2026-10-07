import AppKit
import SwiftUI
import LLMTrayCore

struct BenchmarkView: View {
    @EnvironmentObject var server: ServerManager
    @ObservedObject var benchmark: BenchmarkRunner
    let port: Int
    let modelAlias: String

    @ObservedObject private var journal = SpeedJournalStore.shared
    @State private var promptPreset: BenchmarkPreset = .medium
    @State private var maxTokens: Double = 128
    @State private var trials: Int = 3

    private var serverReady: Bool {
        if case .running = server.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !serverReady {
                Text("Start the server first.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            realUseSection
            Divider().padding(.vertical, 4)
            quickBenchmarkSection
            Divider().padding(.vertical, 4)
            autoTuneSection
        }
    }

    // MARK: - In real use

    /// Every request the server served (the chat's, and apps' and agents'
    /// through the API), per model and launch settings: medians.
    private var realUseSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("In real use").foregroundColor(.secondary)
                Spacer()
                if !journal.journal.entries.isEmpty {
                    Button("Clear") { journal.clear() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            Text("Every request the server answers, the chat's and other apps' and agents' through the API, kept on this Mac. Medians per model and settings.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let summaries = journal.summaries
            if summaries.isEmpty {
                Text("No requests yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(summaries.prefix(8).enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(row.model)  ·  \(row.settings)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.describe(row))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    static func describe(_ row: SpeedJournal.Summary) -> String {
        var parts = [String(format: NSLocalizedString("%lld requests", comment: "speed journal: request count"), row.requests)]
        if let v = row.prefillTokensPerSecond {
            parts.append(String(format: NSLocalizedString("prompt %.0f tok/s", comment: "speed journal: prefill speed"), v))
        }
        if let v = row.decodeTokensPerSecond {
            parts.append(String(format: NSLocalizedString("generation %.1f tok/s", comment: "speed journal: decode speed"), v))
        }
        if let v = row.firstTokenSeconds {
            parts.append(String(format: NSLocalizedString("first token %.1f s", comment: "speed journal: time to first token"), v))
        }
        if let v = row.draftedShare {
            parts.append(String(format: NSLocalizedString("%.0f%% from drafts", comment: "speed journal: share of tokens from speculative drafts"), v * 100))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Quick benchmark

    private var quickBenchmarkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick benchmark").foregroundColor(.secondary)

            Text("Prompt size (input sent to the model):")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("Prompt size", selection: $promptPreset) {
                ForEach(BenchmarkPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Stepper("Response length: \(Int(maxTokens)) tok", value: $maxTokens, in: 16...512, step: 16)
            Text("How many tokens it generates per trial.")
                .font(.caption)
                .foregroundColor(.secondary)

            Stepper("Trials: \(trials)", value: $trials, in: 1...5)
            Text("Averaged into one result below. A throwaway warmup run always precedes them, so first-call Metal kernel compile time never skews the numbers.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button(benchmark.isRunning ? "Running…" : "Run benchmark") {
                    Task {
                        await benchmark.runBenchmark(
                            port: port, modelAlias: modelAlias,
                            promptTokens: promptPreset.rawValue, maxTokens: Int(maxTokens), trials: trials
                        )
                    }
                }
                .disabled(!serverReady || benchmark.isRunning)
                if benchmark.isRunning {
                    Button("Cancel") { benchmark.cancel() }
                    ProgressView().controlSize(.small)
                    Text(benchmark.statusText).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !benchmark.results.isEmpty {
                    Button("Clear") { benchmark.results.removeAll() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let quickBenchmarkError = benchmark.quickBenchmarkError {
                Text(quickBenchmarkError).font(.caption).foregroundColor(.red)
            }

            if benchmark.results.isEmpty {
                Text("No runs yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(benchmark.results.prefix(5)) { result in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.label)
                                .font(.caption.weight(.medium))
                            Text(
                                "TTFT \(String(format: "%.2f", result.ttft))s   "
                                    + "prefill \(String(format: "%.0f", result.prefillTokPerSec)) tok/s   "
                                    + "decode \(String(format: "%.1f", result.decodeTokPerSec)) tok/s"
                            )
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        }
                    }
                    if benchmark.results.count > 5 {
                        Text("(\(benchmark.results.count - 5) older run\(benchmark.results.count - 5 == 1 ? "" : "s") hidden)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Auto-tune

    private var autoTuneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Auto-tune").foregroundColor(.secondary)
            Text("Tries decode-concurrency (1/2/4/8) and prefill-step-size (64/128/256/512) against the running model, restarting the server between each, and keeps whichever measured fastest.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button(benchmark.isRunning ? "Running…" : "Auto-tune performance") {
                    confirmAndStartAutoTune()
                }
                .disabled(!serverReady || benchmark.isRunning)
                if benchmark.isRunning {
                    Button("Cancel") { benchmark.cancel() }
                    ProgressView().controlSize(.small)
                    Text(benchmark.statusText).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !benchmark.autoTuneLog.isEmpty {
                    Button("Clear") { benchmark.autoTuneLog.removeAll() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let autoTuneError = benchmark.autoTuneError {
                Text(autoTuneError).font(.caption).foregroundColor(.red)
            }

            // Inline and persistent (not a one-shot alert on change): the
            // sweep takes minutes, and an alert fired from this view was
            // lost whenever the user had switched tabs or closed settings
            // by the time it finished.
            if let proposal = benchmark.pendingProposal {
                proposalPanel(proposal)
            }

            if benchmark.autoTuneLog.isEmpty {
                Text("No auto-tune run yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                autoTuneResultsTable
            }
        }
    }

    private func proposalPanel(_ proposal: AutoTuneProposal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if proposal.hasChanges {
                Text("Auto-tune found faster settings").fontWeight(.medium)
                Text("decode-concurrency: \(proposal.currentConcurrency) → \(proposal.proposedConcurrency)   prefill-step-size: \(proposal.currentPrefillStep) → \(proposal.proposedPrefillStep)")
                    .font(.system(.caption, design: .monospaced))
                HStack {
                    Button("Apply to profile") { Task { await benchmark.applyAutoTuneProposal(server: server) } }
                        .disabled(benchmark.isRunning)
                    Button("Keep current") { benchmark.discardAutoTuneProposal() }
                        .disabled(benchmark.isRunning)
                }
            } else {
                Text("Current settings are already fastest").fontWeight(.medium)
                Text("decode-concurrency \(proposal.currentConcurrency), prefill-step-size \(proposal.currentPrefillStep)")
                    .font(.system(.caption, design: .monospaced))
                Button("OK") { benchmark.discardAutoTuneProposal() }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
    }

    private var autoTuneResultsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(["decode-concurrency", "prefill-step-size"], id: \.self) { parameter in
                let candidates = benchmark.autoTuneLog.filter { $0.parameter == parameter }
                if !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(parameter)
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                        ForEach(candidates) { candidate in
                            HStack(spacing: 6) {
                                Text(candidate.isWinner ? "★" : " ").frame(width: 10)
                                Text("\(candidate.value)").frame(width: 36, alignment: .leading)
                                Text(String(format: "%.1f tok/s", candidate.throughput))
                            }
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(candidate.isWinner ? .primary : .secondary)
                            .fontWeight(candidate.isWinner ? .semibold : .regular)
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    /// A native NSAlert instead of SwiftUI's .confirmationDialog/.alert --
    /// this view is hosted inside an NSPopover (see LLMTrayApp.swift), and
    /// SwiftUI's own sheet-style dialogs don't reliably present from
    /// inside a popover. Matches the pattern uninstallRuntimeData() already
    /// uses for the same reason.
    private func confirmAndStartAutoTune() {
        let alert = NSAlert()
        alert.messageText = "Before auto-tuning"
        alert.informativeText = "This restarts the server several times and measures raw throughput -- "
            + "close other apps and don't use the Mac for anything else until it finishes, or the "
            + "results (and the setting it picks) will be skewed. Takes several minutes for a large model."
        alert.addButton(withTitle: "Start Auto-tune")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await benchmark.autoTune(server: server, port: port, modelAlias: modelAlias)
        }
    }

}
