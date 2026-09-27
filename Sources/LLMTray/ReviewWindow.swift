import AppKit
import LLMTrayCore
import SwiftUI

extension Notification.Name {
    /// Opens the "Rate LLMTray" window (AppDelegate).
    static let showReview = Notification.Name("LLMTray.showReview")
}

/// The review being written and its send: the draft is kept in
/// UserDefaults until the server takes it, so a send that failed (no
/// network, a 5xx) can be tried again later with the same idempotency key.
@MainActor
final class ReviewStore: ObservableObject {
    static let shared = ReviewStore()

    enum State: Equatable {
        case editing
        case sending
        case accepted
        case rejected(code: String)
        case rateLimited(seconds: Int?)
        case retryLater
    }

    @Published var draft: ReviewDraft {
        didSet { if draft != oldValue { save() } }
    }
    @Published private(set) var state: State = .editing
    /// The published reviews' count and average, when they could be read.
    @Published private(set) var summary: ReviewFeed.Summary?

    private let defaults: UserDefaults
    private let client: ReviewClient

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        client = ReviewClient(userAgent: "LLMTray/" + ReviewStore.appVersion)
        draft = defaults[Pref.reviewDraft].flatMap { try? JSONDecoder().decode(ReviewDraft.self, from: $0) } ?? ReviewDraft()
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// A review was accepted before (this or another time).
    var hasReviewed: Bool { defaults[Pref.reviewSubmittedAt] > 0 }

    /// The window opens: after an accepted review, a fresh form.
    func prepare() {
        if state == .accepted { state = .editing }
        if state != .sending, summary == nil { loadSummary() }
    }

    /// Why the draft can't be sent as it is; nil when it can.
    var validationError: ReviewValidationError? {
        do {
            _ = try submission()
            return nil
        } catch {
            return error as? ReviewValidationError ?? .tooLarge
        }
    }

    private func submission() throws -> ReviewSubmission {
        try ReviewSubmission(rating: draft.rating, text: draft.text, author: draft.author, version: Self.appVersion)
    }

    func send() {
        guard state != .sending, let submission = try? submission() else { return }
        state = .sending
        Task { await send(submission, renewingKeyOnce: true) }
    }

    private func send(_ submission: ReviewSubmission, renewingKeyOnce: Bool) async {
        let key = draft.key(for: submission)
        save()
        let outcome = await client.submit(submission, key: key)
        switch outcome {
        case .accepted:
            draft = ReviewDraft()
            defaults[Pref.reviewDraft] = nil
            defaults[Pref.reviewSubmittedAt] = Date().timeIntervalSince1970
            state = .accepted
            ReviewPrompter.shared.refresh()
        case .keyReused where renewingKeyOnce:
            // The key went with another body before: this content is new to the server.
            draft.dropKey()
            await send(submission, renewingKeyOnce: false)
        case .keyReused:
            // Refused twice: a client problem, not the network.
            state = .rejected(code: "idempotency_key_reused")
        case .rejected(let code):
            state = .rejected(code: code)
        case .rateLimited(let seconds):
            state = .rateLimited(seconds: seconds)
        case .retryLater:
            state = .retryLater
        }
    }

    /// Editing after an error clears it.
    func edited() {
        switch state {
        case .rejected, .rateLimited, .retryLater: state = .editing
        case .editing, .sending, .accepted: break
        }
    }

    private func save() {
        defaults[Pref.reviewDraft] = draft.isEmpty && draft.idempotencyKey == nil ? nil : try? JSONEncoder().encode(draft)
    }

    private func loadSummary() {
        let client = client
        Task {
            if let feed = try? await client.feed() { summary = feed.summary }
        }
    }
}

/// The chat's one-time "Enjoying LLMTray?" row: a day after the first
/// launch, after one answer (ReviewPromptPolicy).
@MainActor
final class ReviewPrompter: ObservableObject {
    static let shared = ReviewPrompter()

    @Published private(set) var isDue = false
    private let defaults = UserDefaults.standard

