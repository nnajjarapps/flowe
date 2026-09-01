import StoreKit
import Observation

/// Instructor subscription tiers. Rank orders them (Boost > Visible) for entitlement resolution.
enum SubscriptionTier: Int, CaseIterable, Identifiable {
    case visible = 1
    case boost = 2

    var id: Int { rawValue }
    var rank: Int { rawValue }

    var productID: String {
        switch self {
        case .visible: return "com.flowepilates.app.visible.monthly"
        case .boost:   return "com.flowepilates.app.boost.monthly"
        }
    }

    init?(productID: String) {
        switch productID {
        case SubscriptionTier.visible.productID: self = .visible
        case SubscriptionTier.boost.productID:   self = .boost
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .visible: return "Flowe Visible"
        case .boost:   return "Flowe Boost"
        }
    }

    var tagline: String {
        switch self {
        case .visible: return "Appear in the student feed"
        case .boost:   return "Featured — appear higher, reach more students"
        }
    }

    var mapsToVisibility: InstructorVisibility {
        switch self {
        case .visible: return .visible
        case .boost:   return .boosted
        }
    }
}

/// StoreKit 2 subscription manager (@MainActor @Observable). App-lifetime singleton; loads products,
/// tracks the active entitlement, and listens for renewals/refunds/cross-device changes.
@MainActor
@Observable
final class SubscriptionService {
    private(set) var products: [Product] = []
    private(set) var tier: SubscriptionTier?
    private(set) var isLoading = false
    var purchaseError: String?

    /// Appears in the feed (Visible or Boost).
    var isVisible: Bool { tier != nil }
    /// Featured placement (Boost).
    var isBoosted: Bool { tier == .boost }

    init() {
        _ = listenForTransactions()
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    func product(for tier: SubscriptionTier) -> Product? {
        products.first { $0.id == tier.productID }
    }

    /// Whether a FREE TRIAL is configured for this tier in App Store Connect AND this Apple ID is still
    /// eligible for it. False when no intro offer exists (the current Visible state — the offer was
    /// removed in ASC) or when the configured offer is a discounted intro price rather than a free
    /// trial. Trial length/existence is never assumed here; ASC is the source of truth.
    func introOfferAvailable(for tier: SubscriptionTier) async -> Bool {
        guard let sub = product(for: tier)?.subscription,
              let offer = sub.introductoryOffer,
              offer.paymentMode == .freeTrial else { return false }
        return await sub.isEligibleForIntroOffer
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        let ids = SubscriptionTier.allCases.map(\.productID)
        let loaded = (try? await Product.products(for: ids)) ?? []
        products = loaded.sorted {
            (SubscriptionTier(productID: $0.id)?.rank ?? 0) < (SubscriptionTier(productID: $1.id)?.rank ?? 0)
        }
    }

    @discardableResult
    func purchase(_ tier: SubscriptionTier) async -> Bool {
        guard let product = product(for: tier) else {
            purchaseError = "This subscription isn't available right now."
            return false
        }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                    // THEN apply the transaction we just verified — order matters.
                    //
                    // `Transaction.currentEntitlements` is not guaranteed to contain a transaction
                    // the instant after `finish()`; StoreKit updates that set asynchronously. So the
                    // refresh above can resolve to the PREVIOUS tier, or to nil, and its last line is
                    // `tier = current?.tier` — which would wipe anything set beforehand. That race is
                    // exactly the "tap Subscribe twice before the app shows the current plan" symptom.
                    //
                    // The just-verified transaction is BY DEFINITION the most recent purchase, which
                    // is the same rule `refreshEntitlements` resolves by — so it wins outright, and it
                    // also covers the case where the entitlement set had not caught up at all.
                    // `self.` is required: the function parameter is also named `tier`.
                    if let bought = SubscriptionTier(productID: transaction.productID) {
                        self.tier = bought
                        // ...and TELL THE BACKEND. `refreshEntitlements` above already reported what it
                        // resolved — which is tier 0 whenever `currentEntitlements` has not caught up
                        // yet — so without this the server keeps a "not subscribed" record for someone
                        // who just paid. The local tier was corrected here and the mirror was not,
                        // which is how a fresh purchase showed a celebration and still read as
                        // unsubscribed everywhere the server is the source of truth.
                        await reportEntitlementToBackend(transaction, tier: bought)
                    }
                    return true
                case .unverified(let transaction, _):
                    // Tampered / unverifiable receipt: grant nothing, but finish it so StoreKit
                    // stops redelivering it on every launch, and tell the user it didn't go through.
                    await transaction.finish()
                    purchaseError = "We couldn't verify that purchase. Please try again."
                    return false
                }
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            purchaseError = error.localizedDescription
            return false
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Resolve the active tier from current entitlements — highest rank among verified,
    /// non-revoked auto-renewables (guards the transient upgrade window).
    func refreshEntitlements() async {
        #if DEBUG
        // Two-party / dev test harness: `-flowe.debugBypassStoreKit 1` grants a full (Boost)
        // entitlement WITHOUT any StoreKit purchase — StoreKit sandbox is unavailable/flaky in the
        // simulator and the agent can't run purchase flows. Everything gated on `isVisible`/`tier`
        // (the "Get discovered" banner, paywall, Studio-wizard step 4, events, out-of-studio, share)
        // then behaves as a real subscriber, and the `tier` change flows through
        // `FlowApp.onChange` → `applyVisibility` so the listing publishes `visibility>0`. Never ships.
        if UserDefaults.standard.bool(forKey: "flowe.debugBypassStoreKit") {
            tier = .visible
            return
        }
        #endif
        // Resolve to the MOST-RECENTLY-PURCHASED active entitlement — the tier the instructor last
        // chose — NOT the highest-ranked one. Both tiers live in ONE subscription group, so switching
        // Boost→Visible is a crossgrade; during the overlap StoreKit can briefly report BOTH the old
        // Boost and the new Visible entitlement. Picking by rank (the previous logic) always kept
        // Boost, so "subscribe to Visible" stayed stuck on Boost forever. `purchaseDate` on an
        // auto-renewable is its latest renewal/purchase, so the newer choice wins; on a genuine
        // upgrade Visible→Boost the Boost transaction is newer and still wins correctly.
        var current: (tier: SubscriptionTier, purchased: Date, tx: Transaction)?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil,
                  let t = SubscriptionTier(productID: transaction.productID) else { continue }
            if current == nil || transaction.purchaseDate > current!.purchased {
                current = (t, transaction.purchaseDate, transaction)
            }
        }
        tier = current?.tier
        await reportEntitlementToBackend(current?.tx, tier: current?.tier)
    }

