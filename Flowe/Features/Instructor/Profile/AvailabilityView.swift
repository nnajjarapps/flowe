import SwiftUI

/// Editor for which weekdays the instructor is bookable. Persists to the instructor's
/// `available` array in SwiftData, so Discover / the booking day-picker reflect it.
struct AvailabilityView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    private let allDays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    @State private var selected: Set<String> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bookable days")
                            .font(FloweFont.serif(22))
                            .foregroundStyle(Color.floweInk)
                        Text("Students can only request sessions on the days you turn on.")
                            .font(FloweFont.sans(13))
                            .foregroundStyle(Color.floweMuted)
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(allDays, id: \.self) { day in
                            dayChip(day)
                        }
                    }

                    HStack {
                        Image(systemName: "info.circle")
                        Text("\(selected.count) days open per week")
                    }
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)
                }
                .padding(20)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle("Availability")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.tint(Color.flowePinkDeep).fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            selected = Set(data.currentInstructor?.available ?? [])
            loaded = true
        }
    }

    private func dayChip(_ day: String) -> some View {
        let isOn = selected.contains(day)
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                if isOn { selected.remove(day) } else { selected.insert(day) }
            }
        } label: {
            Text(day)
                .font(FloweFont.sans(14, .medium))
                .foregroundStyle(isOn ? .white : Color.floweInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 14).fill(FlowGradients.gradDark)
                    } else {
                        RoundedRectangle(cornerRadius: 14).fill(Color.floweCardBg)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func save() {
        data.currentInstructor?.available = allDays.filter { selected.contains($0) }
        data.commit()
        dismiss()
    }
}

#Preview {
    AvailabilityView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
}
