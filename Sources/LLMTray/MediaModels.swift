import Foundation
import LLMTrayCore

/// The image, music and voice models, which live in the models folder under
/// their Hugging Face repos (MediaModelLocation): one list for the managers'
/// paths, the chat scan (which leaves them out), the Hugging Face browser
/// (downloaded through their manager, into place) and Settings → Models.
enum MediaModels {
    enum Kind: String, CaseIterable {
        case image, music, voice

        var title: String {
            switch self {
            case .image: return NSLocalizedString("Image generation", comment: "a media model's kind")
            case .music: return NSLocalizedString("Music", comment: "a media model's kind")
            case .voice: return NSLocalizedString("Voice", comment: "a media model's kind")
            }
        }
    }

    struct Entry: Identifiable, Hashable {
        var id: String { repo }
        /// The Hugging Face repo, and its folder under the models folder.
        let repo: String
        let kind: Kind
        let name: String
        /// Where earlier versions kept it, in the app's own folder.
        let legacy: String
        /// What makes a folder of it complete.
        let check: Check
    }

    enum Check: Hashable {
        /// The folder is there: its download lands whole (a renamed
        /// temporary folder).
        case folder
        /// config.json and the weights' index.
        case configAndIndex
    }

    /// The ACE-Step 5 Hz planner: a folder of the official repo, so not a
    /// repo of its own -- named so that it can't pass for one.
    static let musicPlannerFolder = "ACE-Step/Ace-Step1.5-acestep-5Hz-lm-1.7B"

    static let all: [Entry] = {
        let app = RuntimePaths.externalRuntimeDir
        let image = ImageGenModel.allCases.map {
            Entry(repo: $0.hfRepo, kind: .image, name: $0.displayName, legacy: app + "/mflux_models/" + $0.rawValue, check: .folder)
        }
        let music = MusicModel.allCases.map {
            Entry(repo: $0.hfRepo, kind: .music, name: $0.displayName, legacy: app + "/music_models/" + $0.folderName, check: .folder)
        } + [Entry(repo: musicPlannerFolder, kind: .music, name: "ACE-Step 1.5 LM 1.7B (planner)",
                   legacy: app + "/music_models/ace-step-1.5-lm-1.7B", check: .folder)]
        let voice = VoiceLabModel.all.map {
            Entry(repo: $0.repo, kind: .voice, name: $0.displayName, legacy: app + "/voice_models/" + $0.folderName, check: .configAndIndex)
        }
        return image + music + voice
    }()

    static var repos: [String] { all.map(\.repo) }

