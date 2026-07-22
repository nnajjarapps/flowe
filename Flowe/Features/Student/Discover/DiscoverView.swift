import SwiftUI
import UIKit

/// Discover screen: greeting header, search, category filter, featured hero, instructor list.
struct DiscoverView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.openURL) private var openURL

    @State private var search = ""
    @State private var filter = "All"
    @State private var selected: Instructor?

    /// On-device only. The student's position is never stored, never published and never even
    /// readable from here — `LocationService` hands out distances, not coordinates.
    @State private var location = LocationService()
    /// Defaults on, so granting permission is itself the opt-in and nothing else has to be tapped.
    /// Inert until a fix exists, which is what `isSortingByDistance` guards.
    @State private var nearestFirst = true

    /// One feed row: the listing plus how far away it is, if that is knowable at all.
    private struct Row: Identifiable {
        let instructor: Instructor
        let distanceMetres: Double?
        var id: Int { instructor.legacyId }
    }

    private var isSortingByDistance: Bool { nearestFirst && location.hasFix }

    private var rows: [Row] {
        let matches = data.visibleInstructors.filter { ins in
            ins.legacyId != featuredInstructor?.legacyId &&
            (filter == "All" || ins.specialties.contains(filter)) &&
            (search.isEmpty
             || ins.name.lowercased().contains(search.lowercased())
             || ins.city.lowercased().contains(search.lowercased()))
        }
        let measured = matches.map {
            Row(instructor: $0,
                distanceMetres: location.distance(toLatitude: $0.latitude, longitude: $0.longitude))
        }
        // `visibleInstructors` is already Boost → rating → order, so this is the whole difference
        // distance makes: nothing when we can't measure.
        guard isSortingByDistance else { return measured }
        return measured.sorted(by: Self.byDistance)
    }

    /// Distance ranks **inside** a visibility tier, never across one.
    ///
    /// Boost is a paid placement: an instructor pays to sit above the unboosted list, and letting a
    /// closer free listing overtake them would be selling something we then don't deliver. So the
    /// tier is compared first and proximity only reorders peers within it — a boosted instructor
    /// still outranks everyone below, and among the boosted ones the nearest comes first.
    ///
    /// A listing with no coordinates sorts last *within its own tier*, never out of the feed: most
    /// instructors have never set an area, and "we don't know how far away this is" is not a reason
    /// to stop showing someone. Ranking them after the measured ones is the honest order — they are
    /// the results the sort could not act on — and they keep their rating order among themselves.
    private static func byDistance(_ lhs: Row, _ rhs: Row) -> Bool {
        let left = lhs.instructor, right = rhs.instructor
        if left.visibilityRaw != right.visibilityRaw { return left.visibilityRaw > right.visibilityRaw }
        if let a = lhs.distanceMetres, let b = rhs.distanceMetres {
            if a != b { return a < b }
        } else if lhs.distanceMetres != nil {
            return true
        } else if rhs.distanceMetres != nil {
            return false
        }
        if left.rating != right.rating { return left.rating > right.rating }
        return left.order < right.order
    }

    /// The instructor to feature: only when browsing the full, unfiltered list and one exists.
    private var featuredInstructor: Instructor? {
        guard filter == "All", search.isEmpty else { return nil }
        return data.featuredInstructor
    }

    /// A `LocalizedStringKey` rather than a composed `String`, so the pattern
    /// ("%@ · %lld INSTRUCTORS") is extracted and can be translated — and reordered, since other
    /// languages won't want the count in this position.
    private var listLabel: LocalizedStringKey {
        let prefix = filter == "All" ? "NEAR YOU" : filter.uppercased()
        return "\(prefix) · \(rows.count) INSTRUCTORS"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                FilterChipsBar(items: FloweConstants.discoverCategories, selection: $filter)
                    .padding(.bottom, 16)

                if let featured = featuredInstructor {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(text: "FEATURED")
                        FeaturedHeroCard(instructor: featured) { selected = featured }
                            .accessibilityIdentifier("discover.instructorCard")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }

                if rows.isEmpty {
                    EmptyStateView(
                        icon: "person.2.slash",
                        title: "No instructors yet",
                        message: "Instructors near you will appear here once they join Flowe."
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 40)
                    .padding(.bottom, 24)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(text: listLabel)
                        VStack(spacing: 12) {
                            ForEach(rows) { row in
                                InstructorCard(instructor: row.instructor,
                                               distanceMetres: row.distanceMetres) {
                                    selected = row.instructor
                                }
                                .accessibilityIdentifier("discover.instructorCard")
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Color.flowWhite)
        .sheet(item: $selected) { ins in
            BookingSheet(instructor: ins) { selected = nil }
        }
        .task { await data.syncCatalog() }
        // Only when the student has already agreed. This never raises the prompt — that is the
        // "Use my location" button's job, and a permission sheet on top of a feed the user just
        // opened is exactly the ambush this app shouldn't spring.
        .task { if location.isAuthorized { await location.refresh() } }
        .refreshable { await data.syncCatalog() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GOOD MORNING")
                        .font(FloweFont.mono(11))
                        .foregroundStyle(Color.flowePinkDeep)
                    (Text("Find your ")
                        .font(FloweFont.serif(22))
                     + Text("instructor.")
                        .font(FloweFont.serif(22, .regular, italic: true)))
                        .foregroundStyle(Color.floweInk)
                }
                Spacer()
                Button {
                } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.floweInk)
                        .frame(width: 36, height: 36)
                        .background(Color.floweCardBg)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.floweBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.floweMuted)
                TextField("", text: $search, prompt: Text("Name or city…").foregroundColor(Color.floweMuted))
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweInk)
                    .autocorrectionDisabled()
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.floweMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.floweCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.floweBorder, lineWidth: 1))

            locationBar
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Location control
    //
    // Three states, all of them normal. Refusal is not an error path: the feed keeps working, the
    // cards keep showing cities, and nothing here ever blocks the list from rendering.

    @ViewBuilder
    private var locationBar: some View {
        if location.isDenied {
            HStack(spacing: 6) {
                Image(systemName: "location.slash")
                    .font(.system(size: 11))
                Text("Location off — sorted by rating. Search by city instead.")
                    .font(FloweFont.sans(11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Settings") { openLocationSettings() }
                    .font(FloweFont.sans(11, .medium))
                    .tint(Color.flowePinkDeep)
                    .accessibilityIdentifier("discover.locationSettings")
            }
            .foregroundStyle(Color.floweMuted)
        } else if location.hasFix {
            HStack(spacing: 8) {
                locationPill(icon: "location.fill", title: "Nearest first", isOn: nearestFirst) {
                    withAnimation(.easeInOut(duration: 0.15)) { nearestFirst.toggle() }
                }
                .accessibilityIdentifier("discover.nearestToggle")
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 8) {
                locationPill(icon: "location", title: "Use my location", isOn: false) {
                    Task { await location.refresh() }
                }
                .disabled(location.isLocating)
                .accessibilityIdentifier("discover.useLocation")

                // Said plainly, next to the button that asks for it — a student's location is used
                // to subtract two numbers and is not stored, uploaded or attached to anything.
                Text("Stays on your device.")
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
                Spacer(minLength: 0)
            }
        }
    }

    private func locationPill(icon: String,
                              title: LocalizedStringKey,
                              isOn: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if location.isLocating {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(isOn ? .white : Color.flowePinkDeep)
                } else {
                    Image(systemName: icon).font(.system(size: 10))
                }
                Text(title).font(FloweFont.sans(12, .medium))
            }
            .foregroundStyle(isOn ? .white : Color.flowePinkDeep)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isOn { Capsule().fill(FlowGradients.gradDark) }
                else { Capsule().fill(Color.flowePink.opacity(0.10)) }
            }
        }
        .buttonStyle(.plain)
    }

    /// Denied permission can only be undone in Settings, so that is what the button offers rather
    /// than a second prompt iOS would silently ignore.
    private func openLocationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

#Preview {
    DiscoverView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
}
