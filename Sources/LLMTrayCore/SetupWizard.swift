import Foundation

/// The first-run wizard's logic (adr/0013): when it opens, where it
/// resumes, and what the user's choices turn into. Pure -- the app's
/// SetupWizardModel shows the steps and runs the actions through
/// FeatureSetup, ProfileManager and the Pref keys Settings uses.
public enum SetupWizard {
    /// Stored in Pref.onboardingCompleted when the wizard is finished,
    /// skipped or closed. A later version with new steps can raise it to
    /// show just those to people who saw an older one.
    public static let version = 1

    /// Opens by itself on a fresh install only: never completed and no
    /// model selected -- or a first run that was quit part way (a model
    /// may have been picked in it since).
    public static func opensAutomatically(completedVersion: Int?, selectedModelID: String?,
                                          saved: SetupProgress?) -> Bool {
        guard completedVersion == nil else { return false }
        if saved?.startedAutomatically == true { return true }
        return selectedModelID == nil
    }

    /// Where to pick up: the saved progress of a first run quit part way;
    /// otherwise (opened from Settings or the menu) the first step with
    /// the current settings.
    public static func resume(saved: SetupProgress?, current: SetupChoices, automatic: Bool) -> SetupProgress {
        if automatic, let saved, saved.startedAutomatically { return saved }
        return SetupProgress(choices: current, startedAutomatically: automatic)
    }
}

/// The wizard's steps, in order.
public enum SetupStep: Int, Codable, CaseIterable, Sendable, Comparable {
    case welcome, yourMac, modelsFolder, chatModel, extras, apps, updates, done

    public static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }

    public var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    public var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
}

/// The chat model the user picked.
public enum ChatModelChoice: Codable, Equatable, Sendable {
    /// A model already in the models folder (its path, the model id).
    case local(path: String)
    /// A Hugging Face repo to download; its size as known when picked.
    case download(repo: String, approxBytes: Int64?)
}

/// Everything the wizard can set. Filled with the current settings when
/// it opens, so what the user leaves alone changes nothing.
public struct SetupChoices: Codable, Equatable, Sendable {
    // Models folder
    public var modelsFolder: String
    // Chat model
    public var chatModel: ChatModelChoice?
    // What else (the Default profile). nil: off.
    /// `ImageGenModel` raw value.
    public var imageModel: String?
    /// `ImageGenModel` raw value (one that edits).
    public var editModel: String?
    /// `MusicModel` raw value.
    public var musicModel: String?
    public var creatorMode: Bool
    public var creatorCountdown: Int
    public var webTools: Bool
    public var projectFiles: Bool
    // Apps and agents
    public var port: Int
    public var allowLAN: Bool
    /// `ModelSwitchPolicy` raw value.
    public var modelSwitchPolicy: String
    // Staying up to date
    public var launchAtLogin: Bool
    public var automaticUpdateChecks: Bool
    public var checkUpdatesAtLaunch: Bool
    public var betaUpdates: Bool
    public var usageStatistics: Bool

    public init(modelsFolder: String, chatModel: ChatModelChoice? = nil, imageModel: String? = nil,
                editModel: String? = nil, musicModel: String? = nil, creatorMode: Bool = false,
                creatorCountdown: Int = 3, webTools: Bool = false, projectFiles: Bool = false,
                port: Int = 8765, allowLAN: Bool = false, modelSwitchPolicy: String = ModelSwitchPolicy.auto.rawValue,
                launchAtLogin: Bool = false, automaticUpdateChecks: Bool = true, checkUpdatesAtLaunch: Bool = true,
                betaUpdates: Bool = false, usageStatistics: Bool = false) {
        self.modelsFolder = modelsFolder
        self.chatModel = chatModel
        self.imageModel = imageModel
        self.editModel = editModel
        self.musicModel = musicModel
        self.creatorMode = creatorMode
        self.creatorCountdown = creatorCountdown
        self.webTools = webTools
        self.projectFiles = projectFiles
        self.port = port
        self.allowLAN = allowLAN
        self.modelSwitchPolicy = modelSwitchPolicy
        self.launchAtLogin = launchAtLogin
        self.automaticUpdateChecks = automaticUpdateChecks
        self.checkUpdatesAtLaunch = checkUpdatesAtLaunch
        self.betaUpdates = betaUpdates
        self.usageStatistics = usageStatistics
    }

