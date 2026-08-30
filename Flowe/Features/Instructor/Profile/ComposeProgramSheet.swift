import SwiftUI
import PhotosUI

/// Creates or edits one Flowe Education **program** — a named collection of video exercises. Same `Form`
/// idiom + photo pipeline as `ComposeLessonTypeSheet`; editing and creating share the sheet because the
/// store's upsert is deterministic on the program's `localID`.
struct ComposeProgramSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    private let editing: Program?

    @State private var title: String
    @State private var summary: String
    @State private var cover: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingImage = false
    @State private var filterMessage: String?

    init(editing: Program? = nil) {
        self.editing = editing
        _title = State(initialValue: editing?.title ?? "")
        _summary = State(initialValue: editing?.summary ?? "")
        _cover = State(initialValue: editing?.cover)
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $title)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("program.name")
                } header: {
                    Text("Program name")
                } footer: {
                    Text("A collection of exercises — \"Beginner Reformer\", \"Post-natal Flow\".")
                }

                Section {
                    TextField("What it's for", text: $summary, axis: .vertical)
                        .lineLimit(3...8)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("program.summary")
                } header: {
                    Text("Summary")
                } footer: {
                    Text("Optional. A line shown on the program header, so students know who it's for.")
                }

                Section {
                    photoRow
                } header: {
                    Text("Cover photo")
                } footer: {
                    Text("Optional. One photo sets the tone of the program card.")
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle(editing == nil ? "New program" : "Edit program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Create" : "Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("program.create")
                }
            }
            .floweMessage(
                isPresented: .init(get: { filterMessage != nil },
                                   set: { if !$0 { filterMessage = nil } }),
                title: "Check your program",
                detail: filterMessage
            ) { filterMessage = nil }
        }
    }

    // MARK: - Cover photo (the ComposeLessonTypeSheet pipeline)

    @ViewBuilder
    private var photoRow: some View {
        if let cover, let ui = UIImage(data: cover) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 8)
        }
        HStack(spacing: 16) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Text(cover == nil ? "Add Photo" : "Change Photo")
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            .accessibilityIdentifier("program.photoPicker")
            if cover != nil {
                Button("Remove") { cover = nil; pickerItem = nil }
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
            }
            if isLoadingImage { Spacer(); ProgressView().controlSize(.small) }
        }
        .buttonStyle(.plain)
    }

    private func load(_ item: PhotosPickerItem) async {
        isLoadingImage = true
        defer { isLoadingImage = false }
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let prepared = ProfileImage.preparePost(raw) else { return }
        cover = prepared
    }

    // MARK: - Save

    private func save() {
        if let rejection = ContentFilter.reject(fields: [title, summary]) {
            filterMessage = rejection.message
            return
        }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editing {
            data.updateProgram(editing, title: t, summary: s, cover: cover)
        } else {
            data.addProgram(title: t, summary: s, cover: cover)
        }
        dismiss()
    }
}