    /// Mirror the resolved entitlement to Flowe's backend. StoreKit remains the authority on THIS
    /// device — this only gives the platform its own record, so a lapse or a paying-but-invisible
    /// instructor is answerable server-side instead of being inferable only from a CloudKit field the
    /// instructor's own device wrote. Reported on every refresh (launch, purchase, `Transaction.updates`),
    /// including the lapse case, where tier 0 is what clears the row.
    private func reportEntitlementToBackend(_ transaction: Transaction?, tier: SubscriptionTier?) async {
        await FloweBackendClient.shared.reportEntitlement(
            tier: tier?.rawValue ?? 0,
            productID: transaction?.productID,
            expiresAt: transaction?.expirationDate,
            // `originalID` is stable across renewals AND reinstalls — the one id that identifies this
            // subscription for its whole life, which `id` (per-transaction) does not.
            originalID: transaction.map { String($0.originalID) },
            environment: transaction.map { "\($0.environment)" }
        )
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await update in Transaction.updates {
                var applied: (SubscriptionTier, Transaction)?
                if case .verified(let transaction) = update {
                    await transaction.finish()
                    // A live, non-revoked auto-renewable tells us the tier directly. Keep it so we can
                    // re-apply it AFTER the refresh below.
                    if transaction.revocationDate == nil,
                       (transaction.expirationDate ?? .distantFuture) > Date(),
                       let t = SubscriptionTier(productID: transaction.productID) {
                        applied = (t, transaction)
                    }
                }
                await self?.refreshEntitlements()
                // Same race `purchase()` guards against, reached from the other direction:
                // `refreshEntitlements` ends with `tier = current?.tier`, so if
                // `Transaction.currentEntitlements` has not caught up it wipes a tier that IS valid —
                // and an update fires right after a purchase, which is exactly when it has not caught
                // up. Re-apply the transaction we just verified; it is by definition the newest.
                if let (t, tx) = applied, await self?.tier != t {
                    await MainActor.run { self?.tier = t }
                    await self?.reportEntitlementToBackend(tx, tier: t)
                }
            }
        }
    }
}
