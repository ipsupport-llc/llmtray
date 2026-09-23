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
        /// The model's trained context length, if known: caps the
        /// server-side `--max-tokens` default (Default is shared across
        /// models, so its max_tokens may be sized for a bigger one).
        public var maxContext: Int?

        public init(modelPath: String, internalPort: Int, alias: String, disallowQuantizedKV: Bool, drafterRepo: String?, maxContext: Int? = nil) {
            self.modelPath = modelPath
            self.internalPort = internalPort
            self.alias = alias
            self.disallowQuantizedKV = disallowQuantizedKV
            self.drafterRepo = drafterRepo
            self.maxContext = maxContext
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
            "--max-tokens", String(min(p.maxTokens, c.maxContext ?? p.maxTokens)),
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

    /// The `--draft-model` a profile gets on a model whose usable drafter
    /// (known for the model *and* supported by the runtime) is
    /// `available`: none if the profile turns the drafter off, or if its
    /// own extra arguments already pick one.
    public static func drafter(for p: ResolvedProfile, available: String?) -> String? {
        guard p.mtpDrafter, !extraArgsSetDrafter(p) else { return nil }
        return available
    }

    /// Whether moving a running model from one resolved profile to another
    /// changes its actual launch arguments (so the server must restart).
    /// `context` is the model's real one (KV-shared guard, context cap);
    /// its `drafterRepo` is the drafter *available* to the model, applied
    /// per profile via `drafter(for:available:)` -- so a KV or drafter
    /// difference that doesn't apply to this model restarts nothing.
    public static func needsRestart(from a: ResolvedProfile, to b: ResolvedProfile, context: Context) -> Bool {
        var ca = context, cb = context
        ca.drafterRepo = drafter(for: a, available: context.drafterRepo)
        cb.drafterRepo = drafter(for: b, available: context.drafterRepo)
        return arguments(a, ca) != arguments(b, cb)
    }

    /// Whether the user's own extra arguments already choose a drafter,
    /// which then wins over the automatic one.
    public static func extraArgsSetDrafter(_ p: ResolvedProfile) -> Bool {
        p.extraServerArgs.contains("--draft-model")
    }
}
