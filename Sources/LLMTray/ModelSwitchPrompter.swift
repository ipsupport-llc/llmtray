import AppKit
import Foundation
import LLMTrayCore
import UserNotifications

/// "Ask first" (`ModelSwitchPolicy.ask`): an outside client's request for
/// another model waits here for the user -- a system notification with
/// Switch / Keep, and the same choice in the popover's header. Unanswered
/// in 60 s counts as Keep; a Keep (or a timeout) is remembered for that
/// model for 5 minutes, so an agent retrying isn't asked about again.
@MainActor
final class ModelSwitchPrompter: NSObject, ObservableObject {
    static let shared = ModelSwitchPrompter()

    struct Pending: Equatable {
        let id = UUID()
        /// The requested model's path, and the name to show for it.
        let target: String
        let name: String
        /// Who asked (the client's User-Agent, or "A client").
        let client: String
    }

    @Published private(set) var pending: Pending?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var timeout: Task<Void, Never>?
    private var refusedUntil: [String: Date] = [:]
    private var didSetUpNotifications = false

    static let answerTimeout: TimeInterval = 60
    static let refusalMemory: TimeInterval = 300
    private static let category = "llmtray.modelSwitch"
    private static let switchAction = "switch"
    private static let keepAction = "keep"

    func refusedLately(_ target: String) -> Bool {
        (refusedUntil[target] ?? .distantPast) > Date()
    }

    /// true: switch. Requests for the model already being asked about wait
    /// for the same answer; one for a different model while that's up is
    /// refused (one question at a time).
    func ask(target: String, name: String, client: String) async -> Bool {
        if let pending, pending.target != target { return false }
        if pending == nil {
            let request = Pending(target: target, name: name, client: client)
            pending = request
            notify(request)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.answerTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.answer(false, for: request.id)
            }
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// The user's answer (Switch: true). `id`: only if that request is
    /// still the one pending (a late notification action for an old one is
    /// ignored).
    func answer(_ allow: Bool, for id: UUID? = nil) {
        guard let current = pending, id == nil || id == current.id else { return }
        if !allow { refusedUntil[current.target] = Date().addingTimeInterval(Self.refusalMemory) }
        pending = nil
        timeout?.cancel()
        timeout = nil
        if Self.canNotify {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [current.id.uuidString])
        }
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume(returning: allow) }
    }

    // MARK: - Notification

    /// UNUserNotificationCenter traps without an app bundle (a `swift run`
    /// build): then only the header asks.
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    private func notify(_ request: Pending) {
        guard Self.canNotify else { return }
        let center = UNUserNotificationCenter.current()
        if !didSetUpNotifications {
            didSetUpNotifications = true
            center.delegate = self
            center.setNotificationCategories([UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.switchAction, title: NSLocalizedString("Switch", comment: "model switch notification action")),
                    UNNotificationAction(identifier: Self.keepAction, title: NSLocalizedString("Keep", comment: "model switch notification action")),
                ],
                intentIdentifiers: []
            )])
        }
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Switch models?", comment: "model switch notification title")
        content.body = String(format: NSLocalizedString("%1$@ asks for %2$@. Switching unloads the model loaded now.", comment: "model switch notification: client, model"),
                              request.client, request.name)
        content.categoryIdentifier = Self.category
        let note = UNNotificationRequest(identifier: request.id.uuidString, content: content, trigger: nil)
        Task {
            // Refused: the popover's header still asks.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(note)
        }
    }
}

extension ModelSwitchPrompter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let id = UUID(uuidString: response.notification.request.identifier)
        Task { @MainActor in
            switch action {
            case Self.switchAction: ModelSwitchPrompter.shared.answer(true, for: id)
            case Self.keepAction: ModelSwitchPrompter.shared.answer(false, for: id)
            default: break   // clicked: the popover's header has the choice
            }
        }
        completionHandler()
    }
}
