import Foundation

/// The two model-facing folder tools (adr/0014, "Tools"): `files` looks,
/// `change_files` proposes. Declarations, the lenient reading of their
/// arguments and when each is declared live here; the work is
/// `FolderToolService`'s.
public enum FolderTools {
    public static let filesName = "files"
    public static let changeName = "change_files"

    // MARK: files

    static let filesDescription = "Look in the user's folders: a folder's listing, a file's info, or duplicate files. "
        + "No path: the folders you may access."

    /// What `files` reads (the declared fields plus `hidden`, taken but
    /// never declared: a listing says when it matters).
    public static let filesSchema = ToolSchema(filesName, filesDescription, [
        .init("path", .string, "A folder or file, e.g. ~/Downloads",
              aliases: ["folder", "dir", "directory", "file", "file_path", "filepath", "location", "target"]),
        .init("recursive", .boolean, "Include subfolders",
              aliases: ["deep", "subfolders", "include_subfolders", "recurse"]),
        .init("pattern", .string, "Names to match, e.g. *.pdf", aliases: ["glob", "filter", "match", "name_pattern"]),
        .init("only_duplicates", .boolean, "Find duplicate files instead",
              aliases: ["duplicates", "find_duplicates", "dupes", "duplicate"]),
        .init("hash", .boolean, "A file's SHA-256", aliases: ["sha256", "checksum", "sha"]),
        .init("cursor", .string, aliases: ["next", "page", "next_cursor", "continue", "page_token"]),
        .init("hidden", .boolean, aliases: ["include_hidden", "show_hidden", "all"]),
    ])

    public static var filesDefinition: [String: Any] {
        ToolSchema(filesName, filesDescription, filesSchema.params.filter { $0.name != "hidden" }).definition
    }

    public struct FilesRequest: Equatable, Sendable {
        /// nil: the folders the chat may access.
        public var path: String?
        public var recursive = false
        public var pattern: String?
        public var onlyDuplicates = false
        public var hash = false
        public var cursor: String?
        public var hidden = false

        public init(path: String? = nil, recursive: Bool = false, pattern: String? = nil, onlyDuplicates: Bool = false,
                    hash: Bool = false, cursor: String? = nil, hidden: Bool = false) {
            self.path = path
            self.recursive = recursive
            self.pattern = pattern
            self.onlyDuplicates = onlyDuplicates
            self.hash = hash
            self.cursor = cursor
            self.hidden = hidden
        }
    }

