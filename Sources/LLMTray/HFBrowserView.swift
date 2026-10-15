import LLMTrayCore
import SwiftUI

struct HFBrowserView: View {
    @ObservedObject var browser: HFModelBrowser
    @ObservedObject private var catalog = ModelCatalog.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search Hugging Face (mlx models)…", text: $browser.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { browser.search() }
                Button("Search") {
                    browser.search()
                }
                .disabled(browser.query.trimmingCharacters(in: .whitespaces).isEmpty || browser.isSearching)
            }
            .padding([.horizontal, .top], 12)

            HStack(spacing: 6) {
                Text("Sort by").font(.subheadline).foregroundColor(.secondary)
                Picker("", selection: $browser.sortOption) {
                    ForEach(HFSortOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: browser.sortOption) { browser.search() }
                Spacer()
                fitLegend
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            HStack {
                Image(systemName: "internaldrive").foregroundColor(.secondary)
                Text(diskLine).monospacedDigit()
                Spacer()
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .onAppear { catalog.refreshUsage() }

            if let err = browser.searchError {
                Text(err)
                    .font(.subheadline)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
            }

            if browser.isSearching {
                ProgressView().padding()
            }

            List(browser.results) { model in
                HStack {
                    Button {
                        browser.showModelCard(for: model.id)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .help("View model card")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if let size = browser.sizesByID[model.id] {
                                fitDot(for: size)
                            }
                            Text(model.id)
                                .font(.callout.weight(.medium))
                            if case .gated(let manual)? = browser.infoByID[model.id]?.access {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange)
                                    .help(Text(manual
                                        ? "Gated: request access on its Hugging Face page (the authors review it), and add a token in Settings → Models."
                                        : "Gated: accept its license on its Hugging Face page, and add a token in Settings → Models."))
                            }
                        }
                        if let family = ModelDiscovery.mtpDrafters[model.id] {
                            // Not a chat model: a drafter LLMTray pairs with
                            // its model by itself (speculative decoding).
                            Label(String(format: NSLocalizedString("MTP drafter: speeds up %@, same answers", comment: "HF browser: a drafter model's role"), family),
                                  systemImage: "bolt.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                        HStack(spacing: 4) {
                            if let downloads = model.downloads {
                                Text("\(downloads) downloads")
                            }
                            if let size = browser.sizesByID[model.id] {
                                Text("·")
                                Text(Self.byteFormatter.string(fromByteCount: size))
                            } else {
                                Text("· size…")
                            }
                            if let info = browser.infoByID[model.id], let license = info.license {
                                Text("·")
                                // The license is the publisher's: shown before a
                                // download, non-commercial ones flagged.
                                Text(verbatim: license)
                                    .foregroundColor(info.isNonCommercial ? .orange : .secondary)
                                    .help(Text(info.isNonCommercial ? "Non-commercial license: read it on the model card before using the model." : "The model's license, from its card."))
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                    downloadControl(for: model)
                }
                .padding(.vertical, 2)
            }

            if let err = browser.downloadError {
                Text(err)
                    .font(.subheadline)
                    .foregroundColor(.red)
                    .padding(12)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .sheet(isPresented: Binding(
            get: { browser.modelCardID != nil },
            set: { if !$0 { browser.dismissModelCard() } }
        )) {
            ModelCardView(browser: browser)
        }
    }

    private func fitDot(for sizeBytes: Int64) -> some View {
        let level = ModelFitLevel.estimate(sizeBytes: sizeBytes, physicalMemoryBytes: browser.physicalMemoryBytes)
        return Circle()
            .fill(level.color)
            .frame(width: 7, height: 7)
            .help(level.label)
    }

    private var fitLegend: some View {
        HStack(spacing: 8) {
            ForEach([ModelFitLevel.fits, .tight, .unlikely], id: \.label) { level in
                HStack(spacing: 3) {
                    Circle().fill(level.color).frame(width: 6, height: 6)
                    Text(level.label.components(separatedBy: " -- ").first ?? level.label)
                }
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func downloadControl(for model: HFModelSummary) -> some View {
        if let family = ModelDiscovery.mtpDrafters[model.id] {
            DrafterControl(repo: model.id, family: family)
        } else if let media = MediaModels.entry(repo: model.id) {
            // An image, music or voice model: its own manager downloads it,
            // into the models folder, with what it needs to run.
            MediaDownloadControl(entry: media)
        } else if browser.downloadingID == model.id {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    ProgressView(value: browser.downloadProgress)
                        .frame(width: 100)
                    Button {
                        if browser.isPaused {
                            browser.resumeDownload()
                        } else {
                            browser.pauseDownload()
                        }
                    } label: {
                        Image(systemName: browser.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.plain)
                    .help(browser.isPaused ? "Resume download" : "Pause download")
                    .accessibilityLabel(browser.isPaused ? "Resume download" : "Pause download")
                    Button {
                        browser.cancelDownload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Cancel download")
                    .accessibilityLabel("Cancel download")
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else if ModelDiscovery.isDownloaded(repoID: model.id, root: ModelDiscovery.currentModelsRoot()) {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundColor(.secondary)
        } else {
            let tooBig = browser.sizesByID[model.id].map { size in catalog.freeBytes.map { size > $0 } ?? false } ?? false
            Button("Download") {
                browser.download(model) {
                    NotificationCenter.default.post(name: .modelsDidChange, object: model.id)
                }
            }
            .disabled(browser.downloadingID != nil || tooBig)
            .help(Text(tooBig ? "Not enough free disk space for this model." : "Download into the models folder"))
        }
    }

    private var diskLine: String {
        let free = catalog.freeBytes.map(ModelCatalog.format) ?? "…"
        return String(format: NSLocalizedString("Free on disk: %@ · your models: %@", comment: "HF browser: free space, size of installed models"), free, ModelCatalog.format(catalog.totalBytes))
    }

    private var statusLine: String {
        guard !browser.isPaused else { return NSLocalizedString("Paused", comment: "") }
        guard browser.downloadSpeedBytesPerSec > 0 else { return browser.downloadStatusText }
        let speed = Self.byteFormatter.string(fromByteCount: Int64(browser.downloadSpeedBytesPerSec)) + "/s"
        guard let eta = browser.downloadETASeconds else { return speed }
        return String(format: NSLocalizedString("%@ · %@ left", comment: "download speed, time left"), speed, Self.formatETA(eta))
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    private static func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m \(s % 60)s" }
        let h = m / 60
        return "\(h)h \(m % 60)m"
    }
}


/// The Hugging Face browser's control for an image, music or voice model
/// (MediaModels): installed, downloading (its manager's status), or a
/// Download through that manager -- never into the chat models' path.
private struct MediaDownloadControl: View {
    let entry: MediaModels.Entry
    @ObservedObject private var mflux = ChatTabs.shared.mflux
    @ObservedObject private var music = ChatTabs.shared.music
    @ObservedObject private var voice = VoiceModelStore.shared
    @State private var running = false
    @State private var error: String?

    private var busy: Bool {
        switch entry.kind {
        case .image: return mflux.isBusy
        case .music: return music.isBusy
        case .voice: return voice.isBusy
        }
    }

    private var status: String {
        switch entry.kind {
        case .image: return mflux.statusText
        case .music: return music.statusText
        case .voice: return voice.statusText
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status.isEmpty ? NSLocalizedString("Downloading…", comment: "") : status)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            } else if MediaModels.isReady(entry) {
                Label(String(format: NSLocalizedString("Installed · %@", comment: "HF browser: a media model installed, its kind"), entry.kind.title),
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Button("Download") { start() }
                    .disabled(busy)
                    .help(Text(String(format: NSLocalizedString("Download for %@, into the models folder", comment: "HF browser: a media model's download, its kind"),
                                      entry.kind.title)))
            }
            if let error {
                Text(error).font(.caption).foregroundColor(.red).lineLimit(2)
            }
        }
    }

    private func start() {
        running = true
        error = nil
        Task { @MainActor in
            defer { running = false }
            do {
                switch entry.kind {
                case .image:
                    guard let m = ImageGenModel.allCases.first(where: { MediaModels.entry($0) == entry }) else { return }
                    try await mflux.downloadModel(m)
                case .music:
                    guard let m = MusicModel.allCases.first(where: { MediaModels.entry($0) == entry }) else { return }
                    try await music.download(m)
                case .voice:
                    guard let m = VoiceLabModel.all.first(where: { MediaModels.entry($0) == entry }) else { return }
                    try await voice.download(m)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A drafter's row (ModelDiscovery.mtpDrafters): installed in the Hugging
/// Face cache, where the runtime takes it from -- not the models folder --
/// with the installed models it speeds up; fetched there when one of them
/// is installed and it isn't yet.
private struct DrafterControl: View {
    let repo: String
    let family: String
    @ObservedObject private var catalog = ModelCatalog.shared
    @State private var fetching = false
    @State private var error: String?
    @State private var installed = false

    private var users: [LocalModel] {
        catalog.models.filter { !$0.isAppleSystem && ModelDiscovery.mtpDrafterRepo(forModelPath: $0.path) == repo }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if installed {
                Label("Installed", systemImage: "bolt.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .help(Text(users.isEmpty
                        ? String(format: NSLocalizedString("In the Hugging Face cache; used once a %@ model is installed.", comment: ""), family)
                        : String(format: NSLocalizedString("Used by %@.", comment: "HF browser: models a drafter speeds up"),
                                 users.map(\.displayName).joined(separator: ", "))))
            } else if users.isEmpty {
                Text(String(format: NSLocalizedString("Comes with %@", comment: "HF browser: a drafter without its model"), family))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help(Text("LLMTray fetches it with the model it speeds up: download that model."))
            } else {
                Button(fetching ? "Getting…" : "Get") {
                    fetching = true
                    error = nil
                    Task {
                        error = await MTPDrafterDownload.fetch(repo)
                        fetching = false
                        refresh()
                    }
                }
                .disabled(fetching)
                .help(Text(String(format: NSLocalizedString("Speeds up %@: fetched where LLMTray loads it from.", comment: ""),
                                  users.map(\.displayName).joined(separator: ", "))))
            }
            if let error {
                Text(error).font(.caption).foregroundColor(.red).lineLimit(2)
            }
        }
        .onAppear(perform: refresh)
        // Fetched elsewhere meanwhile (a server start, the download queue),
        // or its model added or removed: the row follows.
        .onChange(of: catalog.models) { _, _ in refresh() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        let now = HFHubCache.localSnapshot(repo: repo) != nil
        if now != installed { installed = now }
    }
}
