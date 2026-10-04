import AppKit
import Foundation

/// Folders and files outside the App Store build's container (adr/0018
/// §3): the user grants each once in an open panel; an app-scope
/// security-scoped bookmark keeps it across launches, and access stays open
/// while the app runs -- the runners it starts (the server, the embedder,
/// voice) inherit it, as the sandbox spike showed. Paths stay what the rest
/// of the app stores (grants, the models folder, projects); this only makes
/// them reachable. The standalone build isn't sandboxed: every call here is
/// a no-op there.
@MainActor
enum SandboxAccess {
    #if APP_STORE
    private static let key = "llmtray.sandbox.bookmarks"   // [path: bookmark]
    private static var open: [String: URL] = [:]

    /// The container's home: always reachable.
    private static var containerHome: String { NSHomeDirectory() }

    /// The user's real home (NSHomeDirectory is the container's in the
    /// sandbox): where an open panel for ~/… starts.
    static var realHome: String {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    private static var stored: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// At launch: every remembered grant opened again (a stale bookmark is
    /// renewed; one that no longer resolves is dropped).
    static func restore() {
        var bookmarks = stored
        for (path, data) in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                bookmarks[path] = nil
                continue
            }
            if url.startAccessingSecurityScopedResource() { open[path] = url }
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks[path] = fresh
            }
        }
        stored = bookmarks
    }

    /// Right after the user picked `url` in an open panel (or dropped it):
    /// kept for later launches, open from now on.
    static func remember(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard open[path] == nil,
              let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        var bookmarks = stored
        bookmarks[path] = data
        stored = bookmarks
        if url.startAccessingSecurityScopedResource() { open[path] = url }
    }

    /// A grant the user took back (a revoked folder, a removed project).
    static func forget(_ path: String) {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        open.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
        var bookmarks = stored
        bookmarks[path] = nil
        stored = bookmarks
    }

    /// In the container, or at or under a granted folder.
    static func canReach(_ path: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if path == containerHome || path.hasPrefix(containerHome + "/") { return true }
        return open.keys.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// `path` reachable, asking for it in an open panel when it isn't yet
    /// (a folder picked from a list rather than a panel, a setting from
    /// before). False when the user cancels or picks another folder.
    @discardableResult
    static func requestAccess(to path: String, message: String) -> Bool {
        if canReach(path) { return true }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        // ~/.llmtray, ~/.lmstudio: the folders it asks for are often hidden.
        panel.showsHiddenFiles = true
        panel.message = message
        panel.prompt = NSLocalizedString("Allow", comment: "open panel button: allow folder access")
        panel.directoryURL = URL(fileURLWithPath: path)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        remember(url)
        return canReach(path)
    }
    #else
    static var realHome: String { NSHomeDirectory() }
    static func restore() {}
    static func remember(_ url: URL) {}
    static func forget(_ path: String) {}
    static func canReach(_ path: String) -> Bool { true }
    @discardableResult
    static func requestAccess(to path: String, message: String) -> Bool { true }
    #endif
}
