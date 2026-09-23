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

    /// The model's own trained context ceiling, straight from its
    /// config.json -- used as the real max for the "Max tokens" slider
    /// instead of one fixed guess for every model (some cap out around 8k,
    /// some go past 256k). Checked at the top level first, then under
    /// "text_config" -- newer multi-modal-style configs (e.g. Qwen3.5) nest
    /// the language-model fields there instead. Returns nil (caller falls
    /// back to a fixed default) if the field is missing entirely rather
    /// than guessing at an unfamiliar config shape.
    static func maxContextLength(forModelPath path: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: path + "/config.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let value = obj["max_position_embeddings"] as? Int { return value }
        if let textConfig = obj["text_config"] as? [String: Any],
           let value = textConfig["max_position_embeddings"] as? Int {
            return value
        }
        return nil
    }

    /// Heuristic, not a fixed model list: multimodal configs (Qwen-VL,
    /// LLaVA-style, etc.) carry a sibling "vision_config" key alongside
    /// "text_config" (same nesting maxContextLength already handles for
    /// Qwen3.5-style configs), or name themselves in "architectures".
    /// False (not "unknown") on anything unrecognized -- the attach-image
    /// button only appears for models this can positively identify.
    static func supportsVision(forModelPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path + "/config.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if obj["vision_config"] != nil { return true }
        if let architectures = obj["architectures"] as? [String] {
            return architectures.contains {
                $0.localizedCaseInsensitiveContains("vision") || $0.localizedCaseInsensitiveContains("VL")
            }
        }
        return false
    }

    /// Models with KV-shared layers (e.g. Gemma 4's `num_kv_shared_layers`)
    /// reuse an earlier layer's raw cache-internal (keys, values) tuple
    /// directly inside the shared layer's attention call, bypassing that
    /// layer's own `cache.update_and_fetch()` -- so if the KV cache has been
    /// switched to quantized mode by the time the shared read happens, the
    /// shared layer receives a quantized-tuple representation instead of a
    /// plain array and crashes `scaled_dot_product_attention` with
    /// "incompatible function arguments" (keys/values typed as `list`).
    /// Real crash observed with LLMTray's default `--quantized-kv-start`.
    /// Detected structurally (config field), not by architecture name, so
    /// it also covers future models with the same sharing pattern.
    static func disallowsQuantizedKV(forModelPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path + "/config.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let n = obj["num_kv_shared_layers"] as? Int, n > 0 { return true }
        if let textConfig = obj["text_config"] as? [String: Any],
           let n = textConfig["num_kv_shared_layers"] as? Int, n > 0 {
            return true
        }
        return false
    }
}
