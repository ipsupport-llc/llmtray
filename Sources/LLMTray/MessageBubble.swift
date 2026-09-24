import AppKit
import SwiftUI

/// One chat message: a compaction summary, or a user/assistant bubble with
/// optional reasoning and images.
@MainActor
struct MessageBubble: View {
    let message: ChatMessage
    let showReasoning: Bool

    var body: some View {
        if message.isSummary {
            summary
        } else {
            bubble
        }
    }

    /// The synthetic message compactSession() splices in -- icon, italic
    /// and dimmed, so it reads as "the app compacted history here", not
    /// something anyone said.
    private var summary: some View {
        Label(message.content, systemImage: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 11).italic())
            .foregroundColor(.secondary)
            .padding(8)
            .background(Color.gray.opacity(0.06))
            .cornerRadius(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isUser: Bool { message.role == "user" }

    private var bubble: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            Text(isUser ? "You" : "Assistant")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            if showReasoning && !message.reasoning.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label(message.content.isEmpty ? "Thinking…" : "Thought process", systemImage: "brain")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(ChatMarkdown.render(message.reasoning, baseSize: 11))
                        .font(.system(size: 11).italic())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color.gray.opacity(0.06))
                .cornerRadius(8)
            }

            if !message.content.isEmpty || message.reasoning.isEmpty {
                // Assistant output is markdown (see ChatMarkdown); the
                // user's own text is shown exactly as typed.
                Group {
                    if isUser || message.content.isEmpty {
                        Text(message.content.isEmpty ? "…" : message.content)
                    } else {
                        Text(ChatMarkdown.render(message.content, baseSize: 13))
                    }
                }
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(8)
                .background(isUser ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
                .cornerRadius(8)
            }

            ForEach(Array(message.images.enumerated()), id: \.offset) { i, data in
                image(data, index: i)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private func image(_ data: Data, index i: Int) -> some View {
        if let nsImage = NSImage(data: data) {
            let prompt = message.imagePrompts[safe: i] ?? ""
            VStack(alignment: .leading, spacing: 2) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 320)
                    .cornerRadius(8)
                    .onTapGesture { ImageActions.openPreview(data, title: prompt.isEmpty ? "Image" : prompt) }
                    .pointingHandCursor()
                    .contextMenu {
                        Button("Copy") { ImageActions.copy(data) }
                        Button("Save…") { ImageActions.save(data, prompt: prompt) }
                    }
                HStack(spacing: 8) {
                    Button { ImageActions.save(data, prompt: prompt) } label: {
                        Label("Save…", systemImage: "square.and.arrow.down").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    Button { ImageActions.copy(data) } label: {
                        Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    if let seconds = message.imageDurations[safe: i] {
                        Text(String(format: "Generated in %.1fs", seconds)).font(.system(size: 10))
                    }
                }
                .foregroundColor(.secondary)
            }
        }
    }
}

/// Step progress and the live preview while an image is being generated.
struct ImageGenerationProgressView: View {
    @EnvironmentObject var chat: ChatClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let progress = chat.mfluxStepProgress, progress.total > 0 {
                    ProgressView(value: Double(progress.step), total: Double(progress.total))
                        .frame(width: 100)
                    Text("Step \(progress.step)/\(progress.total)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(chat.mfluxStatusText.isEmpty ? "Generating image…" : chat.mfluxStatusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            if let preview = chat.mfluxPreviewImage {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 320)
                    .cornerRadius(8)
                    .opacity(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
