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
    /// The latest chip's load: an earlier one finishing after it is dropped.
    private var loads = 0

    /// Shows `url` at `page` (1-based, clamped to the document): false when
    /// it can't be opened as a PDF (locked, or not one) -- the caller opens it
    /// in its app then. The file is read again for every chip, off the main
    /// thread (a large PDF doesn't stall the app; a file changed since, even
    /// with its date kept, isn't shown as it was).
    static func show(_ url: URL, name: String, page: Int, quote: String?, note: String?) async -> Bool {
        let key = url.standardizedFileURL
        let viewer = viewers[key] ?? PDFCitationViewer(url: key)
        viewers[key] = viewer
        viewer.loads += 1
        let load = viewer.loads
        let loaded = await Task.detached { read(key, page: page, quote: quote) }.value
        // A newer chip for the file took over, or the window was closed meanwhile.
        guard viewer.loads == load, viewers[key] === viewer else { return true }
        guard let loaded else {
            viewer.window.close()
            if viewers[key] === viewer { viewers[key] = nil }
            return false
        }
        viewer.pdfView.highlightedSelections = nil
        viewer.pdfView.document = loaded.document
        viewer.state.note = note
        viewer.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Laid out first: PDFView ignores a go(to:) before it has a size.
        viewer.window.layoutIfNeeded()
        viewer.go(loaded, name: name)
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
        // Another file's window cascades from the frontmost viewer, not on top of it.
        let viewerWindows = Self.viewers.values.map(\.window)
        if let front = NSApp.orderedWindows.first(where: { w in viewerWindows.contains { $0 === w } }) {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        } else {
            window.center()
        }
        window.delegate = self
    }

    /// The document and the cited page's quote, found off the main thread
    /// (nil: not a PDF that opens). Only that page's text is searched:
    /// cheap, and never a match elsewhere.
    nonisolated private static func read(_ url: URL, page: Int, quote: String?) -> LoadedPDF? {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { return nil }
        let index = CitationViewer.pageIndex(page, pageCount: document.pageCount)
        let text = index.flatMap { document.page(at: $0)?.string }
        let range = quote.flatMap { q in text.flatMap { CitationViewer.quoteRange(q, in: $0) } }
        return LoadedPDF(document: document, pageIndex: index, quoteRange: range)
    }

    private func go(_ loaded: LoadedPDF, name: String) {
        guard let index = loaded.pageIndex, let target = loaded.document.page(at: index) else { return }
        window.title = String(format: NSLocalizedString("%@ — page %lld", comment: "PDF viewer title: file name, page"), name, index + 1)
        pdfView.go(to: target)
        // The page's text was read with the document: the selection is cheap.
        guard let range = loaded.quoteRange, let selection = target.selection(for: range) else { return }
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

/// A document read off the main thread, handed to it once: PDFKit's objects
/// aren't Sendable, and nothing else touches this one in between.
private final class LoadedPDF: @unchecked Sendable {
    let document: PDFDocument
    let pageIndex: Int?
    let quoteRange: NSRange?

    init(document: PDFDocument, pageIndex: Int?, quoteRange: NSRange?) {
        self.document = document
        self.pageIndex = pageIndex
        self.quoteRange = quoteRange
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
