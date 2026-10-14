import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The shape a reply must have, for a model that can be held to one (Apple's
/// guided generation): the JSON the reply parsers read, nothing else. Other
/// models get the same prompts and ignore it.
public enum ReplyShape: Equatable, Sendable {
    /// {"message1": [label, ...], "message2": ...}: one field per message
    /// (a field per message keeps the count; an array of them didn't), 1-2
    /// of `choices` each.
    case labels(count: Int, choices: [String])
    /// {"ops": [{"op", "id", "kind", "topic", "text", "observed", "quote", ...}]}:
    /// `ids` the only ids it may name, `kinds` the only kinds; `quote2` and
    /// `scope` when the step takes them.
    case ops(actions: [String], ids: [String], kinds: [String], quote2: Bool, scope: Bool)
    /// {"observed", "text", "quote"}: empty strings for nothing.
    case mood
    /// {key: [choice, ...]}: `count` of `choices`.
    case choices(key: String, count: Int, choices: [String])
}

/// Apple's on-device language model (adr/0025): the system's, on the Neural
/// Engine, nothing to download. Called in-process; never Apple's cloud
/// model. Everything is behind availability checks, so the app still runs
/// where the framework isn't (macOS 14-25).
public enum AppleSystemModel {
    /// Its id wherever a model's path would be (memory's reader setting, and
    /// later the catalog): not a folder.
    public static let id = "apple-system"
    public static let displayName = "Apple (on this Mac)"

    public enum Availability: Equatable, Sendable {
        case available
        /// Why not, as the user can act on it.
        case unavailable(String)
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Not usable now (Apple Intelligence off, the model not ready): later.
        case unavailable(String)
        /// Apple's guardrails declined: this request, not later.
        case refused(String)
        /// The request doesn't fit the model's context.
        case contextExceeded
        /// No answer within the deadline.
        case timedOut
        case failed(String)

        /// Worth trying again later from the same place.
        public var isTransient: Bool {
            switch self {
            case .unavailable, .timedOut: return true
            case .refused, .contextExceeded, .failed: return false
            }
        }
    }

    public static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return .unavailable(NSLocalizedString("Apple Intelligence is off (System Settings › Apple Intelligence & Siri).", comment: "apple model"))
                case .deviceNotEligible:
                    return .unavailable(NSLocalizedString("This Mac can't run Apple's model.", comment: "apple model"))
                case .modelNotReady:
                    return .unavailable(NSLocalizedString("Apple's model is still getting ready (downloading or updating).", comment: "apple model"))
                @unknown default:
                    return .unavailable(NSLocalizedString("Apple's model isn't available.", comment: "apple model"))
                }
            }
        }
        #endif
        return .unavailable(NSLocalizedString("Apple's model needs macOS 26 or later.", comment: "apple model"))
    }

    public static var isAvailable: Bool { availability == .available }

    /// Its context, input and output together; nil where it isn't.
    public static var contextSize: Int? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable {
            if #available(macOS 26.4, *) { return SystemLanguageModel.default.contextSize }
            return 4096
        }
        #endif
        return nil
    }

    /// The languages Apple lists for it (codes); it may answer in others.
    public static var languageCodes: Set<String> {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable {
            return Set(SystemLanguageModel.default.supportedLanguages.compactMap { $0.languageCode?.identifier })
        }
        #endif
        return []
    }

    /// One answer to an OpenAI chat request's `messages`, from a fresh
    /// session (never shared), within `timeout` seconds.
    /// `shape`: the reply is held to it (guided generation) and comes back
    /// as its JSON.
    public static func complete(messages: [[String: Any]], maxTokens: Int?, temperature: Double?, shape: ReplyShape? = nil,
                                timeout: TimeInterval = 120) async throws -> String {
        guard let conversation = AppleConversation(messages: messages) else { throw Failure.failed("no user message") }
        guard case .available = availability else {
            if case .unavailable(let why) = availability { throw Failure.unavailable(why) }
            throw Failure.unavailable("")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await respond(conversation, maxTokens: maxTokens, temperature: temperature, shape: shape) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw Failure.timedOut }
                return first
            }
        }
        #endif
        throw Failure.unavailable("")
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    static func respond(_ conversation: AppleConversation, maxTokens: Int?, temperature: Double?, shape: ReplyShape?) async throws -> String {
        var entries: [Transcript.Entry] = []
        if !conversation.instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: conversation.instructions))], toolDefinitions: [])))
        }
        for turn in conversation.turns {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: turn.text))
            switch turn.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            }
        }
        let session = LanguageModelSession(model: .default, tools: [], transcript: Transcript(entries: entries))
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
        do {
            if let shape {
                let schema = try GenerationSchema(root: dynamicSchema(shape), dependencies: [])
                return try await session.respond(to: conversation.prompt, schema: schema, options: options).content.jsonString
            }
            return try await session.respond(to: conversation.prompt, options: options).content
        } catch {
            throw classify(error)
        }
    }

    @available(macOS 26, *)
    static func dynamicSchema(_ shape: ReplyShape) -> DynamicGenerationSchema {
        let string = DynamicGenerationSchema(type: String.self)
        func oneOf(_ name: String, _ choices: [String]) -> DynamicGenerationSchema {
            DynamicGenerationSchema(name: name, anyOf: choices)
        }
        func list(_ item: DynamicGenerationSchema, exactly count: Int) -> DynamicGenerationSchema {
            DynamicGenerationSchema(arrayOf: item, minimumElements: count, maximumElements: count)
        }
        switch shape {
        case .labels(let count, let choices):
            let labels = DynamicGenerationSchema(arrayOf: oneOf("Label", choices), minimumElements: 1, maximumElements: 2)
            return DynamicGenerationSchema(name: "Triage", properties: (1...max(1, count)).map {
                .init(name: "message\($0)", schema: labels)
            })
        case .ops(let actions, let ids, let kinds, let quote2, let scope):
            var properties: [DynamicGenerationSchema.Property] = [.init(name: "op", schema: oneOf("Action", actions))]
            if !ids.isEmpty { properties.append(.init(name: "id", schema: oneOf("NoteID", ids), isOptional: true)) }
            if !kinds.isEmpty { properties.append(.init(name: "kind", schema: oneOf("Kind", kinds), isOptional: true)) }
            if scope { properties.append(.init(name: "scope", schema: oneOf("Scope", ["user", "project"]), isOptional: true)) }
            properties += [
                .init(name: "topic", schema: string, isOptional: true),
                .init(name: "text", schema: string, isOptional: true),
                .init(name: "observed", schema: string, isOptional: true),
                .init(name: "quote", description: "the user's own words, copied exactly", schema: string),
            ]
            if quote2 { properties.append(.init(name: "quote2", description: "words from another message", schema: string, isOptional: true)) }
            let op = DynamicGenerationSchema(name: "Op", properties: properties)
            return DynamicGenerationSchema(name: "Ops", properties: [
                .init(name: "ops", schema: DynamicGenerationSchema(arrayOf: op, minimumElements: 0, maximumElements: 6)),
            ])
        case .mood:
            return DynamicGenerationSchema(name: "Mood", properties: [
                .init(name: "observed", description: "empty when no clear feeling", schema: string),
                .init(name: "text", schema: string),
                .init(name: "quote", schema: string),
            ])
        case .choices(let key, let count, let choices):
            return DynamicGenerationSchema(name: "Answer", properties: [.init(name: key, schema: list(oneOf("Choice", choices), exactly: count))])
        }
    }
    #endif

    /// The framework's errors as LLMTray handles them. Matched by name, so
    /// macOS 26's GenerationError and 27's LanguageModelError both fit.
    static func classify(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is CancellationError { return .timedOut }
        let name = String(describing: error).lowercased()
        if name.contains("guardrail") || name.contains("refusal") { return .refused(String(describing: error)) }
        if name.contains("timeout") || name.contains("timedout") { return .timedOut }
        if name.contains("context") && (name.contains("exceed") || name.contains("size")) { return .contextExceeded }
        if name.contains("assetsunavailable") || name.contains("ratelimited") || name.contains("concurrent") {
            return .unavailable(String(describing: error))
        }
        return .failed(String(describing: error))
    }
}
