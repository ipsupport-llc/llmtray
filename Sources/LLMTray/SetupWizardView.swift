import AppKit
import LLMTrayCore
import SwiftUI

/// The setup wizard's window (adr/0013): not the popover, one at a time.
/// Closing it counts as done (SetupWizardModel.complete).
@MainActor
final class SetupWizardWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: SetupWizardModel?

    /// Open, minimized or not.
    var isOpen: Bool { window != nil }
    /// Once each time it closes (after the wizard's own close work).
    var onClose: (() -> Void)?

    /// Brings it up (already open: to the front). `automatic`: the first
    /// run, resumed where a relaunch left it; else from the settings now.
    func show(automatic: Bool, queue: DownloadQueue, server: ServerManager, startServer: @escaping () -> Void) {
        // Open (minimized too): that one, not a second wizard.
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SetupWizardModel(queue: queue, server: server, automatic: automatic, startServer: startServer,
                                     serverLog: { [weak server] in server?.appendLog($0) })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Set Up LLMTray", comment: "setup window title")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupWizardView(model: model).environmentObject(server))
        window.center()
        model.close = { [weak window] in window?.close() }
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        model?.complete()
        model = nil
        // The view goes now; the model lives on only while a runtime setup
        // it started is still running.
        closing.contentView = nil
        window = nil
        onClose?()
    }
}

extension SetupStep {
    var title: String {
        switch self {
        case .welcome: return NSLocalizedString("Welcome", comment: "setup step")
        case .yourMac: return NSLocalizedString("Your Mac", comment: "setup step")
        case .modelsFolder: return NSLocalizedString("Models folder", comment: "setup step")
        case .chatModel: return NSLocalizedString("Chat model", comment: "setup step")
        case .extras: return NSLocalizedString("What else", comment: "setup step")
        case .apps: return NSLocalizedString("Apps & agents", comment: "setup step")
        case .updates: return NSLocalizedString("Updates", comment: "setup step")
        case .done: return NSLocalizedString("Done", comment: "setup step")
        }
    }
}

@MainActor
struct SetupWizardView: View {
    @ObservedObject var model: SetupWizardModel

