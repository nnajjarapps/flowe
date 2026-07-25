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
        _durationMinutes = State(initialValue: editing?.durationMinutes ?? 0)
        // A fresh type defaults to a small group; editing keeps the stored size (never below 1, since
        // the stepper can't state 0 — a stored 0 only comes from a migrated legacy name).
        _capacity = State(initialValue: max(1, editing?.capacity ?? 2))
        // nil (not stated) and n both leave the toggle off; only a genuine 0 is "Free".
        _isFree = State(initialValue: editing?.price == 0)
        _priceText = State(initialValue: (editing?.price).flatMap { $0 > 0 ? String($0) : nil } ?? "")
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
                    Stepper(value: $capacity, in: 1...50) {
                        // A one-person lesson reads "1-on-1"; any larger group states the ceiling.
                        if capacity == 1 {
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
                            Text(verbatim: "$")
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
        // not stated), never a fabricated 0.
        let price: Int? = isFree ? 0 : Int(priceText.trimmingCharacters(in: .whitespaces))
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)

        if let editing {
            data.updateLessonType(
                editing, name: trimmedName, details: trimmedDetails,
                durationMinutes: durationMinutes, capacity: capacity, price: price, image: image
            )
        } else {
            data.addLessonType(
                name: trimmedName, details: trimmedDetails,
                durationMinutes: durationMinutes, capacity: capacity, price: price, image: image
            )
        }
        dismiss()
    }
}

#Preview {
    ComposeLessonTypeSheet()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
}
