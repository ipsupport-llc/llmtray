import AppKit
import LLMTrayCore
#if APP_STORE
import StoreKit
#endif
import SwiftUI

extension Notification.Name {
    /// Opens the "Support LLMTray" window (AppDelegate).
    static let showSupport = Notification.Name("LLMTray.showSupport")
}

/// The supporters list (adr/0017 §5): the copy cached from ipsupport-api
/// (checked again when read), else the one bundled in the app, refreshed at
/// most once a day when the Support window opens. Offline it shows what it
/// has.
@MainActor
final class SupportersStore: ObservableObject {
    static let shared = SupportersStore()

    @Published private(set) var list: SupportersList = .empty
    private let client = SupportersClient(userAgent: "LLMTray/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
    /// Set only when a fetch succeeded: an offline try doesn't wait a day.
    private var lastFetch: Date?
    private var fetching = false
    /// The highest version ever accepted, kept apart from the cached copy:
    /// an older signed pair put back in the cache can't roll the list back.
    private static let floorKey = "llmtray.supporters.version"
    private var versionFloor: Int {
        get { UserDefaults.standard.integer(forKey: Self.floorKey) }
        set { UserDefaults.standard.set(max(newValue, versionFloor), forKey: Self.floorKey) }
    }

    private static var cacheBody: URL { URL(fileURLWithPath: RuntimePaths.externalRuntimeDir).appendingPathComponent("supporters.json") }
    private static var cacheSignature: URL { cacheBody.appendingPathExtension("sig") }

    private init() {
        if let body = try? Data(contentsOf: Self.cacheBody),
           let signature = try? String(contentsOf: Self.cacheSignature, encoding: .utf8),
           let cached = try? SupportersVerifier.verify(body: body, signature: signature),
           cached.version >= versionFloor {
            list = cached
            versionFloor = cached.version
        }
        if let url = Bundle.main.url(forResource: "supporters", withExtension: "json"),
           let data = try? Data(contentsOf: url), let bundled = try? SupportersVerifier.decode(data),
           SupportersVerifier.isNewer(bundled, than: list) {
            list = bundled
        }
    }

    func refreshIfDue() {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 86_400 { return }
        guard !fetching else { return }
        fetching = true
        Task {
            defer { fetching = false }
            guard let fetched = await client.fetch() else { return }
            lastFetch = Date()
            guard SupportersVerifier.isNewer(fetched.list, than: list), fetched.list.version >= versionFloor else { return }
            list = fetched.list
            versionFloor = fetched.list.version
            try? FileManager.default.createDirectory(at: Self.cacheBody.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fetched.body.write(to: Self.cacheBody, options: .atomic)
            try? fetched.signature.write(to: Self.cacheSignature, atomically: true, encoding: .utf8)
        }
    }

    func submit(_ listing: SupporterListing) async -> SupportersClient.SubmitResult {
        await client.submit(listing)
    }
}

#if APP_STORE
/// Tips through StoreKit 2 (adr/0017 §2): Coffee and Pro are consumable,
/// Founding non-consumable (it's a status: restored on a new Mac). Nothing
/// unlocks anything.
@MainActor
final class TipJar: ObservableObject {
    static let shared = TipJar()

    struct Purchase: Identifiable {
        let tier: SupporterTier
        let jws: String
        var id: String { jws }
    }

    @Published private(set) var products: [SupporterTier: Product] = [:]
    @Published private(set) var busy: SupporterTier?
    @Published private(set) var foundingOwned = false
    @Published var justBought: Purchase?
    @Published var error: String?
    private var updates: Task<Void, Never>?

    /// Purchases not offered for listing yet (one that arrived while the
    /// window was closed: Ask to Buy approved later, bought before the
    /// window was ever opened): offered the next time it opens. Only the
    /// tier and StoreKit's signed transaction -- the proof a listing sends.
    private static let pendingKey = "llmtray.supporters.pendingListings"
    private var pending: [[String: String]] {
        get { UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String: String]] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingKey) }
    }

    private init() {}

    /// At launch: purchases that arrive at any time (Ask to Buy, another
    /// Mac) and ones never finished (the app quit mid-purchase) are
    /// finished and kept for listing.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates { await self?.handle(result) }
        }
        Task { [weak self] in
            for await result in StoreKit.Transaction.unfinished { await self?.handle(result) }
            await self?.refreshFounding()
        }
    }

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        guard transaction.revocationDate == nil, let tier = SupporterTier(productID: transaction.productID) else { return }
        remember(Purchase(tier: tier, jws: result.jwsRepresentation))
        await refreshFounding()
    }

    private func remember(_ purchase: Purchase) {
        guard !pending.contains(where: { $0["jws"] == purchase.jws }) else { return }
        pending.append(["tier": purchase.tier.rawValue, "jws": purchase.jws])
    }

    /// The oldest purchase not offered yet, taken off the queue.
    func takePending() -> Purchase? {
        var queue = pending
        while !queue.isEmpty {
            let entry = queue.removeFirst()
            if let tier = entry["tier"].flatMap(SupporterTier.init(rawValue:)), let jws = entry["jws"] {
                pending = queue
                return Purchase(tier: tier, jws: jws)
            }
        }
        pending = queue
        return nil
    }

    func load() async {
        do {
            let found = try await Product.products(for: SupporterTier.allCases.map(\.productID))
            var byTier: [SupporterTier: Product] = [:]
            for product in found { if let tier = SupporterTier(productID: product.id) { byTier[tier] = product } }
            products = byTier
        } catch {
            self.error = error.localizedDescription
        }
        await refreshFounding()
    }

    func buy(_ tier: SupporterTier) async {
        guard let product = products[tier] else { return }
        busy = tier
        defer { busy = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    error = NSLocalizedString("The App Store couldn't confirm the purchase.", comment: "")
                    return
                }
                await transaction.finish()
                justBought = Purchase(tier: tier, jws: verification.jwsRepresentation)
                await refreshFounding()
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restore() async {
        do { try await AppStore.sync() } catch { self.error = error.localizedDescription }
        await refreshFounding()
    }

    private func refreshFounding() async {
        var owned = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == SupporterTier.founding.productID, t.revocationDate == nil { owned = true }
        }
        foundingOwned = owned
    }
}
#endif

