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
        /// ...and it was file content (a search or a read), not only the
        /// listing's names or a pin's answer: what stops a pin.
        public var projectContent = false
        /// A folder read (`files`) returned something.
        public var folderText = false
        /// A folder change proposal (`change_files`) returned something.
        public var changeResult = false
        /// A network tool (or a generator) returned something: web text.
        public var networkText = false
        /// The request carries the project's pinned files (adr/0012, "Pinned
        /// files"): file text from the turn's start, every turn while pinned.
        public var pinnedText = false

        public init(projectText: Bool = false, folderText: Bool = false, changeResult: Bool = false, networkText: Bool = false,
                    pinnedText: Bool = false) {
            self.projectText = projectText
            self.folderText = folderText
            self.changeResult = changeResult
            self.networkText = networkText
            self.pinnedText = pinnedText
        }

        /// Anything that names files: guarded tools are off.
        public var hasUntrustedText: Bool { projectText || folderText || changeResult || pinnedText }
        /// Outside text a change could be prompted by -- file, folder or web
        /// text: folder changes are off (a change's own result isn't: its
        /// names are the model's).
        public var hasFileText: Bool { projectText || folderText || networkText || pinnedText }
        /// What this turn's tool results brought in (the pinned prefix aside).
        /// The listing doesn't count: a model learns a file's id from it
        /// before pinning the file the user asked for.
        public var hasToolText: Bool { projectContent || folderText || changeResult || networkText }

        /// After a call of `kind` returned.
        /// After a project call that returned names only (the listing, a
        /// pin's answer): the barrier as after any project text, but a pin
        /// still allowed.
        public mutating func recordProjectNames() {
            projectText = true
        }

        public mutating func record(_ kind: Kind) {
            switch kind {
            case .project:
                projectText = true
                projectContent = true
            case .folderRead: folderText = true
            case .folderChange: changeResult = true
            case .guarded: networkText = true
            case .ordinary: break
            }
        }
    }

    /// Guarded tools may be declared and run: not once a project tool has
    /// returned anything in this turn.
    public static func allowsGuarded(projectTextThisTurn: Bool) -> Bool { !projectTextThisTurn }

    public static func allowsGuarded(_ state: TurnState) -> Bool { !state.hasUntrustedText }

    /// A file may be pinned (project_files' pin: true): not after text a
    /// tool returned this turn -- a file mustn't pin itself or another --
    /// though the pinned files' own text doesn't count (else a project with
    /// one pinned could never pin a second). Unpinning is always allowed.
    public static func allowsPin(_ state: TurnState) -> Bool { !state.hasToolText }

    /// Folder changes may be declared and run: not after file or folder
    /// text in this turn.
    public static func allowsChange(_ state: TurnState) -> Bool { !state.hasFileText }

    /// After a folder read in `state` (a turn in which changes are off from
    /// then on): whether the user's next message turns them back on -- not
    /// while files are pinned. What makes `files` say so (the chat has a
    /// change grant for the folder).
    public static func changeWaitsForNextMessage(_ state: TurnState) -> Bool { !state.pinnedText }

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
    public static let changeRefusal = "Not run: folder, file or web contents were read in this turn, so changes wait for "
        + "the user's next message. Don't call it again now: describe the changes you'd make and ask the user to confirm; then call "
        + "change_files first thing in that turn, without reading again."

    /// The refusal of a guarded or change call while files are pinned: the
    /// next message won't lift it.
    public static let pinnedRefusal = "Not run: this project has pinned files in context, so web search, generators and "
        + "folder changes are off in its chats. Tell the user; they can unpin files in the project's Files window."

    /// The refusal of a pin after a tool's text this turn.
    public static let pinRefusal = "Not pinned: text a tool returned this turn can't pin files. Ask the user to pin it "
        + "in the project's Files window, or to ask again in a new message."

    /// The refusal a guarded or change call gets in `state`.
    public static func refusalText(for kind: Kind, _ state: TurnState) -> String {
        if state.pinnedText { return pinnedRefusal }
        if kind == .folderChange { return changeRefusal }
        return state.projectText ? refusal : folderRefusal
    }
}
