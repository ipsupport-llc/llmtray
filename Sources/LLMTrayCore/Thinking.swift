import Foundation

/// How hard a thinking model thinks (the composer's picker, adr/0022):
/// Off, Low, Medium, High -- High as long as the model takes, as before.
public enum ThinkingEffort: String, CaseIterable, Sendable {
    case off, low, medium, high

    public var title: String {
        switch self {
        case .off: return NSLocalizedString("Off", comment: "thinking effort: none")
        case .low: return NSLocalizedString("Low", comment: "thinking effort")
        case .medium: return NSLocalizedString("Medium", comment: "thinking effort")
        case .high: return NSLocalizedString("High", comment: "thinking effort: as long as the model takes")
        }
    }
}

/// What a model's chat template offers for it.
public enum ThinkingStyle: Equatable, Sendable {
    /// Doesn't think, or nothing to steer: no picker.
    case none
    /// Thinks in a reasoning block (Qwen 3.5, Gemma 4, Nemotron, LFM2.5
    /// Thinking): Off by the template's enable_thinking, Low and Medium by
    /// the server's thinking budget.
    case budget
    /// Has its own effort levels (gpt-oss's reasoning_effort).
    case levels
}

public enum Thinking {
    /// Reasoning tokens at most for Low and Medium.
    public static let budgets: [ThinkingEffort: Int] = [.low: 512, .medium: 2048]

    /// The budget a user message is sent with, told to the model too (the
    /// server's cut-off mid-thought is the backstop, not the plan): Low and
    /// Medium of a budget model; nil otherwise.
    public static func budgetToTell(style: ThinkingStyle, effort: ThinkingEffort) -> Int? {
        style == .budget ? budgets[effort] : nil
    }

    /// The line put before the user's message for that budget.
    public static func note(budget: Int) -> String {
        "[App note, not the user's words: the user chose a short reasoning effort -- think at most about \(budget) tokens, "
            + "then answer. Your thinking is cut off there.]"
    }

    /// From the model's chat template (its text): levels where it reads
    /// reasoning_effort, a budget where it thinks in a block.
    public static func style(chatTemplate: String?) -> ThinkingStyle {
        guard let t = chatTemplate, !t.isEmpty else { return .none }
        if t.contains("reasoning_effort") { return .levels }
        for marker in ["enable_thinking", "<think>", "<|channel>", "<|think"] where t.contains(marker) { return .budget }
        return .none
    }

    /// The request's fields for an effort. Off is the template's switch and,
    /// for a template that thinks regardless, a budget of nothing.
    public static func requestFields(style: ThinkingStyle, effort: ThinkingEffort) -> [String: Any] {
        switch (style, effort) {
        case (.none, _), (.budget, .high):
            return [:]
        case (.budget, .off):
            return ["chat_template_kwargs": ["enable_thinking": false], "thinking_budget": 0]
        case (.budget, let e):
            return budgets[e].map { ["thinking_budget": $0] } ?? [:]
        case (.levels, let e):
            return ["chat_template_kwargs": ["reasoning_effort": e == .off ? "low" : e.rawValue]]
        }
    }
}
