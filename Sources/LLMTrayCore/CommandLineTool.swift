import Foundation

/// Installing `llmtray` (adr/0019 §5): a symlink in `~/.local/bin` to the
/// binary inside the app, and where it lives in a bundle. The decisions are
/// pure; `existing(at:)` is the one look at the disk they need.
public enum CommandLineTool {
    /// Inside the app: Contents/Helpers, not Contents/MacOS -- `llmtray` and
    /// `LLMTray` are one name on a case-insensitive volume.
    public static let bundleSubpath = "Contents/Helpers/llmtray"
    public static let linkDirectory = "~/.local/bin"
    public static let linkName = "llmtray"

    /// What's at the link's place now.
    public enum Existing: Equatable, Sendable {
        case nothing
        /// A symlink and where it points (as written, maybe relative).
        case symlink(destination: String)
        /// A file or folder that isn't a symlink: never ours to replace.
        case other
    }

    public enum InstallPlan: Equatable, Sendable {
        case create
        /// Our own link, to another copy of LLMTray (moved, or an older one).
        case replace
        case alreadyInstalled
        /// Another tool's link (its destination): left alone.
        case refuseForeignLink(String)
        /// A file that isn't a link: left alone.
        case refuseFile
    }

    public enum UninstallPlan: Equatable, Sendable {
        case remove
        case nothingInstalled
        /// Not LLMTray's link: left alone.
        case refuseForeign
    }

    public static func existing(at path: String) -> Existing {
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: path) { return .symlink(destination: destination) }
        // fileExists follows links; a dangling one was caught above.
        return fm.fileExists(atPath: path) ? .other : .nothing
    }

    /// A link LLMTray made: to some app's Contents/Helpers/llmtray. Another
    /// tool's `llmtray` (a Homebrew one, a script) is left alone.
    public static func isOurs(_ destination: String) -> Bool {
        destination.hasSuffix(".app/" + bundleSubpath)
    }

    public static func installPlan(existing: Existing, target: String) -> InstallPlan {
        switch existing {
        case .nothing: return .create
        case .symlink(let destination) where destination == target: return .alreadyInstalled
        case .symlink(let destination) where isOurs(destination): return .replace
        case .symlink(let destination): return .refuseForeignLink(destination)
        case .other: return .refuseFile
        }
    }

    public static func uninstallPlan(existing: Existing) -> UninstallPlan {
        switch existing {
        case .nothing: return .nothingInstalled
        case .symlink(let destination) where isOurs(destination): return .remove
        case .symlink, .other: return .refuseForeign
        }
    }

    /// `directory` (absolute) is one of `path`'s entries; a trailing slash,
    /// "~" or "$HOME" in an entry are read the way the shell meant them.
    public static func isOnPath(_ directory: String, path: String, home: String) -> Bool {
        func normalized(_ entry: String) -> String {
            var e = entry
            if e == "~" || e.hasPrefix("~/") { e = home + e.dropFirst() }
            if e == "$HOME" || e.hasPrefix("$HOME/") { e = home + e.dropFirst(5) }
            while e.count > 1, e.hasSuffix("/") { e.removeLast() }
            return e
        }
        let wanted = normalized(directory)
        return path.split(separator: ":").contains { normalized(String($0)) == wanted }
    }

    /// What the login shell is asked to print, between markers: an
    /// interactive login shell may print a banner or a prompt around it.
    /// printenv, not `$PATH`: fish's own `$PATH` is a list, joined by
    /// spaces -- the exported one is colon-separated in every shell.
    public static let pathProbeMarker = "__LLMTRAY_PATH__"
    public static var pathProbeCommand: String {
        "printf '\\n\(pathProbeMarker)'; /usr/bin/printenv PATH; printf '\(pathProbeMarker)\\n'"
    }

    /// The PATH in a probe's output; nil when the markers aren't there.
    public static func parsePathProbe(_ output: String) -> String? {
        guard let start = output.range(of: pathProbeMarker),
              let end = output.range(of: pathProbeMarker, range: start.upperBound..<output.endIndex) else { return nil }
        return String(output[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The file and the line that put `~/.local/bin` on a login shell's PATH,
    /// for the user's shell (`$SHELL`).
    public static func pathHint(shell: String) -> (file: String, line: String) {
        switch (shell as NSString).lastPathComponent {
        case "fish": return ("~/.config/fish/config.fish", "fish_add_path $HOME/.local/bin")
        case "bash": return ("~/.bash_profile", "export PATH=\"$HOME/.local/bin:$PATH\"")
        case "zsh", "": return ("~/.zprofile", "export PATH=\"$HOME/.local/bin:$PATH\"")
        default: return ("~/.profile", "export PATH=\"$HOME/.local/bin:$PATH\"")
        }
    }

    /// The app bundle a binary at `executable` (symlinks already resolved)
    /// is the CLI of: ".../LLMTray.app" for ".../LLMTray.app/Contents/Helpers/llmtray";
    /// nil for a bare build (`swift build`'s .build/debug/llmtray).
    public static func appBundle(containing executable: String) -> String? {
        let suffix = "/" + bundleSubpath
        guard executable.hasSuffix(suffix) else { return nil }
        let bundle = String(executable.dropLast(suffix.count))
        return bundle.hasSuffix(".app") ? bundle : nil
    }
}
