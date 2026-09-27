import AppKit
import LLMTrayCore
import PDFKit
import SwiftUI

/// A citation chip's PDF (adr/0012, "Citations"): the project's copy or the
/// linked file at the cited page, the cited text highlighted when it's still
/// there. One window per file -- a chip for a file already open jumps to its
/// page there. Read-only: the document is only ever read, never written (a
/// highlight is the view's, not an annotation), and the window isn't in the
/// saved window state.
@MainActor
final class PDFCitationViewer: NSObject, NSWindowDelegate {
    /// Retained here, not in a view: the viewer outlives the popover that
    /// opened it. Keyed by the standardized file URL.
    private static var viewers: [URL: PDFCitationViewer] = [:]

    private let url: URL
    private let window: NSWindow
    private let pdfView = PDFView()
    private let state = PDFCitationViewerState()
    /// The file's modification date when it was loaded: a file changed since
    /// is loaded again, not shown as it was.
    private var loadedModification: Date?

    /// Shows `url` at `page` (1-based, clamped to the document): false when
    /// it can't be opened as a PDF (locked, or not one) -- the caller opens it
    /// in its app then.
    static func show(_ url: URL, name: String, page: Int, quote: String?, note: String?) -> Bool {
        let key = url.standardizedFileURL
        let viewer = viewers[key] ?? PDFCitationViewer(url: key)
        guard viewer.load() else {
            viewer.window.close()
            return false
        }
        viewers[key] = viewer
        viewer.state.note = note
        viewer.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Laid out first: PDFView ignores a go(to:) before it has a size.
        viewer.window.layoutIfNeeded()
        viewer.go(page: page, quote: quote, name: name)
        return true
    }

    private init(url: URL) {
        self.url = url
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 860),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        window.isReleasedWhenClosed = false
        // Not in the saved window state: a project's file, not layout.
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: PDFCitationViewerView(
            pdfView: pdfView, state: state, url: url
        ))
        // A second file's window cascades from the last one, not on top of it.
        if let last = Self.viewers.values.first?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            window.center()
        }
        window.delegate = self
    }

    /// Loads the file unless the loaded document is still current.
    private func load() -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if pdfView.document != nil, modified == loadedModification { return true }
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { return false }
        pdfView.document = document
        loadedModification = modified
        return true
    }

    private func go(page: Int, quote: String?, name: String) {
        guard let document = pdfView.document,
              let index = CitationViewer.pageIndex(page, pageCount: document.pageCount),
              let target = document.page(at: index) else { return }
        window.title = String(format: NSLocalizedString("%@ — page %lld", comment: "PDF viewer title: file name, page"), name, index + 1)
        pdfView.highlightedSelections = nil
        pdfView.go(to: target)
        // Only that page's text is searched: cheap, and never a match elsewhere.
        guard let quote, let text = target.string, let range = CitationViewer.quoteRange(quote, in: text),
              let selection = target.selection(for: range) else { return }
        selection.color = .findHighlightColor
        pdfView.highlightedSelections = [selection]
        pdfView.go(to: selection)
    }

    func windowWillClose(_ notification: Notification) {
        window.delegate = nil
        pdfView.highlightedSelections = nil
        pdfView.document = nil
        Self.viewers[url] = nil
    }
}

@MainActor
private final class PDFCitationViewerState: ObservableObject {
    /// The chip's note (the file changed since the answer cited it).
    @Published var note: String?
}

private struct PDFCitationViewerView: View {
    let pdfView: PDFView
    @ObservedObject var state: PDFCitationViewerState
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            PDFViewHost(pdfView: pdfView)
            Divider()
            HStack(spacing: 8) {
                if let note = state.note {
                    Label { Text(verbatim: note) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(note)
                }
                Spacer(minLength: 0)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Open in Preview") { openInPreview() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    /// Preview, or the default PDF app where Preview isn't found.
    private func openInPreview() {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The viewer's own PDFView, so it can move to a page after it's shown.
private struct PDFViewHost: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
