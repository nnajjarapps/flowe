import SwiftUI
import MapKit

/// The map half of Discover: the same visible-instructor list the feed shows, plotted at each
/// instructor's **exact studio location** rather than stacked in a scroll view.
///
/// Everything on this map is already world-readable. A pin sits at `instructor.studioCoordinate` — the
/// exact studio point the public catalog publishes — so the map exposes nothing the list didn't. The
/// student's own position is used only to centre the camera and draw the system blue dot
/// (`UserAnnotation`), and never leaves the device: `LocationService` hands out a coarse point for the
/// camera or a scalar distance, never a coordinate this view could persist or send.
///
/// The parent (`DiscoverView`) owns the filter/search state and the `LocationService` fix, so the same
/// query drives list and map and a fix acquired for one centres the other. Selection is internal —
/// tapping a pin only enlarges it and floats its card; opening the profile takes the extra tap on that
/// card, which calls back through `onSelect` into the single sheet Discover already presents.
struct InstructorMapView: View {
    /// Already filtered by `DiscoverView` and already gated to `studioCoordinate != nil`, so every one
    /// of these has a plottable point — the `if let` in the loop is belt-and-braces, not a real branch.
    let instructors: [Instructor]
    /// The SAME `@State` the list binds to, so the floating chips here and the chips there are one
    /// control: changing either recomputes the parent's `mapInstructors` and re-passes it.
    @Binding var filter: String
    @Binding var search: String
    /// The instance the list uses — passed in so a fix acquired for the feed also centres the map.
    let location: LocationService
    /// Fired by the bottom card's tap, not by selecting a pin. `DiscoverView` turns the instructor
    /// into its private `Row` and drives its existing `.sheet(item:)` — the one booking entry point.
    let onSelect: (Instructor) -> Void

    @Environment(AppSettings.self) private var settings

    @State private var camera: MapCameraPosition = .automatic
    /// The plotted instructor's `legacyId`, or nil for "nothing selected" (count badge showing).
    @State private var selectedID: Int?
    /// Centring is a one-shot: it runs once when the map first appears and never fights the user's
    /// pans afterwards.
    @State private var didCenter = false

    /// The selected instructor, resolved from the binding MapKit drives — nil re-shows the count badge.
    private var selected: Instructor? {
        instructors.first { $0.legacyId == selectedID }
    }

    var body: some View {
        ZStack {
            Map(position: $camera, selection: $selectedID) {
                ForEach(instructors, id: \.legacyId) { ins in
                    if let studio = ins.studioCoordinate {
                        Annotation("", coordinate: studio) {
                            PinView(instructor: ins,
                                    price: settings.money(ins.price),
                                    selected: selectedID == ins.legacyId)
                        }
                        .tag(ins.legacyId)
                        .annotationTitles(.hidden)
                    }
                }
                // Draws the on-device blue dot without any app code reading the student coordinate.
                UserAnnotation()
            }
            .ignoresSafeArea()

            // Floating search + specialty chips, pinned inside the safe area over the full-bleed map.
            VStack(spacing: 10) {
                searchBar
                FilterChipsBar(items: FloweConstants.discoverCategories, selection: $filter)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)

            // Selecting a pin floats its card; nothing selected shows the count badge instead.
            VStack {
                Spacer(minLength: 0)
                if let selected {
                    BottomInstructorCard(instructor: selected,
                                         price: settings.money(selected.price)) {
                        onSelect(selected)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    CountBadge(count: instructors.count)
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: selectedID)
        .task {
            // One-shot camera placement. `location` is the parent's instance, so if the list already
            // has a fix this returns immediately and never re-prompts (it only refreshes when already
            // authorized — the "Use my location" button remains the sole permission trigger).
            guard !didCenter else { return }
            didCenter = true
            if location.isAuthorized, let here = await location.requestCoarseLocation() {
                // Near-you: centre on the student's own coarse point (camera-only, never stored).
                camera = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)))
            } else {
                // No fix / denied: frame the pins themselves so the map opens on the results.
                camera = .region(fitRegion(instructors))
            }
        }
    }

    // MARK: - Floating search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Color.floweMuted)
            TextField("", text: $search,
                      prompt: Text("Name or city…").foregroundColor(Color.floweMuted))
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
            } else {
                // Mirrors the mockup's location glyph — decorative here; the "Use my location" flow
                // lives on the list, and the map already centres on-device via `.task`.
                Image(systemName: "location.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.flowePinkDeep)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.floweBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    // MARK: - Region maths

    /// A region that frames all plotted pins: bounding box, midpoint centre, span padded 40% and
    /// clamped to a 0.02° floor so a single or tightly-clustered pin doesn't open zoomed uncomfortably
    /// tight on one studio. Tel Aviv when there's nothing to frame — the app is Israel-only.
    private func fitRegion(_ instructors: [Instructor]) -> MKCoordinateRegion {
        let points = instructors.compactMap { $0.studioCoordinate }
        guard let first = points.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818),
                span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.02),
                                   longitudeDelta: max((maxLon - minLon) * 1.4, 0.02)))
    }
}

