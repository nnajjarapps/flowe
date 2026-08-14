import SwiftUI
import PhotosUI
import UIKit
import MapKit

/// Editor for the instructor's public listing — photo, name, studio location, bio, rate, experience,
/// certification, specialties and session types. Persists to the instructor's SwiftData record and
/// republishes the listing to the public catalog via `MockDataStore.commit()`.
///
/// Everything here is what a student sees before booking, so the fields are deliberately the full
/// set rather than the three the first pass shipped with.
struct EditProfileView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let allSpecialties = ["Mat", "Reformer", "Barre", "Tower", "Prenatal", "Rehab"]

    @State private var name = ""
    @State private var showBrandDraft = false
    @State private var headline = ""
    @State private var brandColor = ""
    @State private var story = ""
    @State private var bio = ""

    /// Curated brand-accent palette for the Pro brand kit — tasteful, muted studio tones rather than a
    /// free ColorPicker (which invites clashing choices and needs Color↔hex conversion). "" = the app
    /// default (the Flowe pink gradient). Each other entry is the raw hex stored in `Instructor.brandColor`.
    private static let brandSwatches: [String] =
        ["", "#C67B5C", "#B4557C", "#8A5B9A", "#6E9A7A", "#5B7C9A", "#C69A4C", "#3E8078", "#A8574C"]
    @State private var yearsText = ""
    @State private var cert = ""

    /// Flowe Pro work-history rows, edited as a list and encoded back to `experienceTokens` on save.
    /// A local editable mirror of `Instructor.ExperienceEntry` (which is immutable / display-only).
    private struct ExpRow: Identifiable {
        let id = UUID()
        var role = ""
        var place = ""
        var period = ""
    }
    @State private var experienceRows: [ExpRow] = []
    @State private var specialties: Set<String> = []
    @State private var paymentMethods: Set<String> = []

    /// Presents the compose sheet: `nil` isn't "hidden" — `showAddType` drives the create path, while a
    /// non-nil `editingType` drives the edit path on a live `LessonType` row.
    @State private var showAddType = false
    @State private var editingType: LessonType?

    @State private var photo: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false

    @State private var certPhoto: Data?
    @State private var certPickerItem: PhotosPickerItem?
    @State private var isLoadingCert = false

    @State private var coverPhoto: Data?
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var isLoadingCover = false

    @State private var loaded = false
    /// Non-nil when the content filter rejected a field on save.
    @State private var filterMessage: String?
    /// Soft on-device moderation concern (Flowe Intelligence) → "save anyway / edit?" dialog.
    @State private var moderationConcern: String?

    // MARK: Studio location
    //
    // Set by the instructor, on purpose, with the result shown before it is saved. Nothing here
    // runs on its own: no fix is taken and no address is geocoded unless the instructor asks. Unlike
    // the old coarse teaching area this is the EXACT studio point, published so students can find and
    // book the studio.
    @State private var location = LocationService()
    /// The studio address string, shown wherever `city` used to appear. Typed, or reverse-geocoded
    /// from the device's exact fix.
    @State private var address = ""
    /// The exact studio coordinate that will be published. Set by forward-geocoding `address` or by
    /// the device's exact one-shot fix — never snapped.
    @State private var studioLatitude: Double?
    @State private var studioLongitude: Double?
    /// The address string the current coordinate was resolved FOR — a geocode result, a device fix's
    /// reverse-geocoded name (or its coordinate readout when naming failed), or the value loaded from
    /// the model. The coordinate is only trustworthy while `address == resolvedAddress`; as soon as the
    /// user edits the text past this, `onChange` clears the point so a stale pin can never ride along
    /// with a mismatched label into `save()`. nil = no coordinate is currently vouched for.
    @State private var resolvedAddress: String?
    @State private var isLocating = false
    /// A forward-geocode of the typed address is in flight.
    @State private var isGeocoding = false
    /// Shown when a requested device fix didn't arrive — a nudge, not a failure the form blocks on.
    @State private var locationFailed = false
    /// Shown when the typed address couldn't be resolved to a point.
    @State private var geocodeFailed = false

    // The session rate is no longer entered here — each lesson type carries its own price, and the
    // listing's single "starting from" price is derived from the cheapest of them on save. Only a name
    // is required to save.
    private var canSave: Bool { !name.trimmed.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                    photoField

                    field(title: "NAME") {
                        textBox($name, placeholder: "Your name")
                            .accessibilityIdentifier("editProfile.name")
                    }

                    // ✨ On-device brand-story draft (Flowe Intelligence). Shown only when the model is
                    // available (iOS 26 + eligible device + supported language); otherwise absent — the
                    // fields below work exactly as before. See [[FloweIntelligence]].
                    if FloweAI.isAvailable {
                        Button {
                            showBrandDraft = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles").font(.system(size: 12))
                                Text("Draft my headline & story with AI").font(FloweFont.sans(13, .medium))
                            }
                            .foregroundStyle(Color.flowePinkDeep)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.flowePink.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.flowePink.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $showBrandDraft) {
                            if #available(iOS 26, *) {
                                BrandStoryDraftSheet(name: name, specialties: Array(specialties)) { h, s in
                                    headline = h
                                    story = s
                                }
                            }
                        }
                    }

                    field(title: "HEADLINE") {
                        VStack(alignment: .leading, spacing: 6) {
                            textBox($headline, placeholder: "e.g. Reformer & rehab specialist · STOTT")
                                .accessibilityIdentifier("editProfile.headline")
                            Text("One line under your name — what you do, in a nutshell.")
                                .font(FloweFont.sans(11))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }

                    field(title: "BRAND COLOR") {
                        VStack(alignment: .leading, spacing: 8) {
                            brandColorField
                            Text("Your accent — it threads through your profile and studio page.")
                                .font(FloweFont.sans(11))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }

                    field(title: "COVER PHOTO") {
                        VStack(alignment: .leading, spacing: 6) {
                            coverPhotoField
                            Text("A wide banner across the top of your profile — your studio, a class, your vibe.")
                                .font(FloweFont.sans(11))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }

                    field(title: "STUDIO LOCATION") {
                        studioLocationField
                    }

                    field(title: "BIO") {
                        TextEditor(text: $bio)
                            .font(FloweFont.sans(14))
                            .foregroundStyle(Color.floweInk)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .boxed()
                            .accessibilityIdentifier("editProfile.bio")
                    }

                    field(title: "MY STUDIO") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $story)
                                .font(FloweFont.sans(14))
                                .foregroundStyle(Color.floweInk)
                                .frame(minHeight: 100)
                                .scrollContentBackground(.hidden)
                                .padding(10)
                                .boxed()
                                .accessibilityIdentifier("editProfile.story")
                            Text("Your studio story — the brand narrative students and studios read.")
                                .font(FloweFont.sans(11))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }

                    field(title: "YEARS OF EXPERIENCE") {
                        TextField("5", text: $yearsText)
                            .font(FloweFont.sans(14))
                            .foregroundStyle(Color.floweInk)
                            .keyboardType(.numberPad)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .boxed()
                            .accessibilityIdentifier("editProfile.years")
                    }

                    field(title: "CERTIFICATION") {
                        VStack(alignment: .leading, spacing: 6) {
                            textBox($cert, placeholder: "e.g. BASI Comprehensive, 2019")
                                .accessibilityIdentifier("editProfile.cert")
                            Text("Shown on your public profile. Flowe doesn't verify certifications.")
                                .font(FloweFont.sans(11))
                                .foregroundStyle(Color.floweMuted)
                            certPhotoField
                        }
                    }

                    field(title: "SPECIALTIES") {
                        chipGrid(allSpecialties, selection: $specialties)
                    }

                    field(title: "EXPERIENCE") {
                        experienceField
                    }

                    field(title: "LESSON TYPES") {
                        lessonTypesField
                    }

                    field(title: "HOW YOU TAKE PAYMENT") {
                        VStack(alignment: .leading, spacing: 6) {
                            FlowLayout(spacing: 8, lineSpacing: 8) {
                                ForEach(PaymentMethod.all, id: \.self) { paymentChip($0) }
                            }
                            Text("Flowe doesn't collect session fees — students pay you directly, so they need to know how.")
                                .font(FloweFont.sans(11))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .tint(Color.flowePinkDeep).fontWeight(.semibold)
                        // Also blocked while a location lookup is in flight, so Save can't persist a
                        // half-resolved point and can't fire its own resolve-on-save concurrently.
                        .disabled(!canSave || isGeocoding || isLocating)
                        .accessibilityIdentifier("editProfile.save")
                }
            }
        }
        .onAppear(perform: load)
        .task(id: pickerItem) { await loadPickedPhoto() }
        .task(id: certPickerItem) { await loadPickedCert() }
        .task(id: coverPickerItem) { await loadPickedCover() }
        // A legacy instructor's flat chips become editable rich rows the first time they open the
        // editor — a no-op once they own any, and only ever for the signed-in owner.
        .onAppear { data.migrateLessonTypesIfNeeded() }
        .sheet(isPresented: $showAddType) { ComposeLessonTypeSheet() }
        .sheet(item: $editingType) { ComposeLessonTypeSheet(editing: $0) }
        .alert("Check your profile",
               isPresented: .init(get: { filterMessage != nil },
                                  set: { if !$0 { filterMessage = nil } })) {
            Button("OK", role: .cancel) { filterMessage = nil }
        } message: {
            Text(filterMessage ?? "")
        }
        .confirmationDialog("A quick check",
                            isPresented: .init(get: { moderationConcern != nil },
                                               set: { if !$0 { moderationConcern = nil } }),
                            titleVisibility: .visible,
                            presenting: moderationConcern) { _ in
            Button("Save anyway") {
                moderationConcern = nil
                if let me = data.currentInstructor { finishSave(me) }
            }
            Button("Edit", role: .cancel) { moderationConcern = nil }
        } message: { concern in
            Text(concern)
        }
    }

    // MARK: - Photo

    private var photoField: some View {
        VStack(spacing: 12) {
            ZStack {
                // Show the seeded Unsplash fallback too, so the editor previews what the profile
                // actually renders rather than an empty circle.
                EditableAvatarView(id: data.currentInstructor?.img ?? "", photo: photo, size: 104)
                if isLoadingPhoto {
                    Circle().fill(.black.opacity(0.35)).frame(width: 104, height: 104)
                    ProgressView().tint(.white)
                }
            }

            HStack(spacing: 16) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Text(photo == nil ? "Add Photo" : "Change Photo")
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.flowePinkDeep)
                }
                .accessibilityIdentifier("editProfile.photoPicker")

                if photo != nil {
                    Button("Remove") {
                        photo = nil
                        pickerItem = nil
                    }
                    .font(FloweFont.sans(13))
                    .tint(Color.floweMuted)
                    .accessibilityIdentifier("editProfile.photoRemove")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func loadPickedPhoto() async {
        guard let pickerItem else { return }
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        // Downscale before storing — see `ProfileImage`. A failed decode leaves the old photo alone.
        guard let raw = try? await pickerItem.loadTransferable(type: Data.self),
              let prepared = ProfileImage.prepare(raw) else { return }
        photo = prepared
    }

    // MARK: - Certificate photo

    /// A picture of the certificate, sitting under the free-text claim it backs up. Rendered wide
    /// and uncropped — it is a document, not an avatar, and the awarding body and date live at its
    /// edges.
    private var certPhotoField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let certPhoto, let image = UIImage(data: certPhoto) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
                    .overlay {
                        if isLoadingCert {
                            RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.35))
                            ProgressView().tint(.white)
                        }
                    }
                    .accessibilityIdentifier("editProfile.certPhotoPreview")
            } else if isLoadingCert {
                ProgressView().tint(Color.flowePinkDeep)
            }

            HStack(spacing: 16) {
                PhotosPicker(selection: $certPickerItem, matching: .images, photoLibrary: .shared()) {
                    Text(certPhoto == nil ? "Add Certificate Photo" : "Change Certificate Photo")
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.flowePinkDeep)
                }
                .accessibilityIdentifier("editProfile.certPhotoPicker")

                if certPhoto != nil {
                    Button("Remove") {
                        certPhoto = nil
                        certPickerItem = nil
                    }
                    .font(FloweFont.sans(13))
                    .tint(Color.floweMuted)
                    .accessibilityIdentifier("editProfile.certPhotoRemove")
                }
            }
            .padding(.top, 2)
        }
    }

    private func loadPickedCert() async {
        guard let certPickerItem else { return }
        isLoadingCert = true
        defer { isLoadingCert = false }
        // Downscaled without the square crop `prepare` applies — see `ProfileImage.prepareDocument`.
        guard let raw = try? await certPickerItem.loadTransferable(type: Data.self),
              let prepared = ProfileImage.prepareDocument(raw) else { return }
        certPhoto = prepared
    }

    // MARK: - Cover photo (Flowe Pro brand kit)

    /// A wide brand banner. Shown at its natural (wide) proportions here so the author previews what
    /// their hero will actually render, with a one-tap Remove. Mirrors `certPhotoField`.
    private var coverPhotoField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let coverPhoto, let image = UIImage(data: coverPhoto) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
                    .overlay {
                        if isLoadingCover {
                            RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.35))
                            ProgressView().tint(.white)
                        }
                    }
                    .accessibilityIdentifier("editProfile.coverPreview")
            } else if isLoadingCover {
                ProgressView().tint(Color.flowePinkDeep)
            }

            HStack(spacing: 16) {
                PhotosPicker(selection: $coverPickerItem, matching: .images, photoLibrary: .shared()) {
                    Text(coverPhoto == nil ? "Add Cover Photo" : "Change Cover Photo")
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.flowePinkDeep)
                }
                .accessibilityIdentifier("editProfile.coverPicker")

                if coverPhoto != nil {
                    Button("Remove") {
                        coverPhoto = nil
                        coverPickerItem = nil
                    }
                    .font(FloweFont.sans(13))
                    .tint(Color.floweMuted)
                    .accessibilityIdentifier("editProfile.coverRemove")
                }
            }
            .padding(.top, 2)
        }
    }

    private func loadPickedCover() async {
        guard let coverPickerItem else { return }
        isLoadingCover = true
        defer { isLoadingCover = false }
        // Wide downscale (no square crop) — a cover is a banner, not an avatar. Reuses the post pipeline.
        guard let raw = try? await coverPickerItem.loadTransferable(type: Data.self),
              let prepared = ProfileImage.preparePost(raw) else { return }
        coverPhoto = prepared
    }

    // MARK: - Studio location

    /// Lets the instructor set the EXACT studio location published to the world-readable catalog so
    /// students can find and book the studio. This deliberately reverses the old coarse "teaching
    /// area": a studio is a business location, standard for a booking app.
    ///
    /// Two ways in — type the address (forward-geocoded to a point on submit) or take one device fix
    /// and reverse-geocode it into an address. Either way the result is shown (address + a map pin)
    /// before Save, and can be removed in one tap. Nothing is captured in the background.
    private var studioLocationField: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Type-your-address path: forward-geocode on submit.
            HStack(spacing: 8) {
                TextField("", text: $address,
                          prompt: Text("Your studio address").foregroundColor(Color.floweMuted))
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweInk)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit { Task { await geocodeTypedAddress() } }
                    // Editing the address invalidates the pin: the moment the text no longer matches the
                    // string the coordinate was resolved for, drop the coordinate so a stale point can't
                    // be saved under a new label. Our own resolve paths keep `resolvedAddress` in step,
                    // so this only fires on genuine user edits. The map preview vanishing signals
                    // "re-search to place the pin".
                    .onChange(of: address) { _, newValue in
                        if newValue != resolvedAddress {
                            studioLatitude = nil
                            studioLongitude = nil
                            resolvedAddress = nil
                            geocodeFailed = false
                        }
                    }
                    .accessibilityIdentifier("editProfile.address")
                if isGeocoding {
                    ProgressView().controlSize(.mini).tint(Color.flowePinkDeep)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .boxed()

            // Use-my-location path: exact device fix → reverse-geocode into the address field.
            locationButton(title: "Use My Current Location")

            // A small pin preview of the exact point that will be published, plus a one-tap Remove.
            if let coordinate = studioCoordinate {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400))) {
                    Marker("", coordinate: coordinate).tint(Color.flowePinkDeep)
                }
                // A fresh coordinate is a fresh map — `initialPosition` is read once per identity.
                .id("\(coordinate.latitude),\(coordinate.longitude)")
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
                .allowsHitTesting(false)
                .accessibilityIdentifier("editProfile.studioMap")

                HStack(spacing: 12) {
                    // The exact pair is data, not UI copy — never translated.
                    Text(verbatim: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                        .font(FloweFont.mono(11))
                        .foregroundStyle(Color.floweMuted)
                    Spacer(minLength: 8)
                    Button("Remove") {
                        studioLatitude = nil
                        studioLongitude = nil
                        resolvedAddress = nil
                        address = ""
                        locationFailed = false
                        geocodeFailed = false
                    }
                    .font(FloweFont.sans(13))
                    .tint(Color.floweMuted)
                    .accessibilityIdentifier("editProfile.locationRemove")
                }
            }

            // Disclosure — always under the control, so the public nature is stated before Save.
            Text("Your studio location is shown publicly to students so they can find and book you. Use your studio's address — not a private home you'd rather keep off the map.")
                .font(FloweFont.sans(11))
                .foregroundStyle(Color.floweMuted)
                .fixedSize(horizontal: false, vertical: true)

            if location.isDenied {
                HStack(spacing: 6) {
                    Text("Location access is off. Type your studio address above instead, or turn it on in Settings.")
                        .font(FloweFont.sans(11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                    .font(FloweFont.sans(11, .medium))
                    .tint(Color.flowePinkDeep)
                    .accessibilityIdentifier("editProfile.locationSettings")
                }
                .foregroundStyle(Color.floweMuted)
            } else if locationFailed {
                Text("Couldn't find your location. Try again, or type your studio address above.")
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
            } else if geocodeFailed {
                Text("We couldn't find that address. Check it and try again.")
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
            }
        }
    }

    /// The exact studio coordinate held in the two `Double?`s, or nil when unset.
    private var studioCoordinate: CLLocationCoordinate2D? {
        guard let studioLatitude, let studioLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: studioLatitude, longitude: studioLongitude)
    }

    private func locationButton(title: LocalizedStringKey) -> some View {
        Button {
            Task { await captureCurrentLocation() }
        } label: {
            HStack(spacing: 6) {
                if isLocating {
                    ProgressView().controlSize(.mini).tint(Color.flowePinkDeep)
                } else {
                    Image(systemName: "location").font(.system(size: 11))
                }
                Text(title).font(FloweFont.sans(13, .medium))
            }
            .foregroundStyle(Color.flowePinkDeep)
        }
        .buttonStyle(.plain)
        .disabled(isLocating)
        .accessibilityIdentifier("editProfile.locationCapture")
    }

    /// "Use my current location": take one EXACT device fix (no snapping — this is a studio the
    /// instructor is publishing) and reverse-geocode it into the address field. The pin is kept even
    /// if naming fails, since that is what students route to.
    private func captureCurrentLocation() async {
        isLocating = true
        locationFailed = false
        geocodeFailed = false
        defer { isLocating = false }

        guard let coordinate = await location.requestExactLocation(),
              Self.isValidCoordinate(coordinate.latitude, coordinate.longitude) else {
            locationFailed = !location.isDenied   // a refusal is a choice, not a failure to report
            return
        }
        studioLatitude = coordinate.latitude
        studioLongitude = coordinate.longitude
        // The address label must track the point. On a successful reverse-geocode use the name; when
        // naming fails, fall back to the coordinate readout rather than leaving a STALE typed label
        // over a different (device) point — a mismatch and a home-address leak. Either way `address`
        // and `resolvedAddress` are set together so `onChange` treats the pin as matching.
        let label = await location.reverseGeocode(latitude: coordinate.latitude,
                                                  longitude: coordinate.longitude)
            ?? String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
        resolvedAddress = label
        address = label
    }

    /// "Type your address": forward-geocode the typed string to an EXACT point, and normalise the
    /// field to the geocoder's formatted address. A blank/unresolvable address surfaces a nudge and
    /// leaves any existing point alone.
    private func geocodeTypedAddress() async {
        let query = address.trimmed
        guard !query.isEmpty else { return }
        isGeocoding = true
        geocodeFailed = false
        locationFailed = false
        defer { isGeocoding = false }

        guard let result = await location.geocode(address: query),
              Self.isValidCoordinate(result.latitude, result.longitude) else {
            geocodeFailed = true
            return
        }
        studioLatitude = result.latitude
        studioLongitude = result.longitude
        // Set the vouched-for address BEFORE the field so `onChange` sees them equal and keeps the pin.
        resolvedAddress = result.formattedAddress
        address = result.formattedAddress
    }

    /// Reject Null Island, non-finite, and out-of-range pairs — the editor must mirror the rules the
    /// model (`Instructor.studioCoordinate`) enforces, so a bad fix can't render a pin here that then
    /// vanishes everywhere downstream.
    private static func isValidCoordinate(_ lat: Double, _ lon: Double) -> Bool {
        lat.isFinite && lon.isFinite
            && (-90...90).contains(lat) && (-180...180).contains(lon)
            && !(lat == 0 && lon == 0)
    }

    // MARK: - Pieces

    private func field<Content: View>(title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: title)
            content()
        }
    }

    private func textBox(_ text: Binding<String>, placeholder: LocalizedStringKey) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Color.floweMuted))
            .font(FloweFont.sans(14))
            .foregroundStyle(Color.floweInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .boxed()
    }

    private func chipGrid(_ options: [String], selection: Binding<Set<String>>) -> some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(options, id: \.self) { option in
                chip(option, selection: selection)
            }
        }
    }

    private func chip(_ label: String, selection: Binding<Set<String>>) -> some View {
        let isOn = selection.wrappedValue.contains(label)
        return Button {
            if isOn { selection.wrappedValue.remove(label) }
            else { selection.wrappedValue.insert(label) }
        } label: {
            Text(localizedTag: label)
                .font(FloweFont.sans(13, .medium))
                .foregroundStyle(isOn ? .white : Color.flowePinkDeep)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if isOn { Capsule().fill(FlowGradients.gradDark) }
                    else { Capsule().fill(Color.flowePink.opacity(0.10)) }
                }
        }
        .buttonStyle(.plain)
    }

    /// Same pill as `chip`, but keyed on a stable `PaymentMethod` id while showing a localized name.
    private func paymentChip(_ id: String) -> some View {
        let isOn = paymentMethods.contains(id)
        return Button {
            if isOn { paymentMethods.remove(id) } else { paymentMethods.insert(id) }
        } label: {
            Text(PaymentMethod.label(id))
                .font(FloweFont.sans(13, .medium))
                .foregroundStyle(isOn ? .white : Color.flowePinkDeep)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if isOn { Capsule().fill(FlowGradients.gradDark) }
                    else { Capsule().fill(Color.flowePink.opacity(0.10)) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editProfile.payment.\(id)")
    }

    // MARK: - Lesson types

    /// The instructor's rich, self-authored lesson types, replacing the fixed
    /// `["Private","Duet","Group","Online"]` chip menu. Each is a reorderable, editable, deletable row;
    /// zero rows is an honest empty state prompting the first one, never a backfilled default.
    ///
    /// Read from `ownedLessonTypes` (the live `LessonType` rows) rather than the resolver, because these
    /// rows are what the compose sheet edits and swipe/delete removes — the resolver returns flattened
    /// value copies with no persistent identity to mutate.
    @ViewBuilder
    private var lessonTypesField: some View {
        let rows = data.currentInstructor.map { data.ownedLessonTypes(for: $0) } ?? []
        VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Text("Add your first lesson type — a class you offer, in your own words.")
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.legacyId) { index, type in
                    lessonTypeRow(type, index: index, count: rows.count)
                }
            }

            Button {
                showAddType = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("Add lesson type").font(FloweFont.sans(13, .medium))
                }
                .foregroundStyle(Color.flowePinkDeep)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("editProfile.addLessonType")
        }
        // No container-level identifier here: a plain VStack forms no AX element of its own, so an
        // identifier on it propagates down and shadows the specific ids on the leaf button and the
        // empty-state text (they'd all report "editProfile.lessonTypes"). The rows and the add button
        // carry their own ids; the group needs none.
    }

    /// One lesson-type row: optional thumbnail, name, a compact stated-only meta line, and trailing
    /// reorder/delete controls. Tapping the row opens the compose sheet on that live row.
    ///
    /// Reorder is chevron buttons rather than `.onMove`/swipe-to-delete: those need a `List`, and this
    /// editor is a `ScrollView` of custom sections, so the native list gestures aren't available here.
    private func lessonTypeRow(_ type: LessonType, index: Int, count: Int) -> some View {
        HStack(spacing: 12) {
            // A compact row shows a real thumbnail or nothing — no gradient stand-in for a photo-less type.
            if let bytes = type.highlight, let ui = UIImage(data: bytes) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 3) {
                // The instructor's own words — shown verbatim, never localized.
                Text(verbatim: type.name)
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(Color.floweInk)
                if let meta = metaText(for: type) {
                    meta.font(FloweFont.mono(10)).foregroundStyle(Color.floweMuted)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button { moveLessonType(from: index, up: true) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold))
                }
                .disabled(index == 0)
                .accessibilityLabel("Move lesson type up")

                Button { moveLessonType(from: index, up: false) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                }
                .disabled(index == count - 1)
                .accessibilityLabel("Move lesson type down")

                Button(role: .destructive) { data.deleteLessonType(type) } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .accessibilityLabel("Delete lesson type")
                .accessibilityIdentifier("lessonType.delete")
            }
            .buttonStyle(.plain)
            .tint(Color.floweMuted)
            .foregroundStyle(Color.floweMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .boxed()
        .contentShape(Rectangle())
        .onTapGesture { editingType = type }
        .accessibilityIdentifier("editProfile.lessonType.\(type.legacyId)")
    }

    /// A stated-only meta line — capacity, duration, price — built as separate `Text` runs joined by an
    /// explicit "·" so it lays out correctly under RTL, with the count inflected. Each run appears only
    /// when its field is stated (0/nil is "not stated"), matching the student card's rule.
    private func metaText(for type: LessonType) -> Text? {
        var parts: [Text] = []
        if type.capacity == 1 {
            parts.append(Text("1-on-1"))
        } else if type.capacity >= 2 {
            parts.append(Text("Up to ") + Text("^[\(type.capacity) spot](inflect: true)"))
        }
        if type.durationMinutes > 0 {
            parts.append(Text("\(type.durationMinutes) min"))
        }
        if let price = type.price {
            // A formatted currency string is data — verbatim, never a translation key. 0 is "Free".
            parts.append(price == 0 ? Text("Free") : Text(verbatim: settings.money(price)))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
    }

    /// Move one row and republish its `order`. `move(fromOffsets:toOffset:)` reads the destination as an
    /// index in the pre-removal array, so moving down is `index + 2`, not `index + 1`.
    private func moveLessonType(from index: Int, up: Bool) {
        let destination = up ? index - 1 : index + 2
        data.reorderLessonTypes(from: IndexSet(integer: index), to: destination)
    }

    // MARK: - Experience (Flowe Pro)

    /// A list of editable work-history rows + an "Add role" button. Encoded to `experienceTokens` on
    /// save; a row with no `place` is dropped (an empty row the user added but never filled).
    private var experienceField: some View {
        VStack(alignment: .leading, spacing: 10) {
            if experienceRows.isEmpty {
                Text("Add your teaching history — studios, roles, apprenticeships. Optional, but it builds trust with students and studios.")
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach($experienceRows) { $row in
                    experienceRowEditor($row)
                }
            }

            Button {
                experienceRows.append(ExpRow())
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("Add role").font(FloweFont.sans(13, .medium))
                }
                .foregroundStyle(Color.flowePinkDeep)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("editProfile.addExperience")
        }
    }

    /// One work-history row: role / place / period stacked with dividers, and a trailing delete.
    private func experienceRowEditor(_ row: Binding<ExpRow>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                TextField("", text: row.role,
                          prompt: Text("Role — e.g. Senior Reformer instructor").foregroundColor(Color.floweMuted))
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(Color.floweInk)
                Divider().overlay(Color.floweBorder)
                TextField("", text: row.place,
                          prompt: Text("Studio / employer").foregroundColor(Color.floweMuted))
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweInk.opacity(0.85))
                Divider().overlay(Color.floweBorder)
                TextField("", text: row.period,
                          prompt: Text("2018–2021 (optional)").foregroundColor(Color.floweMuted))
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
            }
            .textInputAutocapitalization(.words)

            Button(role: .destructive) {
                experienceRows.removeAll { $0.id == row.wrappedValue.id }
            } label: {
                Image(systemName: "trash").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .tint(Color.floweMuted)
            .foregroundStyle(Color.floweMuted)
            .accessibilityLabel("Delete role")
            .accessibilityIdentifier("editProfile.experienceDelete")
        }
        .padding(12)
        .boxed()
    }

    // MARK: - Brand color (Flowe Pro)

    private var brandColorField: some View {
        FlowLayout(spacing: 14, lineSpacing: 14) {
            ForEach(Self.brandSwatches, id: \.self) { hex in
                brandSwatch(hex)
            }
        }
    }

    /// One selectable swatch. "" is the app default (rendered as the Flowe gradient); the rest are the
    /// brand hex. The current pick gets an ink ring + checkmark.
    private func brandSwatch(_ hex: String) -> some View {
        let isSelected = brandColor == hex
        return Button {
            brandColor = hex
            Haptic.selection()
        } label: {
            ZStack {
                Circle()
                    .fill(hex.isEmpty
                          ? AnyShapeStyle(FlowGradients.gradDark)
                          : AnyShapeStyle(Color(hexString: hex) ?? Color.flowePink))
                    .frame(width: 38, height: 38)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .overlay(
                Circle().stroke(Color.floweInk.opacity(isSelected ? 0.9 : 0), lineWidth: 2).padding(-4)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editProfile.brandSwatch.\(hex.isEmpty ? "default" : hex)")
    }

    // MARK: - Load / save

    private func load() {
        guard !loaded, let me = data.currentInstructor else { return }
        name = me.name
        headline = me.headline
        brandColor = me.brandColor
        story = me.story
        experienceRows = me.experience.map { ExpRow(role: $0.role, place: $0.place, period: $0.period) }
        address = me.address
        bio = me.bio ?? ""
        yearsText = me.yearsExp > 0 ? String(me.yearsExp) : ""
        cert = me.cert
        specialties = Set(me.specialties)
        paymentMethods = Set(PaymentMethod.known(me.paymentMethods))
        photo = me.photo
        certPhoto = me.certPhoto
        coverPhoto = me.coverPhoto
        // No geocode on open: the stored exact point is read straight back, and a network lookup
        // nobody asked for is the wrong thing to do when a screen appears.
        studioLatitude = me.latitude
        studioLongitude = me.longitude
        // The stored address IS the vouched-for label for the stored point (when there is one), so a
        // Save that never touches the location doesn't need to re-geocode and won't be treated as an edit.
        resolvedAddress = (me.latitude != nil && me.longitude != nil) ? me.address : nil
        loaded = true
    }

    private func save() async {
        guard let me = data.currentInstructor else { dismiss(); return }
        // A location the user typed but never searched (or edited after searching) has address text
        // but no vouched-for point. Resolve it NOW rather than publishing a "located but unlocatable"
        // listing (address string, no pin, no distance ranking). If it still won't resolve, abort the
        // save with the inline nudge showing so the user can fix or Remove it — we never silently save
        // a mismatched or point-less location. A resolved (or empty, or Removed) location skips this.
        if !address.trimmed.isEmpty && studioCoordinate == nil {
            await geocodeTypedAddress()
            if studioCoordinate == nil { return }   // geocodeFailed nudge is now visible
        }
        // Every field here is broadcast to the public catalog, so it is screened before publishing
        // (Guideline 1.2). Private messages are deliberately not screened — see `ContentFilter`.
        // Screened AFTER the resolve above so the geocoder's normalised address is what gets checked.
        // Screen only the DESCRIPTIVE experience fields (role + place). The period is a year range
        // like "2016-2018" — its digit-and-hyphen run matches ContentFilter's phone-number heuristic
        // (`\d[\d\s().-]{7,}\d`), so screening it false-positives on every honest work history.
        let experienceText = experienceRows.flatMap { [$0.role, $0.place] }
        if let rejection = ContentFilter.reject(fields: [name, headline, story, address, bio, cert] + experienceText) {
            filterMessage = rejection.message
            return
        }
        // Soft AI second pass on the descriptive public fields (headline/story/bio). save() is already
        // async, so no Task; a concern surfaces the "Save anyway / Edit" dialog rather than blocking.
        if FloweAI.isAvailable,
           let concern = await FloweAI.moderationConcern([headline, story, bio].joined(separator: "\n")) {
            moderationConcern = concern
            return
        }
        finishSave(me)
    }

    /// Apply the edited fields to the model and publish. Split from `save()` so the moderation dialog's
    /// "Save anyway" can complete the save after the soft AI check.
    private func finishSave(_ me: Instructor) {
        me.name = name.trimmed
        me.headline = headline.trimmed
        me.brandColor = brandColor
        me.story = story.trimmed
        // Encode the rows to `period|place|role` tokens, dropping any with no place (an empty row the
        // user added but never filled). Order matches `Instructor.experience`'s decoder.
        me.experienceTokens = experienceRows.compactMap { row in
            let place = row.place.trimmed
            guard !place.isEmpty else { return nil }
            return [row.period.trimmed, place, row.role.trimmed].joined(separator: "|")
        }
        me.bio = bio.trimmed
        me.cert = cert.trimmed
        // `price` is not written here — `data.commit()` → `publishMyListing()` re-derives it from the
        // current lesson types (the cheapest priced one), the same way `sessionTypes` is store-derived.
        me.yearsExp = yearsText.wholeNumber ?? 0
        // Filter through the canonical lists so stored order stays stable rather than set order.
        me.specialties = allSpecialties.filter { specialties.contains($0) }
        // sessionTypes is no longer edited here — it is the denormalised name cache the store re-derives
        // from the rich `LessonType` rows on every mutation, so this Save leaves it untouched.
        me.paymentMethods = PaymentMethod.all.filter { paymentMethods.contains($0) }
        me.photo = photo
        me.certPhoto = certPhoto
        me.coverPhoto = coverPhoto
        // The EXACT studio point + address, set together. nil coordinates (Remove) clear the point
        // and remove the keys from the public record — a real withdrawal, not a value that lingers
        // on other people's devices.
        me.setStudioLocation(latitude: studioLatitude, longitude: studioLongitude, address: address.trimmed)
        data.commit()
        dismiss()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Parse a typed whole number that may carry non-ASCII digits (an Arabic keyboard's `.numberPad`
    /// emits Eastern-Arabic-Indic ٠–٩) or grouping separators — bare `Int("٥")`/`Int("1,000")` return
    /// nil, silently zeroing the field. Maps each Unicode decimal digit via `wholeNumberValue` and
    /// drops the rest; nil only when there's no digit at all. (Mirrors `ComposeLessonTypeSheet`.)
    var wholeNumber: Int? {
        var digits = ""
        for ch in self where ch.isNumber {
            guard let v = ch.wholeNumberValue, (0...9).contains(v) else { continue }
            digits.append(Character("\(v)"))
        }
        return digits.isEmpty ? nil : Int(digits)
    }
}

private extension View {
    /// The editor's shared input surface: card fill, rounded, hairline border.
    func boxed() -> some View {
        background(Color.floweCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
    }
}
