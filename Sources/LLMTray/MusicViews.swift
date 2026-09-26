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

    /// Stops the clip if it's one of these messages' (AudioClipView ids are
    /// "<message id>-<index>").
    func stop(ifAnyOf messages: [ChatMessage]) {
        guard let currentID, messages.contains(where: { currentID.hasPrefix($0.id.uuidString + "-") }) else { return }
        stop()
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
        // Target/selector, fired on the main run loop: no closure capturing
        // self across concurrency domains (which CI's older compiler rejects).
        let timer = Timer(timeInterval: 0.2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        // .common: the scrubber keeps moving while the chat is scrolled.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        position = player?.currentTime ?? 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // A clip started since: not its end.
            guard player === self.player else { return }
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
    /// It came from a tool call that can run again.
    var canRegenerate: Bool = false
    /// Regenerate / Tweak / Remove; nil while the chat can't (busy, no server).
    var action: ((ChatClient.MediaAction) -> Void)?
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
                Button { MediaSharing.copyAudio(data, prompt: prompt) } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(Text("Copy the song as a WAV file"))
                ShareLink(item: SharedAudio(data: data, prompt: prompt),
                          preview: SharePreview(prompt.isEmpty ? "Music" : prompt, image: Image(systemName: "music.note"))) {
                    Label("Share…", systemImage: "square.and.arrow.up").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                if canRegenerate {
                    Button { action?(.regenerate) } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(action == nil)
                    .help(Text("Another version next to this one (a new seed, the same request)"))
                    Button { action?(.tweak) } label: {
                        Label("Tweak…", systemImage: "slider.horizontal.3").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(action == nil)
                    .help(Text("Change the style, lyrics, model or knobs, then make another version"))
                }
                Button { action?(.remove) } label: {
                    Label("Remove", systemImage: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(action == nil)
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

/// Waiting for another chat's image or song (the app-wide generator queue).
struct MediaQueueView: View {
    let ahead: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Image(systemName: "hourglass").foregroundColor(.secondary)
            Text(ahead == 1
                 ? NSLocalizedString("Waiting for another chat's image or music to finish…", comment: "generator queue")
                 : String(format: NSLocalizedString("In the queue: %lld ahead…", comment: "generator queue"), ahead))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Stage and progress while music is being generated.
struct MusicGenerationProgressView: View {
    @EnvironmentObject var chat: ChatClient

    var body: some View {
        if let ahead = chat.mediaQueuePosition {
            MediaQueueView(ahead: ahead)
        } else {
            progress
        }
    }

    private var progress: some View {
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
