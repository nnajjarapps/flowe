import SwiftUI
import PhotosUI

/// Creates or edits one rich, instructor-authored lesson type — a free-form offer like "Sunrise
/// Reformer" or "Rehab 1-on-1", not a tick on a fixed menu. Same `Form` idiom as `ComposeEventSheet`,
/// with each section's rationale in its footer.
///
/// Editing and creating share one sheet because the store's upsert is deterministic on the type's
/// `localID` — a re-publish overwrites the same record rather than duplicating the offer.
struct ComposeLessonTypeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings

    private let editing: LessonType?

    @State private var name: String
    @State private var details: String
    @State private var durationMinutes: Int
    @State private var capacity: Int
    @State private var isFree: Bool
    @State private var priceText: String

    // No-Show Shield policy
    @State private var cancelWindowHours: Int
    @State private var feeIsPercent: Bool
    @State private var feeText: String

    @State private var image: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingImage = false
    @State private var filterMessage: String?

    /// A fixed set of common lengths, plus the 0 "Not set" tag — duration is optional here, unlike an
    /// event, so a type that doesn't state one omits the line entirely.
    private let durations = [30, 45, 50, 55, 60, 75, 90]

    init(editing: LessonType? = nil) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _details = State(initialValue: editing?.details ?? "")
        // A fresh type defaults to a REAL duration in the picker (55, a valid option) — never 0, which
        // isn't a selectable row and, if saved, made bookings fall back to a fabricated "50 min".
        _durationMinutes = State(initialValue: editing?.durationMinutes ?? 55)
        // A fresh type defaults to a small group; editing keeps the stored size (never below 1, since
        // the stepper can't state 0 — a stored 0 only comes from a migrated legacy name).
        // Preserve a "not stated" (0) capacity when editing — `max(1, …)` used to force it to 1, so
        // opening a migrated legacy offer (all created with capacity 0) just to add a price silently
        // relabelled it "1-on-1" everywhere. New types still default to 2 (a small group).
        _capacity = State(initialValue: editing?.capacity ?? 2)
        // nil (not stated) and n both leave the toggle off; only a genuine 0 is "Free".
        _isFree = State(initialValue: editing?.price == 0)
        _priceText = State(initialValue: (editing?.price).flatMap { $0 > 0 ? String($0) : nil } ?? "")
        _cancelWindowHours = State(initialValue: editing?.cancelWindowHours ?? 0)
        _feeIsPercent = State(initialValue: editing?.cancelFeeIsPercent ?? false)
        _feeText = State(initialValue: (editing?.cancelFee).flatMap { $0 > 0 ? String($0) : nil } ?? "")
        _image = State(initialValue: editing?.highlight)
    }

    // Capacity has a sensible default, so only a name is required.
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("lessonType.name")
                } header: {
                    Text("What do you call this lesson?")
                } footer: {
                    Text("Your words, shown exactly as you type them — \"Sunrise Reformer\", \"Prenatal Mat\".")
                }

                Section {
                    TextField("What to expect", text: $details, axis: .vertical)
                        .lineLimit(4...10)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("lessonType.details")
                } header: {
                    Text("Details")
                }

                Section {
                    Picker("Duration", selection: $durationMinutes) {
                        Text("Not set").tag(0)
                        ForEach(durations, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .font(FloweFont.sans(14))
                    .accessibilityIdentifier("lessonType.duration")
                } header: {
                    Text("Duration")
                }

                Section {
                    // Range starts at 0 = "Not stated" so a migrated legacy type keeps that state and
                    // the group-size line stays omitted (matches `LessonType.capacity` semantics and the
                    // Duration "Not set" pattern); 1 reads "1-on-1"; larger states the ceiling.
                    Stepper(value: $capacity, in: 0...50) {
                        if capacity == 0 {
                            Text("Not stated").font(FloweFont.sans(14)).foregroundStyle(Color.floweMuted)
                        } else if capacity == 1 {
                            Text("1-on-1").font(FloweFont.sans(14))
                        } else {
                            Text("^[\(capacity) spot](inflect: true)").font(FloweFont.sans(14))
                        }
                    }
                    .accessibilityIdentifier("lessonType.capacity")
                } header: {
                    Text("Group size")
                } footer: {
                    Text("The maximum group size for this lesson. Flowe doesn't track live availability — students send you a 1:1 request.")
                }

                Section {
                    Toggle("Free", isOn: $isFree)
                        .font(FloweFont.sans(14))
                        .tint(Color.flowePinkDeep)
                    if !isFree {
                        HStack(spacing: 4) {
                            Text(verbatim: settings.currencySymbol)
                                .font(FloweFont.serif(18, .medium))
                                .foregroundStyle(Color.floweInk)
                            TextField("40", text: $priceText)
                                .font(FloweFont.serif(18, .medium))
                                .foregroundStyle(Color.floweInk)
                                .keyboardType(.numberPad)
                                .accessibilityIdentifier("lessonType.price")
                        }
                    }
                } header: {
                    Text("Price")
                } footer: {
                    Text("Flowe takes no payment. Students settle with you directly.")
                }

                Section {
                    Picker("Free cancellation up to", selection: $cancelWindowHours) {
                        Text("No policy").tag(0)
                        Text("12 hours before").tag(12)
                        Text("24 hours before").tag(24)
                        Text("48 hours before").tag(48)
                    }
                    .font(FloweFont.sans(14))
                    .accessibilityIdentifier("lessonType.cancelWindow")
                    if cancelWindowHours > 0 {
                        Picker("Late-cancel / no-show fee", selection: $feeIsPercent) {
                            Text("Flat amount").tag(false)
                            Text("% of price").tag(true)
                        }
                        .pickerStyle(.segmented)
                        HStack(spacing: 4) {
                            Text(verbatim: feeIsPercent ? "%" : settings.currencySymbol)
                                .font(FloweFont.serif(18, .medium))
                                .foregroundStyle(Color.floweInk)
                            TextField(feeIsPercent ? "50" : "30", text: $feeText)
                                .font(FloweFont.serif(18, .medium))
                                .foregroundStyle(Color.floweInk)
                                .keyboardType(.numberPad)
                                .accessibilityIdentifier("lessonType.cancelFee")
                        }
                    }
                } header: {
                    Text("Cancellation policy")
                } footer: {
                    Text(cancelWindowHours > 0
                         ? "Cancel within \(cancelWindowHours)h or no-show and Flowe tracks the fee for you to collect directly — it never charges it. Students see this before they book."
                         : "Protect your income from late cancellations and no-shows. Flowe only tracks what's owed; you collect it yourself.")
                }

                Section {
                    photoRow
                } header: {
                    Text("Highlight photo")
                } footer: {
                    Text("Optional. One striking photo sets the tone of the card.")
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle(editing == nil ? "Add lesson type" : "Edit lesson type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("lessonType.create")
                }
            }
            .alert("Check your lesson type",
                   isPresented: .init(get: { filterMessage != nil },
                                      set: { if !$0 { filterMessage = nil } })) {
                Button("OK", role: .cancel) { filterMessage = nil }
            } message: {
                Text(filterMessage ?? "")
            }
        }
    }

    // MARK: - Photo (the ComposeEventSheet pipeline verbatim)

    @ViewBuilder
    private var photoRow: some View {
        if let image, let ui = UIImage(data: image) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 8)
        }

        HStack(spacing: 16) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Text(image == nil ? "Add Photo" : "Change Photo")
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            .accessibilityIdentifier("lessonType.photoPicker")

            if image != nil {
                Button("Remove") {
                    image = nil
                    pickerItem = nil
                }
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
                .accessibilityIdentifier("lessonType.photoRemove")
            }

            if isLoadingImage {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.plain)
    }

    private func load(_ item: PhotosPickerItem) async {
        isLoadingImage = true
        defer { isLoadingImage = false }
        // Downscaled before it is ever stored — every highlight is a `CKAsset` other phones download.
        // A failed decode leaves the previous choice alone.
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let prepared = ProfileImage.preparePost(raw) else { return }
        image = prepared
    }

    // MARK: - Save

    private func save() {
        // Name and details are public content, screened like a listing or a review. The photo is not
        // screened — nothing here can look at an image — which is why a lesson type is reportable.
        if let rejection = ContentFilter.reject(fields: [name, details]) {
            filterMessage = rejection.message
            return
        }

        // Free → a genuine 0; not free + a typed amount → that amount; not free + blank → nil (price
        // not stated), never a fabricated 0. Parse via `Self.wholeNumber` (NOT bare `Int(_:)`) so a
        // non-ASCII numeric keyboard — Eastern-Arabic-Indic digits on an Arabic keyboard, which the
        // app ships — or a grouping separator doesn't silently drop the amount to nil and hide the
        // instructor from Discover.
        let price: Int? = isFree ? 0 : Self.wholeNumber(priceText)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        // A percentage fee is clamped to 0…100 — `CancellationPolicy.amount` computes `price * fee/100`,
        // so an un-clamped 150% would show the student a fee larger than the session itself. A flat
        // (currency) fee has no such ceiling.
        let rawFee = cancelWindowHours > 0 ? (Self.wholeNumber(feeText) ?? 0) : 0
        let policy = CancellationPolicy(
            windowHours: cancelWindowHours,
            fee: feeIsPercent ? min(rawFee, 100) : rawFee,
            feeIsPercent: feeIsPercent
        )

        if let editing {
            data.updateLessonType(
                editing, name: trimmedName, details: trimmedDetails,
                durationMinutes: durationMinutes, capacity: capacity, price: price,
                policy: policy, image: image
            )
        } else {
            data.addLessonType(
                name: trimmedName, details: trimmedDetails,
                durationMinutes: durationMinutes, capacity: capacity, price: price,
                policy: policy, image: image
            )
        }
        dismiss()
    }

    /// Parse a user-typed whole-number amount that may contain non-ASCII digits (e.g. the
    /// Eastern-Arabic-Indic ٠–٩ an Arabic keyboard's number pad emits) or grouping separators.
    /// Bare `Int("٥٠")` / `Int("1,000")` both return nil — which silently voided prices and no-show
    /// fees for exactly the Arabic-market users this app targets. Map each Unicode decimal digit to
    /// its value via `wholeNumberValue` and drop everything else; nil only when there is no digit at
    /// all (a blank field → "price not stated", preserved). The field is a whole-shekel `.numberPad`,
    /// so no decimal point is possible — a stray separator is grouping, correctly ignored.
    private static func wholeNumber(_ text: String) -> Int? {
        var digits = ""
        for ch in text where ch.isNumber {
            guard let v = ch.wholeNumberValue, (0...9).contains(v) else { continue }
            digits.append(Character("\(v)"))
        }
        return digits.isEmpty ? nil : Int(digits)
    }
}
