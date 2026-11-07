import AVFoundation
import AppKit
import LLMTrayCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Voice > Spoken answers (adr/0016): read answers aloud, the
/// voice (macOS's or Chatterbox), Chatterbox's download and its voice clip.
struct SpokenAnswersSection: View {
    @ObservedObject private var spoken = SpokenAnswers.shared
    @ObservedObject private var store = SpokenVoiceStore.shared
    @State private var error: String?
    @State private var clipWarning: String?

    var body: some View {
        Section {
            Toggle(isOn: $spoken.readsAloud) {
                SettingLabel(title: "Read answers aloud", help: "Each new answer is spoken sentence by sentence while it's written. Code, tables and links aren't read out. Speak under any answer reads that one; the speaker button above the message field turns this on and off.")
            }
            LabeledContent {
                Picker("", selection: $spoken.voiceKind) {
                    Text("System").tag(SpokenVoiceKind.system)
                    Text(verbatim: "Chatterbox").tag(SpokenVoiceKind.chatterbox)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            } label: {
                SettingLabel(title: "Voice", help: "System: the macOS voice for the answer's language, nothing to download (more voices in System Settings > Accessibility > Spoken Content). Chatterbox: a natural neural voice in 23 languages, Russian among them, that can imitate a voice from a short clip; runs on this Mac.")
            }
            if spoken.voiceKind == .chatterbox {
                chatterbox
            }
            if let note = spoken.note {
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Spoken answers")
        }
    }

    @ViewBuilder
    private var chatterbox: some View {
        let _ = store.revision
        let ready = SpokenVoiceStore.isReady
        LabeledContent {
            HStack(spacing: 8) {
                if store.isBusy {
                    if let progress = store.progress {
                        ProgressView(value: progress).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if ready {
                    Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    Button("Remove") { remove() }
                } else {
                    Button(store.hasPartialDownload ? "Resume Download" : "Download") { download() }
                    if store.hasAnything { Button("Remove") { remove() } }
                }
            }
        } label: {
            SettingLabel(title: "Chatterbox Multilingual V3 (8-bit)",
                         help: LocalizedStringKey(String(format: NSLocalizedString("The model, its speech tokenizer and the Russian stress dictionary: %@ in the models folder. Chatterbox (Resemble AI) and ruaccent are MIT-licensed; the speech tokenizer, from CosyVoice2, is Apache-2.0.", comment: "spoken answers: download size"),
                                       ByteCountFormatter.string(fromByteCount: SpokenVoiceFile.totalDownloadBytes, countStyle: .file))))
        }
        if store.isBusy, !store.statusText.isEmpty {
            Text(store.statusText).font(.caption).foregroundStyle(.secondary)
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        LabeledContent {
            HStack(spacing: 8) {
                Text(spoken.clipPath == nil ? NSLocalizedString("Built-in", comment: "spoken answers: Chatterbox's own voice")
                                            : NSLocalizedString("From a clip", comment: "spoken answers: a voice imitated from a clip"))
                    .foregroundStyle(.secondary)
                Button("Choose Clip…") { chooseClip() }
                if spoken.clipPath != nil {
                    Button("Use Built-in") { setClip(nil) }
                }
            }
        } label: {
            SettingLabel(title: "Voice clip", help: "Chatterbox imitates the voice in a clip of 5 to 30 seconds (10 or more is best): clear speech, one speaker, no music. The clip is copied into LLMTray's folder and never leaves this Mac.")
        }
        Text("Use your own voice, or a voice you have permission to use.")
            .font(.caption).foregroundStyle(.secondary)
        if let clipWarning {
            Text(clipWarning).font(.caption).foregroundStyle(.orange)
        }
    }

    private func download() {
        error = nil
        Task {
            do { try await store.download() } catch { self.error = error.localizedDescription }
        }
    }

    private func remove() {
        error = nil
        Task {
            do { try await store.remove() } catch { self.error = error.localizedDescription }
        }
    }

    private func chooseClip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mpeg4Audio, .mp3, .aiff, .audio]
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Choose a clip of 5 to 30 seconds: your own voice, or one you have permission to use.", comment: "spoken answers")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            switch VoiceClipCheck.verdict(seconds: seconds) {
            case .tooShort:
                clipWarning = String(format: NSLocalizedString("The clip is %.0f s: at least 5 s are needed.", comment: "spoken answers"), seconds)
            case .tooLong:
                clipWarning = String(format: NSLocalizedString("The clip is %.0f s: 30 s at most -- cut it shorter.", comment: "spoken answers"), seconds)
            case .short:
                setClip(url)
                clipWarning = NSLocalizedString("A clip under 10 s works, but 10 s or more imitates the voice better.", comment: "spoken answers")
            case .ok:
                setClip(url)
                clipWarning = nil
            }
        }
    }

    private func setClip(_ url: URL?) {
        do {
            try spoken.setClip(url)
            if url == nil { clipWarning = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
