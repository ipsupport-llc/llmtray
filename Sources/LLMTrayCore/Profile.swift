import Foundation

/// A named bundle of chat-request, tool and server-launch settings.
///
/// Profiles are layered: `Default` is the base and normally sets every
/// field. Any other profile is an *overlay* that sets only the fields it
/// changes, and a model assigned to it gets, per field,
/// overlay → `Default` → `Profile.builtIn`. Every field is optional for
/// that reason, and so that a profile file written by an older version
/// (missing newer fields) still loads.
///
/// Stored as one JSON file per profile (see `ProfileStore`), meant to be
/// readable and hand-editable.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var request = RequestSettings()
    public var tools = ToolSettings()
    public var launch = LaunchSettings()

    public static let defaultID = "default"

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    public var isDefault: Bool { id == Self.defaultID }

    private enum CodingKeys: String, CodingKey { case id, name, request, tools, launch }

    // Missing groups decode as empty: a hand-written overlay only lists
    // what it changes ({"name": "Hot", "request": {"temperature": 1.3}}).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed"
        request = try c.decodeIfPresent(RequestSettings.self, forKey: .request) ?? RequestSettings()
        tools = try c.decodeIfPresent(ToolSettings.self, forKey: .tools) ?? ToolSettings()
        launch = try c.decodeIfPresent(LaunchSettings.self, forKey: .launch) ?? LaunchSettings()
    }

    /// Per-chat-request settings. In the in-app chat they're sent on every
    /// request; for external clients they become mlx_lm.server's own
    /// defaults (`--temp` etc.), which apply only when the client didn't
    /// send a value.
    public struct RequestSettings: Codable, Equatable, Sendable {
        public var temperature: Double?
        public var topP: Double?
        /// 0 disables top-k.
        public var topK: Int?
        public var maxTokens: Int?
        public var systemPrompt: String?
        public init() {}
    }

    /// In-app chat tools. External clients bring their own tools; nothing
    /// here is applied to them.
    public struct ToolSettings: Codable, Equatable, Sendable {
        public var enableImageGeneration: Bool?
        /// Names of the chat tools offered to the model (besides image
        /// generation, which has its own switch). Web tools send the
        /// model's queries to public services, so they're opt-in.
        public var enabledTools: [String]?
        /// `ImageGenModel` raw value.
        public var imageGenModel: String?
        /// `ImageQuality` raw value.
        public var imageQuality: String?
        public var unloadModelDuringImageGen: Bool?
        /// Added to the system prompt whenever tools are offered. Empty
        /// string disables it.
        public var toolUsePolicy: String?
        public init() {}
    }

    /// mlx_lm.server launch arguments. Changing them needs a server restart.
    public struct LaunchSettings: Codable, Equatable, Sendable {
        public var kvBits: Int?
        public var kvGroupSize: Int?
        public var quantizedKVStart: Int?
        public var prefillStepSize: Int?
        public var decodeConcurrency: Int?
        public var promptCacheMB: Int?
        /// Use the model's MTP drafter when one is known for it
        /// (`ModelDiscovery.mtpDrafterRepo`).
        public var mtpDrafter: Bool?
        public var extraServerArgs: String?
        // Verbose (DEBUG) server logging is a global diagnostics setting
        // (Settings > Server), not a per-profile one. An older profile file
        // that still has "verboseServerLogging" decodes fine: unknown keys
        // are ignored.
        public init() {}
    }
}

extension Profile {
    /// The rule sent with tools in the in-app chat. The chat templates' own
    /// tool boilerplate only says *how* to call a tool, never when not to,
    /// and a tool-heavy fine-tune (the ipsupport-code Nemotron LoRA) called
    /// generate_image on a plain "привет" 10 times out of 20 -- with "No
    /// tool needed" in its own reasoning. See quant-ternary
    /// nemotron-extreme-quant/docs/FINDINGS.md §2.5.
    /// The local tools (nothing leaves the Mac); web tools are opt-in.
    public static let defaultEnabledTools = ["get_current_date", "calculate"]

