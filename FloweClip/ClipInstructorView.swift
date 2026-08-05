import SwiftUI
import UIKit
import StoreKit

/// Root of the Clip — one screen, driven entirely by `ClipModel.phase`.
struct ClipRootView: View {
    @Environment(ClipModel.self) private var model

    var body: some View {
        ZStack {
            Color.flowWhite.ignoresSafeArea()
            switch model.phase {
            case .idle, .loading:
                ClipLoadingView()
            case .loaded(let instructor):
                ClipInstructorView(instructor: instructor)
            case .notFound:
                ClipMessageView(
                    symbol: "person.crop.circle.badge.questionmark",
                    title: "Profile not available",
                    message: "This instructor link is invalid or the profile is no longer published.",
                    action: nil
                )
            case .offline:
                ClipMessageView(
                    symbol: "wifi.slash",
                    title: "Can't load right now",
                    message: "Check your connection and try again.",
                    action: ("Try again", { model.retry() })
                )
            }
        }
    }
}

// MARK: - Loading

private struct ClipLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.flowePinkDeep)
            Text("Loading profile")
                .font(FloweFont.mono(11))
                .textCase(.uppercase)
                .foregroundStyle(Color.floweMuted)
        }
    }
}

// MARK: - Not-found / offline

private struct ClipMessageView: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    /// Optional (label, action) — present only for the retryable offline state.
    let action: (LocalizedStringKey, () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(Color.flowePink)
            Text(title)
                .font(FloweFont.serif(22, .medium))
                .foregroundStyle(Color.floweInk)
                .multilineTextAlignment(.center)
            Text(message)
                .font(FloweFont.sans(14))
                .foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)
            if let action {
                Button(action: action.1) {
                    Text(action.0).font(FloweFont.sans(15, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.flowePinkDeep)
                .padding(.top, 4)
            }
        }
        .padding(32)
    }
}

// MARK: - Profile

/// A deliberately slim read-only profile — the Clip counterpart to `StudentInstructorProfileView`.
/// Shows identity + the honest facts a viewer needs to decide, then hands off to the full app to book.
/// No reviews wall, no booking flow, no reporting/blocking — those live in the full app.
struct ClipInstructorView: View {
    let instructor: ClipInstructor

    @State private var showAppStoreOverlay = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                stats
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                details
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .background(Color.flowWhite)
        .safeAreaInset(edge: .bottom) { actionRail }
        // The sanctioned "get the full app" CTA for a Clip — not a purchase. Auto-targets the parent app.
        .appStoreOverlay(isPresented: $showAppStoreOverlay) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
    }

    // MARK: Hero

    private var hero: some View {
        heroPhoto
            .aspectRatio(4.0 / 3.0, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 360)
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Color.floweInk.opacity(0.75)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) { heroCaption }
    }

    @ViewBuilder
    private var heroPhoto: some View {
        if let data = instructor.photo, let image = UIImage(data: data) {
            Image(uiImage: image).resizable()
        } else if instructor.img.hasPrefix("http"), let url = URL(string: instructor.img) {
            // Lightweight remote fallback — avoids pulling the app's RemoteImage/caching stack.
            AsyncImage(url: url) { $0.resizable() } placeholder: { gradientHero }
        } else {
            gradientHero
        }
    }

    private var gradientHero: some View {
        LinearGradient(colors: [.flowePinkSoft, .flowePinkDeep],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "figure.pilates")
                    .font(.system(size: 96))
                    .foregroundStyle(.white.opacity(0.18))
                    .padding(24)
            }
    }

    private var heroCaption: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !instructor.address.isEmpty {
                Text(instructor.address)
                    .font(FloweFont.mono(11))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Text(instructor.name)
                .font(FloweFont.serif(30, .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: Color.floweInk.opacity(0.35), radius: 8, y: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: Stats

    private var stats: some View {
        HStack(spacing: 12) {
            ClipStatTile(value: instructor.yearsExp > 0 ? "\(instructor.yearsExp)" : "\u{2014}",
                         label: "YEARS",
                         muted: instructor.yearsExp == 0)
            ClipStatTile(value: instructor.price > 0 ? priceLabel(instructor.price) : "\u{2014}",
                         label: "STARTING",
                         muted: instructor.price == 0)
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let bio = instructor.bio, !bio.isEmpty {
                section("ABOUT") {
                    Text(bio)
                        .font(FloweFont.sans(15))
                        .foregroundStyle(Color.floweInk)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !instructor.specialties.isEmpty {
                section("SPECIALTIES") {
                    ClipChips(items: instructor.specialties)
                }
            }
            if !instructor.address.isEmpty {
                section("STUDIO LOCATION") {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.flowePinkDeep)
                        Text(instructor.address)
                            .font(FloweFont.sans(14))
                            .foregroundStyle(Color.floweInk)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(FloweFont.mono(10))
                .textCase(.uppercase)
                .foregroundStyle(Color.floweMuted)
            content()
        }
    }

    // MARK: Action rail

    private var actionRail: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
            VStack(spacing: 8) {
                Button { showAppStoreOverlay = true } label: {
                    Text("Get the full app to book")
                        .font(FloweFont.sans(16, .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(colors: [.flowePink, .flowePinkDeep],
                                           startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                }
                .buttonStyle(.plain)
                Text("Free to book in the app. You'll pay \(instructor.firstName) directly.")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .background(Color.flowWhite)
    }

    // MARK: Helpers

    /// The Clip has no `AppSettings.money(_:)`, so it formats a plain amount. Israel-first pilot →
    /// shekel symbol. Swap to a locale/currency formatter if the Clip ever ships beyond IL.
    private func priceLabel(_ amount: Int) -> String { "\u{20AA}\(amount)" }
}

// MARK: - Small pieces

private struct ClipStatTile: View {
    let value: String
    let label: LocalizedStringKey
    let muted: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(FloweFont.serif(22, .medium))
                .foregroundStyle(muted ? Color.floweMuted : Color.flowePinkDeep)
            Text(label)
                .font(FloweFont.mono(9))
                .textCase(.uppercase)
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// A minimal wrapping chip row (no dependency on the app's FlowLayout).
private struct ClipChips: View {
    let items: [String]

    var body: some View {
        FlowWrap(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)   // raw user text — never localized
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.flowePinkDeep)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.flowePink.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Tiny flow layout (iOS 16+ `Layout`) so specialty chips wrap instead of clipping. Self-contained to
/// keep the Clip independent of the app's `FlowLayout`.
private struct FlowWrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0, totalHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
