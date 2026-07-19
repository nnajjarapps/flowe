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

    /// Whether the Visible tier's 1-month free trial is still available to this Apple ID.
    func introOfferAvailable(for tier: SubscriptionTier) async -> Bool {
        guard let sub = product(for: tier)?.subscription,
              sub.introductoryOffer != nil else { return false }
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
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlements()
                    return true
                }
                return false
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
        var best: SubscriptionTier?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil,
                  let t = SubscriptionTier(productID: transaction.productID) else { continue }
            if best == nil || t.rank > best!.rank { best = t }
        }
        tier = best
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlements()
            }
        }
    }
}
