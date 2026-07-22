import SwiftUI
import PhotosUI
import UIKit

/// Editor for the instructor's public listing — photo, name, city, bio, rate, experience,
/// certification, specialties and session types. Persists to the instructor's SwiftData record and
/// republishes the listing to the public catalog via `MockDataStore.commit()`.
///
/// Everything here is what a student sees before booking, so the fields are deliberately the full
/// set rather than the three the first pass shipped with.
struct EditProfileView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let allSpecialties = ["Mat", "Reformer", "Barre", "Tower", "Prenatal", "Rehab"]
    private let allSessionTypes = ["Private", "Duet", "Group", "Online"]

    @State private var name = ""
    @State private var city = ""
    @State private var bio = ""
    @State private var priceText = ""
    @State private var yearsText = ""
    @State private var cert = ""
    @State private var specialties: Set<String> = []
    @State private var sessionTypes: Set<String> = []
    @State private var paymentMethods: Set<String> = []

    @State private var photo: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false

    @State private var certPhoto: Data?
    @State private var certPickerItem: PhotosPickerItem?
    @State private var isLoadingCert = false

    @State private var loaded = false
    /// Non-nil when the content filter rejected a field on save.
    @State private var filterMessage: String?

    // MARK: Teaching location
    //
    // Set by the instructor, on purpose, with the result shown before it is saved. Nothing here
    // runs on its own: no fix is taken unless the button below is tapped.
    @State private var location = LocationService()
    /// The area that will be published — already snapped to ~1 km by `LocationService`.
    @State private var teachingArea: CoarseLocation?
    /// Reverse-geocoded name for `teachingArea`, when we managed to resolve one this session.
    @State private var areaName = ""
    @State private var isLocating = false
    /// Shown when a requested fix didn't arrive — a nudge, not a failure the form blocks on.
    @State private var locationFailed = false

    /// An empty rate is allowed — it means "not set yet", and the profile nudges for it. Only a
    /// nonsense value blocks saving, so a new instructor can save a photo and bio before pricing.
    private var priceIsValid: Bool { priceText.isEmpty || (Int(priceText).map { $0 > 0 } ?? false) }
    private var canSave: Bool { priceIsValid && !name.trimmed.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                    photoField

                    field(title: "NAME") {
                        textBox($name, placeholder: "Your name")
                            .accessibilityIdentifier("editProfile.name")
                    }

                    field(title: "CITY") {
                        textBox($city, placeholder: "Where you teach")
                            .accessibilityIdentifier("editProfile.city")
                    }

                    field(title: "TEACHING AREA") {
                        locationField
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

                    field(title: "RATE PER SESSION") {
                        HStack(spacing: 4) {
                            Text("$").font(FloweFont.serif(18, .medium)).foregroundStyle(Color.floweInk)
                            TextField("95", text: $priceText)
                                .font(FloweFont.serif(18, .medium))
                                .foregroundStyle(Color.floweInk)
                                .keyboardType(.numberPad)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .boxed()
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

                    field(title: "SESSION TYPES") {
                        chipGrid(allSessionTypes, selection: $sessionTypes)
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
                    Button("Save") { save() }
                        .tint(Color.flowePinkDeep).fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("editProfile.save")
                }
            }
        }
        .onAppear(perform: load)
        .task(id: pickerItem) { await loadPickedPhoto() }
        .task(id: certPickerItem) { await loadPickedCert() }
        .alert("Check your profile",
               isPresented: .init(get: { filterMessage != nil },
                                  set: { if !$0 { filterMessage = nil } })) {
            Button("OK", role: .cancel) { filterMessage = nil }
        } message: {
            Text(filterMessage ?? "")
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

    // MARK: - Teaching area

    /// Lets the instructor attach an approximate location to their listing so students can see how
    /// far away they are.
    ///
    /// The whole section is written around one fact: a lot of Pilates instructors teach out of their
    /// own home, and the catalog is readable by every user of the app. So the instructor is told the
    /// precision before they tap, shown the exact pair of numbers that will be published afterwards,
    /// and can take it back down in one tap. Nothing is captured in the background.
    private var locationField: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let teachingArea {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.flowePinkDeep)
                        // Place names and coordinates are data, not UI copy — never translated.
                        Text(verbatim: resolvedAreaName)
                            .font(FloweFont.sans(14))
                            .foregroundStyle(Color.floweInk)
                    }
                    Text(verbatim: teachingArea.displayText)
                        .font(FloweFont.mono(11))
                        .foregroundStyle(Color.floweMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .boxed()
                .accessibilityIdentifier("editProfile.locationSummary")

                Text("Students see roughly a 1 km area around this point — never your exact address.")
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)

                HStack(spacing: 16) {
                    locationButton(title: "Update Area")
                    Button("Remove") {
                        self.teachingArea = nil
                        areaName = ""
                        locationFailed = false
                    }
                    .font(FloweFont.sans(13))
                    .tint(Color.floweMuted)
                    .accessibilityIdentifier("editProfile.locationRemove")
                }
            } else {
                Text("Add your area so students nearby can see how far you are. Flowe publishes a point rounded to about 1 km — the neighbourhood, never the address.")
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
                locationButton(title: "Use My Current Location")
            }

            if location.isDenied {
                HStack(spacing: 6) {
                    Text("Location access is off. Your city above still works — turn it on in Settings to add an area.")
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
                Text("Couldn't find your location. Try again, or just type your city above.")
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
            }
        }
    }

    /// The name shown above the coordinates: whatever we reverse-geocoded this session, falling back
    /// to the city the instructor typed, and to the coordinates themselves if there is neither.
    private var resolvedAreaName: String {
        if !areaName.isEmpty { return areaName }
        if !city.trimmed.isEmpty { return city.trimmed }
        return teachingArea?.displayText ?? ""
    }

    private func locationButton(title: LocalizedStringKey) -> some View {
        Button {
            Task { await captureArea() }
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

    private func captureArea() async {
        isLocating = true
        locationFailed = false
        defer { isLocating = false }

        // Already coarsened by the service — the precise fix never leaves it, so there is nothing
        // here that could accidentally be saved at street precision.
        guard let area = await location.requestCoarseLocation() else {
            locationFailed = !location.isDenied   // a refusal is a choice, not a failure to report
            return
        }
        teachingArea = area
        // Geocoding runs on the rounded point, so even this lookup can't leak the exact one.
        guard let resolved = await location.areaName(for: area) else { return }
        areaName = resolved
        // Only fills a blank city. Overwriting would clobber something more specific than a
        // geocoder returns — "Tel Aviv · Florentin", a studio name — that the instructor chose.
        if city.trimmed.isEmpty { city = resolved }
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
            Text(label)
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

    // MARK: - Load / save

    private func load() {
        guard !loaded, let me = data.currentInstructor else { return }
        name = me.name
        city = me.city
        bio = me.bio ?? ""
        priceText = me.price > 0 ? String(me.price) : ""
        yearsText = me.yearsExp > 0 ? String(me.yearsExp) : ""
        cert = me.cert
        specialties = Set(me.specialties)
        sessionTypes = Set(me.sessionTypes)
        paymentMethods = Set(PaymentMethod.known(me.paymentMethods))
        photo = me.photo
        certPhoto = me.certPhoto
        // No reverse-geocode on open: the name falls back to the city field, and a network lookup
        // nobody asked for is the wrong thing to do when a screen appears.
        teachingArea = me.coarseLocation
        loaded = true
    }

    private func save() {
        guard let me = data.currentInstructor else { dismiss(); return }
        // Every field here is broadcast to the public catalog, so it is screened before publishing
        // (Guideline 1.2). Private messages are deliberately not screened — see `ContentFilter`.
        if let rejection = ContentFilter.reject(fields: [name, city, bio, cert]) {
            filterMessage = rejection.message
            return
        }
        me.name = name.trimmed
        me.city = city.trimmed
        me.bio = bio.trimmed
        me.cert = cert.trimmed
        me.price = Int(priceText) ?? 0
        me.yearsExp = Int(yearsText) ?? 0
        // Filter through the canonical lists so stored order stays stable rather than set order.
        me.specialties = allSpecialties.filter { specialties.contains($0) }
        me.sessionTypes = allSessionTypes.filter { sessionTypes.contains($0) }
        me.paymentMethods = PaymentMethod.all.filter { paymentMethods.contains($0) }
        me.photo = photo
        me.certPhoto = certPhoto
        // nil clears both fields and removes the keys from the public record — Remove has to be a
        // real withdrawal, not a value that lingers on other people's devices.
        me.setCoarseLocation(teachingArea)
        data.commit()
        dismiss()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension View {
    /// The editor's shared input surface: card fill, rounded, hairline border.
    func boxed() -> some View {
        background(Color.floweCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
    }
}

#Preview {
    EditProfileView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
}
