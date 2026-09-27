import Foundation
import LLMTrayCore
import ServiceManagement

/// Setting up the app's opt-in features: download a model, then turn the
/// feature on in a profile (Default unless said otherwise); launch at
/// login; the models folder. Settings and the first-run wizard both go
/// through here (adr/0013), so the wizard sets exactly what Settings sets.
/// No UI: the callers ask for confirmation first (sizes are here for
/// that), then run the operation and show its error.
@MainActor
final class FeatureSetup {
    static let shared = FeatureSetup()

    private let profiles = ProfileManager.shared
    /// Settings' model downloads run on a client of their own, not on
    /// whichever chat tab is open (ChatTabs.imageModels); its
    /// isDownloadingModel and status texts are what Settings shows.
    var media: ChatClient { ChatTabs.shared.imageModels }

    private init() {}

    /// An image or music model download is running (one at a time).
    var isDownloadingModel: Bool { media.isDownloadingModel }

    // MARK: - Image generation

    func imageGenModel(profileID: String = Profile.defaultID) -> ImageGenModel {
        ImageGenModel(rawValue: profiles.value(\.tools.imageGenModel, profileID: profileID)) ?? .gptqMixed
    }

    func isImageGenerationEnabled(profileID: String = Profile.defaultID) -> Bool {
        profiles.value(\.tools.enableImageGeneration, profileID: profileID)
    }

    /// Set up to generate: mflux at its pin and the checkpoint in place.
    func isImageModelReady(_ model: ImageGenModel) -> Bool {
        ChatTabs.shared.mflux.isReady(model)
    }

    func setImageGenerationEnabled(_ on: Bool, profileID: String = Profile.defaultID) {
        profiles.set(\.tools.enableImageGeneration, on, profileID: profileID)
    }

    func setImageGenModel(_ model: ImageGenModel, profileID: String = Profile.defaultID) {
        profiles.set(\.tools.imageGenModel, model.rawValue, profileID: profileID)
    }

    /// mflux (if needed) and `model`'s checkpoint. nil on success.
    func downloadImageModel(_ model: ImageGenModel) async -> Error? {
        await media.downloadImageModel(model)
    }

    /// Downloads `model` (the profile's image model, as it was when the
    /// user confirmed), then turns image generation on; stays off on an
    /// error.
    func enableImageGeneration(_ model: ImageGenModel, profileID: String = Profile.defaultID) async -> Error? {
        if let error = await downloadImageModel(model) { return error }
        setImageGenerationEnabled(true, profileID: profileID)
        return nil
    }

    // MARK: - Image editing

    /// The edit model, nil when editing is off.
    func imageEditModel(profileID: String = Profile.defaultID) -> ImageGenModel? {
        ImageGenModel(rawValue: profiles.value(\.tools.imageEditModel, profileID: profileID)).flatMap { $0.supportsEditing ? $0 : nil }
    }

    /// Sets the edit model as is (nil: editing off) -- for one already
    /// downloaded; enableImageEditing downloads first.
    func setImageEditModel(_ model: ImageGenModel?, profileID: String = Profile.defaultID) {
        profiles.set(\.tools.imageEditModel, model?.rawValue ?? "", profileID: profileID)
    }

    /// `model`'s checkpoint first if it isn't there, then it's the edit
    /// model: an edit mustn't stall on a multi-GB download mid-chat.
    func enableImageEditing(_ model: ImageGenModel = .klein4b, profileID: String = Profile.defaultID) async -> Error? {
        if !model.isDownloaded, let error = await downloadImageModel(model) { return error }
        setImageEditModel(model, profileID: profileID)
        return nil
    }

    // MARK: - Music generation

    func musicModel(profileID: String = Profile.defaultID) -> MusicModel {
        MusicModel(rawValue: profiles.value(\.tools.musicModel, profileID: profileID)) ?? .turbo
    }

    func isMusicGenerationEnabled(profileID: String = Profile.defaultID) -> Bool {
        profiles.value(\.tools.enableMusicGeneration, profileID: profileID)
    }

    /// mlx-audio at its pin and the model's checkpoints in place.
    func isMusicModelReady(_ model: MusicModel) -> Bool {
        media.isMusicModelReady(model)
    }

    func setMusicGenerationEnabled(_ on: Bool, profileID: String = Profile.defaultID) {
        profiles.set(\.tools.enableMusicGeneration, on, profileID: profileID)
    }

    func setMusicModel(_ model: MusicModel, profileID: String = Profile.defaultID) {
        profiles.set(\.tools.musicModel, model.rawValue, profileID: profileID)
    }

    /// mlx-audio (if needed) and `model`'s checkpoints. nil on success.
    func downloadMusicModel(_ model: MusicModel) async -> Error? {
        await media.downloadMusicModel(model)
    }

    /// `model` (the profile's music model, as it was when the user
    /// confirmed) set up if it isn't, then music on.
    func enableMusicGeneration(_ model: MusicModel, profileID: String = Profile.defaultID) async -> Error? {
        if !isMusicModelReady(model), let error = await downloadMusicModel(model) { return error }
        setMusicGenerationEnabled(true, profileID: profileID)
        return nil
    }

    /// `model` set up if it isn't, then it's the profile's music model.
    func switchMusicModel(to model: MusicModel, profileID: String = Profile.defaultID) async -> Error? {
        if !isMusicModelReady(model), let error = await downloadMusicModel(model) { return error }
        setMusicModel(model, profileID: profileID)
        return nil
    }

    // MARK: - Download sizes

    /// Bytes to expect for the free-space check -- the published
    /// checkpoints' sizes (the same as their descriptions), rounded up.
    static func downloadBytes(_ model: ImageGenModel) -> Int64 {
        switch model {
        case .gptq8bit: return gigabytes(10)
        case .gptq4bit: return gigabytes(5.5)
        case .gptqMixed: return gigabytes(6.3)
        case .klein4b: return gigabytes(5.3)
        }
    }

    static func downloadBytes(_ model: MusicModel) -> Int64 {
        switch model {
        case .turbo: return gigabytes(9)
        case .sftGPTQ4: return gigabytes(4.5)
        case .sft8bit: return gigabytes(5.5)
        case .sftBF16: return gigabytes(7.5)
        }
    }

    private static func gigabytes(_ value: Double) -> Int64 { Int64(value * 1_000_000_000) }

    // MARK: - Launch at login

    /// SMAppService is the source of truth (the user can also change it in
    /// System Settings > Login Items): read it, don't store it. Static and
    /// nonisolated: GeneralPane isn't main-actor on CI's older toolchain.
    nonisolated static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    nonisolated static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    // MARK: - Models folder

    var modelsFolder: String { ModelDiscovery.currentModelsRoot() }

    /// ModelCatalog rescans when this changes.
    func setModelsFolder(_ path: String) {
        UserDefaults.standard.set(path, forKey: ModelDiscovery.modelsRootDefaultsKey)
    }

    static var lmStudioFolder: String { NSString(string: "~/.lmstudio/models").expandingTildeInPath }

    /// LM Studio's folder exists and holds at least one model LLMTray can
    /// load (a folder with a config.json).
    var lmStudioFolderHasModels: Bool { !ModelDiscovery.scanModels(root: Self.lmStudioFolder).isEmpty }

    func useLMStudioFolder() { setModelsFolder(Self.lmStudioFolder) }
}
