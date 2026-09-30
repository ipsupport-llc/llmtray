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
@MainActor
enum StandaloneImporter {
    private(set) static var isRunning = false

    static func run() {
        guard !isRunning else { return }
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
        isRunning = true
        let destination = URL(fileURLWithPath: RuntimePaths.externalRuntimeDir)
        Task.detached(priority: .userInitiated) {
            let result = Result { try StandaloneImport.run(from: source, to: destination) }
            if scoped { source.stopAccessingSecurityScopedResource() }
            await MainActor.run {
                isRunning = false
                finished(result)
            }
        }
    }

    private static func finished(_ result: Result<StandaloneImport.Summary, Error>) {
        let alert = NSAlert()
        switch result {
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("The import stopped", comment: "")
            alert.informativeText = String(format: NSLocalizedString("What was copied before stays. %@", comment: "import failure detail"), error.localizedDescription)
            alert.runModal()
        case .success(let summary) where summary.imported.isEmpty:
            alert.messageText = NSLocalizedString("Nothing new to import", comment: "")
            alert.informativeText = NSLocalizedString("Everything in that folder is here already.", comment: "")
            alert.runModal()
        case .success:
            alert.messageText = NSLocalizedString("Imported", comment: "")
            alert.informativeText = NSLocalizedString("Chats, projects, profiles and downloaded models from the version from ipsupport.us are here now. Folders you'd given it access to need your OK again. Restart LLMTray to see everything?", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Restart Now", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
            if alert.runModal() == .alertFirstButtonReturn { AppLanguage.relaunch(reopening: .general) }
        }
    }
}
#endif
