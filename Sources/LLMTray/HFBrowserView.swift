import SwiftUI

struct HFBrowserView: View {
    @ObservedObject var browser: HFModelBrowser

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
            .padding(12)

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
                        Text(model.id)
                            .font(.system(size: 12, weight: .medium))
                        if let downloads = model.downloads {
                            Text("\(downloads) downloads")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
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
                    Button {
                        browser.cancelDownload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
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
            Button("Download") {
                browser.download(model) {
                    NotificationCenter.default.post(name: .modelsDidChange, object: model.id)
                }
            }
            .disabled(browser.downloadingID != nil)
        }
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
