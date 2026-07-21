import SwiftUI

/// Editor for when the instructor is bookable — which weekdays, and which hours on each.
/// Persists to the instructor's `available` + `hours` in SwiftData and publishes to the public
/// catalog, so Discover and the student booking flow reflect it.
struct AvailabilityView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    private let allDays = FloweConstants.weekdays

    /// Chosen hours per weekday. A day is open when it has at least one hour.
    @State private var hours: [String: Set<String>] = [:]
    /// The day whose hours are expanded; only one is open at a time to keep the sheet scannable.
    @State private var expanded: String?
    @State private var loaded = false

    private var openDays: [String] { allDays.filter { !(hours[$0] ?? []).isEmpty } }
    private var totalSlots: Int { hours.values.reduce(0) { $0 + $1.count } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When can students book?")
                            .font(FloweFont.serif(22))
                            .foregroundStyle(Color.floweInk)
                        Text("Turn on a day, then pick the hours you teach. Students can only request the times you choose.")
                            .font(FloweFont.sans(13))
                            .foregroundStyle(Color.floweMuted)
                    }

                    VStack(spacing: 10) {
                        ForEach(allDays, id: \.self) { day in
                            dayRow(day)
                        }
                    }

                    summary
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
                    Button("Save") { save() }
                        .tint(Color.flowePinkDeep)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("availability.save")
                }
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - Day row

    private func dayRow(_ day: String) -> some View {
        let chosen = hours[day] ?? []
        let isOpen = !chosen.isEmpty
        let isExpanded = expanded == day

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isOpen && isExpanded {
                        // Collapse without clearing — closing the disclosure isn't "close the day".
                        expanded = nil
                    } else if isOpen {
                        expanded = day
                    } else {
                        // Opening a day pre-fills the standard slate; an open day with no hours
                        // would be indistinguishable from a closed one.
                        hours[day] = Set(FloweConstants.times)
                        expanded = day
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isOpen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isOpen ? Color.flowePinkDeep : Color.floweBorder)

                    Text(day)
                        .font(FloweFont.sans(15, .medium))
                        .foregroundStyle(Color.floweInk)

                    Spacer()

                    if isOpen {
                        Text(verbatim: summaryLabel(for: chosen))
                            .font(FloweFont.mono(10))
                            .foregroundStyle(Color.flowePinkDeep)
                    } else {
                        Text("Closed")
                            .font(FloweFont.mono(10))
                            .foregroundStyle(Color.floweMuted)
                    }

                    if isOpen {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.floweMuted)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("availability.day.\(day)")

            if isExpanded {
                hourGrid(for: day, chosen: chosen)
            }
        }
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isOpen ? Color.flowePink.opacity(0.4) : Color.floweBorder, lineWidth: 1)
        )
    }

    private func hourGrid(for day: String, chosen: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Color.floweBorder)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(FloweConstants.times, id: \.self) { time in
                    hourChip(day: day, time: time, isOn: chosen.contains(time))
                }
            }

            HStack(spacing: 14) {
                Button("Select all") { hours[day] = Set(FloweConstants.times) }
                Button("Close this day", role: .destructive) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        hours[day] = []
                        expanded = nil
                    }
                }
                .accessibilityIdentifier("availability.close.\(day)")
            }
            .font(FloweFont.sans(12, .medium))
            .buttonStyle(.plain)
            .tint(Color.flowePinkDeep)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func hourChip(day: String, time: String, isOn: Bool) -> some View {
        Button {
            var set = hours[day] ?? []
            if isOn { set.remove(time) } else { set.insert(time) }
            hours[day] = set
        } label: {
            Text(time)
                .font(FloweFont.mono(11))
                .foregroundStyle(isOn ? .white : Color.floweInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 10).fill(FlowGradients.gradDark)
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(Color.flowWhite)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.floweBorder, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(spacing: 6) {
            Image(systemName: openDays.isEmpty ? "exclamationmark.triangle" : "info.circle")
            if openDays.isEmpty {
                Text("Students can't book you until you open at least one day.")
            } else {
                Text("\(totalSlots) slots across \(openDays.count) days")
            }
        }
        .font(FloweFont.mono(11))
        .foregroundStyle(openDays.isEmpty ? Color.flowePinkDeep : Color.floweMuted)
    }

    /// "3 slots" — or the single time when there's only one, which is more useful than a count.
    private func summaryLabel(for chosen: Set<String>) -> String {
        if chosen.count == 1, let only = chosen.first { return only.uppercased() }
        return "\(chosen.count) slots"
    }

    // MARK: - Persistence

    private func load() {
        guard !loaded, let me = data.currentInstructor else { return }
        for day in allDays {
            let times = me.hours(on: day)
            if !times.isEmpty { hours[day] = Set(times) }
        }
        expanded = openDays.first
        loaded = true
    }

    private func save() {
        guard let me = data.currentInstructor else { return dismiss() }
        for day in allDays {
            me.setHours(FloweConstants.times.filter { hours[day]?.contains($0) == true }, on: day)
        }
        // `available` stays the day-level view of the same data — the feed and the public catalog
        // already read it, so it must not drift out of sync with the hours.
        me.available = me.bookableDays
        data.commit()
        dismiss()
    }
}

#Preview {
    AvailabilityView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
}
