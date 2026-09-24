import Foundation

/// Profiles and model→profile assignments on disk:
///
///     <dir>/profiles/<id>.json      one Profile each
///     <dir>/profiles/assignments.json   {"<model path>": "<profile id>"}
///
/// Plain JSON so a profile can be hand-edited or copied to another Mac.
/// `Default` (`default.json`) always exists: created on first use from
/// the pre-profiles UserDefaults settings (`migratedDefault`).
public final class ProfileStore {
    public let directory: URL
    private var assignmentsURL: URL { directory.appendingPathComponent("assignments.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// All profiles, `Default` first then by name. Unreadable files are
    /// skipped (and reported), not fatal: one broken hand edit shouldn't
    /// take every profile down with it.
    public func loadAll(onError: (URL, Error) -> Void = { _, _ in }) -> [Profile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var profiles: [Profile] = []
        for file in files where file.pathExtension == "json" && file.lastPathComponent != assignmentsURL.lastPathComponent {
            do {
                var p = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: file))
                // The file name is the id; keep them consistent if someone
                // copied a file without editing its "id".
                p.id = file.deletingPathExtension().lastPathComponent
                profiles.append(p)
            } catch {
                onError(file, error)
            }
        }
        return profiles.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func save(_ profile: Profile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(profile).write(to: url(for: profile.id), options: .atomic)
    }

    public func delete(id: String) throws {
        guard id != Profile.defaultID else { return }
        try? FileManager.default.removeItem(at: url(for: id))
        var a = loadAssignments()
        a = a.filter { $0.value != id }
        try saveAssignments(a)
    }

    public func loadAssignments() -> [String: String] {
        guard let data = try? Data(contentsOf: assignmentsURL),
              let a = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return a
    }

    public func saveAssignments(_ a: [String: String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(a).write(to: assignmentsURL, options: .atomic)
    }

    /// Creates `default.json` from the old global settings if it doesn't
    /// exist yet. The old UserDefaults keys are left alone, so going back
    /// to a pre-profiles build loses nothing.
    ///
    /// Only a *missing* file is created: an existing `default.json` that
    /// doesn't decode (a broken hand edit) throws instead of being
    /// silently replaced by the old settings.
    @discardableResult
    public func ensureDefault(migratingFrom defaults: UserDefaults) throws -> Profile {
        let file = url(for: Profile.defaultID)
        if FileManager.default.fileExists(atPath: file.path) {
            var p = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: file))
            p.id = Profile.defaultID
            return p
        }
        let p = Self.migratedDefault(from: defaults)
        try save(p)
        return p
    }

    /// The pre-profiles `llmtray.*` settings as the `Default` profile,
    /// every field set (missing keys take the built-in value).
    public static func migratedDefault(from d: UserDefaults) -> Profile {
        var p = Profile.builtIn
        p.id = Profile.defaultID
        p.name = "Default"
        func int(_ k: String) -> Int? { d.object(forKey: k) as? Int }
        func dbl(_ k: String) -> Double? { d.object(forKey: k) as? Double }
        func bool(_ k: String) -> Bool? { d.object(forKey: k) as? Bool }
        func str(_ k: String) -> String? { d.object(forKey: k) as? String }
        if let v = dbl("llmtray.temperature") { p.request.temperature = v }
        if let v = dbl("llmtray.topP") { p.request.topP = v }
        if let v = dbl("llmtray.maxTokens") { p.request.maxTokens = Int(v) } else if let v = int("llmtray.maxTokens") { p.request.maxTokens = v }
        // An empty old system prompt means "never set": Default gets the
        // visible built-in one instead, so the user sees what to extend.
        if let v = str("llmtray.systemPrompt"), !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p.request.systemPrompt = v
        }
        if let v = bool("llmtray.enableImageGeneration") { p.tools.enableImageGeneration = v }
        if let v = str("llmtray.imageGenModel") { p.tools.imageGenModel = v }
        if let v = str("llmtray.imageQuality") { p.tools.imageQuality = v }
        if let v = bool("llmtray.unloadModelDuringImageGen") { p.tools.unloadModelDuringImageGen = v }
        if let v = int("llmtray.kvBits") { p.launch.kvBits = KVSettings.validBits(v) }
        if let v = int("llmtray.kvGroupSize") { p.launch.kvGroupSize = KVSettings.validGroupSize(v) }
        if let v = int("llmtray.quantizedKVStart") { p.launch.quantizedKVStart = v }
        if let v = int("llmtray.prefillStepSize") { p.launch.prefillStepSize = v }
        if let v = int("llmtray.decodeConcurrency") { p.launch.decodeConcurrency = v }
        if let v = int("llmtray.promptCacheMB") { p.launch.promptCacheMB = v }
        if let v = bool("llmtray.mtpDrafter") { p.launch.mtpDrafter = v }
        if let v = str("llmtray.extraServerArgs") { p.launch.extraServerArgs = v }
        return p
    }
}
