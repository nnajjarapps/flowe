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

    // MARK: - Bulk entry (set many days at once)
    //
    // Pure UI over the SAME in-memory `hours` dict the per-day editor and `save()` use — every bulk
    // write mutates ONLY weekday keys, never a date key, so per-day editing and date overrides are
    // untouched.

    /// Whether the bulk card is expanded (kept collapsed by default to keep the sheet scannable).
    @State private var bulkExpanded = false
    /// The weekdays a bulk apply will target.
    @State private var selectedBulkDays: Set<String> = []
    /// The times picked once, to apply across `selectedBulkDays`.
    @State private var bulkTimes: Set<String> = []
    @State private var bulkTimePicker: Date = AvailabilityView.defaultPickerTime

    /// The source day for a "copy this day to…" action; non-nil drives the target-picker sheet.
    @State private var copyFromDay: String?
    @State private var copyTargets: Set<String> = []

    // MARK: - Date-specific overrides (vacation / one-off days)
    //
    // These break the weekly pattern for a single calendar date. Persisted as date-keyed tokens in the
    // same `hours` array (see `Instructor.hours(onDate:)`), so publishing is the existing catalog path.

    /// A single-date override: fully closed, or a custom set of times replacing that day's slate.
    enum OverrideEdit: Equatable { case closed; case custom(Set<String>) }

    /// Overrides keyed by POSIX "yyyy-MM-dd".
    @State private var overrides: [String: OverrideEdit] = [:]

    // The add/edit-override sheet.
    @State private var showOverrideSheet = false
    @State private var editingKey: String?          // nil = adding a new date; else the date being edited
    @State private var overrideDate = Date()
    @State private var overrideClosed = false
    @State private var overrideTimes: Set<String> = []
    @State private var overrideTimePicker: Date = AvailabilityView.defaultPickerTime

    private var openDays: [String] { allDays.filter { !(hours[$0] ?? []).isEmpty } }
    private var totalSlots: Int { hours.values.reduce(0) { $0 + $1.count } }

    // MARK: - Time formatting
    //
    // A single 12-hour formatter is the bridge between the picker's `Date` and the stored strings
    // ("9:30 AM"), and the basis for sorting times chronologically. `en_US_POSIX` (NOT plain `en_US`)
    // so a fixed "h:mm a" format both emits and parses 12-hour tokens regardless of the device's
    // Settings › General › Date & Time › 24-Hour Time toggle. A non-POSIX `en_US` formatter still
    // honours that toggle (Apple QA1480), so with 24-Hour Time on — the DEFAULT in Israel — every
    // stored "9:00 AM" token failed to parse: `minutes(of:)` fell back to 0, slots stopped sorting,
    // and the student booking sheet showed scrambled times. POSIX makes the token format stable.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
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
        guard let latest = existing.max() else { return Self.defaultPickerTime }
        // One hour after the latest slot — but never roll PAST midnight: a 11:30 PM slot would
        // otherwise suggest 12:30 AM, which sorts ABOVE every real slot and adds an early-morning time
        // nobody meant. If +1h crosses into the next day, just open the picker at the latest slot.
        guard let next = Calendar.current.date(byAdding: .minute, value: 60, to: latest),
              Calendar.current.isDate(next, inSameDayAs: latest) else {
            return latest
        }
        return next
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

                    bulkSection

                    overridesSection

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
        .sheet(isPresented: $showOverrideSheet) { overrideSheet }
        .sheet(isPresented: copyDayBinding) { copyDaySheet }
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

                    Text(LocalizedStringKey(day))
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
                    Button {
                        copyTargets = []
                        copyFromDay = day
                    } label: {
                        Label("Copy to…", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("availability.copyDay.\(day)")

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

    // MARK: - Bulk entry

    /// A collapsible card to set the same hours across many weekdays at once, so a new instructor
    /// isn't dialling the same times into seven days one at a time. Writes only weekday keys of the
    /// existing `hours` dict; `save()` persists them exactly as it does per-day edits.
    private var bulkSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { bulkExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.flowePinkDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set several days at once")
                            .font(FloweFont.sans(15, .medium))
                            .foregroundStyle(Color.floweInk)
                        Text("Pick times once, then apply them to the days you choose.")
                            .font(FloweFont.sans(12))
                            .foregroundStyle(Color.floweMuted)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.floweMuted)
                        .rotationEffect(.degrees(bulkExpanded ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("availability.bulk.toggle")

            if bulkExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    Divider().overlay(Color.floweBorder)

                    // Presets — quick ways to fill the weekday selection.
                    HStack(spacing: 8) {
                        presetChip("Weekdays") { selectedBulkDays = Set(allDays.prefix(5)) }
                        presetChip("Weekends") { selectedBulkDays = Set(allDays.suffix(2)) }
                        presetChip("Every day") { selectedBulkDays = Set(allDays) }
                    }

                    // Hand-tune the selected weekdays.
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(allDays, id: \.self) { day in
                            weekdayPill(day, selected: selectedBulkDays.contains(day)) {
                                if selectedBulkDays.contains(day) { selectedBulkDays.remove(day) }
                                else { selectedBulkDays.insert(day) }
                            }
                        }
                    }

                    // Pick the times to apply.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Times to apply")
                            .font(FloweFont.mono(10))
                            .foregroundStyle(Color.floweMuted)
                        if bulkTimes.isEmpty {
                            Text("Add the times you teach on those days.")
                                .font(FloweFont.sans(12))
                                .foregroundStyle(Color.floweMuted)
                        } else {
                            FlowLayout(spacing: 8, lineSpacing: 8) {
                                ForEach(sorted(bulkTimes), id: \.self) { time in
                                    bulkTimeChip(time)
                                }
                            }
                        }
                        DatePicker("", selection: $bulkTimePicker, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                        Button { bulkTimes.insert(format(bulkTimePicker)) } label: {
                            Label("Add time", systemImage: "plus.circle.fill")
                                .font(FloweFont.sans(13, .medium))
                                .foregroundStyle(Color.flowePinkDeep)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("availability.bulk.addTime")
                    }

                    // Apply — Replace overwrites each selected day; Add unions into it.
                    let canApply = !selectedBulkDays.isEmpty && !bulkTimes.isEmpty
                    HStack(spacing: 10) {
                        Button { applyBulk(replacing: true) } label: {
                            Text("Replace hours")
                                .font(FloweFont.sans(13, .medium))
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 12).fill(FlowGradients.gradDark))
                                .opacity(canApply ? 1 : 0.4)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canApply)
                        .accessibilityIdentifier("availability.bulk.replace")

                        Button { applyBulk(replacing: false) } label: {
                            Text("Add to selected")
                                .font(FloweFont.sans(13, .medium))
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.flowePinkDeep)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 12).stroke(Color.flowePink, lineWidth: 1))
                                .opacity(canApply ? 1 : 0.4)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canApply)
                        .accessibilityIdentifier("availability.bulk.add")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.floweBorder, lineWidth: 1))
    }

    private func presetChip(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(FloweFont.sans(12, .medium))
                .foregroundStyle(Color.flowePinkDeep)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.flowePink.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func weekdayPill(_ day: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(day))
                .font(FloweFont.sans(13, .medium))
                .foregroundStyle(selected ? .white : Color.floweInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background {
                    if selected {
                        Capsule().fill(FlowGradients.gradDark)
                    } else {
                        Capsule().fill(Color.floweCardBg)
                            .overlay(Capsule().stroke(Color.floweBorder, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("availability.bulk.day.\(day)")
    }

    private func bulkTimeChip(_ time: String) -> some View {
        Button { bulkTimes.remove(time) } label: {
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
    }

    /// Apply `bulkTimes` across `selectedBulkDays`. Replace overwrites each day's set; otherwise union
    /// into whatever is already there. Only weekday keys are touched. Clears the staging afterward.
    private func applyBulk(replacing: Bool) {
        guard !selectedBulkDays.isEmpty, !bulkTimes.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            for day in selectedBulkDays {
                hours[day] = replacing ? bulkTimes : (hours[day] ?? []).union(bulkTimes)
            }
            selectedBulkDays = []
            bulkTimes = []
        }
    }

    // MARK: - Copy one day to others

    private var copyDayBinding: Binding<Bool> {
        Binding(get: { copyFromDay != nil }, set: { if !$0 { copyFromDay = nil } })
    }

    private var copyDaySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                    Text("Copy the times from \(copyFromDay ?? "") to the days you pick.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(allDays.filter { $0 != copyFromDay }, id: \.self) { day in
                            weekdayPill(day, selected: copyTargets.contains(day)) {
                                if copyTargets.contains(day) { copyTargets.remove(day) }
                                else { copyTargets.insert(day) }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle("Copy day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { copyFromDay = nil }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { applyCopyDay() }
                        .tint(Color.flowePinkDeep)
                        .fontWeight(.semibold)
                        .disabled(copyTargets.isEmpty)
                        .accessibilityIdentifier("availability.copyDay.apply")
                }
            }
            .presentationDetents([.medium])
        }
    }

    /// Overwrite each target day's times with the source day's, then dismiss. Weekday keys only.
    private func applyCopyDay() {
        guard let source = copyFromDay else { return }
        let times = hours[source] ?? []
        withAnimation(.easeInOut(duration: 0.16)) {
            for day in copyTargets { hours[day] = times }
        }
        copyFromDay = nil
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
        // Date overrides ride in the same `hours` array under date keys — decode them separately.
        // Skip keys already in the past: an override for a bygone date is dead weight that would
        // otherwise persist in `hours` and re-publish to CloudKit forever. Because `save()` re-emits
        // ONLY what's decoded here (after `clearAllDateOverrides`), dropping stale keys here prunes them
        // from storage on the next save. ISO "yyyy-MM-dd" keys compare chronologically as strings.
        let todayKey = Booking.seriesDateString(Date())
        for key in me.overriddenDates where key >= todayKey {
            switch me.dateOverride(forKey: key) {
            case .closed:               overrides[key] = .closed
            case .custom(let times):    overrides[key] = .custom(Set(times))
            case .none:                 break
            }
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
        // Re-write the date overrides: wipe the old date tokens, then emit the current set. This runs
        // AFTER the weekday loop and BEFORE recomputing `available` — `clearAllDateOverrides` and the
        // date-keyed writers touch only date tokens, and `daysWithHours` ignores date tokens, so
        // `available` stays weekday-only regardless.
        me.clearAllDateOverrides()
        for (key, edit) in overrides {
            switch edit {
            case .closed:
                me.setClosed(onDateKey: key)
            case .custom(let times) where !times.isEmpty:
                me.setHours(sorted(times), onDateKey: key)
            case .custom:
                break   // an empty custom set is not an override — leave the date on its weekday pattern
            }
        }
        // Recompute `available` from the tokens we just wrote — a day is bookable iff it kept ≥1
        // time. Must read the NEW tokens (`daysWithHours`), NOT `bookableDays`, or the legacy
        // full-slate fallback re-opens a day we just closed (the "close silently reopens" bug).
        me.available = me.daysWithHours
        data.commit()
        dismiss()
    }

    // MARK: - Date-override section

    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Time off and one-off days")
                    .font(FloweFont.serif(17, .medium))
                    .foregroundStyle(Color.floweInk)
                Text("Close a date for a holiday, or set different hours for one day.")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
            }

            ForEach(overrides.keys.sorted(), id: \.self) { key in
                overrideRow(key)
            }

            Button { presentAddOverride() } label: {
                Label("Add a date", systemImage: "calendar.badge.plus")
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("availability.addOverride")
        }
    }

    private func overrideRow(_ key: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: overrides[key] == .closed ? "moon.zzz.fill" : "clock.badge.checkmark")
                .font(.system(size: 15))
                .foregroundStyle(Color.flowePinkDeep)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: label(forKey: key))
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(Color.floweInk)
                Text(verbatim: overrideSummary(key))
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) { overrides[key] = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.floweMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove date override")
            .accessibilityIdentifier("availability.removeOverride.\(key)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { presentEditOverride(key) }
    }

    /// The closed/custom summary for an override row. Custom times are shown verbatim (the same English
    /// tokens the weekly editor's chips show), so an instructor sees exactly what was set.
    private func overrideSummary(_ key: String) -> String {
        switch overrides[key] {
        case .closed:            return String(localized: "Closed")
        case .custom(let times): return sorted(times).joined(separator: ", ")
        case .none:              return ""
        }
    }

    // MARK: Add / edit override sheet

    private var overrideSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                    // The date is chosen only when ADDING — editing keeps the same date (the sheet title
                    // shows it), so no picker is needed and the key stays stable.
                    if editingKey == nil {
                        DatePicker("", selection: $overrideDate, in: overrideDateRange,
                                   displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.graphical)
                            .tint(Color.flowePinkDeep)
                    }

                    HStack(spacing: 8) {
                        modeChip(title: "Close this date", active: overrideClosed) { overrideClosed = true }
                        modeChip(title: "Custom hours", active: !overrideClosed) { overrideClosed = false }
                    }

                    if overrideClosed {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Students won't be able to book on this date.")
                                .font(FloweFont.sans(13))
                                .foregroundStyle(Color.floweMuted)
                            if bookingsOnDate(overrideDate) > 0 {
                                warningRow("You have sessions booked on this date. Closing it won't cancel them.")
                            }
                        }
                    } else {
                        customTimesEditor
                    }
                }
                .padding(20)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle(Text(verbatim: overrideDate.formatted(date: .abbreviated, time: .omitted)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showOverrideSheet = false }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveOverride() }
                        .tint(Color.flowePinkDeep)
                        .fontWeight(.semibold)
                        .disabled(!overrideClosed && overrideTimes.isEmpty)
                        .accessibilityIdentifier("availability.saveOverride")
                }
            }
        }
        .presentationDetents([.large])
    }

    private var customTimesEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if overrideTimes.isEmpty {
                Text("Add the times you'll teach on this day.")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(sorted(overrideTimes), id: \.self) { time in
                        overrideTimeChip(time)
                    }
                }
            }

            DatePicker("", selection: $overrideTimePicker, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()

            Button { overrideTimes.insert(format(overrideTimePicker)) } label: {
                Label("Add time", systemImage: "plus.circle.fill")
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("availability.override.addTime")
        }
    }

    private func overrideTimeChip(_ time: String) -> some View {
        Button { overrideTimes.remove(time) } label: {
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
    }

    private func modeChip(title: LocalizedStringKey, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(FloweFont.sans(13, .medium))
                .foregroundStyle(active ? .white : Color.floweMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 12).fill(FlowGradients.gradDark)
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(Color.floweCardBg)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.floweBorder, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func warningRow(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.flowePinkDeep)
            Text(text)
                .font(FloweFont.sans(12))
                .foregroundStyle(Color.flowePinkDeep)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Override helpers

    /// Accepted override window: today through the last bookable day (matches the booking horizon).
    private var overrideDateRange: ClosedRange<Date> {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: FloweWeek.maxDayID, to: start) ?? start
        return start...end
    }

    private static let keyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func date(fromKey key: String) -> Date? { Self.keyParser.date(from: key) }

    /// A localized, region-formatted label for a date key (e.g. "Aug 14, 2026").
    private func label(forKey key: String) -> String {
        guard let d = date(fromKey: key) else { return key }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    /// The instructor's own non-cancelled sessions already booked on a date — surfaced as a warning
    /// before closing it, since the serverless model can't silently cancel a student's booking.
    private func bookingsOnDate(_ date: Date) -> Int {
        let ds = FloweWeek.bookingDateString(for: date)
        return data.incomingBookings.filter { $0.date == ds && $0.status != .cancelled }.count
    }

    private func presentAddOverride() {
        editingKey = nil
        overrideDate = Calendar.current.startOfDay(for: Date())
        overrideClosed = false
        overrideTimes = []
        overrideTimePicker = Self.defaultPickerTime
        showOverrideSheet = true
    }

    private func presentEditOverride(_ key: String) {
        editingKey = key
        overrideDate = date(fromKey: key) ?? Calendar.current.startOfDay(for: Date())
        switch overrides[key] {
        case .closed:            overrideClosed = true;  overrideTimes = []
        case .custom(let t):     overrideClosed = false; overrideTimes = t
        case .none:              overrideClosed = false; overrideTimes = []
        }
        overrideTimePicker = Self.defaultPickerTime
        showOverrideSheet = true
    }

    private func saveOverride() {
        let key = Booking.seriesDateString(overrideDate)
        // Adding on a date that already has an override just replaces it (one override per date).
        if let editingKey, editingKey != key { overrides[editingKey] = nil }
        overrides[key] = overrideClosed ? .closed : .custom(overrideTimes)
        showOverrideSheet = false
    }
}
