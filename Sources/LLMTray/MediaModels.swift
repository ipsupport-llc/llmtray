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
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                && !((try? fm.contentsOfDirectory(atPath: path)) ?? []).isEmpty
        case .configAndIndex:
            return fm.fileExists(atPath: path + "/config.json") && fm.fileExists(atPath: path + "/model.safetensors.index.json")
        }
    }

    /// Where the model is (or a download puts it).
    static func path(_ entry: Entry) -> String {
        MediaModelLocation.resolve(repo: entry.repo, root: ModelDiscovery.currentModelsRoot(), legacy: entry.legacy) {
            isInPlace($0, entry.check)
        }
    }

    /// Where a download goes: the models folder.
    static func downloadPath(_ entry: Entry) -> String {
        MediaModelLocation.preferred(repo: entry.repo, root: ModelDiscovery.currentModelsRoot())
    }

    static func isInstalled(_ entry: Entry) -> Bool { isInPlace(path(entry), entry.check) }

    /// Only in the app's old folder (on another volume than the models
    /// folder, or not moved yet).
    static func isInOldPlace(_ entry: Entry) -> Bool { path(entry) == entry.legacy }

    static func entry(_ model: ImageGenModel) -> Entry { entry(repo: model.hfRepo)! }
    static func entry(_ model: MusicModel) -> Entry { entry(repo: model.hfRepo)! }
    static func entry(_ model: VoiceLabModel) -> Entry { entry(repo: model.repo)! }
    static var musicPlanner: Entry { entry(repo: musicPlannerFolder)! }

    /// At launch, before anything uses them: each model found only in the
    /// app's old folder moves to the models folder when that's a rename.
    /// Returns what moved, for the log.
    @discardableResult
    static func moveIntoModelsFolder() -> [String] {
        let root = ModelDiscovery.currentModelsRoot()
        var moved: [String] = []
        for entry in all {
            guard case let .move(from, to) = MediaModelLocation.migration(repo: entry.repo, root: root, legacy: entry.legacy,
                                                                          isInPlace: { isInPlace($0, entry.check) }) else { continue }
            do {
                try FileManager.default.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: from, toPath: to)
                moved.append(entry.repo)
            } catch {
                NSLog("LLMTray: couldn't move %@ into the models folder: %@", from, error.localizedDescription)
            }
        }
        return moved
    }
}
