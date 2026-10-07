import Foundation
import LLMTrayCore

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
    /// A browser download that started and didn't finish (its manifest
    /// without the completion marker) isn't a model, unless it's the
    /// download queue's chat model now (`downloading`, "org/name"): the
    /// wizard's pick, which a chat waits for rather than starts.
    static func scanModels(root: String, downloading: String? = nil) -> [LocalModel] {
        let fm = FileManager.default
        guard let publishers = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var found: [LocalModel] = []
        // Image, music and voice models share the folder (MediaModels):
        // not chat models.
        let media = MediaModels.repos
        for publisher in publishers {
            let publisherPath = root + "/" + publisher
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: publisherPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let modelNames = try? fm.contentsOfDirectory(atPath: publisherPath) else { continue }
            for modelName in modelNames {
                let modelPath = publisherPath + "/" + modelName
                // A download still running or left over isn't a model.
                if MediaModelLocation.isPartial(modelName) || MediaModelLocation.isOneOf(media, path: modelPath, root: root) { continue }
                var modelIsDir: ObjCBool = false
                guard fm.fileExists(atPath: modelPath, isDirectory: &modelIsDir), modelIsDir.boolValue else { continue }
                let configPath = modelPath + "/config.json"
                if MediaModelLocation.isUnfinishedBrowserDownload(modelPath), publisher + "/" + modelName != downloading { continue }
                if fm.fileExists(atPath: configPath) {
                    found.append(LocalModel(path: modelPath))
                }
            }
        }
        return found.sorted { $0.displayName < $1.displayName }
    }

    /// A Hugging Face repo id ("org/name") maps directly onto the two-level
    /// <root>/<org>/<name> layout this scanner expects: "already
    /// downloaded" is that folder being complete (ModelFolder), not just
    /// its config.json, which a cancelled download left behind.
    static func isDownloaded(repoID: String, root: String) -> Bool {
        ModelFolder.isComplete(atPath: root + "/" + repoID)
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

    /// The model hears audio: its config describes an audio part
    /// (an audio_config object) and the checkpoint has the weights it runs
    /// on -- a text-only conversion can keep audio_config without them. A
    /// tower model (Gemma 4 E2B/E4B) needs its audio_tower; an encoder-free
    /// one (gemma4_unified, the 12B) its embed_audio. The weight names come
    /// from the index, or a single file's safetensors header.
    static func supportsAudio(forModelPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path + "/config.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["audio_config"] is [String: Any] else { return false }
        let needed = (obj["model_type"] as? String) == "gemma4_unified" ? "embed_audio." : "audio_tower."
        return weightNames(inFolder: path).contains { $0.contains(needed) }
    }

    /// The checkpoint's tensor names: its index's weight map -- only those
    /// whose shard file is there (a download that stopped part way has the
    /// index without every shard) -- or the header of a lone
    /// model.safetensors (an 8-byte length, then JSON).
    private static func weightNames(inFolder path: String) -> [String] {
        if let index = FileManager.default.contents(atPath: path + "/model.safetensors.index.json"),
           let map = (try? JSONSerialization.jsonObject(with: index) as? [String: Any])?["weight_map"] as? [String: String] {
            let present = Set(Set(map.values).filter { FileManager.default.fileExists(atPath: path + "/" + $0) })
            return map.filter { present.contains($0.value) }.map(\.key)
        }
        guard let file = FileHandle(forReadingAtPath: path + "/model.safetensors") else { return [] }
        defer { try? file.close() }
        guard let lengthData = try? file.read(upToCount: 8), lengthData.count == 8 else { return [] }
        let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard length > 0, length < 100_000_000, let header = try? file.read(upToCount: Int(length)),
              let obj = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else { return [] }
        return obj.keys.filter { $0 != "__metadata__" }
    }

    /// HF repo of a Multi-Token-Prediction drafter for this model, if we
    /// publish one: mlx_lm.server's `--draft-model` then speculatively
    /// decodes with it (same output, faster -- ~+50% tok/s on short prompts
    /// for Gemma 4 26B-A4B). Matched by architecture shape from config.json
    /// rather than by folder name, so any MLX quant of the same base model
    /// gets it; the drafter only shares the tokenizer and hidden size with
    /// the main model, not its weights.
    static func mtpDrafterRepo(forModelPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path + "/config.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let modelType = obj["model_type"] as? String
        guard modelType == "gemma4" || modelType == "gemma4_text" else { return nil }
        let text = (obj["text_config"] as? [String: Any]) ?? obj
        // Gemma 4 26B-A4B: 2816 hidden, 30 layers, MoE block.
        if text["hidden_size"] as? Int == 2816,
           text["num_hidden_layers"] as? Int == 30,
           text["enable_moe_block"] as? Bool == true {
            return "roman220220/gemma-4-26B-A4B-it-assistant-mlx-8bit"
        }
        return nil
    }

    /// The file a model's own MTP head ships in (our Qwen 3.5 quants): an
    /// installed model gets it alone, mlx-lm loads it with the weights.
    static let mtpHeadFile = "model-mtp.safetensors"

    /// The model's config declares an MTP head (Qwen 3.5:
    /// `mtp_num_hidden_layers`), whether or not its weights are here.
    static func declaresMTPHead(forModelPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path + "/config.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let text = (obj["text_config"] as? [String: Any]) ?? obj
        return (text["mtp_num_hidden_layers"] as? Int ?? 0) > 0
    }

    static func hasMTPHead(forModelPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/" + mtpHeadFile)
    }

    /// Publishers whose repos a missing MTP head is fetched from: ours. The
    /// repo is read from the folder's name (<root>/<org>/<name>, ours and LM
    /// Studio's alike), which proves nothing on its own -- so not from any
    /// org a renamed or copied folder may name.
    static let mtpHeadPublishers: Set<String> = ["roman220220"]

    /// The repo a model folder's MTP head would come from, or nil.
    static func mtpHeadRepo(forModelPath path: String) -> String? {
        let parts = Array(URL(fileURLWithPath: path).standardizedFileURL.pathComponents.suffix(2))
        guard parts.count == 2, mtpHeadPublishers.contains(parts[0]),
              !parts[1].isEmpty, !parts[1].hasPrefix(".") else { return nil }
        return parts.joined(separator: "/")
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
