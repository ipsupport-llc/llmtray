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
    /// first old place's that is (a models folder used before, the app's
    /// own folder), else where a download would put it.
    public static func resolve(repo: String, root: String, legacy: String?,
                               isInPlace: (String) -> Bool) -> String {
        resolve(repo: repo, root: root, oldPlaces: legacy.map { [$0] } ?? [], isInPlace: isInPlace)
    }

    public static func resolve(repo: String, root: String, oldPlaces: [String],
                               isInPlace: (String) -> Bool) -> String {
        let target = preferred(repo: repo, root: root)
        if isInPlace(target) { return target }
        return oldPlaces.first(where: isInPlace) ?? target
    }

    public enum Migration: Equatable {
        /// Rename `from` to `to` (create its parent first).
        case move(from: String, to: String)
        /// Nothing to move, or it would be a copy: it stays where it is.
        case none
    }

    /// The old copy moves when it's complete, the models folder is there
    /// or can be made (canCreate: never an external disk's missing mount
    /// point), has nothing at the target (not even a partial one), and is
    /// -- or, not made yet, its nearest existing folder is -- on the old
    /// copy's volume: a rename, never a copy.
    public static func migration(repo: String, root: String, legacy: String?,
                                 isInPlace: (String) -> Bool) -> Migration {
        guard let legacy, isInPlace(legacy) else { return .none }
        let target = preferred(repo: repo, root: root)
        guard !exists(target), canRename(legacy, into: root) else { return .none }
        return .move(from: legacy, to: target)
    }

    private static func nearestExisting(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        return url.path
    }

    /// Anything at `path`, a dangling link included (fileExists follows
    /// links: a model linked to a disk that isn't mounted reads as absent,
    /// and a rename would replace the link).
    public static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// The models folder can take a download: it's there, or can be made
    /// -- unless it's on an external disk that isn't connected (its mount
    /// point under /Volumes is missing: making it would write to the boot
    /// disk).
    public static func canCreate(root: String) -> Bool {
        let path = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) { return isDir.boolValue }
        let parts = (path as NSString).pathComponents
        if parts.count >= 3, parts[1] == "Volumes" {
            // Mounted: a folder left at the mount point after the disk went
            // is on the boot disk.
            let mount = URL(fileURLWithPath: "/Volumes/" + parts[2])
            return (try? mount.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
        }
        return true
    }

    /// `from` can be renamed into `root` (made if need be): canCreate, and
    /// the same volume as root -- or, not made yet, its nearest existing
    /// folder.
    public static func canRename(_ from: String, into root: String) -> Bool {
        canCreate(root: root) && sameVolume(from, nearestExisting((root as NSString).expandingTildeInPath))
    }

    /// A browser download of the folder started and didn't finish: its
    /// manifest is there, its completion marker isn't.
    public static func isUnfinishedBrowserDownload(_ path: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: path + "/" + ModelFolder.manifestName)
            && !fm.fileExists(atPath: path + "/" + ModelFolder.completionMarkerName)
    }

    /// Both existing paths, links resolved, are on one volume.
    public static func sameVolume(_ a: String, _ b: String) -> Bool {
        guard let va = volume(of: a), let vb = volume(of: b) else { return false }
        return va.isEqual(vb)
    }

    private static func volume(of path: String) -> NSObjectProtocol? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObjectProtocol
    }

    /// Renames `from` to `to` -- rename(2): within one volume only, never
    /// a copy that could stop half way (a different volume fails with
    /// EXDEV and leaves both as they were).
    public static func rename(_ from: String, to: String) throws {
        if Foundation.rename(from, to) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: from])
        }
    }

    /// A download in progress or left over, as LLMTray names them:
    /// `<name>.partial` and `<name>.partial-<UUID>`. Not a model to list.
    public static func isPartial(_ folderName: String) -> Bool {
        if folderName.hasSuffix(".partial") { return true }
        guard let range = folderName.range(of: ".partial-", options: .backwards) else { return false }
        return UUID(uuidString: String(folderName[range.upperBound...])) != nil
    }

    /// `path` is the folder of one of `repos` under `root` (case-insensitive,
    /// as Hugging Face repo names are).
    public static func isOneOf(_ repos: [String], path: String, root: String) -> Bool {
        let p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path.lowercased()
        let r = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.path.lowercased()
        return repos.contains { p == r + "/" + $0.lowercased() }
    }
}
