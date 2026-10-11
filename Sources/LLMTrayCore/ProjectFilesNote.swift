import Foundation

/// The files added to a chat's project since its last message, told to the
/// model with the user's next one (adr/0012, "New files are said"): a file
/// dropped on the chat made a project and indexed it, and the model knew
/// nothing of it. Names only, as the listing has them -- file text, not the
/// user's words, so marked as the app's and kept short.
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
    public static func text(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(shownNames).map { "\"\(clean($0))\"" }.joined(separator: ", ")
        let more = names.count > shownNames ? " and \(names.count - shownNames) more" : ""
        return "[App note, not the user's words: added to this chat's project since the last message: \(shown)\(more). "
            + "project_files lists, searches and reads them.]"
    }

    /// A name on one line, without brackets or quotes that could close the
    /// note, at most 80 characters.
    static func clean(_ name: String) -> String {
        var s = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0 != "\u{7F}" && !"[]\"".unicodeScalars.contains($0) }
            .map(Character.init))
        if s.unicodeScalars.count > nameScalars {
            s = String(String.UnicodeScalarView(s.unicodeScalars.prefix(nameScalars - 1))) + "…"
        }
        return s
    }
}
