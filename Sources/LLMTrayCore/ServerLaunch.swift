import Foundation

/// Builds mlx_lm.server's argument list from a resolved profile.
///
/// Pure, so the launch path is unit-testable; ServerManager supplies the
/// model-derived facts (`disallowQuantizedKV`, the drafter repo) and runs
/// the process.
public enum ServerLaunch {
    public struct Context: Equatable, Sendable {
        public var modelPath: String
        public var internalPort: Int
        public var alias: String
        /// The model reuses KV across layers (Gemma 4 E2B/E4B,
        /// `num_kv_shared_layers > 0`); quantized KV crashes it, so KV
        /// quantization is forced off whatever the profile says.
        public var disallowQuantizedKV: Bool
        /// `--draft-model` value, already decided by the caller (profile's
        /// `mtpDrafter`, a known drafter for this model, runtime support).
        public var drafterRepo: String?

        public init(modelPath: String, internalPort: Int, alias: String, disallowQuantizedKV: Bool, drafterRepo: String?) {
            self.modelPath = modelPath
            self.internalPort = internalPort
            self.alias = alias
            self.disallowQuantizedKV = disallowQuantizedKV
            self.drafterRepo = drafterRepo
        }
    }

    public static func arguments(_ p: ResolvedProfile, _ c: Context) -> [String] {
        var args = [
            "-m", "mlx_lm.server",
            "--model", c.modelPath, "--port", String(c.internalPort),
            "--prefill-step-size", String(p.prefillStepSize),
            "--prompt-cache-bytes", String(p.promptCacheMB * 1_048_576),
            // Server-side sampling defaults: mlx_lm.server uses these only
            // for request fields the client didn't send, so external
            // clients (through the proxy) get the profile's sampling while
            // anything they send explicitly still wins. Without them the
            // server default is temp 0 (greedy).
            "--temp", String(p.temperature),
            "--top-p", String(p.topP),
            "--max-tokens", String(p.maxTokens),
        ]
        if p.topK > 0 {
            args += ["--top-k", String(p.topK)]
        }
        let kvBits = c.disallowQuantizedKV ? 0 : p.kvBits
        if kvBits > 0 {
            args += ["--kv-bits", String(kvBits), "--kv-group-size", String(p.kvGroupSize),
                     "--quantized-kv-start", String(p.quantizedKVStart)]
        }
        if p.decodeConcurrency > 1 {
            args += ["--decode-concurrency", String(p.decodeConcurrency)]
        }
        if !c.alias.isEmpty {
            args += ["--model-alias", c.alias]
        }
        if let drafter = c.drafterRepo {
            args += ["--draft-model", drafter]
        }
        if p.verboseServerLogging {
            args += ["--log-level", "DEBUG"]
        }
        args += p.extraServerArgs.split(separator: " ").map(String.init)
        return args
    }

    /// Whether switching a running model from one resolved profile to
    /// another changes its launch arguments (so the server must restart).
    /// Includes the sampling defaults, which are launch arguments too.
    public static func needsRestart(from a: ResolvedProfile, to b: ResolvedProfile) -> Bool {
        let c = Context(modelPath: "", internalPort: 0, alias: "", disallowQuantizedKV: false, drafterRepo: nil)
        return arguments(a, c) != arguments(b, c) || a.mtpDrafter != b.mtpDrafter
    }

    /// Whether the user's own extra arguments already choose a drafter,
    /// which then wins over the automatic one.
    public static func extraArgsSetDrafter(_ p: ResolvedProfile) -> Bool {
        p.extraServerArgs.contains("--draft-model")
    }
}