    public static let defaultToolUsePolicy =
        "Call a tool only when the user's latest message needs it: to do what they asked (for example "
        + "draw, generate or create an image), or to get what you can't know yourself -- today's date or "
        + "time, exact arithmetic, current news, facts you'd have to look up. For greetings, small talk and "
        + "anything you can answer from your own knowledge, answer in text and do not call any tool."

    /// Earlier built-in rules, replaced by the current one in a Default
    /// that still has one of them unedited (see ProfileStore.ensureDefault).
    public static let formerDefaultToolUsePolicies = [
        "Only call a tool when the user's latest message explicitly asks you to perform that action "
            + "(for example: draw, generate or create an image). For greetings, small talk, questions and "
            + "anything else, answer in text and do not call any tool.",
    ]

    /// Shown (and sent) as Default's system prompt, so users see what the
    /// model gets and what they can add to it, instead of an empty box.
    public static let defaultSystemPrompt =
        "You are a helpful assistant running locally on the user's Mac. "
        + "Answer in the language the user writes in. Be concise and direct; "
        + "use Markdown (lists, code blocks) when it helps readability."

    /// Every field set: the last layer of resolution. Values match what the
    /// app used before profiles existed (except the system prompt, which
    /// used to be empty).
    public static let builtIn: Profile = {
        var p = Profile(id: "builtin", name: "Built-in")
        p.request.temperature = 0.6
        p.request.topP = 0.95
        p.request.topK = 0
        p.request.maxTokens = 1024
        p.request.systemPrompt = defaultSystemPrompt
        p.tools.enableImageGeneration = false
        p.tools.enabledTools = defaultEnabledTools
        p.tools.imageGenModel = "gptqMixed"
        p.tools.imageQuality = "balanced"
        p.tools.unloadModelDuringImageGen = true
        p.tools.toolUsePolicy = defaultToolUsePolicy
        p.launch.kvBits = KVSettings.defaultBits
        p.launch.kvGroupSize = KVSettings.defaultGroupSize
        p.launch.quantizedKVStart = 0
        p.launch.prefillStepSize = 128
        p.launch.decodeConcurrency = 1
        p.launch.promptCacheMB = 1024
        p.launch.mtpDrafter = true
        p.launch.extraServerArgs = ""
        return p
    }()

    /// Number of fields this profile sets (for "overrides N settings").
    public var overrideCount: Int {
        Profile.allFields.filter { $0.isSet(self) }.count
    }
}

/// Field-by-field layered lookup.
public enum ProfileResolver {
    /// overlay → base → built-in. `overlay` is nil (or the base itself)
    /// for models on `Default`.
    public static func value<T>(_ keyPath: KeyPath<Profile, T?>, overlay: Profile?, base: Profile) -> T {
        if let v = overlay?[keyPath: keyPath] { return v }
        if let v = base[keyPath: keyPath] { return v }
        // builtIn sets every field; a nil here is a programming error in
        // `Profile.builtIn`, caught by the tests.
        return Profile.builtIn[keyPath: keyPath]!
    }

    /// Which layer a field's value comes from, for the editor.
    public enum Source: Equatable { case overlay, base, builtIn }

    public static func source<T>(_ keyPath: KeyPath<Profile, T?>, overlay: Profile?, base: Profile) -> Source {
        if overlay?[keyPath: keyPath] != nil { return .overlay }
        if base[keyPath: keyPath] != nil { return .base }
        return .builtIn
    }

