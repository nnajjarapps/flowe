import SwiftUI

/// Editor for the instructor's public profile — bio, session rate, and specialties.
/// Persists directly to the instructor's SwiftData record.
struct EditProfileView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    private let allSpecialties = ["Mat", "Reformer", "Barre", "Tower", "Prenatal", "Rehab"]

    @State private var bio = ""
    @State private var priceText = ""
    @State private var specialties: Set<String> = []
    @State private var loaded = false

    private var priceIsValid: Bool { Int(priceText).map { $0 > 0 } ?? false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                    field(title: "BIO") {
                        TextEditor(text: $bio)
                            .font(FloweFont.sans(14))
                            .foregroundStyle(Color.floweInk)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(Color.floweCardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
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
                        .background(Color.floweCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
                    }

                    field(title: "SPECIALTIES") {
                        FlowLayout(spacing: 8, lineSpacing: 8) {
                            ForEach(allSpecialties, id: \.self) { spec in
                                specialtyChip(spec)
                            }
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
                        .disabled(!priceIsValid)
                }
            }
        }
        .onAppear {
            guard !loaded, let me = data.currentInstructor else { return }
            bio = me.bio ?? ""
            priceText = String(me.price)
            specialties = Set(me.specialties)
            loaded = true
        }
    }

    private func field<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: title)
            content()
        }
    }

    private func specialtyChip(_ spec: String) -> some View {
        let isOn = specialties.contains(spec)
        return Button {
            if isOn { specialties.remove(spec) } else { specialties.insert(spec) }
        } label: {
            Text(spec)
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

    private func save() {
        guard let me = data.currentInstructor else { dismiss(); return }
        me.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        if let price = Int(priceText) { me.price = price }
        me.specialties = allSpecialties.filter { specialties.contains($0) }
        data.commit()
        dismiss()
    }
}

#Preview {
    EditProfileView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
}
