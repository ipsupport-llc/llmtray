import SwiftUI

struct BenchmarkView: View {
    @EnvironmentObject var server: ServerManager
    @ObservedObject var benchmark: BenchmarkRunner
    let port: Int
    let modelAlias: String

    @State private var promptPreset: BenchmarkPreset = .medium
    @State private var maxTokens: Double = 128
    @State private var trials: Int = 3
    @State private var showAutoTuneWarning = false

    private var serverReady: Bool {
        if case .running = server.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !serverReady {
                Text("Start the server first.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Text("Quick benchmark").foregroundColor(.secondary)
            Picker("Prompt size", selection: $promptPreset) {
                ForEach(BenchmarkPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Stepper("Generate: \(Int(maxTokens)) tok", value: $maxTokens, in: 16...512, step: 16)
            Stepper("Trials: \(trials) (averaged)", value: $trials, in: 1...5)

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
                    Text(benchmark.statusText).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }

            if let errorText = benchmark.errorText {
                Text(errorText).font(.system(size: 10)).foregroundColor(.red)
            }

            if !benchmark.results.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(benchmark.results.prefix(5)) { result in
                        HStack(spacing: 8) {
                            Text(result.label).frame(width: 110, alignment: .leading)
                            Text("TTFT \(String(format: "%.2f", result.ttft))s")
                            Text("prefill \(String(format: "%.0f", result.prefillTokPerSec)) tok/s")
                            Text("decode \(String(format: "%.1f", result.decodeTokPerSec)) tok/s")
                        }
                        .font(.system(size: 10, design: .monospaced))
                    }
                }
                .padding(.top, 2)
            }

            Divider().padding(.vertical, 4)

            Text("Auto-tune").foregroundColor(.secondary)
            Text("Restarts the server several times to try different decode-concurrency and prefill-step-size values, then keeps whichever measured fastest. Takes several minutes for a large model. Close other apps and leave the Mac idle while it runs -- background load skews every measurement.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            HStack {
                Button(benchmark.isRunning ? "Running…" : "Auto-tune performance") {
                    showAutoTuneWarning = true
                }
                .disabled(!serverReady || benchmark.isRunning)
                if benchmark.isRunning && !benchmark.autoTuneLog.isEmpty {
                    Button("Cancel") { benchmark.cancel() }
                }
            }
            .confirmationDialog(
                "Before auto-tuning",
                isPresented: $showAutoTuneWarning,
                titleVisibility: .visible
            ) {
                Button("Start auto-tune") {
                    Task {
                        await benchmark.autoTune(server: server, port: port, modelAlias: modelAlias)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Close other apps and don't use the Mac for anything else until this finishes -- it restarts the server repeatedly and measures raw throughput, so any other load (browser tabs, other GPU/CPU work) will skew the result toward the wrong setting.")
            }

            if !benchmark.autoTuneLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(benchmark.autoTuneLog) { candidate in
                        HStack(spacing: 6) {
                            Text(candidate.isWinner ? "★" : " ").frame(width: 12)
                            Text("\(candidate.parameter)=\(candidate.value)").frame(width: 170, alignment: .leading)
                            Text(String(format: "%.1f tok/s", candidate.throughput))
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(candidate.isWinner ? .primary : .secondary)
                        .fontWeight(candidate.isWinner ? .semibold : .regular)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}
