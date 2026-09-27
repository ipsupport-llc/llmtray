import Foundation

/// A Hugging Face repo already in the hub cache (what huggingface_hub
/// downloaded): the snapshot `refs/main` points at, when its files are
/// there. The model server gets that folder instead of the repo id, so a
/// start needs no network (the id makes it ask the Hub for the revision
/// every time, and wait on it offline).
public enum HFHubCache {
    /// HF_HUB_CACHE, else HF_HOME/hub, else ~/.cache/huggingface/hub.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 home: String = NSHomeDirectory()) -> String {
        if let hub = environment["HF_HUB_CACHE"], !hub.isEmpty { return hub }
        if let hf = environment["HF_HOME"], !hf.isEmpty { return hf + "/hub" }
        return home + "/.cache/huggingface/hub"
    }

    /// The snapshot folder of `repo` ("org/name") at `refs/main`, if it has
    /// a config and its weights (every shard its index lists, else every
    /// .safetensors there, each with its blob); nil otherwise.
    public static func localSnapshot(repo: String, cacheDirectory: String = directory()) -> String? {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let root = cacheDirectory + "/models--" + parts[0] + "--" + parts[1]
        guard let rev = try? String(contentsOfFile: root + "/refs/main", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rev.isEmpty, !rev.contains("/") else { return nil }
        let snapshot = root + "/snapshots/" + rev
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshot + "/config.json") else { return nil }
        if let data = fm.contents(atPath: snapshot + "/model.safetensors.index.json"),
           let index = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let map = index["weight_map"] as? [String: String] {
            let shards = Set(map.values)
            guard !shards.isEmpty, shards.allSatisfy({ fm.fileExists(atPath: snapshot + "/" + $0) }) else { return nil }
            return snapshot
        }
        // Snapshot entries are symlinks into blobs/: fileExists follows
        // them, so a pruned blob counts as missing.
        let weights = ((try? fm.contentsOfDirectory(atPath: snapshot)) ?? []).filter { $0.hasSuffix(".safetensors") }
        guard !weights.isEmpty, weights.allSatisfy({ fm.fileExists(atPath: snapshot + "/" + $0) }) else { return nil }
        return snapshot
    }
}
