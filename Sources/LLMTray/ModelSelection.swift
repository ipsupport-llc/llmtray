import Foundation
import LLMTrayCore

/// Picking the chat model and its profile: one code path for the popover's
/// pickers (ChatHeaderView), the menu bar's quick menu and the setup
/// wizard's start, so they can't gate the same action differently.
@MainActor
enum ModelSelection {
    /// The model to load now after `id` was picked: another one is running
    /// and switching is allowed. Stopped or idle-unloaded: nil -- nothing
    /// loads until a message or Start. Not mid-turn either: the turn's next
    /// round would ask for its own model back (the header's Load is there
    /// once it ends).
    static func modelToLoad(afterPicking id: String?, server: ServerManager, benchmark: BenchmarkRunner) -> LocalModel? {
        guard case .running = server.state, OperationAvailability(server: server, benchmark: benchmark).canSwitchModel,
              !ChatTabs.shared.isAnyBusy,
              let model = ModelCatalog.shared.model(id: id), model.path != server.loadedModelPath else { return nil }
        return model
    }

    /// For the loaded model a profile switch can change launch arguments --
    /// not while a request or the auto-tune could be cut off.
    static func canAssignProfile(to modelID: String?, server: ServerManager, benchmark: BenchmarkRunner) -> Bool {
        modelID != nil && OperationAvailability(server: server, benchmark: benchmark)
            .canAssignProfile(toLoadedModel: modelID == server.loadedModelPath)
    }

    /// Launch-setting differences are applied by the "Restart Server"
    /// prompt, not by restarting here (that would cut off requests).
    static func assignProfile(_ profileID: String, to modelID: String?, server: ServerManager, benchmark: BenchmarkRunner) {
        guard canAssignProfile(to: modelID, server: server, benchmark: benchmark), let modelID else { return }
        ProfileManager.shared.assign(profileID: profileID, to: modelID)
    }
}

/// What each local model can do, for the popover's model card: read once
/// per model (its config.json, the curated list), not on every render.
@MainActor
enum ModelCapabilities {
    private static var cache: [String: [RecommendedModel.Capability]] = [:]
    private static var recommended: [RecommendedModel]?

    /// A download (or a model replaced in place) can change a folder's
    /// config.json: read again. The list ships in the app bundle
    /// (Resources/runtime), so a runtime install doesn't change it -- it's
    /// read again here anyway.
    private static let invalidation = NotificationCenter.default.addObserver(
        forName: .modelsDidChange, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated {
            cache = [:]
            recommended = nil
        }
    }

    static func of(_ path: String) -> [RecommendedModel.Capability] {
        _ = invalidation
        if let known = cache[path] { return known }
        if recommended == nil {
            // Missing or unreadable (a dev checkout without it): just the config's.
            let url = URL(fileURLWithPath: RuntimePaths.runtimeDir).appendingPathComponent(ModelRecommendations.fileName)
            recommended = (try? ModelRecommendations.load(contentsOf: url)) ?? []
        }
        let capabilities = ModelRecommendations.capabilities(ofLocalPath: path, in: recommended ?? [],
                                                             vision: ModelDiscovery.supportsVision(forModelPath: path))
        cache[path] = capabilities
        return capabilities
    }

    /// The card's symbol for each.
    static func symbol(_ capability: RecommendedModel.Capability) -> String {
        switch capability {
        case .vision: return "eye"
        case .tools: return "wrench.and.screwdriver"
        case .reasoning: return "brain"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Also the setup wizard's model list.
    static func name(_ capability: RecommendedModel.Capability) -> String {
        switch capability {
        case .vision: return NSLocalizedString("reads images", comment: "setup: model capability")
        case .tools: return NSLocalizedString("calls tools", comment: "setup: model capability")
        case .reasoning: return NSLocalizedString("reasons", comment: "setup: model capability")
        case .code: return NSLocalizedString("writes code", comment: "setup: model capability")
        }
    }
}
