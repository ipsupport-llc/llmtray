#if APP_STORE
import AppKit
import Foundation
import LLMTrayCore

/// Settings › General › "Import from LLMTray (direct download)" (adr/0018
/// §3): the user grants the Developer ID build's data folder once, and its
/// chats, projects, profiles and downloaded models are copied into the
/// container (StandaloneImport). The grant is for this import only: nothing
/// is kept. Settings themselves come over by themselves -- macOS moves the
/// preferences into the container on the first launch.
/// Best with the other LLMTray quit: a project's index is copied as it is
/// on disk.
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
        finished(result)
    }

    private static func finished(_ result: Result<StandaloneImport.Summary, Error>) {
        let alert = NSAlert()
        switch result {
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("The import stopped", comment: "")
            alert.informativeText = String(format: NSLocalizedString("What was copied before stays; importing again goes on from there. %@", comment: "import failure detail"), error.localizedDescription)
            alert.runModal()
        case .success(let summary) where summary.imported.isEmpty:
            alert.messageText = NSLocalizedString("Nothing new to import", comment: "")
            alert.informativeText = NSLocalizedString("Everything in that folder is here already.", comment: "")
            alert.runModal()
        case .success(let summary):
            alert.messageText = NSLocalizedString("Imported", comment: "")
            var text = NSLocalizedString("Chats, projects, profiles and the image, music, voice and embedding models from the version from ipsupport.us are here now. Folders you'd given it access to, and your chat models folder, need your OK again.", comment: "")
            if summary.defaultProfile == .addedAsProfile {
                text += " " + NSLocalizedString("Its Default profile is in Settings › Profiles as \u{201C}Default (ipsupport.us)\u{201D}: yours here was changed, so it was kept.", comment: "")
            }
            alert.informativeText = text + "\n\n" + NSLocalizedString("LLMTray restarts now to load them.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Restart", comment: ""))
            alert.runModal()
            AppLanguage.relaunch(reopening: .general)
        }
    }
}
#endif
