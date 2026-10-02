import Foundation

/// When each installed model was last used: loaded, or sent a request
/// through the proxy. Keyed by the model's path, like its alias and profile.
/// A request records at most once a minute per model, so a busy client
/// doesn't write the defaults on every call.
public struct ModelUsageStore {
    public static let key = "llmtray.modelLastUsed"
    static let minInterval: TimeInterval = 60

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var all: [String: Date] {
        (defaults.dictionary(forKey: Self.key) as? [String: Date]) ?? [:]
    }

    public func lastUsed(_ modelPath: String) -> Date? { all[modelPath] }

    /// True when it was written (the last record is a minute old or more).
    @discardableResult
    public func record(_ modelPath: String, at date: Date = Date()) -> Bool {
        var dict = all
        if let last = dict[modelPath], date.timeIntervalSince(last) < Self.minInterval, date >= last { return false }
        dict[modelPath] = date
        defaults.set(dict, forKey: Self.key)
        return true
    }

    public func forget(_ modelPath: String) {
        var dict = all
        guard dict.removeValue(forKey: modelPath) != nil else { return }
        defaults.set(dict, forKey: Self.key)
    }
}

/// Removing an installed model from the models folder: what may be removed,
/// and where it goes.
public enum ModelRemoval {
    public enum Refusal: Error, Equatable {
        /// Not a folder below the models folder (or the models folder itself).
        case outsideModelsFolder
        /// No config.json: not a model folder ModelDiscovery lists.
        case notAModel
    }

    /// The model folder, checked: strictly inside `root` (symlinks in the
    /// root's own path resolved, the model's last component not -- a linked
    /// model is removed as the link, never what it points to), and holding a
    /// config.json.
    public static func check(modelPath: String, root: String) throws -> URL {
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL
        let model = URL(fileURLWithPath: (modelPath as NSString).expandingTildeInPath).standardizedFileURL
        let parent = model.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let modelURL = parent.appendingPathComponent(model.lastPathComponent)
        let rootParts = rootURL.pathComponents, parts = modelURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts,
              !model.lastPathComponent.isEmpty, model.lastPathComponent != "..", model.lastPathComponent != "." else {
            throw Refusal.outsideModelsFolder
        }
        guard FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("config.json").path) else {
            throw Refusal.notAModel
        }
        return modelURL
    }

    /// The folders between the model and the root left empty by its removal
    /// (an `<org>/` folder whose last model this was), innermost first --
    /// .DS_Store aside. Never the root.
    public static func emptyParents(of modelURL: URL, root: String) -> [URL] {
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL
        var result: [URL] = []
        var dir = modelURL.deletingLastPathComponent().standardizedFileURL
        while dir.pathComponents.count > rootURL.pathComponents.count,
              Array(dir.pathComponents.prefix(rootURL.pathComponents.count)) == rootURL.pathComponents {
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).filter { $0 != ".DS_Store" }
            guard left.isEmpty else { break }
            result.append(dir)
            dir = dir.deletingLastPathComponent()
        }
        return result
    }

    /// When the model arrived: its folder's creation date (a download
    /// creates the folder as it starts; a copy made in Finder keeps the
    /// original's).
    public static func addedDate(modelPath: String) -> Date? {
        let url = URL(fileURLWithPath: modelPath)
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
