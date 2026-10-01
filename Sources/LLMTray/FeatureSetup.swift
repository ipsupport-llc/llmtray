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

    // MARK: - Project files

    var projectFiles: ProjectIndexer { .shared }

    var isProjectFilesEnabled: Bool { projectFiles.isEnabled }

    /// The embedder the feature downloads (the registry's default, bge-m3);
    /// nil when runtime/embedders.json can't be read.
    var projectFilesEmbedder: EmbedderEntry? { try? projectFiles.embedders.defaultEntry() }

    var isProjectFilesEmbedderReady: Bool {
        projectFilesEmbedder.map(projectFiles.embedders.isReady) ?? false
    }

    var isProjectFilesEmbedderDownloaded: Bool {
        projectFilesEmbedder.map(projectFiles.embedders.isDownloaded) ?? false
    }

    /// On; with `downloadingEmbedder`, the embedder downloaded too (files are
    /// indexed by their words meanwhile, and embedded once it's in place).
    /// The feature stays on if the download fails: nil, or its error.
    func enableProjectFiles(downloadingEmbedder: Bool) async -> Error? {
        projectFiles.setEnabled(true)
        guard downloadingEmbedder, !isProjectFilesEmbedderReady else { return nil }
        return await downloadProjectFilesEmbedder()
    }

    /// The embedder's pinned files, fetched or repaired. nil on success.
    func downloadProjectFilesEmbedder() async -> Error? {
        do {
            try await projectFiles.embedders.download(try projectFiles.embedders.defaultEntry())
            return nil
        } catch {
            return error
        }
    }

    /// Off: nothing indexes and no runner starts; the indexes and the
    /// embedder stay (Remove takes the embedder away).
    func disableProjectFiles() {
        projectFiles.setEnabled(false)
    }

    /// Removes the embedder's weights (after its runner has exited).
    func removeProjectFilesEmbedder() async -> Error? {
        do {
            guard let entry = projectFilesEmbedder else { return nil }
            try await projectFiles.embedders.remove(entry)
            return nil
        } catch {
            return error
        }
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

    /// The embedder's pinned files, as the registry lists them.
    static func downloadBytes(_ entry: EmbedderEntry) -> Int64 { entry.source.bytes }

    private static func gigabytes(_ value: Double) -> Int64 { Int64(value * 1_000_000_000) }

    // MARK: - Launch at login

    /// SMAppService is the source of truth (the user can also change it in
    /// System Settings > Login Items): read it, don't store it. Static and
    /// nonisolated: GeneralPane isn't main-actor on CI's older toolchain.
    nonisolated static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    nonisolated static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    // MARK: - Memory

    /// The measured peaks (runtime/feature_memory.json); empty when the
    /// file can't be read -- nothing is gated then.
    private(set) lazy var featureMemory: FeatureMemory = {
        let url = URL(fileURLWithPath: RuntimePaths.runtimeDir).appendingPathComponent(FeatureMemory.fileName)
        return (try? FeatureMemory.load(contentsOf: url)) ?? FeatureMemory(cases: [])
    }()

    /// Probed once: a GPU limit raised with sysctl shows after a relaunch.
    private(set) lazy var hardware = HardwareProbe.current()

    /// Whether the model fits this Mac (nil: not measured, not gated).
    func memoryFit(_ model: ImageGenModel) -> FeatureFit? {
        featureMemory.fit(FeatureMemory.image(model.rawValue), on: hardware)
    }

    /// Editing takes more than generating (the reference image's latents).
    func memoryFit(editingWith model: ImageGenModel) -> FeatureFit? {
        featureMemory.fit(FeatureMemory.imageEdit(model.rawValue), on: hardware)
    }

    func memoryFit(_ model: MusicModel) -> FeatureFit? {
        featureMemory.fit(FeatureMemory.music(model.rawValue), on: hardware)
    }

    /// Voice Lab's memory: the measured peak, else the model's published
    /// footprint (VoiceMemoryFit sets it against the GPU limit).
    func voiceBytes(_ model: VoiceLabModel) -> Int64 {
        featureMemory.peakBytes(FeatureMemory.voice(model.id)) ?? model.footprintBytes
    }

    // MARK: - Recommended chat models

    /// The curated list (runtime/recommended_models.json) filtered for this
    /// Mac, recommended first; empty if the file can't be read.
    /// `liveSizes`: repo -> the Hub's current size, where already read.
    func recommendedChatModels(liveSizes: [String: Int64] = [:]) -> [ModelRecommendations.Pick] {
        let url = URL(fileURLWithPath: RuntimePaths.runtimeDir).appendingPathComponent(ModelRecommendations.fileName)
        guard let models = try? ModelRecommendations.load(contentsOf: url) else { return [] }
        return ModelRecommendations.picks(from: models, for: HardwareProbe.current(), liveSizes: liveSizes)
    }

    // MARK: - Models folder

    var modelsFolder: String { ModelDiscovery.currentModelsRoot() }

    /// ModelCatalog rescans when this changes.
    func setModelsFolder(_ path: String) {
        // The App Store build reaches a folder outside its container only
        // once the user has granted it (adr/0018 §3); a no-op otherwise.
        guard SandboxAccess.requestAccess(to: path, message: NSLocalizedString("Allow LLMTray to use this folder for its models.", comment: "open panel: models folder access"))
        else { return }
        UserDefaults.standard.set(path, forKey: ModelDiscovery.modelsRootDefaultsKey)
    }

    static var lmStudioFolder: String { NSString(string: "~/.lmstudio/models").expandingTildeInPath }

    /// LM Studio's folder exists and holds at least one model LLMTray can
    /// load (a folder with a config.json).
    #if APP_STORE
    /// The App Store build names no other app (adr/0018 §5): no preset for
    /// its folder -- any folder can still be chosen.
    var lmStudioFolderHasModels: Bool { false }
    #else
    var lmStudioFolderHasModels: Bool { !ModelDiscovery.scanModels(root: Self.lmStudioFolder).isEmpty }
    #endif

    func useLMStudioFolder() { setModelsFolder(Self.lmStudioFolder) }
}
