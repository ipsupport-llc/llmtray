import LLMTrayCore
import SwiftUI

extension Notification.Name {
    /// The composer's voice button: start a voice conversation in the
    /// chat that's the notification's object (adr/0031).
    static let startVoiceConversation = Notification.Name("llmtray.startVoiceConversation")
}

/// The voice conversation over the chat area (adr/0031): an orb that
/// reacts to both voices, its state, and live captions -- the user's words
/// as recognized, the answer's sentences as they play.
struct VoiceConversationView: View {
    @ObservedObject var voice: VoiceConversation
    let modelName: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Voice conversation", systemImage: "waveform.circle.fill").font(.headline)
                Spacer()
                Text(verbatim: modelName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if case .failed(let message) = voice.phase {
                failure(message)
            } else {
                Spacer(minLength: 8)
                VoiceOrb(phase: voice.phase, level: voice.level)
                Text(stateText).font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.top, 2)
                Spacer(minLength: 14)
                captions.padding(.horizontal, 28).frame(maxWidth: 600)
                Spacer(minLength: 16)
            }
            HStack(spacing: 14) {
                Text("Esc ends the conversation").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if case .failed = voice.phase { voice.dismiss() } else { voice.stop() }
                } label: {
                    Label(isFailed ? "Close" : "End", systemImage: "stop.circle")
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var isFailed: Bool {
        if case .failed = voice.phase { return true }
        return false
    }

    private var stateText: String {
        switch voice.phase {
        case .starting(let text): return text
        case .listening: return NSLocalizedString("Listening", comment: "voice conversation state")
        case .hearing: return NSLocalizedString("Hearing you", comment: "voice conversation state")
        case .thinking: return NSLocalizedString("Thinking", comment: "voice conversation state")
        case .speaking: return NSLocalizedString("Speaking", comment: "voice conversation state")
        case .off, .failed: return ""
        }
    }

    @ViewBuilder
    private var captions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !voice.userText.isEmpty {
                caption(NSLocalizedString("You", comment: "voice conversation caption"), voice.userText, dim: false)
            }
            if !voice.heard.isEmpty {
                caption("LLMTray", voice.heard.suffix(3).joined(separator: " "), dim: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ who: String, _ text: String, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: who).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(verbatim: text).font(.title3).foregroundStyle(dim ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
            Text(verbatim: message).multilineTextAlignment(.center).frame(maxWidth: 440)
            SettingsLink { Text("Open Settings") }
            Spacer()
        }
        .padding(24)
    }
}

/// The orb: rings that breathe with the microphone, a glyph per state.
struct VoiceOrb: View {
    let phase: VoiceConversation.Phase
    let level: Float

    var body: some View {
        let l = CGFloat(phase == .speaking ? 0.6 : min(1, level * 1.4))
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(Color.accentColor.opacity(0.18 - Double(i) * 0.05), lineWidth: 2)
                    .frame(width: 150 + CGFloat(i) * 34 + l * CGFloat(i + 1) * 12)
            }
            Circle()
                .fill(RadialGradient(colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.55)],
                                     center: .init(x: 0.38, y: 0.32), startRadius: 4, endRadius: 90))
                .frame(width: 132 + l * 16)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 24)
            glyph
        }
        .frame(height: 250)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch phase {
        case .thinking, .starting:
            HStack(spacing: 7) { ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.9)).frame(width: 9) } }
        case .speaking:
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.92))
        default:
            Image(systemName: "waveform").font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.92))
        }
    }
}

/// Settings > Voice > Voice conversation (adr/0031).
struct VoiceConversationSection: View {
    @ObservedObject private var store = VoiceInputStore.shared
    @AppStorage(Pref.voiceFillers) private var fillers
    @AppStorage(Pref.voiceSendAudio) private var sendAudio
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent {
                Picker("", selection: $store.recognizer) {
                    Text(verbatim: "Parakeet").tag(VoiceRecognizer.parakeet)
                    Text(verbatim: "Whisper").tag(VoiceRecognizer.whisper)
                    Text(verbatim: "macOS").tag(VoiceRecognizer.apple)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            } label: {
                SettingLabel(title: "Speech recognition", help: "Parakeet: fast, 25 European languages including Russian (2.5 GB). Whisper: 99 languages, slower (1.6 GB). macOS: no download, but only languages macOS recognizes on this Mac without the internet, and only with Dictation on. Nothing you say leaves this Mac.")
            }
            let _ = store.revision
            LabeledContent {
                HStack(spacing: 8) {
                    if store.isBusy {
                        if let p = store.progress { ProgressView(value: p).frame(width: 120) } else { ProgressView().controlSize(.small) }
                    } else if store.isReady {
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        if store.recognizer != .apple { Button("Remove") { remove() } }
                    } else {
                        Button(String(format: NSLocalizedString("Download (%@)", comment: "voice conversation: size"),
                                      ByteCountFormatter.string(fromByteCount: store.missingBytes(for: store.recognizer), countStyle: .file))) {
                            download()
                        }
                    }
                }
            } label: {
                SettingLabel(title: "Models", help: "The recognizer, plus Silero VAD (where speech starts and stops) and Smart Turn (whether a pause ends your turn), in the models folder. Licences: Parakeet CC BY 4.0 (NVIDIA), Whisper MIT, Silero MIT, Smart Turn BSD-2-Clause.")
            }
            if store.isBusy, !store.statusText.isEmpty {
                Text(store.statusText).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Toggle(isOn: $fillers) {
                SettingLabel(title: "Fillers on pauses", help: "When an answer takes more than a second, a short “hmm” or “let me check” in the answers' voice, so the silence doesn't feel like a dropped call. Made in the conversation's quiet moments and kept per voice.")
            }
            Toggle(isOn: $sendAudio) {
                SettingLabel(title: "Send my voice to models that hear", help: "Models that hear audio (Gemma 4 E2B, E4B, 12B) get your turn's recording along with its text, so they hear how you said it. Up to 30 seconds a turn.")
            }
            Text("The voice that answers is the one picked under Spoken answers.").font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Voice conversation")
        }
    }

    private func download() {
        error = nil
        Task { do { try await store.download() } catch { self.error = error.localizedDescription } }
    }

    private func remove() {
        error = nil
        Task { do { try await store.remove(store.recognizer) } catch { self.error = error.localizedDescription } }
    }
}

/// The composer's voice button: starts a voice conversation in this chat.
struct VoiceConversationButton: View {
    @EnvironmentObject var chat: ChatClient
    @ObservedObject private var voice = VoiceConversation.shared

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .startVoiceConversation, object: chat)
        } label: {
            Image(systemName: "waveform.circle").font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(voice.isActive(in: chat))
        .help(Text("Talk with the model: a voice conversation (Esc ends it)"))
        .accessibilityLabel(Text("Voice conversation"))
    }
}
