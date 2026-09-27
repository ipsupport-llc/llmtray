import Foundation

/// The trust barrier between file text and the tools that act on it
/// (adr/0012, "Trust"; adr/0014, Hardening 2), decided in code, never by
/// asking the model: file text can't make a network or generator tool run in
/// the same turn, and file or folder text can't make a folder change.
public enum ToolTrust {
    public enum Kind: Equatable {
        case ordinary
        /// Returns project file text (search, read) or names (list).
        case project
        /// Reads a granted folder (`files`): names and bounded contents.
        case folderRead
        /// Proposes folder changes (`change_files`): its result names files.
        case folderChange
        /// Reaches the network (ToolCatalog's usesNetwork) or starts a
        /// generator (image, edit, music).
        case guarded
    }

    /// What the turn has returned so far that isn't the user's.
    public struct TurnState: Equatable, Sendable {
        /// A project tool returned something.
        public var projectText = false
        /// A folder read (`files`) returned something.
        public var folderText = false
        /// A folder change proposal (`change_files`) returned something.
        public var changeResult = false

        public init(projectText: Bool = false, folderText: Bool = false, changeResult: Bool = false) {
            self.projectText = projectText
            self.folderText = folderText
            self.changeResult = changeResult
        }

        /// Anything that names files: guarded tools are off.
        public var hasUntrustedText: Bool { projectText || folderText || changeResult }
        /// File or folder text a change could be prompted by: folder changes
        /// are off (a change's own result isn't: its names are the model's).
        public var hasFileText: Bool { projectText || folderText }

        /// After a call of `kind` returned.
        public mutating func record(_ kind: Kind) {
            switch kind {
            case .project: projectText = true
            case .folderRead: folderText = true
            case .folderChange: changeResult = true
            case .ordinary, .guarded: break
            }
        }
    }

    /// Guarded tools may be declared and run: not once a project tool has
    /// returned anything in this turn.
    public static func allowsGuarded(projectTextThisTurn: Bool) -> Bool { !projectTextThisTurn }

    public static func allowsGuarded(_ state: TurnState) -> Bool { !state.hasUntrustedText }

    /// Folder changes may be declared and run: not after file or folder
    /// text in this turn.
    public static func allowsChange(_ state: TurnState) -> Bool { !state.hasFileText }

    /// Whether a call of `kind` may run now.
    public static func allows(_ kind: Kind, _ state: TurnState) -> Bool {
        switch kind {
        case .guarded: return allowsGuarded(state)
        case .folderChange: return allowsChange(state)
        case .ordinary, .project, .folderRead: return true
        }
    }

    /// The calls of one response to refuse before any of it runs -- before
    /// a Creator mode draft, a generator queue ticket or the chat model's
    /// unload: every guarded call of a batch that has a project call, or of
    /// a turn where project text came back already.
    public static func refusedUpFront(_ batch: [(id: String, kind: Kind)], projectTextThisTurn: Bool) -> Set<String> {
        refusedUpFront(batch, state: TurnState(projectText: projectTextThisTurn))
    }

    /// The same with the folder tools: guarded calls beside anything that
    /// returns file names or text (or after it in the turn), and folder
    /// changes beside a project or folder read (or after one).
    public static func refusedUpFront(_ batch: [(id: String, kind: Kind)], state: TurnState) -> Set<String> {
        var after = state
        for call in batch { after.record(call.kind) }
        return Set(batch.filter { !allows($0.kind, after) }.map(\.id))
    }

    /// The refusal the model gets (a `.refused` result: left out of later
    /// turns).
    public static let refusal = "Not run: project file text is part of this turn, so web and generator tools are off "
        + "until the user's next message. Don't call it again now; answer in text, and say what you'd do if the user asks."

    /// The refusal of a guarded call after (or beside) folder names.
    public static let folderRefusal = "Not run: file names from the user's folders are part of this turn, so web and "
        + "generator tools are off until the user's next message. Answer in text."

    /// The refusal of a folder change after (or beside) a read.
    public static let changeRefusal = "Not run: folder or file contents were read in this turn, so changes wait for "
        + "the user's next message. Describe the changes you'd make and ask the user to confirm; then call "
        + "change_files first thing in that turn, without reading again."

    /// The refusal a guarded or change call gets in `state`.
    public static func refusalText(for kind: Kind, _ state: TurnState) -> String {
        if kind == .folderChange { return changeRefusal }
        return state.projectText ? refusal : folderRefusal
    }
}
