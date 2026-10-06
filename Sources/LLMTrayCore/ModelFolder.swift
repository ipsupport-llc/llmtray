import Foundation

/// Whether a model folder is all there: LLMTray's own download once it wrote
/// its completion marker; a folder it didn't download (no manifest of its
/// files) when it has a config and its weights.
public enum ModelFolder {
    /// Written by a download once every file is in place.
    public static let completionMarkerName = ".llmtray-complete"
    /// Which revision of each file a download has on disk; there without the
    /// marker, the download is under way or was interrupted.
    public static let manifestName = ".llmtray-files.json"
    static let weightsIndexName = "model.safetensors.index.json"

    public static func isComplete(atPath path: String, fileManager fm: FileManager = .default) -> Bool {
        let dir = path.hasSuffix("/") ? path : path + "/"
        if fm.fileExists(atPath: dir + completionMarkerName) { return true }
        if fm.fileExists(atPath: dir + manifestName) { return false }
        guard fm.fileExists(atPath: dir + "config.json") else { return false }
        // Sharded weights: every file the index names.
        if let data = fm.contents(atPath: dir + weightsIndexName),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let map = obj["weight_map"] as? [String: String] {
            let files = Set(map.values)
            return !files.isEmpty && files.allSatisfy { fm.fileExists(atPath: dir + $0) }
        }
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        return names.contains { $0.hasSuffix(".safetensors") }
    }

    /// Removes a cancelled download from `path`: the files it `wrote`, the
    /// ones its manifest lists (an earlier attempt's), the manifest, then the
    /// folders left empty, `path` itself included. Anything else there (a
    /// copy put in by hand that the download hadn't replaced yet) stays, and
    /// nothing at all goes once the download completed (its marker is there).
    public static func removeUnfinishedDownload(atPath path: String, wrote: [String], fileManager fm: FileManager = .default) {
        let dir = URL(fileURLWithPath: path).standardizedFileURL
        guard !fm.fileExists(atPath: dir.appendingPathComponent(completionMarkerName).path) else { return }
        let manifestURL = dir.appendingPathComponent(manifestName)
        let listed = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL)))?.keys
        for file in Set(wrote).union(listed ?? [:].keys) {
            let url = dir.appendingPathComponent(file).standardizedFileURL
            // A listed path stays inside the folder ("../" in a repo's file
            // list must not reach out).
            guard url.path.hasPrefix(dir.path + "/") else { continue }
            try? fm.removeItem(at: url)
        }
        try? fm.removeItem(at: manifestURL)
        // Deepest first, so a parent is empty once its children are gone.
        let subfolders = (fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path.count > $1.path.count }
        for folder in subfolders + [dir] where (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }
    }
}

extension ModelRecommendations {
    /// What the chat model step offers, given the models already here: a
    /// pick already complete in the folder isn't offered again as a download
    /// (an incomplete copy stays: its download resumes); the local copy is
    /// marked instead.
    public struct Offer: Equatable, Sendable {
        /// The picks to download.
        public var downloads: [Pick]
        /// Local model path -> the pick it is a complete copy of.
        public var local: [String: Pick]

        /// The local copy of a recommended pick: marked, and listed first.
        public func isRecommended(localPath: String) -> Bool { local[localPath]?.role == .recommended }

        /// `models` (the local ones, by their folder) with the recommended ones
        /// first, otherwise in their order.
        public func ordered<T>(_ models: [T], path: (T) -> String) -> [T] {
            models.filter { isRecommended(localPath: path($0)) } + models.filter { !isRecommended(localPath: path($0)) }
        }
    }

    /// The local model folder holding `repo` ("org/name"): its path ends in
    /// the repo's two components, compared case-insensitively.
    public static func localPath(of repo: String, in paths: [String]) -> String? {
        let suffix = "/" + repo.lowercased()
        return paths.first { p in
            let l = (p.hasSuffix("/") ? String(p.dropLast()) : p).lowercased()
            return l.hasSuffix(suffix) || l == repo.lowercased()
        }
    }

    /// What the curated list says a local model can do (the popover's model
    /// card); `vision`: what its config.json says (ModelDiscovery), for the
    /// models the list doesn't know. `audio` from the folder alone: the
    /// list's own claim gives way to it, a text-only conversion in a listed
    /// model's folder hears nothing. In the list's Capability order.
    public static func capabilities(ofLocalPath path: String, in models: [RecommendedModel],
                                    vision: Bool, audio: Bool = false) -> [RecommendedModel.Capability] {
        var found = Set(models.first { localPath(of: $0.repo, in: [path]) != nil }?.capabilities ?? [])
        if vision { found.insert(.vision) }
        if audio { found.insert(.audio) } else { found.remove(.audio) }
        return RecommendedModel.Capability.allCases.filter(found.contains)
    }

    /// `isComplete` is asked of a matching folder (`ModelFolder.isComplete`).
    public static func offer(_ picks: [Pick], localPaths: [String], isComplete: (String) -> Bool) -> Offer {
        var offer = Offer(downloads: [], local: [:])
        for pick in picks {
            if let path = localPath(of: pick.model.repo, in: localPaths), offer.local[path] == nil, isComplete(path) {
                offer.local[path] = pick
            } else {
                offer.downloads.append(pick)
            }
        }
        return offer
    }
}
