import SwiftUI
import UIKit

/// Discover screen: greeting header, search, category filter, featured hero, instructor list.
struct DiscoverView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    /// Bumped by the tab shell when the already-selected Discover tab is re-tapped;
    /// scrolls the list to the top (see `ScrollToTop` in FloweCommon). A no-op in Map mode.
    @Environment(\.tabReselectTrigger) private var reselectTick

    @State private var search = ""
    @State private var filter = "All"
    @State private var retakeQuiz = false
    @State private var showGuestSignIn = false   // 5.1.1(v): a guest tapping an account action
    @State private var showOpportunities = false
    /// Natural-language search interpretation in flight (Flowe Intelligence).
    @State private var interpreting = false

    /// List (the scrolling feed) vs Map (the same instructors plotted at their exact studio points). A view
    /// toggle, not a data one — both sides read the exact same visible-instructor query.
    private enum DiscoverMode { case list, map }
    @State private var viewMode: DiscoverMode = .list
    /// The tapped row, not just its instructor — carrying `distanceMetres` so the profile can show the
    /// same "~N km" the card did without recomputing (there is no `LocationService` inside the profile).
    @State private var selected: Row?

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
             // A guest can't probe/confirm a street by typing it — address is not searchable for them.
             || (!session.isGuest && ins.address.lowercased().contains(search.lowercased())))
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

    /// The instructors to plot on the map: the SAME `rows` predicate — visibility-filtered source,
    /// specialty match, name/address search — but keeping featured instructors (the map shows everyone)
    /// and adding the `studioCoordinate != nil` gate, since a pin needs a point. Most instructors have
    /// never set a studio location, so this is legitimately shorter than the list; the map's count badge
    /// reports only what's plotted. No sort: pins have no order.
    private var mapInstructors: [Instructor] {
        data.visibleInstructors.filter { ins in
            ins.studioCoordinate != nil &&
            (filter == "All" || ins.specialties.contains(filter)) &&
            (search.isEmpty
             || ins.name.lowercased().contains(search.lowercased())
             || ins.address.lowercased().contains(search.lowercased()))
        }
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

    /// Whether the user has narrowed the list. An empty result then means "nothing matched", which is
    /// a different message from "the catalog is empty".
    private var isSearchingOrFiltering: Bool { !search.isEmpty || filter != "All" }

    /// Composed from separate localized `Text` pieces (not a substituted string) so BOTH the prefix
    /// — "NEAR YOU" or the selected category — and the "%lld INSTRUCTORS" count localize through the
    /// catalog against the environment locale. Substituting a raw `filter` into a `%@` key left the
    /// prefix in English; concatenation keeps every piece translatable (and RTL-mirrors correctly).
    private var listLabel: Text {
        let prefix: LocalizedStringKey = filter == "All" ? "NEAR YOU" : LocalizedStringKey(filter)
        return Text(prefix) + Text(verbatim: " · ") + Text("\(rows.count) INSTRUCTORS")
    }

    var body: some View {
        // The greeting + List/Map toggle stays put across both modes; only what sits under it swaps.
        VStack(spacing: 0) {
            titleRow
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 12)

            if viewMode == .map {
                // The map owns its own floating search + chips (bound to the same `search`/`filter`),
                // and reports selections back through the SAME `selected`/`.sheet(item:)` the list uses.
                InstructorMapView(instructors: mapInstructors,
                                  filter: $filter,
                                  search: $search,
                                  location: location) { ins in
                    selected = Row(instructor: ins,
                                   distanceMetres: location.distance(toLatitude: ins.latitude,
                                                                     longitude: ins.longitude))
                }
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Top anchor for active-tab-reselect scroll-to-top.
                        Color.clear.frame(height: 0).id(ScrollToTop.anchorID)

                        header
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 12)

                        FilterChipsBar(items: FloweConstants.discoverCategories, selection: $filter)
                            .padding(.bottom, 16)
                            // Selection feedback for the category chips (the chip's own pop-scale
                            // lives in FilterChipsBar). `filter` only changes on a chip tap here.
                            .onChange(of: filter) { Haptic.selection() }

                // Personalized matches — only on the default, unfiltered view (owns its own insets).
                if filter == "All", search.isEmpty {
                    RecommendedSection(
                        preferences: session.studentPreferences,
                        distance: { location.distance(toLatitude: $0.latitude, longitude: $0.longitude) },
                        onSelect: { instructor, dist in
                            selected = Row(instructor: instructor, distanceMetres: dist)
                        },
                        onTakeQuiz: { if session.isGuest { showGuestSignIn = true } else { retakeQuiz = true } }
                    )
                    .floweAppear()
                }

                // Opportunities nudge — the student on-ramp into the Flowe Pro career marketplace. Only on
                // the default view, and only when there's actually something open to browse, so it never
                // leads to an empty list (the Profile card is the evergreen entry). See [[FlowePro]].
                // Hidden for a guest: the Flowe Pro career on-ramp is account-based (applying needs an
                // identity), and its Apply button would otherwise self-abort with no sign-in prompt.
                if !session.isGuest, filter == "All", search.isEmpty, !data.studentBrowsableOpportunities.isEmpty {
                    opportunitiesBanner
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .floweAppear()
                }

                if let featured = featuredInstructor {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(text: "FEATURED")
                        FeaturedHeroCard(instructor: featured) {
                            selected = Row(instructor: featured,
                                           distanceMetres: location.distance(toLatitude: featured.latitude,
                                                                             longitude: featured.longitude))
                        }
                            .accessibilityIdentifier("discover.instructorCard")
                            .floweAppear()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }

                if rows.isEmpty {
                    // Only when there is nothing else on screen. When a featured instructor is shown
                    // above, `rows` is empty because that one listing *is* the whole catalog — an
                    // empty state under a real card would tell the user "no instructors" beside one.
                    if featuredInstructor == nil {
                        // While searching/filtering, "no matches" is a real answer about the query, not
                        // a load state — so only defer to the load phase when the user isn't filtering.
                        if isSearchingOrFiltering {
                            EmptyStateView(
                                icon: "magnifyingglass",
                                title: "No matches",
                                message: "No instructors match — try a different search or category."
                            )
                            .padding(.horizontal, 20)
                            .padding(.top, 40)
                            .padding(.bottom, 24)
                        } else {
                            FeedPlaceholder(phase: data.catalogPhase,
                                            retry: { Task { await data.syncCatalog() } }) {
                                EmptyStateView(
                                    icon: "person.2.slash",
                                    title: "No instructors yet",
                                    message: "Instructors near you will appear here once they join Flowe."
                                )
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 40)
                            .padding(.bottom, 24)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        listLabel
                            .font(FloweFont.mono(11))
                            .foregroundStyle(Color.floweMuted)
                        VStack(spacing: 12) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                InstructorCard(instructor: row.instructor,
                                               distanceMetres: row.distanceMetres) {
                                    selected = row
                                }
                                .accessibilityIdentifier("discover.instructorCard")
                                .floweAppear(index)
                            }
                        }
                        // Reflow the list smoothly when the category filter changes.
                        .animation(FloweMotion.spring, value: filter)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                        }
                    }
                }
                .scrollToTopOnTabReselect(trigger: reselectTick, proxy: proxy)
                }
            }
        }
        .background(Color.flowWhite)
        // The rich student-facing profile — not the booking sheet directly. It presents BookingSheet
        // (at the day picker) on top of itself when the student taps Book.
        .fullScreenCover(item: $selected) { row in
            StudentInstructorProfileView(instructor: row.instructor,
                                         distanceMetres: row.distanceMetres) { selected = nil }
        }
        .sheet(isPresented: $retakeQuiz) {
            StudentQuizView(existing: session.studentPreferences) { prefs in
                session.saveStudentPreferences(prefs)
                retakeQuiz = false
            } onSkip: {
                retakeQuiz = false
            }
        }
        .sheet(isPresented: $showGuestSignIn) { GuestSignInSheet() }
        .sheet(isPresented: $showOpportunities) { StudentOpportunitiesView() }
        // Keep the open feed fresh so the banner's show/hide (gated on there being something to browse)
        // reflects reality — otherwise it only appears after the student opens the sheet once.
        .task { await data.syncOpportunities() }
        .task { await data.syncCatalog() }
        // Only when the student has already agreed. This never raises the prompt — that is the
        // "Use my location" button's job, and a permission sheet on top of a feed the user just
        // opened is exactly the ambush this app shouldn't spring.
        .task { if location.isAuthorized { await location.refresh() } }
        // Manual pull-to-refresh: pulls the latest published instructor catalog + re-fixes distance.
        .refreshable {
            await data.syncCatalog()
            if location.isAuthorized { await location.refresh() }
        }
    }

    // MARK: - Opportunities banner (Flowe Pro student on-ramp)

    /// A brand-tinted nudge into the opportunity browse, deliberately distinct from the white instructor
    /// cards so it doesn't read as "another instructor". Gated at the call site on there being something
    /// to browse; the tap opens `StudentOpportunitiesView` (same sheet as the Profile entry).
    private var opportunitiesBanner: some View {
        Button {
            Haptic.tap()
            showOpportunities = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(FlowGradients.gradDark, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find a role or apprenticeship")
                        .font(FloweFont.sans(15, .medium))
                        .foregroundStyle(Color.floweInk)
                    Text("Studios near you are hiring assistants & apprentices")
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.floweMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.flowePink.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.flowePink.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("discover.opportunities")
    }

    // MARK: - Header

    /// Time-of-day greeting so the feed reads like it was opened just now. Uppercase to match the
    /// mono label style *and* the localization keys, so it translates (see the instructor dashboard).
    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "GOOD MORNING"
        case 12..<17: return "GOOD AFTERNOON"
        default:      return "GOOD EVENING"
        }
    }

    /// Greeting on the left, the List/Map toggle + notifications bell on the right. Lives outside
    /// `header` so it stays pinned above both the scrolling list and the full-bleed map.
    private var titleRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(greeting))
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.flowePinkDeep)
                (Text("Find your ")
                    .font(FloweFont.serif(22))
                 + Text("instructor.")
                    .font(FloweFont.serif(22, .regular, italic: true)))
                    .foregroundStyle(Color.floweInk)
            }
            Spacer()
            // A guest stays in the LIST — the Map plots exact studio coordinates (a precise-location
            // leak), and the notifications bell would request push authorization + register subscriptions.
            // Both are hidden until sign-in.
            if !session.isGuest {
                viewToggle
                ActivityBellButton(isInstructor: false)
            }
        }
    }

    /// Two-segment icon toggle mirroring `locationPill`'s fill/tint: the active segment carries the
    /// dark gradient and a white glyph, the inactive one the card background and muted glyph.
    private var viewToggle: some View {
        HStack(spacing: 0) {
            toggleSegment(icon: "line.3.horizontal", mode: .list, label: "List view")
            toggleSegment(icon: "map", mode: .map, label: "Map view")
        }
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.floweBorder, lineWidth: 1))
    }

    private func toggleSegment(icon: String, mode: DiscoverMode, label: String) -> some View {
        let isOn = viewMode == mode
        return Button {
            withAnimation(FloweMotion.spring) { viewMode = mode }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(isOn ? .white : Color.floweMuted)
                .frame(width: 36, height: 36)
                .background { if isOn { FlowGradients.gradDark } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.floweMuted)
                // With on-device AI available, the field doubles as a natural-language search — the hint
                // invites it. The plain name/address contains-match still runs live as you type.
                TextField("", text: $search,
                          prompt: Text(FloweAI.isAvailable ? "Try “reformer near me”" : "Name or address…")
                            .foregroundColor(Color.floweMuted))
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweInk)
                    .autocorrectionDisabled()
                    .onSubmit { interpretSearch() }
                // ✨ Interpret the free-text query into filters (category + place + near-me). Shown only
                // when the model is available and there's something to interpret. See [[FloweIntelligence]].
                if FloweAI.isAvailable, !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { interpretSearch() } label: {
                        if interpreting {
                            ProgressView().controlSize(.mini).tint(Color.flowePinkDeep)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.flowePinkDeep)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(interpreting)
                    .accessibilityLabel("Search with AI")
                    .accessibilityIdentifier("discover.aiSearch")
                }
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.floweMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
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
    // cards keep showing studio addresses, and nothing here ever blocks the list from rendering.

    @ViewBuilder
    private var locationBar: some View {
        if location.isDenied {
            HStack(spacing: 6) {
                Image(systemName: "location.slash")
                    .font(.system(size: 11))
                Text("Location off — sorted by rating. Search by address instead.")
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
                    withAnimation(FloweMotion.spring) { nearestFirst.toggle() }
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

    // MARK: - Natural-language search (Flowe Intelligence)

    /// Interpret the current free-text query into Discover filters **on-device**: pick a real category,
    /// pull out a place/name to search, and honour a "near me". Falls back silently when the model is
    /// unavailable or can't parse — the plain text search is untouched. See [[FloweIntelligence]].
    private func interpretSearch() {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !interpreting else { return }
        interpreting = true
        Task {
            defer { interpreting = false }
            if #available(iOS 26, *), FloweAI.isAvailable,
               let parsed = try? await FloweIntelligence.shared.parseSearch(query, categories: FloweConstants.discoverCategories) {
                // The model aims at the real list, but validate anyway — an unknown category → "All".
                let matched = FloweAI.resolveCategory(parsed.category, in: FloweConstants.discoverCategories)
                withAnimation(FloweMotion.spring) {
                    filter = matched
                    search = parsed.locationOrName
                    if parsed.nearMe { nearestFirst = true }
                }
                Haptic.selection()
                // Asked for nearby and we can get a fix → warm it so the distance sort actually bites.
                if parsed.nearMe, !location.hasFix, location.isAuthorized {
                    await location.refresh()
                }
            }
        }
    }
}
