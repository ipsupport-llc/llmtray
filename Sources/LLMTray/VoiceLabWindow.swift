import AppKit
import LLMTrayCore
import SwiftUI

extension Notification.Name {
    /// Opens the Voice Lab window (AppDelegate).
    static let showVoiceLab = Notification.Name("LLMTray.showVoiceLab")
}

/// The Voice Lab window (adr/0016): one big Start/Stop, the mic's level,
/// whether the model is listening or speaking, what it says (its text
/// channel), the time. Closing it stops the session.
@MainActor
final class VoiceLabWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = NSLocalizedString("Voice Lab", comment: "window title")
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: VoiceLabView())
            window.contentMinSize = NSSize(width: 380, height: 420)
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        VoiceLabSession.shared.stop()
    }
}

struct VoiceLabView: View {
    @ObservedObject private var session = VoiceLabSession.shared
    @ObservedObject private var store = VoiceModelStore.shared
    @AppStorage(Pref.voiceLabMode) private var mode
    @State private var showsLog = false

    var body: some View {
        VStack(spacing: 16) {
            Label("Experimental — English only", systemImage: "flask")
                .font(.caption)
                .foregroundStyle(.secondary)
            VoiceLabModePicker(mode: $mode)
                .onChange(of: mode) { session.applyMode() }
            if session.phase == .running, session.isWalkieTalkie {
                talkButton
                HStack(spacing: 12) {
                    stateLine
                    Button("End", action: session.stop)
                        .help(Text("End the conversation (the chat model reloads)"))
                }
            } else {
                startStopButton
                stateLine
            }
            if session.phase == .running, let notice = session.speedNotice {
                Text(verbatim: notice).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let note = session.replyNote {
                Text(verbatim: note).font(.caption).foregroundStyle(.orange)
            }
            MicLevelMeter(level: session.level, active: session.phase == .running)
                .frame(height: 8)
                .frame(maxWidth: 260)
            if let startedAt = session.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(verbatim: Self.elapsed(context.date.timeIntervalSince(startedAt)))
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            notice
            transcriptView
            DisclosureGroup("Log", isExpanded: $showsLog) {
                ScrollView {
                    Text(verbatim: session.log.isEmpty ? "—" : session.log)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 100)
            }
            .font(.caption)
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 420)
    }

    private var startStopButton: some View {
        let active = session.isActive
        return Button {
            if active { session.stop() } else { session.start() }
        } label: {
            ZStack {
                Circle().fill(active ? Color.red : Color.accentColor)
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 96, height: 96)
        }
        .buttonStyle(.plain)
        // Off in Settings, or no model: nothing to start.
        .disabled(session.phase == .stopping || (!active && !session.canStart()))
        .keyboardShortcut(.space, modifiers: [])
        .help(active ? Text("Stop") : Text("Start talking"))
        .accessibilityLabel(active ? Text("Stop") : Text("Start"))
    }

    /// Walkie-talkie: press, talk, press again; the model answers after.
    /// While it makes its reply, the button cancels it.
    private var talkButton: some View {
        let (symbol, title, color): (String, Text, Color) = {
            switch session.turn {
            case .waiting: return ("mic.fill", Text("Talk"), .accentColor)
            case .talking: return ("paperplane.fill", Text("Done"), .red)
            case .thinking: return ("xmark", Text("Cancel reply"), .orange)
            }
        }()
        return Button(action: session.toggleTalk) {
            ZStack {
                Circle().fill(color)
                VStack(spacing: 2) {
                    Image(systemName: symbol).font(.system(size: 30, weight: .semibold))
                    title.font(.caption.bold())
                }
                .foregroundStyle(.white)
            }
            .frame(width: 96, height: 96)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(Text(session.turn == .talking ? "Done talking: the model answers" : session.turn == .thinking ? "Cancel the reply" : "Press, talk, press again"))
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var stateLine: some View {
        switch session.phase {
        case .idle:
            Text("Press Start and talk. Use headphones: the model hears its own voice from the speakers.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        case .preparing(let text):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(verbatim: text) }
                .foregroundStyle(.secondary)
        case .running where session.isSpeaking:
            Text("Speaking…").font(.headline).foregroundStyle(Color.accentColor)
        case .running where session.isWalkieTalkie:
            switch session.turn {
            case .waiting: Text("Press Talk and speak.").foregroundStyle(.secondary)
            case .talking: Text("Talking… press Done when you're finished.").font(.headline)
            case .thinking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if session.replyReadySeconds > 0 {
                        Text(String(format: NSLocalizedString("Thinking… %@ s of reply ready", comment: "Voice Lab: seconds"),
                                    String(format: "%.1f", session.replyReadySeconds)))
                            .font(.headline).monospacedDigit()
                    } else {
                        Text("Thinking…").font(.headline)
                    }
                }
            }
        case .running:
            Text("Listening…").font(.headline)
        case .stopping:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Stopping…") }
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(verbatim: message)
                .foregroundStyle(.red).font(.callout)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        case .microphoneDenied:
            VStack(spacing: 6) {
                Text("LLMTray isn't allowed to use the microphone.")
                    .foregroundStyle(.red)
                Button("Open Privacy Settings…") { VoiceLabSession.openMicrophoneSettings() }
            }
        }
    }

    @ViewBuilder
    private var notice: some View {
        if !store.isEnabled {
            Text("Voice Lab is off -- turn it on in Settings > Voice.")
                .font(.caption).foregroundStyle(.orange)
        } else if !store.isDownloaded(store.selected) {
            Text("The voice model isn't downloaded -- download it in Settings > Voice.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(verbatim: session.transcript.isEmpty ? " " : session.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .id("end")
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(alignment: .topLeading) {
                if session.transcript.isEmpty {
                    Text("What the model says appears here.")
                        .foregroundStyle(.tertiary).padding(8)
                }
            }
            .onChange(of: session.transcript) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Full duplex / walkie-talkie / automatic (by this Mac's measured speed).
struct VoiceLabModePicker: View {
    @Binding var mode: String

    var body: some View {
        Picker("Mode", selection: $mode) {
            Text("Automatic").tag(VoiceLabMode.auto.rawValue)
            Text("Full duplex").tag(VoiceLabMode.duplex.rawValue)
            Text("Walkie-talkie").tag(VoiceLabMode.walkieTalkie.rawValue)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(Text("Full duplex: talk any time, the model hears you while it speaks -- needs a Mac that runs it in real time. Walkie-talkie: talk, press Done, then listen. Automatic picks by this Mac's measured speed."))
    }
}

/// A horizontal bar: the mic's level, 0...1.
struct MicLevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > 0.85 ? Color.orange : Color.green)
                    .frame(width: active ? geo.size.width * CGFloat(level) : 0)
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .accessibilityLabel(Text("Microphone level"))
    }
}
