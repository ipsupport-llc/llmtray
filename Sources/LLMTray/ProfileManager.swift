import Foundation
import LLMTrayCore

/// App-side owner of profiles: loads them from disk, answers "what settings
/// does this model get", and writes edits back.
///
/// One shared instance: ServerManager (launch args), ChatClient (via
/// ContentView's ChatSettings), BenchmarkRunner (auto-tune results) and the
/// settings UI must all see the same profiles.
@MainActor
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var assignments: [String: String] = [:]
    @Published private(set) var loadErrors: [String] = []

    private let store: ProfileStore

    init(directory: URL = URL(fileURLWithPath: RuntimePaths.externalRuntimeDir).appendingPathComponent("profiles")) {
        store = ProfileStore(directory: directory)
        reload()
    }

    /// Re-reads everything from disk -- picks up hand edits to the JSON
    /// files (called when the settings panel opens).
    func reload() {
        var errors: [String] = []
        do {
            try store.ensureDefault(migratingFrom: .standard)
        } catch {
            // A broken hand edit of default.json: never overwritten (that
            // would silently throw away the user's settings). Built-in
            // values are used until it's fixed or deleted.
            errors.append("default.json can't be read (\(error.localizedDescription)) -- using built-in settings until it's fixed or deleted. Edits to Default aren't saved meanwhile.")
        }
        profiles = store.loadAll { url, error in
            guard url.lastPathComponent != "\(Profile.defaultID).json" else { return }
            errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        // Kept as stored, even for a profile that didn't load this time (a
        // broken hand edit): filtering them out here would get the
        // filtered list written back by the next assign() and lose those
        // models' assignments for good. Lookups fall back to Default.
        assignments = store.loadAssignments()
        loadErrors = errors
    }

    var defaultProfile: Profile {
        profiles.first { $0.isDefault } ?? {
            var p = Profile.builtIn
            p.id = Profile.defaultID
            p.name = "Default"
            return p
        }()
    }

    func profile(id: String) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// The profile a model is assigned to (Default if none).
    func profileID(for modelPath: String?) -> String {
        guard let id = modelPath.flatMap({ assignments[$0] }), profile(id: id) != nil else { return Profile.defaultID }
        return id
    }

    func profile(for modelPath: String?) -> Profile {
        profile(id: profileID(for: modelPath)) ?? defaultProfile
    }

    /// The overlay applied on top of Default, nil for Default itself.
    private func overlay(for modelPath: String?) -> Profile? {
        let p = profile(for: modelPath)
        return p.isDefault ? nil : p
    }

    func resolved(for modelPath: String?) -> ResolvedProfile {
        ProfileResolver.resolve(overlay: overlay(for: modelPath), base: defaultProfile)
    }

    func value<T>(_ keyPath: KeyPath<Profile, T?>, for modelPath: String?) -> T {
        ProfileResolver.value(keyPath, overlay: overlay(for: modelPath), base: defaultProfile)
    }

    func source<T>(_ keyPath: KeyPath<Profile, T?>, for modelPath: String?) -> ProfileResolver.Source {
        ProfileResolver.source(keyPath, overlay: overlay(for: modelPath), base: defaultProfile)
    }

    // MARK: - Editing

    /// Sets a field on the profile this model uses (its overlay, or Default).
    func set<T>(_ keyPath: WritableKeyPath<Profile, T?>, _ value: T?, for modelPath: String?) {
        update(id: profileID(for: modelPath)) { $0[keyPath: keyPath] = value }
    }

    /// Clears an overlay's field so it inherits from Default again. No-op on
    /// Default (it has nothing to inherit from but the built-ins).
    func reset<T>(_ keyPath: WritableKeyPath<Profile, T?>, for modelPath: String?) {
        let id = profileID(for: modelPath)
        guard id != Profile.defaultID else { return }
        update(id: id) { $0[keyPath: keyPath] = nil }
    }

    func update(id: String, _ mutate: (inout Profile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        var p = profiles[i]
        mutate(&p)
        guard p != profiles[i] else { return }
        profiles[i] = p
        persist(p)
    }

    @discardableResult
    func create(name: String, copying source: Profile? = nil) -> Profile {
        var p = Profile(name: uniqueName(name))
        if let source {
            // A copy of Default would pin every field; copy only an
            // overlay's own overrides so the new profile still inherits.
            if !source.isDefault {
                p.request = source.request
                p.tools = source.tools
                p.launch = source.launch
            }
        }
        profiles.append(p)
        persist(p)
        profiles = store.loadAll()
        return p
    }

    func rename(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        update(id: id) { $0.name = trimmed }
    }

    func delete(id: String) {
        guard id != Profile.defaultID else { return }
        do {
            try store.delete(id: id)
        } catch {
            loadErrors = ["delete failed: \(error.localizedDescription)"]
        }
        reload()
    }

    func assign(profileID: String, to modelPath: String) {
        if profileID == Profile.defaultID {
            assignments.removeValue(forKey: modelPath)
        } else {
            assignments[modelPath] = profileID
        }
        do {
            try store.saveAssignments(assignments)
        } catch {
            loadErrors = ["could not save assignments: \(error.localizedDescription)"]
        }
    }

    func models(assignedTo profileID: String) -> [String] {
        assignments.filter { $0.value == profileID }.map(\.key).sorted()
    }

    /// Whether writes to this profile can be saved (false for a Default
    /// whose file is broken -- it isn't in `profiles` then).
    func isEditable(id: String) -> Bool {
        profile(id: id) != nil
    }

    private func persist(_ p: Profile) {
        do {
            try store.save(p)
        } catch {
            loadErrors = ["could not save \(p.name): \(error.localizedDescription)"]
        }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(profiles.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