/// The "Support LLMTray" window: one, brought to the front when asked again.
@MainActor
enum SupportWindow {
    private static var window: NSWindow?

    static func show() {
        SupportersStore.shared.refreshIfDue()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = NSLocalizedString("Support LLMTray", comment: "")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SupportView())
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SupportView: View {
    @ObservedObject private var supporters = SupportersStore.shared
    #if APP_STORE
    @ObservedObject private var tips = TipJar.shared
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Support LLMTray").font(.title2.bold())
            Text("No subscriptions. No feature locks. Support development if LLMTray is useful to you.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            tiers
            Divider()
            supportersList
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 460)
        #if APP_STORE
        .task {
            await tips.load()
            if tips.justBought == nil { tips.justBought = tips.takePending() }
        }
        .sheet(item: $tips.justBought) { purchase in
            ListingSheet(tier: purchase.tier, proof: .appStore(jws: purchase.jws))
        }
        #endif
    }

    @ViewBuilder
    private var tiers: some View {
        #if APP_STORE
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SupporterTier.allCases.reversed(), id: \.self) { tier in
                if let product = tips.products[tier] {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: product.displayName).font(.headline)
                            if !product.description.isEmpty {
                                Text(verbatim: product.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if tier == .founding, tips.foundingOwned {
                            Label("Thank you!", systemImage: "star.fill").foregroundStyle(.orange)
                        } else {
                            Button(product.displayPrice) { Task { await tips.buy(tier) } }
                                .disabled(tips.busy != nil)
                        }
                    }
                }
            }
            if tips.products.isEmpty {
                Text("The tips aren't available right now.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Restore Purchases") { Task { await tips.restore() } }.buttonStyle(.link)
                if let error = tips.error { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
            }
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: URL(string: "https://github.com/sponsors/ipsupport-llc")!) {
                Label("Support on GitHub Sponsors", systemImage: "heart.fill")
            }
            Text("One-time: Coffee $5, Pro Supporter $25, Founding Supporter $150.").font(.caption).foregroundStyle(.secondary)
            // Listing a sponsor waits for signing in with GitHub (OAuth): a
            // bare login would let anyone list or remove someone else's
            // entry (ipsupport-api adr/0011). Until then sponsors aren't
            // listed from the app.
        }
        #endif
    }

    private var supportersList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Supporters").font(.headline)
            if supporters.list.supporters.isEmpty {
                Text("Be the first to be listed here.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(SupporterTier.allCases, id: \.self) { tier in
                            let people = supporters.list.ordered.filter { $0.tier == tier }
                            if !people.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tier.title).font(.caption.bold()).foregroundStyle(tier == .founding ? .orange : .secondary)
                                    ForEach(people) { person in
                                        HStack(spacing: 5) {
                                            if tier == .founding { Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption) }
                                            // Plain text, never markup: the name is someone else's.
                                            Text(verbatim: person.name).font(tier == .founding ? .body.bold() : .body)
                                            if let url = person.linkURL {
                                                Link(destination: url) { Image(systemName: "link").font(.caption) }
                                                    .help(url.absoluteString)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

extension SupporterTier {
    var title: String {
        switch self {
        case .founding: return NSLocalizedString("Founding Supporters", comment: "supporters tier")
        case .pro: return NSLocalizedString("Pro Supporters", comment: "supporters tier")
        case .coffee: return NSLocalizedString("Coffee", comment: "supporters tier")
        }
    }
}

/// "List my name in Supporters" (adr/0017 §4): opt-in, the name typed by the
/// user, an optional link; sent with the proof of payment, shown once a
/// person approves it. `proof` nil: a GitHub sponsor types their login.
private struct ListingSheet: View {
    let tier: SupporterTier
    let proof: SupporterListing.Proof?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var link = ""
    @State private var login = ""
    @State private var sponsorTier: SupporterTier = .coffee
    @State private var sending = false
    @State private var result: SupportersClient.SubmitResult?

    private var listing: SupporterListing {
        SupporterListing(name: name, link: link, tier: proof == nil ? sponsorTier : tier,
                         proof: proof ?? .github(login: login))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(proof == nil ? "List my name in Supporters" : "Thank you! List your name in Supporters?").font(.headline)
            Text("Only what you type here is published, after a person has checked it. Never your Apple ID or email.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if proof == nil {
                TextField("Your GitHub login (the sponsoring account)", text: $login)
                Picker("Tier", selection: $sponsorTier) {
                    ForEach(SupporterTier.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
                }
            }
            TextField("Name to show (up to 40 characters)", text: $name)
            TextField("Link (optional, https://…)", text: $link)
            if let result { Text(verbatim: message(result)).font(.callout).foregroundStyle(result == .accepted ? .green : .red) }
            HStack {
                Spacer()
                Button(result == .accepted ? "Done" : "No thanks") { dismiss() }
                if result != .accepted {
                    Button("List my name") {
                        sending = true
                        Task {
                            result = await SupportersStore.shared.submit(listing)
                            sending = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || !listing.isValid || (proof == nil && login.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private func message(_ result: SupportersClient.SubmitResult) -> String {
        switch result {
        case .accepted: return NSLocalizedString("Thanks! Your name will appear once it's been checked.", comment: "")
        case .refused: return NSLocalizedString("This couldn't be listed: the payment wasn't found, or the name was refused.", comment: "")
        case .rateLimited: return NSLocalizedString("Too many tries -- please try again later.", comment: "")
        case .retryLater: return NSLocalizedString("Couldn't reach the server -- please try again later.", comment: "")
        }
    }
}
