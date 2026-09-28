import AppKit
import LLMTrayCore
import SwiftUI

/// Settings > Voice (adr/0016). Voice Lab is off by default; on, it shows
/// its model with the size and licence, Download / Remove, and what fits
/// in memory next to the chat model. Nothing is downloaded until asked.
struct VoicePane: View {
    @EnvironmentObject var server: ServerManager
    @ObservedObject private var store = VoiceModelStore.shared
    @ObservedObject private var session = VoiceLabSession.shared
    @ObservedObject private var runtime = AudioRuntime.shared
    @State private var error: String?
    @State private var hardware: HardwareInfo?
    @State private var chatBytes: Int64?
    @State private var partial = false
    @AppStorage(Pref.voiceLabMode) private var mode
    private var model: VoiceLabModel { store.selected }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.isEnabled) {
                    SettingLabel(title: "Voice Lab", help: "Talk with a local speech-to-speech model that listens and answers in its own voice, both at once, like a phone call. Experimental and English only: no tools, no projects, nothing kept.")
                }
                Text("Experimental — English only. The chat model is unloaded while Voice Lab runs, and reloads after.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Voice Lab")
            }
            if store.isEnabled {
                modelSection
                memorySection
                Section {
                    LabeledContent {
                        VoiceLabModePicker(mode: $mode)
                            .onChange(of: mode) { session.applyMode() }
                    } label: {
                        SettingLabel(title: "Mode", help: "Full duplex: talk any time, the model hears you while it speaks -- needs a Mac that runs it in real time. Walkie-talkie: talk, press Done, then listen. Automatic picks by this Mac's measured speed when Voice Lab starts.")
                    }
                    Label("Use headphones: the model hears its own voice from the speakers.", systemImage: "headphones")
                    if store.isDownloaded(model) {
                        Button("Open Voice Lab…") { NotificationCenter.default.post(name: .showVoiceLab, object: nil) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: "\(store.revision)-\(model.id)") {
            partial = store.hasPartialDownload(model)
        }
        .task(id: server.loadedModelPath) {
            hardware = HardwareProbe.current()
            let path = server.loadedModelPath ?? UserDefaults.standard[Pref.selectedModelID]
            chatBytes = path.map { ModelWeights.bytes(inFolder: $0) }
        }
    }

    private var modelSection: some View {
        Section("Model") {
            LabeledContent {
                Picker("", selection: $store.selected) {
                    ForEach(VoiceLabModel.all) { Text(verbatim: $0.displayName).tag($0) }
                }
                .labelsHidden()
                .disabled(store.isBusy || session.isActive)
            } label: {
                SettingLabel(title: "Voice model", help: "GPTQ 3-bit: IPSupport's build of the same model with a 3-bit language model -- smaller and faster, every test answer right. 4-bit: mlx-community's build. Each is downloaded only when you ask.")
            }
            LabeledContent {
                HStack {
                    Text(verbatim: statusText).foregroundStyle(.secondary).lineLimit(2)
                    if store.isBusy {
                        ProgressView().controlSize(.small)
                    } else if store.isDownloaded(model) {
                        Button("Remove", action: remove).disabled(session.isActive)
                    } else {
                        Button(partial ? "Resume Download" : "Download", action: download)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.displayName)
                    HStack(spacing: 4) {
                        Text(String(format: NSLocalizedString("Licence: %@", comment: "voice model licence"), model.licenseName))
                        Link("Model card", destination: model.cardURL)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.isBusy, let progress = store.progress {
                ProgressView(value: progress) {
                    Text(verbatim: "\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(verbatim: error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private var statusText: String {
        if store.isBusy, !store.statusText.isEmpty { return store.statusText }
        let size = ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)
        if store.isDownloaded(model) {
            return runtime.isInstalled
                ? String(format: NSLocalizedString("%@ · downloaded", comment: "voice model status: size"), size)
                : String(format: NSLocalizedString("%@ · downloaded; mlx-audio is installed at the first start", comment: "voice model status: size"), size)
        }
        return partial
            ? String(format: NSLocalizedString("%@ · partly downloaded", comment: "voice model status: size"), size)
            : String(format: NSLocalizedString("%@ · not downloaded", comment: "voice model status: size"), size)
    }

    @ViewBuilder
    private var memorySection: some View {
        if let hardware {
            let fit = VoiceMemoryFit(voiceBytes: model.footprintBytes, chatBytes: chatBytes,
                                     gpuLimitBytes: hardware.gpuLimitBytes, physicalMemoryBytes: hardware.physicalMemoryBytes)
            Section("Memory") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if fit.verdict == .tooBig {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(verbatim: Self.memoryText(fit)).fixedSize(horizontal: false, vertical: true)
                }
                if let command = fit.sysctlCommand {
                    HStack {
                        Text(verbatim: command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                    Text("Run it in Terminal to raise the GPU memory limit; it resets when the Mac restarts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func memoryText(_ fit: VoiceMemoryFit) -> String {
        let voice = GPUFit.gigabytes(fit.voiceBytes)
        let limit = fit.gpuLimitBytes.map { GPUFit.gigabytes(Int64(clamping: $0)) } ?? "?"
        let chat = fit.chatBytes.map { GPUFit.gigabytes($0) }
        switch fit.verdict {
        case .unknown:
            return String(format: NSLocalizedString("Voice Lab takes about %@ GB of memory while it runs.", comment: "voice memory: GB"), voice)
        case .fitsBesideChat:
            if let chat {
                return String(format: NSLocalizedString("Voice Lab takes about %1$@ GB; with the chat model's %2$@ GB it fits the %3$@ GB the GPU may use. The chat model is unloaded while it runs all the same.", comment: "voice memory: voice GB, chat GB, limit GB"), voice, chat, limit)
            }
            return String(format: NSLocalizedString("Voice Lab takes about %1$@ GB of the %2$@ GB the GPU may use.", comment: "voice memory: voice GB, limit GB"), voice, limit)
        case .fitsAlone:
            return String(format: NSLocalizedString("Voice Lab takes about %1$@ GB of the %2$@ GB the GPU may use -- not together with the chat model's %3$@ GB, so the chat model is unloaded while it runs.", comment: "voice memory: voice GB, limit GB, chat GB"), voice, limit, chat ?? "?")
        case .tooBig:
            return fit.suggestedWiredLimitMB != nil
                ? String(format: NSLocalizedString("Voice Lab takes about %1$@ GB, more than the %2$@ GB the GPU may use: raise the GPU memory limit first.", comment: "voice memory: voice GB, limit GB"), voice, limit)
                : String(format: NSLocalizedString("Voice Lab takes about %1$@ GB, more than the %2$@ GB the GPU may use on this Mac: it would run out of memory.", comment: "voice memory: voice GB, limit GB"), voice, limit)
        }
    }

    private func download() {
        error = nil
        Task {
            do { try await store.download(model) } catch { self.error = error.localizedDescription }
            partial = store.hasPartialDownload(model)
        }
    }

    private func remove() {
        error = nil
        Task {
            do { try await store.remove(model) } catch { self.error = error.localizedDescription }
        }
    }
}
