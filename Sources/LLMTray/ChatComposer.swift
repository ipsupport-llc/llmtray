import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The message being composed: its text and attached images. Shared by the
/// composer and the chat area (images can be dropped on either).
@MainActor
final class ComposerModel: ObservableObject {
    @Published var draft = ""
    /// Always PNG -- ChatRequestBuilder sends them as image/png.
    @Published var attachments: [Data] = []
    /// Only a vision-capable model can take images; switching to one that
    /// can't drops what's attached.
    @Published var acceptsImages = false {
        didSet { if !acceptsImages { attachments.removeAll() } }
    }

    var isEmpty: Bool { draft.trimmingCharacters(in: .whitespaces).isEmpty && attachments.isEmpty }

    /// Takes the draft and attachments for sending and clears them.
    func take() -> (text: String, images: [Data]) {
        defer { draft = ""; attachments = [] }
        return (draft, attachments)
    }

    func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            attach(NSImage(contentsOf: url))
        }
    }

    @discardableResult
    func attach(_ nsImage: NSImage?) -> Bool {
        guard acceptsImages, let nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        attachments.append(png)
        return true
    }

    /// Images dropped on the chat or the composer: files (incl. the
    /// floating screenshot thumbnail, which hands over a file URL) or raw
    /// image data.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsImages else { return false }
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let image = NSImage(contentsOf: url)
                    DispatchQueue.main.async { self.attach(image) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    let image = obj as? NSImage
                    DispatchQueue.main.async { self.attach(image) }
                }
            }
        }
        return handled
    }

    /// Dropping a file onto the text field itself makes AppKit's field
    /// editor insert its *path* as text before any SwiftUI drop handler
    /// sees it -- a dragged screenshot was sent as "/var/folders/...png" and
    /// the model replied it can't open local files. A path to an existing
    /// image file appearing in the draft becomes an attachment instead.
    func convertDroppedImagePaths() {
        guard acceptsImages, draft.contains("/") else { return }
        var remaining = draft
        var converted = false
        for line in draft.components(separatedBy: .newlines) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("/") || candidate.hasPrefix("file://") else { continue }
            let url = candidate.hasPrefix("file://") ? URL(string: candidate) : URL(fileURLWithPath: candidate)
            guard let url, url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  FileManager.default.fileExists(atPath: url.path),
                  attach(NSImage(contentsOf: url)) else { continue }
            remaining = remaining.replacingOccurrences(of: candidate, with: "")
            converted = true
        }
        if converted {
            draft = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// The input bar: turn actions (regenerate, compact, tok/s), attachments,
/// the text field and Send/Stop.
struct ChatComposer: View {
    @EnvironmentObject var chat: ChatClient
    @ObservedObject var composer: ComposerModel
    let canChat: Bool
    let canRegenerate: Bool
    let canCompact: Bool
    var isFocused: FocusState<Bool>.Binding
    let send: () -> Void
    let regenerate: () -> Void
    let compact: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            if canRegenerate || chat.lastTokensPerSecond != nil || canCompact || chat.currentSessionID == nil {
                turnActions
            }
            if !composer.attachments.isEmpty {
                attachmentStrip
            }
            HStack(spacing: 8) {
                if composer.acceptsImages {
                    Button { composer.pickImages() } label: { Image(systemName: "paperclip") }
                        .buttonStyle(.plain)
                        .help("Attach image(s) for the model to see")
                }
                // Not disabled during streaming: a disabled NSTextField
                // resigns first responder, which kicked focus out of the
                // field every time a response started -- send's own guard
                // already stops a second send.
                TextField("Message…", text: $composer.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                    .onChange(of: composer.draft) { _ in composer.convertDroppedImagePaths() }
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { composer.handleDrop($0) }
                    .focused(isFocused)
                    .disabled(!canChat)

                if chat.isBusy {
                    Button { chat.cancel() } label: { Image(systemName: "stop.fill") }
                        .help("Stop generating")
                        .accessibilityLabel("Stop generating")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                        .help("Send")
                        .accessibilityLabel("Send")
                        .disabled(!canChat || composer.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private var turnActions: some View {
        HStack {
            if chat.currentSessionID == nil {
                Label("Temporary — not saved", systemImage: "eye.slash")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if canRegenerate {
                Button(action: regenerate) {
                    Label("Regenerate", systemImage: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            if canCompact {
                Button(action: compact) {
                    Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(chat.isBusy)
            }
            Spacer()
            if let tps = chat.lastTokensPerSecond {
                Text(String(format: "%.1f tok/s", tps))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(composer.attachments.enumerated()), id: \.offset) { i, data in
                    if let nsImage = NSImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .onTapGesture { ImageActions.openPreview(data, title: "Attachment") }
                                .pointingHandCursor()
                                .contextMenu {
                                    Button("Copy") { ImageActions.copy(data) }
                                    Button("Save…") { ImageActions.save(data, prompt: "attachment") }
                                }
                            Button {
                                composer.attachments.remove(at: i)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                    .background(Circle().fill(Color.black.opacity(0.5)))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                            .help("Remove attachment")
                            .accessibilityLabel("Remove attachment")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}
