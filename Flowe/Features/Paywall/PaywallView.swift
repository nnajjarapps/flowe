import SwiftUI
import StoreKit

/// Instructor subscription paywall — "Get discovered". Presents the two tiers (Visible / Boost),
/// the free trial, current status, and the App-Review-required disclosures + restore.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionService.self) private var subscription

    @State private var purchasing: SubscriptionTier?
    @State private var restoring = false
    @State private var trialEligible = true
    @State private var showPrivacy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FlowSpacing.xl) {
                    hero
                        .floweAppear(0)
                    ForEach(Array(SubscriptionTier.allCases.enumerated()), id: \.element) { index, tier in
                        tierCard(tier)
                            .floweAppear(index + 1)
                    }
                    if subscription.products.isEmpty {
                        Text("Fetching the latest prices…")
                            .font(FloweFont.mono(10))
                            .foregroundStyle(Color.floweMuted)
                    }
                    footer
                }
                .padding(20)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle("Get Discovered")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(Color.floweMuted)
                }
            }
            // Re-check once `products` actually finishes loading, not just on first appear —
            // SubscriptionService.init() kicks off loadProducts() as its own detached Task, so this
            // view can appear (and check eligibility against a still-empty product list) before that
            // finishes. A plain one-shot `.task` would then get stuck reporting false forever; keying
            // on whether products are still empty re-runs it the moment they populate.
            .task(id: subscription.products.isEmpty) {
                trialEligible = await subscription.introOfferAvailable(for: .visible)
            }
            .sheet(isPresented: $showPrivacy) {
                LegalDocumentView(resource: LegalDoc.privacy.resource, title: LegalDoc.privacy.title)
            }
            // Surface purchase failures — StoreKit errors, an unavailable product, or an
            // unverifiable receipt. Without this the spinner just reverts and the user is left
            // guessing whether anything happened.
            .alert("Purchase failed", isPresented: Binding(
                get: { subscription.purchaseError != nil },
                set: { if !$0 { subscription.purchaseError = nil } }
            )) {
                Button("OK", role: .cancel) { subscription.purchaseError = nil }
            } message: {
                Text(subscription.purchaseError ?? "")
            }
        }
    }

    // MARK: Hero + status

    private var hero: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.flowePink.opacity(0.12)).frame(width: 76, height: 76)
                Image(systemName: "sparkles")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            Text("Get discovered")
                .font(FloweFont.serif(24))
                .foregroundStyle(Color.floweInk)
            Text(statusMessage)
                .font(FloweFont.sans(14))
                .foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)
        }
    }

    private var statusMessage: String {
        switch subscription.tier {
        case .boost:   return "You're Boosted — featured in the student feed."
        case .visible: return "You're Visible in the student feed."
        case nil:      return "Subscribe so students can find and book you."
        }
    }

    // MARK: Tier card

    /// The concrete perks each tier unlocks beyond its tagline, shown as check bullets so the paywall
    /// makes the per-tier value explicit: Visible → community events + out-of-studio cover; Boost → the
    /// Visible superset + the recruiting Opportunities marketplace. `LocalizedStringKey` so they localize.
    private static func features(for tier: SubscriptionTier) -> [LocalizedStringKey] {
        switch tier {
        case .visible: return ["Post community events", "Request cover when you're out of studio"]
        case .boost:   return ["Everything in Visible", "Post recruiting opportunities"]
        }
    }

    private func tierCard(_ tier: SubscriptionTier) -> some View {
        let product = subscription.product(for: tier)
        let isCurrent = subscription.tier == tier
        // Show the trial for new Visible subscribers; if a product is loaded, respect its eligibility.
        let showTrial = tier == .visible && !isCurrent && (product == nil || trialEligible)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.title).font(FloweFont.serif(18)).foregroundStyle(Color.floweInk)
                    Text(tier.tagline).font(FloweFont.sans(12)).foregroundStyle(Color.floweMuted)
                }
                Spacer()
                if let product {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(product.displayPrice).font(FloweFont.serif(18, .medium)).foregroundStyle(Color.floweInk)
                        Text("/month").font(FloweFont.mono(9)).foregroundStyle(Color.floweMuted)
                    }
                }
            }

            if showTrial {
                Label(Self.trialLabel(for: product), systemImage: "gift")
                    .font(FloweFont.sans(12, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            // Per-tier feature bullets — make each subscription's concrete unlocks explicit (replaces the
            // single Boost-only "featured placement" line). Accurate to what the tiers actually gate.
            // Enumerate for a stable Int id — LocalizedStringKey isn't Hashable, so `id: \.self` won't compile.
            ForEach(Array(Self.features(for: tier).enumerated()), id: \.offset) { _, feature in
                Label(feature, systemImage: "checkmark.seal")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
            }

            Button {
                Task { await buy(tier) }
            } label: {
                Group {
                    if purchasing == tier {
                        ProgressView().tint(.white)
                    } else {
                        Text(buttonTitle(tier: tier, isCurrent: isCurrent, showTrial: showTrial))
                            .font(FloweFont.sans(15, .medium))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(isCurrent ? AnyShapeStyle(Color.floweMuted.opacity(0.4)) : AnyShapeStyle(FlowGradients.gradDark))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .flowePressable()
            .disabled(isCurrent || product == nil || purchasing != nil)
        }
        .padding(16)
        .floweCard()
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tier == .boost ? Color.flowePinkDeep.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
    }

    /// Reads the trial length straight from StoreKit's `introductoryOffer.period` instead of hardcoding
    /// a guess — App Store Connect is the source of truth for how long the trial actually is, and this
    /// keeps the on-screen copy from ever silently drifting out of sync with it again.
    private static func trialLabel(for product: Product?) -> String {
        guard let product, let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else {
            return "Free trial"
        }
        let n = offer.period.value
        let unit: String
        switch offer.period.unit {
        case .day:   unit = n == 1 ? "day" : "days"
        case .week:  unit = n == 1 ? "week" : "weeks"
        case .month: unit = n == 1 ? "month" : "months"
        case .year:  unit = n == 1 ? "year" : "years"
        @unknown default: unit = "period"
        }
        return "\(n) \(unit) free, then \(product.displayPrice)/month"
    }

    private func buttonTitle(tier: SubscriptionTier, isCurrent: Bool, showTrial: Bool) -> String {
        if isCurrent { return "Current plan" }
        if showTrial { return "Start free trial" }
        if subscription.tier == .visible && tier == .boost { return "Upgrade to Boost" }
        return "Subscribe"
    }

    private func buy(_ tier: SubscriptionTier) async {
        purchasing = tier
        defer { purchasing = nil }
        _ = await subscription.purchase(tier)
    }

    // MARK: Footer (restore + disclosures)

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                Task { restoring = true; await subscription.restore(); restoring = false }
            } label: {
                Text(restoring ? "Restoring…" : "Restore Purchases")
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            .buttonStyle(.plain)

            Text("Subscriptions renew monthly until cancelled. Cancel anytime in Settings › Apple ID › Subscriptions. Payment is charged to your Apple Account.")
                .font(FloweFont.sans(11))
                .foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Text("·").foregroundStyle(Color.floweMuted)
                Button("Privacy Policy") { showPrivacy = true }
            }
            .font(FloweFont.mono(10))
            .tint(Color.flowePinkDeep)
        }
        .padding(.top, 4)
    }
}
