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
        /// Global diagnostics setting (Settings > Server), not per profile.
        public var verboseLogging: Bool

        public init(modelPath: String, internalPort: Int, alias: String, disallowQuantizedKV: Bool, drafterRepo: String?, maxContext: Int? = nil, verboseLogging: Bool = false) {
            self.modelPath = modelPath
            self.internalPort = internalPort
            self.alias = alias
            self.disallowQuantizedKV = disallowQuantizedKV
            self.drafterRepo = drafterRepo
            self.maxContext = maxContext
            self.verboseLogging = verboseLogging
        }
    }

    public static func arguments(_ p: ResolvedProfile, _ c: Context) -> [String] {
        var args = [
            "-m", "mlx_lm.server",
            "--model", c.modelPath, "--port", String(c.internalPort),
            "--prefill-step-size", String(p.prefillStepSize),
            "--prompt-cache-bytes", String(p.promptCacheMB * 1_048_576),
            // Server-side sampling defaults: mlx_lm.server uses these only
            // for request fields the client didn't send. Only a fallback:
            // the proxy fills the same fields from the profile's current
            // values into every request (requestDefaults), so changing them
            // never needs a restart (see withoutSampling). Without them the
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
        if c.verboseLogging {
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
        return restartKey(a, ca) != restartKey(b, cb)
    }

    /// What decides whether a running server must restart: its arguments
    /// without the generated sampling flags (sampling reaches it with every
    /// request, requestDefaults), but with the profile's extra arguments
    /// whole -- a sampling flag the user put there is a launch setting.
    public static func restartKey(_ p: ResolvedProfile, _ c: Context) -> [String] {
        var generated = p
        generated.extraServerArgs = ""
        return withoutSampling(arguments(generated, c)) + p.extraServerArgs.split(separator: " ").map(String.init)
    }

    /// The sampling flags `arguments` sets; each takes one value.
    static let samplingFlags: Set<String> = ["--temp", "--top-p", "--top-k", "--max-tokens"]

    /// `args` without the sampling flags and their values: what decides
    /// whether a running server must restart. Sampling reaches it with
    /// every request anyway (requestDefaults).
    public static func withoutSampling(_ args: [String]) -> [String] {
        var out: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if samplingFlags.contains(arg) { skipNext = true; continue }
            out.append(arg)
        }
        return out
    }

    /// The request fields the proxy fills from the profile when a client
    /// didn't send them, as JSON literals -- the same values `arguments`
    /// gives the server, but current, not as of the last launch.
    /// `launchedExtraArgs`: the extra arguments the running server was
    /// started with (default: the profile's), since those are what it uses.
    public static func requestDefaults(_ p: ResolvedProfile, maxContext: Int?, launchedExtraArgs: String? = nil) -> [(key: String, json: String)] {
        func number(_ d: Double) -> String { d.isFinite ? String(d) : "0" }
        // A sampling flag in the profile's extra arguments is the server's
        // default then, as before: not overridden per request.
        let extra = Set((launchedExtraArgs ?? p.extraServerArgs).split(separator: " ").map {
            String($0.split(separator: "=", maxSplits: 1).first ?? $0)   // --temp=0.2 too
        })
        let flag = ["temperature": "--temp", "top_p": "--top-p", "max_tokens": "--max-tokens", "top_k": "--top-k"]
        var fields: [(key: String, json: String)] = [
            ("temperature", number(p.temperature)),
            ("top_p", number(p.topP)),
            ("max_tokens", String(min(p.maxTokens, maxContext ?? p.maxTokens))),
            // 0 too (= off): left out, the launch-time --top-k would apply.
            ("top_k", String(max(0, p.topK))),
        ]
        return fields.filter { !extra.contains(flag[$0.key] ?? "") }
    }

    /// Whether the user's own extra arguments already choose a drafter,
    /// which then wins over the automatic one.
    public static func extraArgsSetDrafter(_ p: ResolvedProfile) -> Bool {
        p.extraServerArgs.contains("--draft-model")
    }
}
