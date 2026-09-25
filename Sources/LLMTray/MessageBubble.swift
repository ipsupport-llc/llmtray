import AppKit
import SwiftUI

/// One chat message: a compaction summary, or a user/assistant bubble with
/// optional reasoning and images.
@MainActor
struct MessageBubble: View {
    /// The chat's visible height: a generated image fits in it whole.
    @Environment(\.visibleChatHeight) private var visibleChatHeight
    let message: ChatMessage
    let showReasoning: Bool
    /// Debug view of the tool calls (Pref.showToolCalls): call id -> the
    /// tool's result; nil hides them.
    var toolResults: [String: String]?
    /// Credits of the data this answer's tools used.
    var sources: [String] = []

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

            ForEach(sources, id: \.self) { source in
                Text(verbatim: source)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            if let toolResults, !message.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(message.toolCalls, id: \.id) { call in
                        ToolCallRow(call: call, result: toolResults[call.id])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private func image(_ data: Data, index i: Int) -> some View {
        if let nsImage = NSImage(data: data) {
            let prompt = message.imagePrompts[safe: i] ?? ""
            // A generated image is the answer: large and centred, as wide as
            // the chat allows (the popover's whole width, up to 640 in the
            // window). One the user attached stays a thumbnail by their text.
            // Never taller than the chat shows at once (the popover's is
            // short), nor enlarged past its own pixels (a small one blurs).
            let pixels = nsImage.representations.map { CGFloat(max($0.pixelsWide, $0.pixelsHigh)) }.max() ?? 0
            let natural = pixels > 0 ? pixels : max(nsImage.size.width, nsImage.size.height)
            let side = min(isUser ? 280 : Self.generatedImageSide, natural)
            let height = isUser ? side : min(side, max(160, visibleChatHeight - 56))
            VStack(alignment: isUser ? .trailing : .center, spacing: 6) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: side, maxHeight: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(isUser ? 0 : 0.18), radius: 8, y: 3)
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
                        Text(String(format: NSLocalizedString("Generated in %.1fs", comment: "image generation time"), seconds)).font(.system(size: 10))
                    }
                }
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .center)
            .padding(.vertical, isUser ? 0 : 4)
        }
    }

    static let generatedImageSide: CGFloat = 640
}

/// Step progress and the live preview while an image is being generated.
private struct VisibleChatHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 640
}

extension EnvironmentValues {
    /// The chat's scroll view height (ContentView), for sizing images.
    var visibleChatHeight: CGFloat {
        get { self[VisibleChatHeightKey.self] }
        set { self[VisibleChatHeightKey.self] = newValue }
    }
}

struct ImageGenerationProgressView: View {
    @Environment(\.visibleChatHeight) private var visibleChatHeight
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
                // Where the finished image will be, at its size.
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: MessageBubble.generatedImageSide,
                           maxHeight: min(MessageBubble.generatedImageSide, max(160, visibleChatHeight - 56)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(0.85)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tool call in the debug view: the call collapsed, its result expanded.
private struct ToolCallRow: View {
    let call: ToolCall
    let result: String?
    @State private var expanded = false

    /// Capped: a huge argument (a long prompt) shouldn't lay out in full.
    private var label: String {
        let text = Self.compact(call.argumentsJSON)
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(result.map { $0.count > 4000 ? String($0.prefix(4000)) + "…" : $0 } ?? NSLocalizedString("(no result yet)", comment: "tool call debug view"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(6)
        } label: {
            Label {
                Text("\(call.name)(\(label))")
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "wrench.and.screwdriver").imageScale(.small)
            }
            .foregroundColor(.secondary)
        }
    }

    /// {"expression":"2+2"} -> expression: "2+2"
    static func compact(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return json }
        return obj.keys.sorted().map { key -> String in
            let value = obj[key]!
            if let s = value as? String { return "\(key): \"\(s)\"" }
            // Nested values as one-line JSON, not Swift's multi-line dump.
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                return "\(key): \(String(decoding: data, as: UTF8.self))"
            }
            return "\(key): \(value)"
        }.joined(separator: ", ")
    }
}