    static func entry(repo: String) -> Entry? {
        all.first { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
    }

    static func isInPlace(_ path: String, _ check: Check) -> Bool {
        let fm = FileManager.default
        switch check {
        case .folder:
            // The managers move a download in whole; a browser download of
            // it from before (into the chat path) may have stopped part way.
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                && !((try? fm.contentsOfDirectory(atPath: path)) ?? []).isEmpty
                && !MediaModelLocation.isUnfinishedBrowserDownload(path)
        case .configAndIndex:
            // Every shard the index names, too: a stopped download can have
            // the small files without the weights.
            guard fm.fileExists(atPath: path + "/config.json"), !MediaModelLocation.isUnfinishedBrowserDownload(path),
                  let data = fm.contents(atPath: path + "/model.safetensors.index.json"),
                  let map = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["weight_map"] as? [String: String],
                  !map.isEmpty else { return false }
            return Set(map.values).allSatisfy { fm.fileExists(atPath: path + "/" + $0) }
        }
    }

    /// Models folders media models were kept in before the current one
    /// (the user picked another since): still looked in, and moved from at
    /// launch when that's a rename.
    private static let rootsKey = "llmtray.mediaModelRoots"

    static func rememberCurrentRoot() {
        let root = ModelDiscovery.currentModelsRoot()
        var roots = UserDefaults.standard.stringArray(forKey: rootsKey) ?? []
        guard !roots.contains(root) else { return }
        roots.append(root)
        UserDefaults.standard.set(roots, forKey: rootsKey)
    }

    /// Where else it may be, in order: earlier models folders, then the
    /// app's own folder.
    static func oldPlaces(_ entry: Entry) -> [String] {
        let root = ModelDiscovery.currentModelsRoot()
        let roots = (UserDefaults.standard.stringArray(forKey: rootsKey) ?? []).filter { $0 != root }
        return roots.map { MediaModelLocation.preferred(repo: entry.repo, root: $0) } + [entry.legacy]
    }

    /// Where the model is (or a download puts it).
    static func path(_ entry: Entry) -> String {
        MediaModelLocation.resolve(repo: entry.repo, root: ModelDiscovery.currentModelsRoot(), oldPlaces: oldPlaces(entry)) {
            isInPlace($0, entry.check)
        }
    }

    /// Where a download goes: the models folder.
    static func downloadPath(_ entry: Entry) -> String {
        rememberCurrentRoot()
        return MediaModelLocation.preferred(repo: entry.repo, root: ModelDiscovery.currentModelsRoot())
    }

    struct FolderUnavailable: LocalizedError {
        var errorDescription: String? {
            NSLocalizedString("The models folder isn't available -- is its disk connected? Choose it again in Settings → Models.", comment: "")
        }
    }

    /// Before a download: the models folder is there (or can be made).
    static func checkModelsFolder() throws {
        guard MediaModelLocation.canCreate(root: ModelDiscovery.currentModelsRoot()) else { throw FolderUnavailable() }
    }

    struct TargetIsALink: LocalizedError {
        let path: String
        var errorDescription: String? {
            String(format: NSLocalizedString("%@ is a link to a folder that isn't available: connect its disk, or remove the link.", comment: ""), path)
        }
    }

    /// Before a download lands: what's at its place is no installed model
    /// (a download that stopped there, an empty folder) -- to the Trash, so
    /// the new one can move in. A link is the user's: left alone.
    static func clearIncompleteTarget(_ entry: Entry) throws {
        let target = MediaModelLocation.preferred(repo: entry.repo, root: ModelDiscovery.currentModelsRoot())
        guard MediaModelLocation.exists(target), !isInPlace(target, entry.check) else { return }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: target)) != nil { throw TargetIsALink(path: target) }
        try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: nil)
    }

    /// Usable: installed, with the music planner a turbo model needs.
    static func isReady(_ entry: Entry) -> Bool {
        guard isInstalled(entry) else { return false }
        if entry.kind == .music, let model = MusicModel.allCases.first(where: { $0.hfRepo == entry.repo }), model.usesPlanner {
            return isInstalled(musicPlanner)
        }
        return true
    }

    /// In the app's own folder (downloaded by an earlier version, on
    /// another volume than the models folder).
    static func isInAppFolder(_ entry: Entry) -> Bool { isInstalled(entry) && path(entry) == entry.legacy }

    /// A download landed: Settings' list and disk use read the disk again.
    static func didDownload() {
        NotificationCenter.default.post(name: .modelsDidChange, object: nil)
    }

    static func isInstalled(_ entry: Entry) -> Bool { isInPlace(path(entry), entry.check) }

    /// Not in the current models folder (an earlier one, or the app's own
    /// folder, on another volume).
    static func isInOldPlace(_ entry: Entry) -> Bool { path(entry) != MediaModelLocation.preferred(repo: entry.repo, root: ModelDiscovery.currentModelsRoot()) && isInstalled(entry) }

    static func entry(_ model: ImageGenModel) -> Entry { entry(repo: model.hfRepo)! }
    static func entry(_ model: MusicModel) -> Entry { entry(repo: model.hfRepo)! }
    static func entry(_ model: VoiceLabModel) -> Entry { entry(repo: model.repo)! }
    static var musicPlanner: Entry { entry(repo: musicPlannerFolder)! }

    /// At launch, before anything uses them: each model found only in the
    /// app's old folder moves to the models folder when that's a rename.
    /// Returns what moved, for the log.
    @discardableResult
    static func moveIntoModelsFolder() -> [String] {
        // Looked in later, should the folder change.
        rememberCurrentRoot()
        let root = ModelDiscovery.currentModelsRoot()
        let fm = FileManager.default
        var moved: [String] = []
        for entry in all {
            // The first old place it's complete in.
            guard let source = oldPlaces(entry).first(where: { isInPlace($0, entry.check) }),
                  case let .move(from, to) = MediaModelLocation.migration(repo: entry.repo, root: root, legacy: source,
                                                                          isInPlace: { isInPlace($0, entry.check) }) else { continue }
            do {
                try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try MediaModelLocation.rename(from, to: to)
                moved.append(entry.repo)
            } catch {
                NSLog("LLMTray: couldn't move %@ into the models folder: %@", from, error.localizedDescription)
            }
        }
        // A voice download stopped part way in the app's folder goes on
        // from the models folder.
        for entry in all where entry.kind == .voice {
            let old = entry.legacy + ".partial", new = MediaModelLocation.preferred(repo: entry.repo, root: root) + ".partial"
            guard fm.fileExists(atPath: old), !MediaModelLocation.exists(new), MediaModelLocation.canRename(old, into: root) else { continue }
            try? fm.createDirectory(atPath: (new as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? MediaModelLocation.rename(old, to: new)
        }
        // Image and music downloads' leftovers (<name>.partial-<UUID>: they
        // restart, nothing to resume; nothing downloads this early), in the
        // app's folder and next to each model in the models folder.
        for dir in ["mflux_models", "music_models"].map({ RuntimePaths.externalRuntimeDir + "/" + $0 }) {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where MediaModelLocation.isPartial(name) && !name.hasSuffix(".partial") {
                try? fm.removeItem(atPath: dir + "/" + name)
            }
        }
        for entry in all where entry.kind != .voice {
            let target = MediaModelLocation.preferred(repo: entry.repo, root: root)
            let dir = (target as NSString).deletingLastPathComponent, prefix = (target as NSString).lastPathComponent + ".partial-"
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix(prefix) && MediaModelLocation.isPartial(name) {
                try? fm.removeItem(atPath: dir + "/" + name)
            }
        }
        if !moved.isEmpty { rememberCurrentRoot() }
        return moved
    }
}
