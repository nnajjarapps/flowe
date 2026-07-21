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
