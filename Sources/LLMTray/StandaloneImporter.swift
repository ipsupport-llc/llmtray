#if APP_STORE
import AppKit
import Foundation
import LLMTrayCore
import UniformTypeIdentifiers

/// Settings › General › "Import from LLMTray (direct download)" (adr/0018
/// §3): the user grants the Developer ID build's data folder once, and its
/// chats, projects, profiles and downloaded models are copied into the
/// container (StandaloneImport); then its preferences file, picked in a
/// second panel, brings its settings (StandaloneSettingsImport) -- the App
/// Store build has its own bundle id, so macOS doesn't move them, and the
/// sandbox can't read another app's domain. The grants are for this import
/// only: nothing is kept.
/// Best with the other LLMTray quit (it can't run beside this one anyway):
/// a project's index is copied as it is on disk.
@MainActor
enum StandaloneImporter {
    static func run() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = NSLocalizedString("Choose the LLMTray folder of the version from ipsupport.us (it's already selected), then Import.", comment: "import open panel message")
        panel.prompt = NSLocalizedString("Import", comment: "import open panel button")
        panel.directoryURL = URL(fileURLWithPath: SandboxAccess.realHome + "/Library/Application Support/LLMTray")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        guard StandaloneImport.looksLikeDataFolder(source) else {
            if scoped { source.stopAccessingSecurityScopedResource() }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("That isn't LLMTray's folder", comment: "")
            alert.informativeText = NSLocalizedString("Choose ~/Library/Application Support/LLMTray: the folder with sessions, projects and the models of the version from ipsupport.us.", comment: "")
            alert.runModal()
            return
        }
        // Clones: well under a second even for tens of GB, so on the main
        // actor -- nothing the app holds in memory is saved over the files
        // meanwhile -- and the app relaunches right after, so its stores
        // load what came in instead of writing theirs over it.
        let destination = URL(fileURLWithPath: RuntimePaths.externalRuntimeDir)
        let untouched = ProfileStore.migratedDefault(from: .standard)
        let result = Result { try StandaloneImport.run(from: source, to: destination, untouchedDefault: untouched) }
        if scoped { source.stopAccessingSecurityScopedResource() }
        // Settings after the data: the Default profile's merge above
        // compared with what this install's settings make of it.
        let settings: SettingsOutcome = (try? result.get()) == nil ? .skipped : importSettings()
        finished(result, settings: settings)
    }

    enum SettingsOutcome: Equatable {
        case imported(changed: Int), skipped, unreadable
    }

    /// The Developer ID build's ~/Library/Preferences/us.ipsupport.llmtray.plist:
    /// read where it is when that's allowed (only outside the sandbox), else
    /// the user picks it (preselected). Cancel keeps the settings here.
    private static func importSettings() -> SettingsOutcome {
        let file = URL(fileURLWithPath: SandboxAccess.realHome + "/Library/Preferences/" + StandaloneImport.settingsFileName)
        if let data = try? Data(contentsOf: file) { return apply(data) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.propertyList]
        // A file URL: the panel opens its folder (Preferences in the hidden
        // ~/Library) with the file selected.
        panel.directoryURL = file
        panel.message = String(format: NSLocalizedString("Now its settings: choose %@ (it's already selected), then Import. Cancel keeps the settings here.", comment: "settings import open panel message"), StandaloneImport.settingsFileName)
        panel.prompt = NSLocalizedString("Import", comment: "import open panel button")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return .skipped }
        guard url.lastPathComponent == StandaloneImport.settingsFileName else { return .unreadable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return apply(data)
    }

    private static func apply(_ data: Data) -> SettingsOutcome {
        guard let settings = StandaloneImport.settings(fromPlist: data) else { return .unreadable }
        return .imported(changed: StandaloneImport.apply(settings: settings, to: .standard))
    }

    private static func finished(_ result: Result<StandaloneImport.Summary, Error>, settings: SettingsOutcome) {
        let alert = NSAlert()
        let settingsChanged: Int
        if case .imported(let changed) = settings { settingsChanged = changed } else { settingsChanged = 0 }
        switch result {
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("The import stopped", comment: "")
            alert.informativeText = String(format: NSLocalizedString("What was copied before stays; importing again goes on from there. %@", comment: "import failure detail"), error.localizedDescription)
            alert.runModal()
        case .success(let summary) where summary.imported.isEmpty && settingsChanged == 0:
            alert.messageText = NSLocalizedString("Nothing new to import", comment: "")
            alert.informativeText = NSLocalizedString("Everything in that folder is here already.", comment: "")
            if settings == .unreadable { alert.informativeText += " " + settingsUnreadable }
            alert.runModal()
        case .success(let summary):
            alert.messageText = NSLocalizedString("Imported", comment: "")
            var text = summary.imported.isEmpty
                ? NSLocalizedString("The chats and models in that folder were here already.", comment: "")
                : NSLocalizedString("Chats, projects, profiles and the image, music, voice and embedding models from the version from ipsupport.us are here now. Folders you'd given it access to, and your chat models folder, need your OK again.", comment: "")
            if summary.defaultProfile == .addedAsProfile {
                text += " " + NSLocalizedString("Its Default profile is in Settings › Profiles as \u{201C}Default (ipsupport.us)\u{201D}: yours here was changed, so it was kept.", comment: "")
            }
            switch settings {
            case .imported:
                // The token is a Keychain item of the other app's: the
                // sandbox doesn't reach it.
                text += " " + NSLocalizedString("Its settings came too; a Hugging Face token has to be entered again in Settings › Models.", comment: "")
            case .unreadable: text += " " + settingsUnreadable
            case .skipped: break
            }
            alert.informativeText = text + "\n\n" + NSLocalizedString("LLMTray restarts now to load them.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Restart", comment: ""))
            alert.runModal()
            AppLanguage.relaunch(reopening: .general)
        }
    }

    private static var settingsUnreadable: String {
        String(format: NSLocalizedString("Its settings weren't imported: that isn't %@.", comment: "settings import: wrong or unreadable file"), StandaloneImport.settingsFileName)
    }
}
#endif
