import AppKit
import LLMTrayCore
import SwiftUI

/// A document a message made (adr/0020): the first page, its title and page
/// count, and what the user can do with it. The PDF stays in the chat's
/// folder; it goes anywhere else only by one of these clicks.
@MainActor
struct DocumentCard: View {
    let document: DocumentRef
    /// The chat's folder, where the PDF and its thumbnail are.
    let folder: URL
    /// The chat's project: Add to Project; nil outside one.
    let project: UUID?
    /// Makes it again from the saved call; nil while the chat is busy.
    var remake: (() -> Void)?
    @State private var note: String?

    private var url: URL { folder.appendingPathComponent(document.filename) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
                .onTapGesture(count: 2) { open() }
            VStack(alignment: .leading, spacing: 6) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(String(format: NSLocalizedString("PDF · %lld pages", comment: "a document's card"), document.pages))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button("Open") { open() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Save As…") { saveAs() }
                    if let project {
                        Button("Add to Project") { addToProject(project) }
                    }
                    if let remake {
                        Button { remake() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Make the document again from the same content")
                            .accessibilityLabel("Make again")
                    }
                }
                .controlSize(.small)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2)))
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(format: NSLocalizedString("Document: %@", comment: ""), document.title)))
    }

    @ViewBuilder private var thumbnail: some View {
        if let name = document.thumbnail, let image = NSImage(contentsOf: folder.appendingPathComponent(name)) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 108)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
        } else {
            Image(systemName: "doc.richtext")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(width: 84, height: 108)
        }
    }

    private func open() {
        if !NSWorkspace.shared.open(url) { note = NSLocalizedString("The PDF couldn't be opened.", comment: "") }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.filename
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            note = error.localizedDescription
        }
    }

    private func addToProject(_ project: UUID) {
        Task {
            guard await enableProjectFiles() else { return }
            await ProjectIndexer.shared.addFiles([url], to: project)
            note = ProjectIndexer.shared.addNotes[project] ?? NSLocalizedString("Added to the project.", comment: "a document's card")
        }
    }
}