    public static func resolve(overlay: Profile?, base: Profile) -> ResolvedProfile {
        func v<T>(_ kp: KeyPath<Profile, T?>) -> T { value(kp, overlay: overlay, base: base) }
        return ResolvedProfile(
            profileID: overlay?.id ?? base.id,
            profileName: overlay?.name ?? base.name,
            // Clamped like the launch values below: a hand-edited or
            // mistyped value must not reach the server as-is.
            temperature: min(max(0, v(\.request.temperature)), 2),
            topP: min(max(0, v(\.request.topP)), 1),
            topK: max(0, v(\.request.topK)),
            maxTokens: max(1, v(\.request.maxTokens)),
            systemPrompt: v(\.request.systemPrompt),
            enableImageGeneration: v(\.tools.enableImageGeneration),
            enabledTools: v(\.tools.enabledTools),
            imageGenModel: v(\.tools.imageGenModel),
            imageQuality: v(\.tools.imageQuality),
            unloadModelDuringImageGen: v(\.tools.unloadModelDuringImageGen),
            toolUsePolicy: v(\.tools.toolUsePolicy),
            kvBits: KVSettings.validBits(v(\.launch.kvBits)),
            kvGroupSize: KVSettings.validGroupSize(v(\.launch.kvGroupSize)),
            quantizedKVStart: max(0, v(\.launch.quantizedKVStart)),
            prefillStepSize: max(1, v(\.launch.prefillStepSize)),
            decodeConcurrency: max(1, v(\.launch.decodeConcurrency)),
            promptCacheMB: max(0, v(\.launch.promptCacheMB)),
            mtpDrafter: v(\.launch.mtpDrafter),
            extraServerArgs: v(\.launch.extraServerArgs)
        )
    }
}

/// A profile with every layer applied -- what actually gets used.
public struct ResolvedProfile: Equatable, Sendable {
    public var profileID: String
    public var profileName: String
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var maxTokens: Int
    public var systemPrompt: String
    public var enableImageGeneration: Bool
    public var enabledTools: [String]
    public var imageGenModel: String
    public var imageQuality: String
    public var unloadModelDuringImageGen: Bool
    public var toolUsePolicy: String
    public var kvBits: Int
    public var kvGroupSize: Int
    public var quantizedKVStart: Int
    public var prefillStepSize: Int
    public var decodeConcurrency: Int
    public var promptCacheMB: Int
    public var mtpDrafter: Bool
    public var extraServerArgs: String
}

/// Type-erased handle on one optional field, for counting and resetting
/// overrides generically.
public struct ProfileField {
    public let name: String
    let isSetFn: (Profile) -> Bool
    let clearFn: (inout Profile) -> Void

    // Plain WritableKeyPath (no `& Sendable`): older toolchains (CI's
    // macos-14 Xcode) can't infer the key path type through that
    // composition.
    init<T>(_ name: String, _ kp: WritableKeyPath<Profile, T?>) {
        self.name = name
        isSetFn = { $0[keyPath: kp] != nil }
        clearFn = { $0[keyPath: kp] = nil }
    }

    public func isSet(_ p: Profile) -> Bool { isSetFn(p) }
    public func clear(_ p: inout Profile) { clearFn(&p) }
}

extension Profile {
    public static let allFields: [ProfileField] = [
        ProfileField("temperature", \.request.temperature),
        ProfileField("topP", \.request.topP),
        ProfileField("topK", \.request.topK),
        ProfileField("maxTokens", \.request.maxTokens),
        ProfileField("systemPrompt", \.request.systemPrompt),
        ProfileField("enableImageGeneration", \.tools.enableImageGeneration),
        ProfileField("enabledTools", \.tools.enabledTools),
        ProfileField("imageGenModel", \.tools.imageGenModel),
        ProfileField("imageQuality", \.tools.imageQuality),
        ProfileField("unloadModelDuringImageGen", \.tools.unloadModelDuringImageGen),
        ProfileField("toolUsePolicy", \.tools.toolUsePolicy),
        ProfileField("kvBits", \.launch.kvBits),
        ProfileField("kvGroupSize", \.launch.kvGroupSize),
        ProfileField("quantizedKVStart", \.launch.quantizedKVStart),
        ProfileField("prefillStepSize", \.launch.prefillStepSize),
        ProfileField("decodeConcurrency", \.launch.decodeConcurrency),
        ProfileField("promptCacheMB", \.launch.promptCacheMB),
        ProfileField("mtpDrafter", \.launch.mtpDrafter),
        ProfileField("extraServerArgs", \.launch.extraServerArgs),
    ]
}
