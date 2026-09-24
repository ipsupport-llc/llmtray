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
                Text("Sort by").font(.system(size: 11)).foregroundColor(.secondary)
                Picker("", selection: $browser.sortOption) {
                    ForEach(HFSortOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: browser.sortOption) { _ in browser.search() }
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
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .onAppear { catalog.refreshUsage() }

            if let err = browser.searchError {
                Text(err)
                    .font(.system(size: 11))
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
                                .font(.system(size: 12, weight: .medium))
                            if case .gated(let manual)? = browser.infoByID[model.id]?.access {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange)
                                    .help(Text(manual
                                        ? "Gated: request access on its Hugging Face page (the authors review it), and add a token in Settings → Models."
                                        : "Gated: accept its license on its Hugging Face page, and add a token in Settings → Models."))
                            }
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
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                    downloadControl(for: model)
                }
                .padding(.vertical, 2)
            }

            if let err = browser.downloadError {
                Text(err)
                    .font(.system(size: 11))
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
        .font(.system(size: 9))
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func downloadControl(for model: HFModelSummary) -> some View {
        if browser.downloadingID == model.id {
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
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        } else if ModelDiscovery.isDownloaded(repoID: model.id, root: ModelDiscovery.currentModelsRoot()) {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
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
        guard !browser.isPaused else { return "Paused" }
        guard browser.downloadSpeedBytesPerSec > 0 else { return browser.downloadStatusText }
        let speed = Self.byteFormatter.string(fromByteCount: Int64(browser.downloadSpeedBytesPerSec)) + "/s"
        guard let eta = browser.downloadETASeconds else { return speed }
        return "\(speed) · \(Self.formatETA(eta)) left"
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
