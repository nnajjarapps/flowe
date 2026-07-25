import SwiftUI

/// Editor for when the instructor is bookable — which weekdays, and which hours on each.
/// Persists to the instructor's `available` + `hours` in SwiftData and publishes to the public
/// catalog, so Discover and the student booking flow reflect it.
///
/// Hours are fully custom: the instructor adds any time they like via a time picker, rather than
/// choosing from a fixed slate. The model stores free-form time strings, so nothing downstream
/// (booking, catalog) needs to know these are no longer a preset grid.
struct AvailabilityView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    private let allDays = FloweConstants.weekdays

    /// Chosen times per weekday. A day is open when it has at least one time.
    @State private var hours: [String: Set<String>] = [:]
    /// The day whose times are expanded; only one is open at a time to keep the sheet scannable.
    @State private var expanded: String?
    @State private var loaded = false

    /// The day currently having a time added (drives the picker sheet), and the picker's value.
    @State private var addTimeDay: String?
    @State private var pickerTime: Date = AvailabilityView.defaultPickerTime

    private var openDays: [String] { allDays.filter { !(hours[$0] ?? []).isEmpty } }
    private var totalSlots: Int { hours.values.reduce(0) { $0 + $1.count } }

    // MARK: - Time formatting
    //
    // A single 12-hour formatter is the bridge between the picker's `Date` and the stored strings
    // ("9:30 AM"), and the basis for sorting times chronologically. en_US so the stored token format
    // stays stable regardless of device locale — the booking flow reads these strings verbatim.

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f
    }()

    private static var defaultPickerTime: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private func format(_ date: Date) -> String { Self.timeFormatter.string(from: date) }

    /// Minutes past midnight for a stored time string — used only for chronological ordering.
    private func minutes(of time: String) -> Int {
        guard let d = Self.timeFormatter.date(from: time) else { return 0 }
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func sorted(_ times: Set<String>) -> [String] {
        times.sorted { minutes(of: $0) < minutes(of: $1) }
    }

    /// Sensible default for the picker: one hour after the latest existing time, else 9:00 AM — so
    /// adding a run of slots is a few taps rather than re-dialling from scratch each time.
    private func suggestedTime(for day: String) -> Date {
        let existing = (hours[day] ?? []).compactMap { Self.timeFormatter.date(from: $0) }
        if let latest = existing.max(),
           let next = Calendar.current.date(byAdding: .minute, value: 60, to: latest) {
            return next
        }
        return Self.defaultPickerTime
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When can students book?")
                            .font(FloweFont.serif(22))
                            .foregroundStyle(Color.floweInk)
                        Text("Turn on a day, then add the exact times you teach. Students can only request the times you choose.")
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
        .sheet(isPresented: addTimeBinding) { addTimeSheet }
    }

    // MARK: - Day row

    private func dayRow(_ day: String) -> some View {
        let chosen = hours[day] ?? []
        let isOpen = !chosen.isEmpty
        let isExpanded = expanded == day

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expanded = isExpanded ? nil : day
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

                    Text(isOpen ? summaryLabel(for: chosen) : "Closed")
                        .font(FloweFont.mono(10))
                        .foregroundStyle(isOpen ? Color.flowePinkDeep : Color.floweMuted)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.floweMuted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("availability.day.\(day)")

            if isExpanded {
                timesEditor(for: day, chosen: chosen)
            }
        }
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isOpen ? Color.flowePink.opacity(0.4) : Color.floweBorder, lineWidth: 1)
        )
    }

    private func timesEditor(for day: String, chosen: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Color.floweBorder)

            if chosen.isEmpty {
                Text("No times yet — add the times you teach on \(day).")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(sorted(chosen), id: \.self) { time in
                        timeChip(day: day, time: time)
                    }
                }
            }

            HStack(spacing: 16) {
                Button {
                    pickerTime = suggestedTime(for: day)
                    addTimeDay = day
                } label: {
                    Label("Add time", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("availability.add.\(day)")

                if !chosen.isEmpty {
                    Button("Close this day", role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            hours[day] = []
                            expanded = nil
                        }
                    }
                    .accessibilityIdentifier("availability.close.\(day)")
                }
            }
            .font(FloweFont.sans(12, .medium))
            .buttonStyle(.plain)
            .tint(Color.flowePinkDeep)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    /// A chosen time; tapping it (the ✕) removes it.
    private func timeChip(day: String, time: String) -> some View {
        Button {
            var set = hours[day] ?? []
            set.remove(time)
            hours[day] = set
        } label: {
            HStack(spacing: 6) {
                Text(time).font(FloweFont.mono(11))
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(FlowGradients.gradDark))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("availability.slot.\(day).\(time)")
    }

    // MARK: - Add-time picker

    private var addTimeBinding: Binding<Bool> {
        Binding(get: { addTimeDay != nil }, set: { if !$0 { addTimeDay = nil } })
    }

    private var addTimeSheet: some View {
        NavigationStack {
            VStack {
                DatePicker("", selection: $pickerTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .padding(.top, 20)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle(addTimeDay.map { "Add time · \($0)" } ?? "Add time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { addTimeDay = nil }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let day = addTimeDay {
                            var set = hours[day] ?? []
                            set.insert(format(pickerTime))
                            hours[day] = set
                        }
                        addTimeDay = nil
                    }
                    .tint(Color.flowePinkDeep)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("availability.addTime.confirm")
                }
            }
            .presentationDetents([.medium])
        }
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
        .accessibilityIdentifier("availability.summary")
    }

    /// The single time when there's only one (more useful than a count), else a slot count.
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
            // Store each day's custom times in chronological order so the booking flow lists them
            // sensibly (it reads `hours(on:)` verbatim).
            me.setHours(sorted(hours[day] ?? []), on: day)
        }
        // Recompute `available` from the tokens we just wrote — a day is bookable iff it kept ≥1
        // time. Must read the NEW tokens (`daysWithHours`), NOT `bookableDays`, or the legacy
        // full-slate fallback re-opens a day we just closed (the "close silently reopens" bug).
        me.available = me.daysWithHours
        data.commit()
        dismiss()
    }
}

#Preview {
    AvailabilityView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
}