    private init() {}

    /// At launch: the first one is when the week starts.
    func recordLaunch() {
        if defaults[Pref.reviewFirstLaunch] == 0 { defaults[Pref.reviewFirstLaunch] = Date().timeIntervalSince1970 }
        refresh()
    }

    /// A chat answer completed without an error.
    func recordAnswer() {
        defaults[Pref.reviewAnswerCount] += 1
        refresh()
    }

    func later() {
        defaults[Pref.reviewPromptSnoozedUntil] = ReviewPromptPolicy.snoozed(from: Date()).timeIntervalSince1970
        refresh()
    }

    func never() {
        defaults[Pref.reviewPromptNever] = true
        refresh()
    }

    func refresh() {
        func date(_ key: PrefKey<Double>) -> Date? {
            let value = defaults[key]
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        let due = ReviewPromptPolicy.shouldPrompt(
            now: Date(), firstLaunch: date(Pref.reviewFirstLaunch), answers: defaults[Pref.reviewAnswerCount],
            snoozedUntil: date(Pref.reviewPromptSnoozedUntil), neverAsk: defaults[Pref.reviewPromptNever],
            reviewed: defaults[Pref.reviewSubmittedAt] > 0
        )
        if due != isDue { isDue = due }
    }
}

/// "Enjoying LLMTray? Leave a review · Ask later · Don't ask again", under the chat's
/// header. Only between turns, and not in a temporary chat.
struct ReviewPromptRow: View {
    @EnvironmentObject var chat: ChatClient
    @ObservedObject private var prompter = ReviewPrompter.shared
    @ObservedObject private var tabs = ChatTabs.shared

    var body: some View {
        if prompter.isDue, chat.currentSessionID != nil, !chat.isBusy, !tabs.isAnyBusy {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "star.bubble").foregroundColor(.accentColor)
                    Text("Enjoying LLMTray?")
                    Spacer(minLength: 4)
                    Button("Leave a Review") {
                        prompter.later()
                        NotificationCenter.default.post(name: .showReview, object: nil)
                    }
                    Button("Ask Later") { prompter.later() }
                        .help(Text("Ask again in two weeks"))
                    Button("Don't Ask Again") { prompter.never() }
                }
                .font(.system(size: 11))
                .buttonStyle(.link)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
            .onAppear { prompter.refresh() }
        }
    }
}

/// The "Rate LLMTray" window: one, brought to the front when asked again.
@MainActor
enum ReviewWindow {
    private static var window: NSWindow?

