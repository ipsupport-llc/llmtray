import Foundation

/// The trust barrier between project files and the tools that reach out
/// (adr/0012, "Trust"), decided in code, never by asking the model: file
/// text can't make a network or generator tool run in the same turn.
public enum ToolTrust {
    public enum Kind: Equatable {
        case ordinary
        /// Returns project file text (search, read) or names (list).
        case project
        /// Reaches the network (ToolCatalog's usesNetwork) or starts a
        /// generator (image, edit, music).
        case guarded
    }

    /// Guarded tools may be declared and run: not once a project tool has
    /// returned anything in this turn.
    public static func allowsGuarded(projectTextThisTurn: Bool) -> Bool { !projectTextThisTurn }

    /// The calls of one response to refuse before any of it runs -- before
    /// a Creator mode draft, a generator queue ticket or the chat model's
    /// unload: every guarded call of a batch that has a project call, or of
    /// a turn where project text came back already.
    public static func refusedUpFront(_ batch: [(id: String, kind: Kind)], projectTextThisTurn: Bool) -> Set<String> {
        guard projectTextThisTurn || batch.contains(where: { $0.kind == .project }) else { return [] }
        return Set(batch.filter { $0.kind == .guarded }.map(\.id))
    }

    /// The refusal the model gets (a `.refused` result: left out of later
    /// turns).
    public static let refusal = "Not run: project file text is part of this turn, so web and generator tools are off "
        + "until the user's next message. Don't call it again now; answer in text, and say what you'd do if the user asks."
}
