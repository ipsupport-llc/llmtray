import Foundation

/// The files added to a chat's project since its last message, told to the
/// model with the user's next one (adr/0012, "New files are said"): a file
/// dropped on the chat made a project and indexed it, and the model knew
/// nothing of it. The model is told how many and of which kinds; the names
/// are for the user's caption.
public enum ProjectFilesNote {
    /// Names shown at most; the rest are counted.
    public static let shownNames = 10
    static let nameScalars = 80

    /// The files in `current` that `seen` didn't have, in `current`'s order
    /// (a name twice counts twice).
    public static func added(current: [String], seen: [String]) -> [String] {
        var left = Dictionary(seen.map { ($0, 1) }, uniquingKeysWith: +)
        return current.filter { name in
            if let n = left[name], n > 0 { left[name] = n - 1; return false }
            return true
        }
    }

    /// The line put before the user's message for the model; nil for none.
    /// How many and of which kinds, never their names: a name is file text,
    /// and the turn's trust barrier counts it only once project_files has
    /// put it in front of the model -- so the model calls project_files.
    public static func text(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        var kinds: [String] = []
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            let kind = !ext.isEmpty && ext.count <= 5 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "file"
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        let count = names.count == 1 ? "1 new file" : "\(names.count) new files"
        return "[App note, not the user's words: \(count) (\(kinds.prefix(6).joined(separator: ", "))) added to this chat's project "
            + "since the last message. If the message is about them: project_files with no arguments lists the files with their ids, "
            + "then project_files(doc: <id>) reads one and project_files(query: \"...\") searches them.]"
    }

    /// A name for the bubble's caption: one line, no control, format or
    /// separator characters (bidi overrides, U+2028), at most 80.
    public static func clean(_ name: String) -> String {
        var s = String(name.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse: return false
            default: return true
            }
        }.map(Character.init))
        if s.unicodeScalars.count > nameScalars {
            s = String(String.UnicodeScalarView(s.unicodeScalars.prefix(nameScalars - 1))) + "…"
        }
        return s
    }
}
