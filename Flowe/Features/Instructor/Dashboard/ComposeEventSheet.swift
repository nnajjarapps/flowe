import SwiftUI
import PhotosUI

/// Creates or edits an instructor-hosted event. Same `Form` idiom as `ComposePostSheet`, with each
/// section's rationale in its footer.
///
/// Editing and creating share one sheet because the store's upsert is deterministic on the event's
/// `localID` — a re-publish overwrites the same record rather than duplicating the workshop.
struct ComposeEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings

    private let editing: CommunityEvent?

    @State private var title: String
    @State private var about: String
    @State private var startsAt: Date
    @State private var durationMinutes: Int
    @State private var location: String
    @State private var capacity: Int
    @State private var isFree: Bool
    @State private var priceText: String

    @State private var image: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingImage = false
    @State private var filterMessage: String?

    private let durations = [45, 60, 75, 90, 120]

    init(editing: CommunityEvent? = nil) {
        self.editing = editing
        _title = State(initialValue: editing?.title ?? "")
        _about = State(initialValue: editing?.about ?? "")
        // A fresh event defaults to the next round hour; editing keeps the stored time.
        _startsAt = State(initialValue: editing?.startsAt ?? Date().addingTimeInterval(3600))
        _durationMinutes = State(initialValue: editing?.durationMinutes ?? 60)
        _location = State(initialValue: editing?.location ?? "")
        _capacity = State(initialValue: max(1, editing?.capacity ?? 10))
        // nil (not stated) and n both leave the toggle off; only a genuine 0 is "Free".
        _isFree = State(initialValue: editing?.price == 0)
        _priceText = State(initialValue: (editing?.price).flatMap { $0 > 0 ? String($0) : nil } ?? "")
        _image = State(initialValue: editing?.highlight)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && capacity >= 1
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("event.title")
                } header: {
                    Text("What are you hosting?")
                } footer: {
                    Text("A class, a workshop or a retreat — whatever you're opening to the community.")
                }

                Section {
                    TextField("Tell people what to expect", text: $about, axis: .vertical)
                        .lineLimit(4...10)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("event.about")
                } header: {
                    Text("Description")
                }

                Section {
                    DatePicker("Starts", selection: $startsAt, in: Date()...,
                               displayedComponents: [.date, .hourAndMinute])
                        .font(FloweFont.sans(14))
                    Picker("Duration", selection: $durationMinutes) {
                        ForEach(durations, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .font(FloweFont.sans(14))
                } header: {
                    Text("When")
                }

                Section {
                    TextField("Studio or address", text: $location)
                        .font(FloweFont.sans(14))
                } header: {
                    Text("Where")
                } footer: {
                    Text("A studio name and street is enough — Flowe doesn't map events.")
                }

                Section {
                    Stepper(value: $capacity, in: 1...50) {
                        Text("^[\(capacity) spot](inflect: true)")
                            .font(FloweFont.sans(14))
                    }
                    .accessibilityIdentifier("event.capacity")
                } header: {
                    Text("Capacity")
                } footer: {
                    Text("Flowe counts registrations, and two people can take the last spot at the same moment. If that happens, the later one is told and their spot is released.")
                }

                Section {
                    Toggle("Free event", isOn: $isFree)
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
            .navigationTitle(editing == nil ? "Host an event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Host" : "Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("event.create")
                }
            }
            .alert("Check your event",
                   isPresented: .init(get: { filterMessage != nil },
                                      set: { if !$0 { filterMessage = nil } })) {
                Button("OK", role: .cancel) { filterMessage = nil }
            } message: {
                Text(filterMessage ?? "")
            }
        }
    }

    // MARK: - Photo (the ComposePostSheet pipeline verbatim)

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
            .accessibilityIdentifier("event.photoPicker")

            if image != nil {
                Button("Remove") {
                    image = nil
                    pickerItem = nil
                }
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
                .accessibilityIdentifier("event.photoRemove")
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
        // Title and description are public content, screened like a listing or a review. The photo is
        // not screened — nothing here can look at an image — which is why an event is reportable.
        if let rejection = ContentFilter.reject(fields: [title, about]) {
            filterMessage = rejection.message
            return
        }

        // Advisory only — the real "who's in" decision is the §4 reconciliation, not this check. But
        // an organizer who typed a smaller number than the people already holding a spot should be
        // told rather than silently squeezing them out.
        if let editing, let count = editing.attendees, capacity < count {
            filterMessage = String(localized:
                "\(count) people have already registered — set the capacity to at least that.")
            return
        }

        // Not free + a typed amount → that amount; not free + blank → nil (price not stated), never a
        // fabricated 0; free → a genuine 0.
        let price: Int? = isFree ? 0 : Int(priceText.trimmingCharacters(in: .whitespaces))
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAbout = about.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)

        if let editing {
            data.updateEvent(
                editing, title: trimmedTitle, about: trimmedAbout, location: trimmedLocation,
                startsAt: startsAt, durationMinutes: durationMinutes, capacity: capacity,
                price: price, image: image
            )
        } else {
            data.addEvent(
                title: trimmedTitle, about: trimmedAbout, location: trimmedLocation,
                startsAt: startsAt, durationMinutes: durationMinutes, capacity: capacity,
                price: price, image: image
            )
        }
        dismiss()
    }
}

#Preview {
    ComposeEventSheet()
        .environment(MockDataStore.preview)
}