    var body: some View {
        VStack(spacing: 0) {
            SetupStepIndicator(current: model.step)
                .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 20)
            }
            Divider()
            buttons.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 680, height: 520)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .yourMac: YourMacStep(model: model)
        case .modelsFolder: ModelsFolderStep(model: model)
        case .chatModel: ChatModelStep(model: model)
        case .extras: ExtrasStep(model: model)
        case .apps: AppsStep(model: model)
        case .updates: UpdatesStep(model: model)
        case .done: DoneStep(model: model, queue: model.queue)
        }
    }

    /// Back on its own at the left, forward on the right: the next step's
    /// button is where Get Started was, Skip beside it.
    private var buttons: some View {
        HStack {
            if model.step == .welcome {
                Button("Skip Setup") { model.skip() }
                    .help(Text("Closes this window. Settings › General › Set Up LLMTray… opens it again."))
            } else if !model.isFinished {
                Button { model.back() } label: { Label("Back", systemImage: "chevron.backward") }
            }
            Spacer()
            if model.step != .welcome, model.step != .done {
                Button("Skip") { model.skip() }
                    .help(Text("Puts this step back to how it was when setup opened, and goes on."))
            }
            if model.step == .done {
                if model.isFinished {
                    Button("Close") { model.close?() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") { model.finish() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Button { model.next() } label: {
                    HStack(spacing: 4) {
                        model.step == .welcome ? Text("Get Started") : Text("Next")
                        Image(systemName: "chevron.forward")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The steps, the current one marked.
private struct SetupStepIndicator: View {
    let current: SetupStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SetupStep.allCases, id: \.self) { step in
                VStack(spacing: 4) {
                    Capsule()
                        .fill(step <= current ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                    Text(verbatim: step.title)
                        .font(.caption2)
                        .foregroundStyle(step == current ? .primary : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: step.title))
                .accessibilityAddTraits(step == current ? .isSelected : [])
            }
        }
    }
}

/// A heading and one plain line under it.
private struct StepHeader: View {
    let title: Text
    let subtitle: Text?

    init(_ title: Text, _ subtitle: Text? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            title.font(.title2.bold())
            if let subtitle {
                subtitle.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - 1 Welcome

private struct WelcomeStep: View {
    @ObservedObject var model: SetupWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let banner = Self.banner {
                Image(nsImage: banner)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .accessibilityLabel(Text("Welcome to LLMTray"))
            } else {
                StepHeader(Text("Welcome to LLMTray"))
            }
            VStack(alignment: .leading, spacing: 6) {
                capability("bubble.left.and.bubble.right", Text("Chat with language models that run on this Mac."))
                capability("photo", Text("Make images and edit them."))
                capability("music.note", Text("Make songs and instrumentals."))
                capability("terminal", Text("Let coding agents and scripts use your models."))
                capability("network", Text("An OpenAI-compatible API on localhost for other apps."))
            }
            Label {
                Text("Models run on this Mac. Your chats don't leave it; only the web tools, if you turn them on, reach the internet.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock")
            }
            .foregroundStyle(.secondary)
            Text("The next steps set up a model and the features you want. Each one can be skipped; nothing is downloaded or turned on unless you choose it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Before the server first starts: a port another app holds
            // would only show up later as a failed start.
            PortInUseNote(model: model, showsField: true)
        }
        .onAppear { model.checkPort() }
    }

    private func capability(_ symbol: String, _ text: Text) -> some View {
        Label { text } icon: { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
    }

    /// docs/assets/welcome-banner.jpg: in the app's Resources (build_app.sh
    /// copies it), or the repo's docs folder when run with `swift run`.
    static let banner: NSImage? = {
        if let url = Bundle.main.url(forResource: "welcome-banner", withExtension: "jpg"), let image = NSImage(contentsOf: url) {
            return image
        }
        guard let exe = Bundle.main.executablePath else { return nil }
        var dir = URL(fileURLWithPath: exe).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return NSImage(contentsOf: dir.appendingPathComponent("docs/assets/welcome-banner.jpg"))
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()
}

// MARK: - 2 Your Mac

private struct YourMacStep: View {
    @ObservedObject var model: SetupWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(Text("Your Mac"), Text("What decides which models run well here."))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Chip").foregroundStyle(.secondary)
                    Text(verbatim: model.hardware.chip ?? "—")
                }
                GridRow {
                    Text("Memory").foregroundStyle(.secondary)
                    Text(verbatim: Self.memory(model.hardware.physicalMemoryBytes))
                }
                GridRow {
                    Text("GPU memory limit").foregroundStyle(.secondary)
                    Text(verbatim: model.hardware.gpuLimitBytes.map(Self.memory) ?? "—")
                        .help(Text("How much memory the GPU may use. A model's files must fit under it."))
                }
                GridRow {
                    Text("Free disk space").foregroundStyle(.secondary)
                    Text(verbatim: model.modelsFolderFreeBytes.map(ModelCatalog.format) ?? "—")
                }
            }
            Divider()
            Text("The runtime").font(.headline)
            runtimeStatus
        }
        .onAppear { model.prepareRuntime() }
    }

    @ViewBuilder
    private var runtimeStatus: some View {
        switch model.runtime {
        case .unknown, .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking…") }
        case .installing:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(MLXRuntimeInstaller.isFullBuild ? "Copying the included runtime…" : "Setting up the runtime (mlx-lm). This takes a few minutes the first time.")
                }
                if !model.runtimeLine.isEmpty {
                    Text(verbatim: model.runtimeLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("It goes on in the background: you can continue.").font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label(MLXRuntimeInstaller.isFullBuild ? "Ready. This is the Full build: the runtime is included." : "Ready.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .noPython:
            VStack(alignment: .leading, spacing: 6) {
                Label("No Python 3.10 or newer was found.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("This version of LLMTray sets up its runtime with Python. Install Python from python.org or Homebrew, then check again. Or use LLMTray-Full, which includes everything it needs.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link(destination: URL(string: "https://www.python.org/downloads/macos/")!) { Text("python.org") }
                    Link(destination: URL(string: "https://github.com/ipsupport-llc/llmtray/releases/latest/download/LLMTray-Full.dmg")!) { Text("Download LLMTray-Full") }
                    Spacer()
                    Button("Check Again") { model.prepareRuntime() }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("The runtime couldn't be set up.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(verbatim: message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Open Server Log…") { NotificationCenter.default.post(name: .showServerLog, object: nil) }
                    Spacer()
                    Button("Try Again") { model.prepareRuntime() }
                }
            }
        }
    }

    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

// MARK: - 3 Models folder

private struct ModelsFolderStep: View {
    @ObservedObject var model: SetupWizardModel

    var body: some View {
        let folder = model.progress.choices.modelsFolder
        let found = model.models(in: folder)
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(Text("Models folder"), Text("Where LLMTray keeps its models, one folder per model."))
            Picker(selection: $model.progress.choices.modelsFolder) {
                Text(verbatim: abbreviated(model.defaultModelsFolder)).tag(model.defaultModelsFolder)
                if let lmStudio = model.lmStudioFolder {
                    Text(String(format: NSLocalizedString("%@ (LM Studio's, shared with it)", comment: "setup: models folder"), abbreviated(lmStudio)))
                        .tag(lmStudio)
                }
                if folder != model.defaultModelsFolder, folder != model.lmStudioFolder {
                    Text(verbatim: abbreviated(folder)).tag(folder)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.locksModelsFolder)
            Button("Choose Another Folder…") { model.chooseModelsFolder() }
                .disabled(model.locksModelsFolder)
            if model.isWizardDownloadActive {
                // The download goes on into the folder it started in.
                Text("The chat model is downloading into this folder. Change it in Settings after setup, or pick another chat model first.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.locksModelsFolder {
                // Finish selects the downloaded model from this folder.
                Text("The chat model you picked was downloaded into this folder. Change it in Settings after setup, or pick another chat model first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if found.isEmpty {
                Text("No models in this folder yet. The next step offers some to download.").foregroundStyle(.secondary)
            } else {
                Text(String(format: NSLocalizedString("Models found: %lld", comment: "setup: models folder"), found.count)).font(.headline)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(found.prefix(12)) { Text(verbatim: $0.displayName).font(.callout) }
                    if found.count > 12 {
                        Text(String(format: NSLocalizedString("and %lld more", comment: "setup: models folder"), found.count - 12))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

// MARK: - 4 Chat model

private struct ChatModelStep: View {
    @ObservedObject var model: SetupWizardModel
    @ObservedObject private var catalog = ModelCatalog.shared
    // The picked download's state (cancelled from the popover, done).
    @ObservedObject private var queue: DownloadQueue

    init(model: SetupWizardModel) {
        self.model = model
        queue = model.queue
    }

    /// Without the wizard's download while it's still coming in (its
    /// folder shows up before all its files are there).
    private var localModels: [LocalModel] {
        guard let repo = model.selectedDownloadRepo, !model.isWizardDownloadComplete else { return catalog.models }
        return catalog.models.filter { $0.path != catalog.root + "/" + repo }
    }

    /// A pick already complete here is listed with the local models, not
    /// offered for download again (completeness cached in the model).
    private var offer: ModelRecommendations.Offer {
        let complete = model.completePickFolders
        return ModelRecommendations.offer(model.picks, localPaths: localModels.map(\.path), isComplete: complete.contains)
    }

    /// What completeness depends on: the folders, the picks, the chat
    /// downloads' states (not their progress).
    private var localCopiesKey: [String] {
        catalog.models.map(\.path) + model.picks.map(\.model.repo)
            + queue.state.items.filter { $0.kind == .chatModel }.map { "\($0.target) \($0.status)" }
    }

    /// Picked here, or the wizard's download of it is in place.
    private func isSelected(_ local: LocalModel, _ offer: ModelRecommendations.Offer) -> Bool {
        if model.selectedLocalPath == local.path { return true }
        guard let repo = model.selectedDownloadRepo, model.isWizardDownloadComplete else { return false }
        return offer.local[local.path]?.model.repo == repo
    }

    var body: some View {
        let offer = self.offer
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(Text("A chat model"), Text("Pick one to chat with. A download starts right away and goes on in the background."))
            if !localModels.isEmpty {
                Text("Already on this Mac").font(.headline)
                ForEach(offer.ordered(localModels, path: \.path)) { local in
                    HStack {
                        Text(verbatim: local.displayName).lineLimit(1).truncationMode(.middle)
                        if offer.isRecommended(localPath: local.path) { RecommendedBadge() }
                        if let size = catalog.sizes[local.id] {
                            Text(verbatim: ModelCatalog.format(size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        if isSelected(local, offer) {
                            Label("Selected", systemImage: "checkmark").foregroundStyle(.green)
                        } else {
                            Button("Use") { model.pick(local: local) }
                        }
                    }
                }
                Divider()
            }
            Text("Download").font(.headline)
            if offer.downloads.isEmpty {
                if model.picks.isEmpty {
                    Text("No suggestions for this Mac's memory. Browse Hugging Face for a model.").foregroundStyle(.secondary)
                } else {
                    Text("The suggestions for this Mac are already here. Browse Hugging Face for another model.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(offer.downloads) { pick in
                pickRow(pick)
            }
            HStack {
                Button("Browse Hugging Face…") { model.browseHuggingFace() }
                Spacer()
            }
        }
        .onAppear {
            model.loadPicks()
            model.refreshLocalCopies(localPaths: catalog.models.map(\.path))
        }
        .onChange(of: localCopiesKey) { model.refreshLocalCopies(localPaths: catalog.models.map(\.path)) }
    }

    private func pickRow(_ pick: ModelRecommendations.Pick) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: pick.model.title).fontWeight(.semibold)
                    if pick.role == .recommended { RecommendedBadge() }
                }
                Text(verbatim: pick.model.summary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = roleNote(pick.role) {
                    note.font(.caption).foregroundStyle(pick.role == .larger ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: details(pick)).font(.caption).foregroundStyle(.secondary)
                if pick.model.gated {
                    Text("Gated: accept its license on Hugging Face and save a token in Settings › Models first.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if model.selectedDownloadRepo == pick.model.repo, model.isWizardDownloadComplete {
                Label("Downloaded", systemImage: "checkmark").foregroundStyle(.green)
            } else if model.selectedDownloadRepo == pick.model.repo, model.isWizardDownloadActive {
                VStack(alignment: .trailing, spacing: 2) {
                    Label("Downloading", systemImage: "arrow.down.circle").foregroundStyle(.green)
                    // How far it is (the queue's progress for this repo).
                    // The running one (a failed earlier try can still be listed).
                    if let item = queue.state.items.first(where: {
                        guard $0.kind == .chatModel, $0.target == pick.model.repo, case .running = $0.status else { return false }
                        return true
                    }), case .running(let progress?) = item.status {
                        ProgressView(value: progress).controlSize(.small).frame(width: 120)
                        Text(DownloadQueueRow.progressText(progress, of: item.approxBytes))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("Download") { model.pick(download: pick) }
                    .disabled(model.needsToken(pick))
            }
        }
        .padding(.vertical, 2)
    }

    /// Where a pick stands against this Mac's recommended model.
    private func roleNote(_ role: ModelRecommendations.Pick.Role) -> Text? {
        switch role {
        case .recommended, .alternative: return nil
        case .lighter: return Text("Lighter than the recommended one: faster and leaves memory to other apps, but its answers are simpler.")
        case .larger: return Text("Bigger than the recommended one: better answers, but slower, with less memory left for other apps.")
        case .forCode: return Text("Made for programming and agents: coding tools and the OpenAI API.")
        }
    }

    private func details(_ pick: ModelRecommendations.Pick) -> String {
        var parts = [ModelCatalog.format(pick.sizeBytes)]
        if pick.fit == .tight { parts.append(NSLocalizedString("tight fit", comment: "setup: model fit")) }
        parts += pick.model.capabilities.map(ModelCapabilities.name)
        if let license = pick.model.license { parts.append(license) }
        return parts.joined(separator: " · ")
    }
}

private struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended").font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}

// MARK: - 5 What else

private struct ExtrasStep: View {
    @ObservedObject var model: SetupWizardModel

    private var choices: Binding<SetupChoices> { $model.progress.choices }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(Text("What else"), Text("All off unless you turn them on. Models are downloaded after Finish, one at a time."))
            feature(isOn: Binding(get: { model.progress.choices.imageModel != nil },
                                  set: { model.progress.choices.imageModel = $0 ? model.imagePick.rawValue : nil }),
                    title: Text("Image generation"),
                    detail: Text("The model can make an image when you ask for one."),
                    size: model.imageModelSize(model.imagePick), fit: model.imageFit(model.imagePick)) {
                Picker("", selection: Binding(get: { model.imagePick }, set: { pick in
                    guard SetupWizardModel.fits(model.imageFit(pick)) else { return }
                    model.imagePick = pick
                    if model.progress.choices.imageModel != nil { model.progress.choices.imageModel = pick.rawValue }
                })) {
                    ForEach(ImageGenModel.selectable) {
                        Text(verbatim: $0.displayName).tag($0).disabled(!SetupWizardModel.fits(model.imageFit($0)))
                    }
                }
                .labelsHidden().frame(maxWidth: 340)
            }
            feature(isOn: Binding(get: { model.progress.choices.editModel != nil },
                                  set: { model.progress.choices.editModel = $0 ? ImageGenModel.klein4b.rawValue : nil }),
                    title: Text("Image editing"),
                    detail: Text("Changes an image you attach or one made in the chat, with FLUX.2 klein 4B."),
                    size: model.imageModelSize(.klein4b), fit: model.editFit(.klein4b))
            feature(isOn: Binding(get: { model.progress.choices.musicModel != nil },
                                  set: { model.progress.choices.musicModel = $0 ? model.musicPick.rawValue : nil }),
                    title: Text("Music"),
                    detail: Text("A song with sung lyrics, or an instrumental, from a description (ACE-Step 1.5)."),
                    size: model.musicModelSize(model.musicPick), fit: model.musicFit(model.musicPick)) {
                Picker("", selection: Binding(get: { model.musicPick }, set: { pick in
                    guard SetupWizardModel.fits(model.musicFit(pick)) else { return }
                    model.musicPick = pick
                    if model.progress.choices.musicModel != nil { model.progress.choices.musicModel = pick.rawValue }
                })) {
                    ForEach(MusicManager.selectable) {
                        Text(verbatim: $0.displayName).tag($0).disabled(!SetupWizardModel.fits(model.musicFit($0)))
                    }
                }
                .labelsHidden().frame(maxWidth: 340)
            }
            feature(isOn: choices.creatorMode,
                    title: Text("Creator mode"),
                    detail: Text("Before an image or song is made, shows the prompt and settings to change first. It goes ahead after the countdown unless you touch it."),
                    size: nil) {
                Stepper(value: choices.creatorCountdown, in: 0...30) {
                    Text(String(format: NSLocalizedString("Countdown: %lld s", comment: "setup: creator mode"), model.progress.choices.creatorCountdown))
                }
                .fixedSize()
                .disabled(!model.progress.choices.creatorMode)
            }
            feature(isOn: choices.webTools,
                    title: Text("Web tools"),
                    detail: Text("Web search, news, Wikipedia, weather and more. The model's queries go to those services."),
                    size: nil, usesInternet: true)
            if let embedder = model.embedderDescription {
                feature(isOn: choices.projectFiles,
                        title: Text("Project files"),
                        detail: Text("Files you add to a project are indexed on this Mac, so its chats can search them."),
                        size: embedder)
            }
            // Folder access (adr/0014) joins here once it's merged.
        }
    }

    private func feature(isOn: Binding<Bool>, title: Text, detail: Text, size: String?, usesInternet: Bool = false,
                         fit: FeatureFit? = nil) -> some View {
        feature(isOn: isOn, title: title, detail: detail, size: size, usesInternet: usesInternet, fit: fit) { EmptyView() }
    }

    /// `fit`: the model's memory on this Mac -- one that doesn't fit can't
    /// be turned on (only off), a tight one is on offer with the warning.
    private func feature<Extra: View>(isOn: Binding<Bool>, title: Text, detail: Text, size: String?, usesInternet: Bool = false,
                                      fit: FeatureFit? = nil, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                HStack(spacing: 6) {
                    title.fontWeight(.semibold)
                    if let size { Text(verbatim: size).font(.caption).foregroundStyle(.secondary) }
                    if usesInternet {
                        Label("Uses the internet", systemImage: "globe").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .disabled(!isOn.wrappedValue && !SetupWizardModel.fits(fit))
            detail.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
            MemoryFitNote(fit: fit).padding(.leading, 20)
            extra().padding(.leading, 20)
        }
    }
}

// MARK: - 6 Apps and agents

private struct AppsStep: View {
    @ObservedObject var model: SetupWizardModel
    // Re-rendered when the server starts or stops (the locked fields).
    @EnvironmentObject private var server: ServerManager

    var body: some View {
        let editable = model.canEditNetwork
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(Text("Apps and agents"), Text("Other apps reach your models through an OpenAI-compatible API on this Mac."))
            LabeledContent("Port") {
                TextField("", value: $model.progress.choices.port, format: .number.grouping(.never))
                    .frame(width: 80).disabled(!editable)
            }
            // The field above picks any port; the note offers a free one.
            PortInUseNote(model: model, showsField: false)
            Toggle(isOn: $model.progress.choices.allowLAN) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow connections from the local network")
                    Text("Off: only this Mac. On: anyone on your network, so only on networks you trust.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!editable)
            if !editable {
                Text("Stop the server to change these.").font(.caption).foregroundStyle(.secondary)
            }
            Picker(selection: $model.progress.choices.modelSwitchPolicy) {
                Text("Switch at once").tag(ModelSwitchPolicy.auto.rawValue)
                Text("Ask first").tag(ModelSwitchPolicy.ask.rawValue)
                Text("Keep the loaded model").tag(ModelSwitchPolicy.keep.rawValue)
            } label: {
                Text("When an app asks for another model")
            }
            .fixedSize()
            Text("Switching unloads the loaded model. Ask first shows a notification; Keep sends the app an error that names the loaded model.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Point an app or agent at LLMTray:")
            HStack {
                Text(verbatim: model.baseURLSnippet)
                    .font(.body.monospaced()).textSelection(.enabled)
                    .padding(6).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                Button("Copy") { model.copySnippet() }
            }
            Text("No API key is needed; if an app asks for one, any text works.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { model.checkPort() }
        .onChange(of: model.progress.choices.port) { model.checkPort() }
        .onChange(of: model.canEditNetwork) { model.checkPort() }
        .onChange(of: model.progress.choices.allowLAN) { model.checkPort() }
    }
}

/// The chosen port is already held by another app, or out of range: says
/// so, with the next free port one click away, Use Anyway for a check that
/// may be wrong and (`showsField`, where there's no port field of the
/// step's own) any other port to type in.
private struct PortInUseNote: View {
    @ObservedObject var model: SetupWizardModel
    let showsField: Bool
    @State private var candidate = Pref.port.defaultValue

    var body: some View {
        if let problem = model.portProblem {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(message(problem)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    if let free = model.freePort {
                        Button(String(format: NSLocalizedString("Use %lld", comment: "setup: use this free port"), free)) { model.usePort(free) }
                    }
                    if showsField {
                        TextField("", value: $candidate, format: .number.grouping(.never))
                            .frame(width: 70)
                        Stepper("", value: $candidate, in: PortCheck.validRange).labelsHidden()
                        Button("Use This Port") { model.usePort(candidate) }
                            .disabled(!PortCheck.validRange.contains(candidate) || problem == .inUse(candidate))
                    }
                    if case .inUse = problem {
                        Button("Use Anyway") { model.usePortAnyway() }
                            .help(Text("Keeps this port. If another app really has it, the server won't start until you change the port in Settings."))
                    }
                }
                .padding(.leading, 22)
            }
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .onAppear { candidate = Self.clamped(model.freePort ?? port(problem) + 1) }
            .onChange(of: model.freePort) { candidate = Self.clamped($1 ?? candidate) }
        }
    }

    private func message(_ problem: SetupWizardModel.PortProblem) -> String {
        switch problem {
        case .inUse(let port):
            return String(format: NSLocalizedString("Port %lld is already used by another app, so LLMTray's server can't start on it. Choose another port.", comment: "setup: port in use"), port)
        case .outOfRange(let port):
            return String(format: NSLocalizedString("Port %1$lld is out of range: choose one from %2$lld to %3$lld.", comment: "setup: port out of range"),
                          port, PortCheck.validRange.lowerBound, PortCheck.validRange.upperBound)
        }
    }

    private func port(_ problem: SetupWizardModel.PortProblem) -> Int {
        switch problem {
        case .inUse(let port), .outOfRange(let port): return port
        }
    }

    private static func clamped(_ port: Int) -> Int {
        min(max(port, PortCheck.validRange.lowerBound), PortCheck.validRange.upperBound)
    }
}

// MARK: - 7 Staying up to date

private struct UpdatesStep: View {
    @ObservedObject var model: SetupWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(Text("Staying up to date"))
            Toggle(isOn: $model.progress.choices.launchAtLogin) {
                Text("Open LLMTray when you log in")
            }
            Toggle(isOn: $model.progress.choices.automaticUpdateChecks) {
                Text("Check for updates automatically")
            }
            Toggle(isOn: $model.progress.choices.checkUpdatesAtLaunch) {
                Text("Also check when LLMTray starts")
            }
            Picker(selection: $model.progress.choices.betaUpdates) {
                Text("Stable").tag(false)
                Text("Beta").tag(true)
            } label: {
                Text("Update channel")
            }
            .pickerStyle(.segmented).fixedSize()
            Text("Beta: pre-release builds with features still being tested.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle(isOn: $model.progress.choices.usageStatistics) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share anonymous usage statistics")
                    Text("Send an anonymous daily report: app and macOS version, chip, memory size, language, which features you used and the families of the models (never their names). No prompts, content, files or model names ever leave your Mac. You can turn this off at any time in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Show Reports…") { TelemetryReportWindow.show() }
                .buttonStyle(.link)
                .padding(.leading, 20)
        }
    }
}

// MARK: - 8 Done

private struct DoneStep: View {
    @ObservedObject var model: SetupWizardModel
    @ObservedObject var queue: DownloadQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isFinished {
                StepHeader(Text("Almost done"), Text("Some settings couldn't be changed:"))
                ForEach(model.finishErrors, id: \.self) { Text(verbatim: $0).foregroundStyle(.red) }
            } else {
                StepHeader(Text("Done"), Text("Finish applies what you chose. You can change all of it later in Settings."))
                // Finish stops here while the port is taken (SetupWizardModel.finish).
                PortInUseNote(model: model, showsField: true)
                let lines = model.summaryLines
                if lines.isEmpty && model.summaryDownloads.isEmpty && queue.state.items.isEmpty {
                    Text("Nothing to change.").foregroundStyle(.secondary)
                }
                ForEach(lines, id: \.self) { line in Label { Text(verbatim: line) } icon: { Image(systemName: "checkmark") } }
            }
            let downloading = queue.state.items.filter { $0.status != .cancelled }
            let queued = model.isFinished ? [] : model.summaryDownloads
            if !downloading.isEmpty || !queued.isEmpty {
                Divider()
                Text("Downloads").font(.headline)
                ForEach(downloading) { item in
                    Label { Text(verbatim: "\(DownloadQueue.name(of: item)) · \(status(item))") } icon: { Image(systemName: "arrow.down.circle") }
                }
                ForEach(queued, id: \.self) { line in
                    Label { Text(verbatim: line) } icon: { Image(systemName: "clock") }
                }
                Text("They run one at a time, shown in the menu bar's window. You can close this window meanwhile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if !model.isFinished { model.checkPort() } }
    }

    private func status(_ item: DownloadQueueState.Item) -> String {
        switch item.status {
        case .pending: return NSLocalizedString("waiting", comment: "download status")
        case .running(let progress):
            return progress.map { "\(Int($0 * 100)) %" }
                ?? NSLocalizedString("downloading", comment: "download status")
        case .done: return NSLocalizedString("done", comment: "download status")
        case .failed(let message): return String(format: NSLocalizedString("failed: %@", comment: "download status"), message)
        case .cancelled: return NSLocalizedString("cancelled", comment: "download status")
        }
    }
}
