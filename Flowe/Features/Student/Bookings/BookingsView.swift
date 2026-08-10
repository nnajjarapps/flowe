import SwiftUI

private enum BookingTab: String, CaseIterable {
    case upcoming, past

    var label: String { rawValue.capitalized }
}

/// "My Sessions" — stat row, Upcoming/Past segmented control, and the booking list.
struct BookingsView: View {
    @Environment(MockDataStore.self) private var data

    @State private var tab: BookingTab = .upcoming

    /// Namespace for the segmented control's sliding selection pill (matchedGeometryEffect).
    @Namespace private var segNS

    private var list: [Booking] {
        tab == .upcoming ? data.upcomingBookings : data.pastBookings
    }

    var body: some View {
        ScrollView {
            // ONLY the list scrolls. The title/stats/segmented header is pinned via `.safeAreaInset`
            // below — keeping the Upcoming/Past control OUT of the `.refreshable` scroll content, whose
            // pull-gesture otherwise intermittently swallows the segment taps on device (the production
            // "tapping Past does nothing" bug). Mirrors the proven-working CommunityView structure.
            VStack(spacing: 0) {
                if list.isEmpty {
                    if data.bookingsPhase == .loading {
                        // First load with nothing cached: shimmering card skeletons rather than a
                        // lone spinner.
                        bookingSkeleton
                    } else {
                        emptyState
                            .padding(.top, 20)
                    }
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, booking in
                            BookingCard(booking: booking)
                                .floweAppear(index)
                        }
                    }
                    .padding(.top, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color.flowWhite)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .task {
            await data.syncBookings(asInstructor: false)
            // Reviews come along so "Leave a review" flips to "Edit review" after a reinstall.
            await data.syncReviews(asInstructor: false)
            // Auto-celebrate any newly-crossed practice milestone to the community (Flowe Community).
            data.checkMilestones()
        }
        // Manual pull-to-refresh: an instructor's accept/decline lands server-side with no live
        // socket, so a swipe-down is the instant way to see Pending → Confirmed. Mirrors the .task.
        .refreshable {
            await data.syncBookings(asInstructor: false)
            await data.syncReviews(asInstructor: false)
            data.checkMilestones()
        }
    }

    /// Pinned header — title, stats, and the Upcoming/Past control. Sits in a `.safeAreaInset` OUTSIDE
    /// the scroll so its taps are never contended by the ScrollView's `.refreshable` pull-gesture.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            statRow.padding(.top, 16)
            segmented.padding(.top, 16)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Color.flowWhite)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
        }
    }

    // MARK: Title

    private var title: some View {
        // 28pt matches the app's screen-title scale (Community/Messages); the old 20pt made this
        // screen's header read as a subheading next to its siblings.
        (
            Text("My ")
                .font(FloweFont.serif(28))
            + Text("Sessions")
                .font(FloweFont.serif(28, .regular, italic: true))
        )
        .foregroundStyle(Color.floweInk)
    }

    // MARK: Stat row

    private var statRow: some View {
        HStack(spacing: 8) {
            StatTile(value: "\(data.upcomingCount)", label: "Upcoming", accent: .flowePinkDeep)
            StatTile(value: "\(data.completedCount)", label: "Completed", accent: .floweSuccess)
            StatTile(value: data.hoursDisplay, label: "Hours", accent: .flowePinkSoft)
        }
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        FeedPlaceholder(phase: data.bookingsPhase,
                        retry: { Task { await data.syncBookings(asInstructor: false) } }) {
            switch tab {
            case .upcoming:
                EmptyStateView(
                    icon: "calendar.badge.plus",
                    title: "No sessions yet",
                    message: "Book a class from Discover to see your upcoming sessions here."
                )
            case .past:
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "No past sessions",
                    message: "Once you complete a class, it'll show up here."
                )
            }
        }
    }

    // MARK: Segmented control

    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(BookingTab.allCases, id: \.self) { t in
                Button {
                    guard tab != t else { return }
                    Haptic.selection()
                    // matchedGeometryEffect on the selected pill's background + FloweMotion.pop
                    // slides it between segments instead of cross-fading in place.
                    withAnimation(FloweMotion.pop) { tab = t }
                } label: {
                    Text(LocalizedStringKey(t.label))
                        .font(FloweFont.sans(12, .medium))
                        .foregroundStyle(tab == t ? Color.floweInk : Color.floweMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if tab == t {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.flowWhite)
                                    .shadow(color: Color.flowePink.opacity(0.15), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "segPill", in: segNS)
                            }
                        }
                        // Unselected tab's Color.clear background isn't hit-tested — make the whole pill tappable.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Loading skeleton

    /// Shimmering placeholder cards shown during the first bookings load (see `body`).
    private var bookingSkeleton: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.floweCardBg)
                        .frame(height: 68)
                    HStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.floweCardBg)
                            .frame(width: 110, height: 12)
                        Spacer()
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.floweCardBg)
                            .frame(width: 60, height: 12)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .floweCard()
                .floweShimmer(true)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 24)
    }
}
