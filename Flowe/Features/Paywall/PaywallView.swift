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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FlowSpacing.xl) {
                    hero
                    if subscription.products.isEmpty {
                        unavailable
                    } else {
                        ForEach(SubscriptionTier.allCases) { tier in
                            tierCard(tier)
                        }
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
            .task {
                trialEligible = await subscription.introOfferAvailable(for: .visible)
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

    private func tierCard(_ tier: SubscriptionTier) -> some View {
        let product = subscription.product(for: tier)
        let isCurrent = subscription.tier == tier
        let showTrial = tier == .visible && trialEligible && !isCurrent

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
                Label("1 month free, then \(product?.displayPrice ?? "")/month", systemImage: "gift")
                    .font(FloweFont.sans(12, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
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
            .buttonStyle(.plain)
            .disabled(isCurrent || product == nil || purchasing != nil)
        }
        .padding(16)
        .floweCard()
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tier == .boost ? Color.flowePinkDeep.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
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

    private var unavailable: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading subscriptions…")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

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
                Link("Privacy Policy", destination: URL(string: "https://flowepilates.com/privacy")!)
            }
            .font(FloweFont.mono(10))
            .tint(Color.flowePinkDeep)
        }
        .padding(.top, 4)
    }
}

#Preview {
    PaywallView()
        .environment(SubscriptionService())
}