// MARK: - Pin

/// A map pin: circular avatar bubble + a price capsule + a downward tail whose tip lands on the
/// coordinate. Grows and turns pink-ringed when selected, and floats above its neighbours so a pin
/// sitting close to others stays tappable.
private struct PinView: View {
    let instructor: Instructor
    let price: String
    let selected: Bool

    private var diameter: CGFloat { selected ? 46 : 38 }

    var body: some View {
        VStack(spacing: -1) {
            ZStack(alignment: .bottom) {
                AvatarView(id: instructor.img, photo: instructor.photo, size: diameter)
                    .overlay(
                        Circle().stroke(selected ? Color.flowePinkDeep : Color.flowWhite,
                                        lineWidth: 2.5)
                    )
                // Price bubble, overhanging the avatar's lower edge like the mockup. Shows the
                // "from" starting price (cheapest lesson type); hidden when the derived price is 0.
                if instructor.price > 0 {
                    Text("from \(price)")
                        .font(FloweFont.mono(9))
                        .foregroundStyle(selected ? .white : Color.flowePinkDeep)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            if selected { Capsule().fill(FlowGradients.gradDark) }
                            else { Capsule().fill(Color.flowWhite) }
                        }
                        .fixedSize()
                        .offset(y: 9)
                }
            }
            PinTail()
                .fill(selected ? Color.flowePinkDeep : Color.flowWhite)
                .frame(width: 10, height: 6)
        }
        .shadow(color: selected ? Color.flowePinkDeep.opacity(0.55) : Color.black.opacity(0.22),
                radius: selected ? 6 : 3, y: 2)
        // The tail tip, not the bubble centre, should sit on the coordinate. Annotation anchors its
        // content's centre, so lift the whole pin by half its height plus the tail.
        .offset(y: -(diameter / 2 + 6))
        .zIndex(selected ? 1 : 0)
    }
}

/// A downward-pointing triangle — the pin's pointer, tip at bottom-centre.
private struct PinTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Selected-instructor card

/// The floating card for the selected pin — a horizontal mirror of `InstructorCard`: avatar, name,
/// rating (or "New"), address, up to two specialty chips, "from ₪X", chevron. Tapping it is what opens
/// the profile; selecting the pin only surfaced it.
private struct BottomInstructorCard: View {
    let instructor: Instructor
    let price: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(id: instructor.img, photo: instructor.photo, size: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top) {
                        Text(instructor.name)
                            .font(FloweFont.serif(15))
                            .foregroundStyle(Color.floweInk)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        // Same honesty as the list: no fabricated 0.0 before the first real review.
                        if instructor.reviews > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.flowePink)
                                Text(String(format: "%.1f", instructor.rating))
                                    .font(FloweFont.mono(11))
                                    .foregroundStyle(Color.flowePinkDeep)
                            }
                        } else {
                            Text("New")
                                .font(FloweFont.mono(10))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.system(size: 10))
                        Text(instructor.address)
                            .font(FloweFont.sans(11))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.floweMuted)

                    HStack(spacing: 4) {
                        ForEach(instructor.specialties.prefix(2), id: \.self) { s in
                            SpecialtyTag(text: s)
                        }
                        Spacer(minLength: 8)
                        // Starting price (cheapest lesson type); hidden when the derived price is 0.
                        if instructor.price > 0 {
                            Text("from \(price)")
                                .font(FloweFont.serif(13, .medium))
                                .foregroundStyle(Color.flowePinkDeep)
                        }
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.floweMuted)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.floweBorder, lineWidth: 1))
            .shadow(color: Color.flowePinkDeep.opacity(0.25), radius: 14, y: 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Count badge

/// The "N instructors near you" pill shown when no pin is selected. Counts the plotted pins only —
/// most instructors have never set a studio location, so this is intentionally fewer than the list count.
private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count) INSTRUCTORS NEAR YOU")
            .font(FloweFont.mono(11))
            .foregroundStyle(Color.floweInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.floweBorder, lineWidth: 1))
            .shadow(color: Color.flowePinkDeep.opacity(0.2), radius: 10, y: 4)
    }
}
