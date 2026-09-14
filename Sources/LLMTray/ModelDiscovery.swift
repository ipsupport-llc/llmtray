import Foundation

struct LocalModel: Identifiable, Hashable {
    let id: String        // full path, unique
    let displayName: String  // "publisher/model-name"
    let path: String

    init(path: String) {
        self.path = path
        self.id = path
        let comps = path.split(separator: "/")
        if comps.count >= 2 {
            self.displayName = comps.suffix(2).joined(separator: "/")
        } else {
            self.displayName = path
        }
    }
}

enum ModelDiscovery {
    static let modelsRootDefaultsKey = "llmtray.modelsRoot"

    /// Own namespace by default -- earlier builds reused ~/.lmstudio/models
    /// directly, which quietly assumed LM Studio's layout/ownership of that
    /// folder. Anyone who actually wants that (e.g. to share models already
    /// downloaded via LM Studio) can still point Settings at it; this just
    /// stops assuming it uninvited.
    static var defaultModelsRoot: String {
        NSString(string: "~/.llmtray/models").expandingTildeInPath
    }

    /// Reads the configured root straight from UserDefaults -- used by
    /// callers (HFModelBrowser, AppDelegate's quick-start menu) that don't
    /// have a live SwiftUI @AppStorage binding to ContentView's copy of the
    /// same value.
    static func currentModelsRoot() -> String {
        UserDefaults.standard.string(forKey: modelsRootDefaultsKey) ?? defaultModelsRoot
    }

    /// Scans <root>/<publisher>/<model-name>/ for directories that contain
    /// a config.json (the LM Studio / mlx_lm convention), two levels deep.
    /// Silently skips anything that doesn't match -- an unreadable or
    /// unexpected directory shouldn't crash model discovery.
    static func scanModels(root: String) -> [LocalModel] {
        let fm = FileManager.default
        guard let publishers = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var found: [LocalModel] = []
        for publisher in publishers {
            let publisherPath = root + "/" + publisher
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: publisherPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let modelNames = try? fm.contentsOfDirectory(atPath: publisherPath) else { continue }
            for modelName in modelNames {
                let modelPath = publisherPath + "/" + modelName
                var modelIsDir: ObjCBool = false
                guard fm.fileExists(atPath: modelPath, isDirectory: &modelIsDir), modelIsDir.boolValue else { continue }
                let configPath = modelPath + "/config.json"
                if fm.fileExists(atPath: configPath) {
                    found.append(LocalModel(path: modelPath))
                }
            }
        }
        return found.sorted { $0.displayName < $1.displayName }
    }

    /// A Hugging Face repo id ("org/name") maps directly onto the two-level
    /// <root>/<org>/<name> layout this scanner expects, so checking
    /// "already downloaded" is just checking that exact path.
    static func isDownloaded(repoID: String, root: String) -> Bool {
        FileManager.default.fileExists(atPath: root + "/\(repoID)/config.json")
    }
}