    /// The values `ToolArgumentParser` read against `filesSchema`.
    public static func filesRequest(_ values: [String: Any]) -> FilesRequest {
        func text(_ key: String) -> String? {
            guard let s = values[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        var r = FilesRequest(path: text("path"), recursive: values["recursive"] as? Bool ?? false, pattern: text("pattern"),
                             onlyDuplicates: values["only_duplicates"] as? Bool ?? false, hash: values["hash"] as? Bool ?? false,
                             cursor: text("cursor"), hidden: values["hidden"] as? Bool ?? false)
        // "pdf" or ".pdf" for "*.pdf": a pattern without a wildcard is a
        // name's end, as "only the PDFs" is usually written.
        if let p = r.pattern, !p.contains("*"), !p.contains("?"), !p.contains("[") {
            r.pattern = p.hasPrefix(".") ? "*" + p : (p.contains(".") ? p : "*." + p)
        }
        return r
    }

    // MARK: change_files

    // What models got wrong in real Downloads folders (adr/0014, "Listing
    // sizes and the plan's warnings"): one took this for a text editor and
    // wrote a shell script instead; one split a 22,000-file folder by
    // extension and trashed "x (1).zip", which wasn't a copy.
    static let changeDescription = "Make folders, move or rename files and folders, move them to the Trash: one list, "
        + "done for real once the user approves it. Not for editing a file's contents. "
        + "A subfolder is one item: move it whole or leave it, unless asked. "
        + "Duplicates are only what files(only_duplicates) finds, not a (1) in a name."

    static let opParams: [ToolSchema.Param] = [
        .init("op", .oneOf(["make_dir", "move", "trash"]),
              aliases: ["action", "type", "operation", "kind", "cmd", "command"],
              valueAliases: ["mkdir": "make_dir", "makedir": "make_dir", "make_folder": "make_dir", "create_folder": "make_dir",
                             "create_dir": "make_dir", "new_folder": "make_dir", "create": "make_dir", "folder": "make_dir",
                             "rename": "move", "mv": "move", "moveto": "move", "move_to": "move",
                             "delete": "trash", "remove": "trash", "rm": "trash", "recycle": "trash", "move_to_trash": "trash"]),
        .init("path", .string, "make_dir, trash", aliases: ["folder", "dir", "directory", "file", "item"]),
        .init("from", .string, "move: the item", aliases: ["source", "src", "old", "old_path", "source_path"]),
        .init("to", .string, "move: its new path, or a folder to move it into",
              aliases: ["destination", "dest", "target", "new_path", "into", "dst", "destination_path"]),
        .init("name", .string, aliases: ["new_name", "newname", "rename_to"]),
    ]

    /// What `change_files` reads: the list, and one op sent without it
    /// (its fields at the top level). The list is required only as
    /// declared: `changeOps` says what's missing.
    public static let changeSchema = ToolSchema(changeName, changeDescription, [
        .init("ops", .objects(opParams), aliases: ["operations", "changes", "actions", "items", "plan", "steps"]),
    ] + opParams)

    public static var changeDefinition: [String: Any] {
        ToolSchema(changeName, changeDescription, [
            .init("ops", .objects(opParams.filter { $0.name != "name" }), required: true),
        ]).definition
    }

    /// One op as the model sent it, paths as written.
    public struct RawOp: Equatable, Sendable {
        public var kind: ChangeKind
        /// make_dir, trash: the item; move: its source.
        public var path: String
        /// move: the destination as written.
        public var to: String?
        /// move: a new name in the same folder (`to` wins).
        public var newName: String?

        public init(kind: ChangeKind, path: String, to: String? = nil, newName: String? = nil) {
            self.kind = kind
            self.path = path
            self.to = to
            self.newName = newName
        }
    }

    public struct ArgumentError: Error, Equatable {
        public var message: String
    }

    /// The ops of a call (read against `changeSchema`); the op may be left
    /// out when the fields say it (`from` and `to`: a move). At most
    /// `maxOps`.
    public static func changeOps(_ values: [String: Any], maxOps: Int = 200) -> Result<[RawOp], ArgumentError> {
        var list = values["ops"] as? [[String: Any]] ?? []
        // One op without the list.
        if list.isEmpty, values["op"] != nil || values["from"] != nil || values["path"] != nil {
            list = [values.filter { $0.key != "ops" }]
        }
        guard !list.isEmpty else {
            return .failure(error("\"ops\" is empty: send the changes as a list"))
        }
        guard list.count <= maxOps else {
            return .failure(error("at most \(maxOps) ops per call: send the rest in another call"))
        }
        var out: [RawOp] = []
        for (i, item) in list.enumerated() {
            func text(_ key: String) -> String? {
                guard let s = item[key] as? String, !s.isEmpty else { return nil }
                return s
            }
            let from = text("from") ?? text("path")
            let to = text("to"), name = text("name")
            var kind = (item["op"] as? String).flatMap(ChangeKind.init(rawValue:))
            if kind == nil, from != nil, to != nil || name != nil { kind = .move }
            guard let kind else {
                return .failure(error("ops[\(i)] needs \"op\": make_dir, move or trash"))
            }
            switch kind {
            case .makeDir, .trash:
                guard let path = text("path") ?? text("from") ?? (kind == .makeDir ? to : nil) else {
                    return .failure(error("ops[\(i)] (\(kind.rawValue)) needs \"path\""))
                }
                out.append(RawOp(kind: kind, path: path))
            case .move:
                guard let from, to != nil || name != nil else {
                    return .failure(error("ops[\(i)] (move) needs \"from\" and \"to\""))
                }
                out.append(RawOp(kind: .move, path: from, to: to, newName: name))
            }
        }
        return .success(out)
    }

    static func error(_ problem: String) -> ArgumentError {
        ArgumentError(message: "\(changeName): \(problem). Retry: \(changeName)({\"ops\":[{\"op\":\"make_dir\",\"path\":\"~/Downloads/PDFs\"},"
            + "{\"op\":\"move\",\"from\":\"~/Downloads/a.pdf\",\"to\":\"~/Downloads/PDFs\"},{\"op\":\"trash\",\"path\":\"~/Downloads/old.zip\"}]})")
    }

    // MARK: Declaration

    /// Which folder tools a request declares: none with the feature off;
    /// `files` unless the request has no room for more file text;
    /// `change_files` only in a saved chat (Hardening 8). After file or
    /// folder text in the turn it stays declared and is refused in code
    /// (Hardening 2: `ToolTrust.allows`, the refusal saying to ask the user
    /// and call it in their next message) -- a model that no longer saw it
    /// concluded it had no way to move files and wrote a script instead.
    /// Pinned files, which keep changes off in every turn, drop it; so does
    /// its first refusal in the turn (`changeRefused`: it has said how to go
    /// on, like a generator that's spent).
    public static func declared(featureOn: Bool, temporaryChat: Bool, turn: ToolTrust.TurnState,
                                fileTextRoomSpent: Bool, changeRefused: Bool = false) -> [String] {
        guard featureOn else { return [] }
        var names: [String] = []
        if !fileTextRoomSpent { names.append(filesName) }
        if !temporaryChat, !turn.pinnedText, !changeRefused { names.append(changeName) }
        return names
    }
}
