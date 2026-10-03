import Foundation

/// Where an image, music or voice model lives: in the models folder, under
/// its Hugging Face repo like every other model (`<root>/<org>/<name>`), so
/// it's downloaded once, counted in the folder's disk use and removable from
/// Settings → Models. Earlier versions kept them in the app's own folder
/// (`legacy`); one found only there keeps working from there, and moves to
/// the models folder when that's a rename (the same volume).
public enum MediaModelLocation {
    /// Where it goes: `<root>/<repo>`.
    public static func preferred(repo: String, root: String) -> String {
        (root as NSString).expandingTildeInPath + "/" + repo
    }

    /// Where it is: the models folder's copy when it's complete, else the
    /// old place's when that is, else where a download would put it.
    public static func resolve(repo: String, root: String, legacy: String?,
                               isInPlace: (String) -> Bool) -> String {
        let target = preferred(repo: repo, root: root)
        if isInPlace(target) { return target }
        if let legacy, isInPlace(legacy) { return legacy }
        return target
    }

    public enum Migration: Equatable {
        /// Rename `from` to `to` (create its parent first).
        case move(from: String, to: String)
        /// Nothing to move, or it would be a copy: it stays where it is.
        case none
    }

    /// The old copy moves when it's complete, the models folder has none
    /// (not even a partial one), and both are on one volume.
    public static func migration(repo: String, root: String, legacy: String?,
                                 isInPlace: (String) -> Bool) -> Migration {
        guard let legacy, isInPlace(legacy) else { return .none }
        let target = preferred(repo: repo, root: root)
        guard !FileManager.default.fileExists(atPath: target), sameVolume(legacy, target) else { return .none }
        return .move(from: legacy, to: target)
    }

    /// Both paths' nearest existing folders are on one volume.
    public static func sameVolume(_ a: String, _ b: String) -> Bool {
        guard let va = volume(of: a), let vb = volume(of: b) else { return false }
        return va.isEqual(vb)
    }

    private static func volume(of path: String) -> NSObjectProtocol? {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObjectProtocol
    }

    /// A download in progress or left over (`<name>.partial`,
    /// `<name>.partial-<uuid>`): not a model to list.
    public static func isPartial(_ folderName: String) -> Bool {
        folderName.hasSuffix(".partial") || folderName.contains(".partial-")
    }

    /// `path` is the folder of one of `repos` under `root` (case-insensitive,
    /// as Hugging Face repo names are).
    public static func isOneOf(_ repos: [String], path: String, root: String) -> Bool {
        let p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path.lowercased()
        let r = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.path.lowercased()
        return repos.contains { p == r + "/" + $0.lowercased() }
    }
}