    /// These choices with `step`'s fields taken from `other`: Skip puts a
    /// step back to how it was (other: the baseline); applying one step
    /// early takes just its fields (self: the baseline, other: the choices).
    public func merging(_ step: SetupStep, from other: SetupChoices) -> SetupChoices {
        var merged = self
        switch step {
        case .welcome, .yourMac, .done:
            break
        case .modelsFolder:
            merged.modelsFolder = other.modelsFolder
        case .chatModel:
            merged.chatModel = other.chatModel
        case .extras:
            merged.imageModel = other.imageModel
            merged.editModel = other.editModel
            merged.musicModel = other.musicModel
            merged.creatorMode = other.creatorMode
            merged.creatorCountdown = other.creatorCountdown
            merged.webTools = other.webTools
            merged.projectFiles = other.projectFiles
        case .apps:
            merged.port = other.port
            merged.allowLAN = other.allowLAN
            merged.modelSwitchPolicy = other.modelSwitchPolicy
        case .updates:
            merged.launchAtLogin = other.launchAtLogin
            merged.automaticUpdateChecks = other.automaticUpdateChecks
            merged.checkUpdatesAtLaunch = other.checkUpdatesAtLaunch
            merged.betaUpdates = other.betaUpdates
            merged.usageStatistics = other.usageStatistics
        }
        return merged
    }
}

/// Where the wizard is, kept in Pref.onboardingProgress so a relaunch
/// resumes it.
public struct SetupProgress: Codable, Equatable, Sendable {
    public var step: SetupStep
    /// What the user has chosen so far.
    public var choices: SetupChoices
    /// The settings as they are now: what the wizard opened with, plus
    /// what it has already applied (the models folder, the chat model).
    /// Finish applies only what differs from it.
    public var baseline: SetupChoices
    /// The settings when the wizard opened: what Skip goes back to, also
    /// for a step already applied.
    public var original: SetupChoices
    /// Opened by itself on a first run (not from Settings or the menu):
    /// only that one resumes after a relaunch.
    public var startedAutomatically: Bool
    /// A chat model was picked in the wizard: the server starts with it
    /// once it's there.
    public var startsServer: Bool

    private enum CodingKeys: String, CodingKey { case step, choices, baseline, original, startedAutomatically, startsServer }

    /// Lenient: progress saved without `original` (an earlier build)
    /// takes the baseline for it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = try c.decode(SetupStep.self, forKey: .step)
        choices = try c.decode(SetupChoices.self, forKey: .choices)
        baseline = try c.decode(SetupChoices.self, forKey: .baseline)
        original = try c.decodeIfPresent(SetupChoices.self, forKey: .original) ?? baseline
        startedAutomatically = try c.decode(Bool.self, forKey: .startedAutomatically)
        startsServer = try c.decode(Bool.self, forKey: .startsServer)
    }

    public init(step: SetupStep = .welcome, choices: SetupChoices, baseline: SetupChoices? = nil,
                startedAutomatically: Bool, startsServer: Bool = false) {
        self.step = step
        self.choices = choices
        self.baseline = baseline ?? choices
        self.original = baseline ?? choices
        self.startedAutomatically = startedAutomatically
        self.startsServer = startsServer
    }

    /// Skip: the step goes back to how it was when the wizard opened, and
    /// on to the next one. What it had already applied (the folder, a
    /// picked chat model) is undone by the actions returned.
    public mutating func skip() -> [SetupAction] {
        let actions = SetupPlan.revert(step, applied: baseline, original: original)
        choices = choices.merging(step, from: original)
        baseline = baseline.merging(step, from: original)
        if step == .chatModel, choices.chatModel == original.chatModel { startsServer = false }
        if let next = step.next { step = next }
        return actions
    }

    /// The actions that apply `step`'s choices now (the models folder, so
    /// the next step lists its models; the chat model, so its download
    /// starts), with the baseline moved on so Finish doesn't repeat them.
    public mutating func applyEarly(_ step: SetupStep) -> [SetupAction] {
        let target = baseline.merging(step, from: choices)
        let actions = SetupPlan.actions(from: target, baseline: baseline, startsServer: false)
        baseline = target
        return actions
    }
}

/// One thing Finish (or an early step) does, in the order it's done.
public enum SetupAction: Equatable, Sendable {
    case setModelsFolder(String)
    case selectModel(path: String)
    /// Undoing a pick: no model selected, as before the wizard.
    case clearModelSelection
    /// Undoing a picked download: it's cancelled if it hasn't finished.
    case cancelChatDownload(repo: String)
    case setPort(Int)
    case setAllowLAN(Bool)
    case setModelSwitchPolicy(String)
    case setCreatorMode(Bool)
    case setCreatorCountdown(Int)
    case setWebTools(Bool)
    case disableImageGeneration
    case disableImageEditing
    case disableMusicGeneration
    case setProjectFiles(Bool)
    case setLaunchAtLogin(Bool)
    case setAutomaticUpdateChecks(Bool)
    case setCheckUpdatesAtLaunch(Bool)
    case setBetaUpdates(Bool)
    case setUsageStatistics(Bool)
    // Downloads (the queue: one at a time, the chat model first).
    case downloadChatModel(repo: String, approxBytes: Int64?)
    case downloadImageModel(String)
    case downloadEditModel(String)
    case downloadMusicModel(String)
    /// Project files' embedder (when it isn't there yet: the app checks).
    case downloadEmbedder
    /// Start the server with the chosen chat model, now or once its
    /// download is done.
    case startServer

