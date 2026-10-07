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
        /// The model folder has its own MTP head (`model-mtp.safetensors`,
        /// Qwen 3.5) and the runtime uses it: the server drafts with it
        /// unless the profile turns `mtpDrafter` off.
        public var mtpHead: Bool
        /// The model's trained context length, if known: caps the
        /// server-side `--max-tokens` default (Default is shared across
        /// models, so its max_tokens may be sized for a bigger one).
        public var maxContext: Int?
        /// Global diagnostics setting (Settings > Server), not per profile.
        public var verboseLogging: Bool
        /// `--prefill-memory-mb`: what a prefill chunk's attention scores may
        /// take (the runtime shrinks the chunk as the context grows); nil
        /// when the runtime has no such flag or the GPU limit isn't known.
        public var prefillMemoryMB: Int?
        /// `--buffer-cache-mb`: MLX's cache of freed buffers, the prefill
        /// chunk's share -- not on top of it: what it caches is that scratch,
        /// freed (the next chunk reuses its buffers; in decoding there's no
        /// chunk). Uncapped, a draft model's buffers of a new size every step
        /// piled up to ~4 GB and a 24 GB Mac swapped. nil when the runtime
        /// has no such flag.
        public var bufferCacheMB: Int?
        /// GPU memory the model leaves: the GPU limit less its weights
        /// (gpuHeadroomBytes); caps the prompt cache (promptCacheBytes). nil
        /// when the GPU limit isn't known -- the profile's size then.
        public var gpuHeadroomBytes: Int64?

        /// How the memory beside the weights is shared out (Settings >
        /// Server > Memory).
        public var memoryShares: MemoryShares
        /// The runtime has --mmap-lookup-tables and --lazy-towers.
        public var supportsLowMemoryWeights: Bool

        public init(modelPath: String, internalPort: Int, alias: String, disallowQuantizedKV: Bool, drafterRepo: String?, maxContext: Int? = nil, verboseLogging: Bool = false,
                    prefillMemoryMB: Int? = nil, bufferCacheMB: Int? = nil, gpuHeadroomBytes: Int64? = nil,
                    memoryShares: MemoryShares = .default, supportsLowMemoryWeights: Bool = false, mtpHead: Bool = false) {
            self.modelPath = modelPath
            self.internalPort = internalPort
            self.alias = alias
            self.disallowQuantizedKV = disallowQuantizedKV
            self.drafterRepo = drafterRepo
            self.maxContext = maxContext
            self.verboseLogging = verboseLogging
            self.prefillMemoryMB = prefillMemoryMB
            self.bufferCacheMB = bufferCacheMB
            self.gpuHeadroomBytes = gpuHeadroomBytes
            self.memoryShares = memoryShares
            self.supportsLowMemoryWeights = supportsLowMemoryWeights
            self.mtpHead = mtpHead
        }
    }

    /// How the GPU memory the weights leave is shared out: a margin kept
    /// free (activations, Metal's own), then of the rest a share for the
    /// prompt cache and one for a prefill chunk's scratch; what neither takes
    /// holds the live KV cache and a checkpoint's copy (both at a half ran a
    /// 35K-token prefill out of memory with a 5 GB cache). Settings > Server.
    public struct MemoryShares: Equatable, Sendable {
        public var marginMB: Int
        public var promptCachePercent: Int
        public var prefillPercent: Int

        public init(marginMB: Int, promptCachePercent: Int, prefillPercent: Int) {
            self.marginMB = max(0, marginMB)
            self.promptCachePercent = min(max(0, promptCachePercent), 100)
            // Together at most 90%: the live cache needs some of it.
            self.prefillPercent = min(max(0, prefillPercent), max(0, 90 - self.promptCachePercent))
        }

        public static let `default` = MemoryShares(marginMB: 1536, promptCachePercent: 40, prefillPercent: 20)

        var marginBytes: Int64 { Int64(marginMB) * 1_048_576 }
    }

    /// The default margin, for callers without shares of their own.
    static var memoryMargin: Int64 { MemoryShares.default.marginBytes }

    /// GPU memory left beside the model's weights (negative: they don't
    /// fit); nil when the GPU limit isn't known.
    public static func gpuHeadroomBytes(gpuLimitBytes: UInt64?, weightsBytes: Int64) -> Int64? {
        gpuLimitBytes.map { Int64(clamping: $0) - weightsBytes }
    }

    /// The prefill chunk's memory: its share of what the GPU limit leaves
    /// beside the weights and the margin, 256 MB to 4 GB (a long prompt with
    /// a fixed big chunk ran a 26B model out of memory at a 30K offset).
    public static func prefillMemoryMB(gpuLimitBytes: UInt64?, weightsBytes: Int64, shares: MemoryShares = .default) -> Int? {
        guard let gpuLimitBytes else { return nil }
        let free = Int64(clamping: gpuLimitBytes) - weightsBytes - shares.marginBytes
        return min(4096, max(256, Int(free * Int64(shares.prefillPercent) / 100 / 1_048_576)))
    }

    /// `--prompt-cache-bytes`: the profile's size, but at most its share of
    /// what the model leaves beside the margin. The cached KV lives in GPU
    /// memory too -- a 4 GB cache beside a model that leaves 1.2 GB ran a
    /// 20K-token prefill out of memory. 0 when nothing's left: the runtime
    /// then drops cached prompts as each new request comes in (0 is a cap
    /// of 0 bytes there, not "unlimited").
    public static func promptCacheBytes(profileMB: Int, gpuHeadroomBytes: Int64?, shares: MemoryShares = .default) -> Int64 {
        let profile = Int64(max(0, profileMB)) * 1_048_576
        guard let gpuHeadroomBytes else { return profile }
        return min(profile, max(0, (gpuHeadroomBytes - shares.marginBytes) * Int64(shares.promptCachePercent) / 100))
    }

    /// The prompt cache a launch gets when the GPU memory cuts it below the
    /// profile's (for the launch log); nil when it doesn't, or when the
    /// profile's extra arguments set `--prompt-cache-bytes` themselves.
    public static func promptCacheCut(_ p: ResolvedProfile, _ c: Context) -> (effective: Int64, profile: Int64)? {
        guard !extraArgsSetPromptCache(p) else { return nil }
        let profile = Int64(max(0, p.promptCacheMB)) * 1_048_576
        let effective = promptCacheBytes(profileMB: p.promptCacheMB, gpuHeadroomBytes: c.gpuHeadroomBytes, shares: c.memoryShares)
        return effective < profile ? (effective, profile) : nil
    }

    /// The user's own `--prompt-cache-bytes` (extra arguments) wins.
    static func extraArgsSetPromptCache(_ p: ResolvedProfile) -> Bool {
        extraArgsSet("--prompt-cache-bytes", p)
    }

    /// `--prompt-cache-size`: how many cached prompts the server keeps. Its
    /// default, 10, evicted useful checkpoints -- each request stores
    /// several (system, user, junction), and an agent runs a few
    /// conversations side by side. The byte cap (promptCacheBytes, already
    /// sized to the free GPU memory) is the real limit; the count only has
    /// to not evict first.
    static let promptCacheEntries = 64

    /// Whether the profile's extra arguments set `flag`, as `--x v` or `--x=v`.
    static func extraArgsSet(_ flag: String, _ p: ResolvedProfile) -> Bool {
        p.extraServerArgs.split(separator: " ").contains { $0 == flag || $0.hasPrefix(flag + "=") }
    }

    public static func arguments(_ p: ResolvedProfile, _ c: Context) -> [String] {
        var args = [
            "-m", "mlx_lm.server",
            "--model", c.modelPath, "--port", String(c.internalPort),
            "--prefill-step-size", String(p.prefillStepSize),
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
        if !extraArgsSetPromptCache(p) {
            args += ["--prompt-cache-bytes", String(promptCacheBytes(profileMB: p.promptCacheMB, gpuHeadroomBytes: c.gpuHeadroomBytes, shares: c.memoryShares))]
        }
        // No runtime check: upstream mlx-lm added it together with
        // --prompt-cache-bytes (#906), which every launch already passes.
        if !extraArgsSet("--prompt-cache-size", p) {
            args += ["--prompt-cache-size", String(promptCacheEntries)]
        }
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
        // Said either way: a head that has just been downloaded changes the
        // launch, so a restart is offered (pendingLaunchChange). 3: the most
        // drafts per step; the runtime picks 0...3 by what's fastest.
        // Not with a drafter model: that one is drafted with instead.
        if c.mtpHead, c.drafterRepo == nil, !extraArgsSetDrafter(p), !extraArgsSet("--num-draft-tokens", p) {
            args += ["--num-draft-tokens", p.mtpDrafter ? "3" : "0"]
        }
        if p.lowMemoryWeights, c.supportsLowMemoryWeights {
            args += ["--mmap-lookup-tables", "--lazy-towers"]
        }
        if c.verboseLogging {
            args += ["--log-level", "DEBUG"]
        }
        if let mb = c.prefillMemoryMB, !p.extraServerArgs.contains("--prefill-memory-mb") {
            args += ["--prefill-memory-mb", String(mb)]
        }
        if let mb = c.bufferCacheMB, !p.extraServerArgs.contains("--buffer-cache-mb") {
            args += ["--buffer-cache-mb", String(mb)]
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

    /// What a launch does about the model's MTP drafter.
    public enum DrafterPlan: Equatable, Sendable {
        /// Nothing: no drafter is known for the model, the profile turns it
        /// off, or its own extra arguments pick one.
        case none
        /// Known, but the installed runtime can't load it (an older pinned
        /// mlx-lm would fail the whole start): Check for Updates.
        case runtimeTooOld
        /// In the hub cache: `--draft-model` gets its snapshot folder, so
        /// the start needs no network.
        case use(folder: String)
        /// Not downloaded yet: start without it (never wait on the network)
        /// and fetch `repo` in the background for a later start.
        case startWithoutAndDownload(repo: String)
    }

    /// The drafter decision for a launch: `knownRepo` is the model's
    /// drafter (ModelDiscovery), `localSnapshot` its folder in the hub
    /// cache if it's complete there.
    public static func drafterPlan(for p: ResolvedProfile, knownRepo: String?, runtimeSupports: Bool, localSnapshot: String?) -> DrafterPlan {
        guard let repo = knownRepo, p.mtpDrafter, !extraArgsSetDrafter(p) else { return .none }
        guard runtimeSupports else { return .runtimeTooOld }
        if let folder = localSnapshot { return .use(folder: folder) }
        return .startWithoutAndDownload(repo: repo)
    }

    /// The drafter to fetch along with a freshly downloaded model: its
    /// known repo, when the profile the model runs under wants it and it
    /// isn't in the hub cache yet. The runtime isn't asked -- one that can't
    /// load it yet may be updated before the model's first start.
    public static func drafterToFetch(with p: ResolvedProfile, knownRepo: String?, cached: Bool) -> String? {
        guard let repo = knownRepo, !cached, p.mtpDrafter, !extraArgsSetDrafter(p) else { return nil }
        return repo
    }

    /// Environment for the model server: it never goes to the network (the
    /// model is a local folder, the drafter its cached snapshot), so a start
    /// works offline and never waits on the Hub.
    public static let offlineEnvironment: [String: String] = [
        "HF_HUB_OFFLINE": "1",
        "HF_DATASETS_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
    ]

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
        // What `arguments` leaves out for the user's own flags stays out.
        var c = c
        if extraArgsSet("--num-draft-tokens", p) || extraArgsSetDrafter(p) { c.mtpHead = false }
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
        let fields: [(key: String, json: String)] = [
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
