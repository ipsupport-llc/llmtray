import Foundation
import LLMTrayCore

/// The first project of a fresh install: "Getting Started", with its
/// instructions, the LLMTray guide as its file (added once Project files are
/// turned on: nothing is indexed before, adr/0013) and a chat open in it; new
/// chats go into it while its card is shown. The card in its empty chats
/// (GettingStartedCard) walks through four steps.
@MainActor
enum GettingStarted {
    static let guideName = "LLMTray Guide.md"

    static var guideURL: URL { URL(fileURLWithPath: RuntimePaths.runtimeDir).appendingPathComponent(guideName) }

    static let instructions = "You are the assistant in LLMTray, a Mac app that runs AI models locally. Answer briefly, "
        + "in the user's language. For questions about LLMTray, search this project's files (the LLMTray guide) and cite "
        + "the pages you used."

    /// The project, while it exists.
    static var projectID: UUID? {
        guard let raw = UserDefaults.standard[Pref.gettingStartedProject], let id = UUID(uuidString: raw),
              ChatLibraryStore.shared.library.project(id) != nil else { return nil }
        return id
    }

    static func isProject(_ id: UUID?) -> Bool { id != nil && id == projectID }

    /// Nothing from before: setup never finished, no saved chat, no
    /// project -- and this was never made (a user who deleted it keeps it
    /// deleted).
    static var isFreshInstall: Bool {
        guard UserDefaults.standard[Pref.gettingStartedProject] == nil,
              UserDefaults.standard[Pref.onboardingCompleted] == nil,
              ChatLibraryStore.shared.library.projects.isEmpty else { return false }
        let chats = ((try? FileManager.default.contentsOfDirectory(atPath: ChatSessionStore.sessionsDir)) ?? [])
            .filter { $0.hasSuffix(".json") && $0 != "library.json" }
        return chats.isEmpty
    }

    /// At launch: on a fresh install, the project and a chat in it.
    static func setUpIfFreshInstall() {
        guard isFreshInstall else { return }
        let name = NSLocalizedString("Getting Started", comment: "the first project of a fresh install")
        guard let project = ChatLibraryStore.shared.addProject(named: name) else { return }
        ChatLibraryStore.shared.setInstructions(project.id, instructions)
        UserDefaults.standard[Pref.gettingStartedProject] = project.id.uuidString
        UserDefaults.standard[Pref.gettingStartedGuidePending] = true
        ChatTabs.shared.newChat(inProject: project.id)
        addGuideIfPending()
    }

    /// The guide into the project, once Project files are on (called again
    /// when they're turned on).
    static func addGuideIfPending() {
        guard UserDefaults.standard[Pref.gettingStartedGuidePending], let project = projectID,
              ProjectIndexer.shared.isEnabled, FileManager.default.fileExists(atPath: guideURL.path) else { return }
        UserDefaults.standard[Pref.gettingStartedGuidePending] = false
        Task { await ProjectIndexer.shared.addFiles([guideURL], to: project) }
    }

    /// The project new chats go into: this one, while its card is shown.
    static var defaultProjectForNewChats: UUID? { cardVisible ? projectID : nil }

    /// A message was sent in a chat of `project`.
    static func noteMessage(inProject project: UUID?) {
        if isProject(project) { UserDefaults.standard[Pref.gettingStartedWrote] = true }
    }

    // MARK: The card

    enum Step: Int, CaseIterable { case write, files, ask, create }

    static func isDone(_ step: Step, selectedModelID: String?) -> Bool {
        switch step {
        case .write:
            return UserDefaults.standard[Pref.gettingStartedWrote]
        case .files:
            guard let project = projectID else { return false }
            return (ProjectIndexer.shared.documents[project] ?? []).contains { $0.name != guideName }
        case .ask:
            return ProjectIndexer.shared.isEnabled
        case .create:
            let profiles = ProfileManager.shared
            return profiles.value(\.tools.enableImageGeneration, for: selectedModelID)
                || profiles.value(\.tools.enableMusicGeneration, for: selectedModelID)
                || VoiceModelStore.shared.isEnabled
        }
    }

    static var cardVisible: Bool {
        projectID != nil && !UserDefaults.standard[Pref.gettingStartedHidden]
            && !Step.allCases.allSatisfy { isDone($0, selectedModelID: UserDefaults.standard[Pref.selectedModelID]) }
    }

    static func hideCard() { UserDefaults.standard[Pref.gettingStartedHidden] = true }
}