    static func show() {
        ReviewStore.shared.prepare()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = NSLocalizedString("Rate LLMTray", comment: "")
            window.isReleasedWhenClosed = false
            // Not in the saved window state: it's the user's text.
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: ReviewView(close: { [weak window] in window?.close() }))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ReviewView: View {
    @ObservedObject private var store = ReviewStore.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.state == .accepted {
                accepted
            } else {
                form
            }
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 340)
    }

    private var accepted: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundColor(.green)
            Text("Thanks! Your review will appear after moderation.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Spacer()
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var form: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("How do you like LLMTray?").font(.headline)
            Spacer()
            if let summary = store.summary, summary.count > 0, let average = summary.average {
                Text(summary.count == 1
                     ? String(format: NSLocalizedString("%@ ★ from 1 review", comment: "review summary: average"), String(format: "%.1f", average))
                     : String(format: NSLocalizedString("%@ ★ from %lld reviews", comment: "review summary: average, count"),
                              String(format: "%.1f", average), summary.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        // Not while sending: what's typed then would go with the accepted draft.
        StarPicker(rating: binding(\.rating))
            .disabled(store.state == .sending)
        TextEditor(text: binding(\.text))
            .font(.body)
            .frame(minHeight: 120)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .accessibilityLabel(Text("Review"))
            .disabled(store.state == .sending)
        HStack {
            TextField("Your name (optional)", text: binding(\.author))
                .textFieldStyle(.roundedBorder)
                .disabled(store.state == .sending)
            let length = ReviewSubmission.textLength(store.draft.text)
            Text(verbatim: "\(length) / \(ReviewSubmission.maxTextLength)")
                .font(.caption.monospacedDigit())
                .foregroundColor(length > ReviewSubmission.maxTextLength ? .red : .secondary)
        }
        Text("Sent to ipsupport.us; no account, no device identifiers. Reviews are published on the LLMTray website after moderation.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        status
        HStack {
            Spacer()
            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
            // ⌘Return: Return is a new line in the text.
            Button { store.send() } label: {
                if store.state == .retryLater { Text("Retry") } else { Text("Send") }
            }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.state == .sending || store.validationError != nil)
        }
    }

    private func binding<T: Equatable>(_ path: WritableKeyPath<ReviewDraft, T>) -> Binding<T> {
        Binding(get: { store.draft[keyPath: path] }, set: { value in
            guard store.draft[keyPath: path] != value else { return }
            store.draft[keyPath: path] = value
            store.edited()
        })
    }

    @ViewBuilder
    private var status: some View {
        switch store.state {
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sending…").foregroundColor(.secondary)
            }
        case .rejected(let code):
            message(Self.rejectionMessage(code), color: .red)
        case .rateLimited(let seconds):
            if let seconds {
                message(String(format: NSLocalizedString("Too many reviews from this network. Try again in %lld min.", comment: ""),
                               max(1, (seconds + 59) / 60)), color: .orange)
            } else {
                message(NSLocalizedString("Too many reviews from this network. Try again later.", comment: ""), color: .orange)
            }
        case .retryLater:
            message(NSLocalizedString("Couldn't reach ipsupport.us. Your review is kept: try again later.", comment: ""), color: .orange)
        case .editing, .accepted:
            if let error = store.validationError, let text = Self.validationMessage(error) {
                message(text, color: .secondary)
            }
        }
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text).font(.callout).foregroundColor(color).fixedSize(horizontal: false, vertical: true)
    }

    /// Only what isn't obvious from the form: an empty one just can't be sent yet.
    private static func validationMessage(_ error: ReviewValidationError) -> String? {
        switch error {
        case .rating, .emptyText: return nil
        case .textTooLong(let length):
            return String(format: NSLocalizedString("The review is %lld characters too long.", comment: ""),
                          length - ReviewSubmission.maxTextLength)
        case .textControlCharacter:
            return NSLocalizedString("The review has characters that can't be sent (control characters).", comment: "")
        case .authorTooLong:
            return String(format: NSLocalizedString("The name can be at most %lld characters.", comment: ""), ReviewSubmission.maxAuthorLength)
        case .authorControlCharacter:
            return NSLocalizedString("The name must be on one line.", comment: "")
        case .tooLarge:
            return NSLocalizedString("The review is too long.", comment: "")
        }
    }

    private static func rejectionMessage(_ code: String) -> String {
        switch code {
        case "invalid_rating": return NSLocalizedString("Pick a rating from 1 to 5 stars.", comment: "")
        case "invalid_text": return NSLocalizedString("The review wasn't accepted: it must be 1 to 2000 characters, without control characters.", comment: "")
        case "invalid_author": return NSLocalizedString("The name wasn't accepted: up to 64 characters, on one line.", comment: "")
        case "invalid_version": return NSLocalizedString("This version of LLMTray can't send reviews. Please update the app.", comment: "")
        default:
            return String(format: NSLocalizedString("The review service didn't accept the request (%@). Please report a bug.", comment: ""), code)
        }
    }
}

/// 1 to 5 stars.
private struct StarPicker: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Button { rating = star } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: 22))
                        .foregroundColor(star <= rating ? .yellow : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(String(format: NSLocalizedString("%lld of 5 stars", comment: ""), star)))
                .accessibilityLabel(Text(String(format: NSLocalizedString("%lld of 5 stars", comment: ""), star)))
            }
        }
        .accessibilityElement(children: .contain)
    }
}