    public var isDownload: Bool {
        switch self {
        case .downloadChatModel, .downloadImageModel, .downloadEditModel, .downloadMusicModel, .downloadEmbedder: return true
        default: return false
        }
    }
}

public enum SetupPlan {
    /// What undoes `step`'s early actions: `applied` (the baseline, with
    /// them) back to `original`. Only the early steps have any.
    public static func revert(_ step: SetupStep, applied: SetupChoices, original: SetupChoices) -> [SetupAction] {
        switch step {
        case .modelsFolder:
            return applied.modelsFolder == original.modelsFolder ? [] : [.setModelsFolder(original.modelsFolder)]
        case .chatModel:
            guard applied.chatModel != original.chatModel else { return [] }
            var actions: [SetupAction] = []
            if case .download(let repo, _) = applied.chatModel { actions.append(.cancelChatDownload(repo: repo)) }
            switch original.chatModel {
            case .local(let path): actions.append(.selectModel(path: path))
            case nil: if case .local = applied.chatModel { actions.append(.clearModelSelection) }
            case .download: break   // never the opening state (a selection is local)
            }
            return actions
        default:
            return []
        }
    }

    /// What turns `baseline` (the settings now) into `choices`, in order:
    /// the models folder and the chat model first, then the settings, then
    /// the downloads (each feature turned on once its model is in place),
    /// and last the server start. Nothing for what's unchanged.
    public static func actions(from choices: SetupChoices, baseline: SetupChoices, startsServer: Bool) -> [SetupAction] {
        var actions: [SetupAction] = []
        var downloads: [SetupAction] = []
        if choices.modelsFolder != baseline.modelsFolder {
            actions.append(.setModelsFolder(choices.modelsFolder))
        }
        if choices.chatModel != baseline.chatModel {
            switch choices.chatModel {
            case .local(let path): actions.append(.selectModel(path: path))
            case .download(let repo, let bytes): downloads.append(.downloadChatModel(repo: repo, approxBytes: bytes))
            case nil: break   // nothing picked: the selection stays as it is
            }
        }
        if choices.port != baseline.port { actions.append(.setPort(choices.port)) }
        if choices.allowLAN != baseline.allowLAN { actions.append(.setAllowLAN(choices.allowLAN)) }
        if choices.modelSwitchPolicy != baseline.modelSwitchPolicy {
            actions.append(.setModelSwitchPolicy(choices.modelSwitchPolicy))
        }
        if choices.creatorMode != baseline.creatorMode { actions.append(.setCreatorMode(choices.creatorMode)) }
        if choices.creatorCountdown != baseline.creatorCountdown {
            actions.append(.setCreatorCountdown(max(0, choices.creatorCountdown)))
        }
        if choices.webTools != baseline.webTools { actions.append(.setWebTools(choices.webTools)) }
        if choices.imageModel != baseline.imageModel {
            if let model = choices.imageModel { downloads.append(.downloadImageModel(model)) } else { actions.append(.disableImageGeneration) }
        }
        if choices.editModel != baseline.editModel {
            if let model = choices.editModel { downloads.append(.downloadEditModel(model)) } else { actions.append(.disableImageEditing) }
        }
        if choices.musicModel != baseline.musicModel {
            if let model = choices.musicModel { downloads.append(.downloadMusicModel(model)) } else { actions.append(.disableMusicGeneration) }
        }
        if choices.projectFiles != baseline.projectFiles {
            // On at once (files are searched by their words meanwhile),
            // the embedder queued.
            actions.append(.setProjectFiles(choices.projectFiles))
            if choices.projectFiles { downloads.append(.downloadEmbedder) }
        }
        if choices.launchAtLogin != baseline.launchAtLogin { actions.append(.setLaunchAtLogin(choices.launchAtLogin)) }
        if choices.automaticUpdateChecks != baseline.automaticUpdateChecks {
            actions.append(.setAutomaticUpdateChecks(choices.automaticUpdateChecks))
        }
        if choices.checkUpdatesAtLaunch != baseline.checkUpdatesAtLaunch {
            actions.append(.setCheckUpdatesAtLaunch(choices.checkUpdatesAtLaunch))
        }
        if choices.betaUpdates != baseline.betaUpdates { actions.append(.setBetaUpdates(choices.betaUpdates)) }
        if choices.usageStatistics != baseline.usageStatistics {
            actions.append(.setUsageStatistics(choices.usageStatistics))
        }
        actions += downloads
        if startsServer, choices.chatModel != nil { actions.append(.startServer) }
        return actions
    }
}
