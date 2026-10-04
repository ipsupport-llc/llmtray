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

    private static var addingGuide = false

    /// The guide into the project, once Project files are on (called again
    /// when they're turned on, and at launch). Still pending until it's
    /// among the project's files: a failed or cut-short add is tried again.
    static func addGuideIfPending() {
        guard UserDefaults.standard[Pref.gettingStartedGuidePending], !addingGuide, let project = projectID,
              ProjectIndexer.shared.isEnabled, FileManager.default.fileExists(atPath: guideURL.path) else { return }
        if hasGuide(project) {
            UserDefaults.standard[Pref.gettingStartedGuidePending] = false
            return
        }
        addingGuide = true
        Task {
            let result = await ProjectIndexer.shared.add([guideURL], to: project).first
            addingGuide = false
            switch result {
            case .added, .duplicate: UserDefaults.standard[Pref.gettingStartedGuidePending] = false
            default: break
            }
        }
    }

    private static func hasGuide(_ project: UUID) -> Bool {
        (ProjectIndexer.shared.documents[project] ?? []).contains { $0.name == guideName }
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

    /// All four done hides it for good, like Hide: turning a feature off
    /// later doesn't bring it (and new chats going into the project) back.
    static var cardVisible: Bool {
        guard projectID != nil, !UserDefaults.standard[Pref.gettingStartedHidden] else { return false }
        guard Step.allCases.allSatisfy({ isDone($0, selectedModelID: UserDefaults.standard[Pref.selectedModelID]) }) else { return true }
        // Not while a view is being drawn (this is read there).
        DispatchQueue.main.async { hideCard() }
        return false
    }

    static func hideCard() { UserDefaults.standard[Pref.gettingStartedHidden] = true }
}
