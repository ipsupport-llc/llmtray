import AppKit
import AVFoundation
import SwiftUI
import LLMTrayCore
import UniformTypeIdentifiers

/// The app's one audio player: starting a clip stops the one playing.
@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    /// The clip loaded (playing or paused), by the caller's id.
    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    var duration: TimeInterval { player?.duration ?? 0 }

    func toggle(_ data: Data, id: String) {
        if currentID == id, let player {
            if player.isPlaying { pause() } else { resume() }
            return
        }
        stop()
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.delegate = self
        self.player = player
        currentID = id
        resume()
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        position = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        currentID = nil
        isPlaying = false
        position = 0
        timer?.invalidate()
        timer = nil
    }

    private func resume() {
        guard let player, player.play() else { return }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        position = player?.currentTime ?? 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.position = 0
            self.timer?.invalidate()
            self.timer = nil
        }
    }
}

/// One generated piece of music in a chat bubble: play / pause, a scrubber,
/// the style it was asked for, Save.
struct AudioClipView: View {
    let data: Data
    let id: String
    let prompt: String
    let generationSeconds: Double?
    @ObservedObject private var playback = AudioPlayback.shared

    private var isCurrent: Bool { playback.currentID == id }

    /// The clip's own length, from its WAV header (no player needed).
    private var length: TimeInterval { WAVInfo.duration(data) ?? 0 }

    var body: some View {
        let total = isCurrent ? playback.duration : length
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { playback.toggle(data, id: id) } label: {
                    Image(systemName: isCurrent && playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCurrent && playback.isPlaying ? Text("Pause") : Text("Play"))
                VStack(alignment: .leading, spacing: 3) {
                    Slider(value: Binding(
                        get: { isCurrent && total > 0 ? playback.position / total : 0 },
                        set: { fraction in
                            if !isCurrent { playback.toggle(data, id: id) }
                            playback.seek(to: fraction)
                        }
                    ))
                    .controlSize(.small)
                    HStack {
                        Text(verbatim: Self.clock(isCurrent ? playback.position : 0))
                        Spacer()
                        Text(verbatim: Self.clock(total))
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
                }
            }
            if !prompt.isEmpty {
                Label(prompt, systemImage: "music.note")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button { Self.save(data, prompt: prompt) } label: {
                    Label("Save…", systemImage: "square.and.arrow.down").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                if let generationSeconds {
                    Text(String(format: NSLocalizedString("Generated in %.1fs", comment: "image generation time"), generationSeconds))
                        .font(.system(size: 10))
                }
            }
            .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A Save panel, named after the prompt.
    static func save(_ data: Data, prompt: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        let base = prompt.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .prefix(6).joined(separator: "-")
        panel.nameFieldStringValue = (base.isEmpty ? "music" : base) + ".wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Stage and progress while music is being generated.
struct MusicGenerationProgressView: View {
    @EnvironmentObject var chat: ChatClient

    var body: some View {
        HStack(spacing: 8) {
            if let progress = chat.musicProgress {
                ProgressView(value: Double(progress), total: 100).frame(width: 100)
            } else {
                ProgressView().controlSize(.small)
            }
            Image(systemName: "music.note").foregroundColor(.secondary)
            Text(chat.musicStatusText.isEmpty ? NSLocalizedString("Generating music…", comment: "") : chat.musicStatusText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
