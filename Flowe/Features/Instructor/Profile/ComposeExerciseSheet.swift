import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

/// Creates or edits one Flowe Education **video exercise** inside a program. Same `Form` idiom as
/// `ComposeLessonTypeSheet`, plus a video picker: picking a clip loads it, reads its duration, and
/// auto-generates a poster frame. The clip itself rides the one-shot upload (never stored on the @Model).
struct ComposeExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    private let program: Program
    private let editing: VideoExercise?

    @State private var title: String
    @State private var coachingNotes: String
    @State private var prescription: String
    @State private var focus: String
    @State private var level: String

    /// The freshly picked clip (transient — passed to the upload, never persisted on the model). Nil on an
    /// edit where the instructor keeps the existing video.
    @State private var videoData: Data?
    @State private var thumbnail: Data?
    @State private var durationSeconds: Int
    @State private var videoPickerItem: PhotosPickerItem?
    @State private var isLoadingVideo = false
    @State private var filterMessage: String?

    private let levels = ["", "beginner", "intermediate", "advanced"]

    init(program: Program, editing: VideoExercise? = nil) {
        self.program = program
        self.editing = editing
        _title = State(initialValue: editing?.title ?? "")
        _coachingNotes = State(initialValue: editing?.coachingNotes ?? "")
        _prescription = State(initialValue: editing?.prescription ?? "")
        _focus = State(initialValue: editing?.focus ?? "")
        _level = State(initialValue: editing?.level ?? "")
        _thumbnail = State(initialValue: editing?.thumbnail)
        _durationSeconds = State(initialValue: editing?.durationSeconds ?? 0)
    }

    /// A title and a playable clip (freshly picked, or already attached on an edit) are required.
    private var hasVideo: Bool { videoData != nil || (editing?.hasVideo ?? false) }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasVideo
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    videoRow
                } header: {
                    Text("Video")
                } footer: {
                    Text("Record it first, then pick it here. This is public in your library — students watch it directly.")
                }

                Section {
                    TextField("Name", text: $title)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("exercise.name")
                } header: {
                    Text("Exercise name")
                } footer: {
                    Text("\"Reformer Foundations\", \"Core & Alignment\".")
                }

                Section {
                    TextField("Cues to follow along", text: $coachingNotes, axis: .vertical)
                        .lineLimit(3...10)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("exercise.notes")
                } header: {
                    Text("Coaching notes")
                }

                Section {
                    TextField("e.g. 3x10 @ 3-1-3", text: $prescription)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("exercise.prescription")
                } header: {
                    Text("Prescription")
                } footer: {
                    Text("Sets, reps, tempo — however you cue it. Optional.")
                }

                Section {
                    TextField("core, mobility", text: $focus)
                        .font(FloweFont.sans(14))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("exercise.focus")
                    Picker("Level", selection: $level) {
                        Text("Not set").tag("")
                        Text("Beginner").tag("beginner")
                        Text("Intermediate").tag("intermediate")
                        Text("Advanced").tag("advanced")
                    }
                    .font(FloweFont.sans(14))
                } header: {
                    Text("Focus & level")
                } footer: {
                    Text("Comma-separated focus tags, shown as chips on the card.")
                }
            }
            .onChange(of: videoPickerItem) { _, item in
                guard let item else { return }
                Task { await loadVideo(item) }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle(editing == nil ? "Add exercise" : "Edit exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .disabled(!canSave || isLoadingVideo)
                        .accessibilityIdentifier("exercise.create")
                }
            }
            .alert("Check your exercise",
                   isPresented: .init(get: { filterMessage != nil },
                                      set: { if !$0 { filterMessage = nil } })) {
                Button("OK", role: .cancel) { filterMessage = nil }
            } message: {
                Text(filterMessage ?? "")
            }
        }
    }

    // MARK: - Video row

    @ViewBuilder
    private var videoRow: some View {
        if let thumbnail, let ui = UIImage(data: thumbnail) {
            ZStack {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 6)
            }
            .listRowInsets(EdgeInsets())
            .padding(.vertical, 8)
        }
        HStack(spacing: 16) {
            PhotosPicker(selection: $videoPickerItem, matching: .videos, photoLibrary: .shared()) {
                Text(hasVideo ? "Replace video" : "Add video")
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            .accessibilityIdentifier("exercise.videoPicker")

            if durationSeconds > 0 {
                Text(Self.durationLabel(durationSeconds))
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)
            }
            if isLoadingVideo {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadVideo(_ item: PhotosPickerItem) async {
        isLoadingVideo = true
        defer { isLoadingVideo = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }

        // Stage to a temp file to read the duration and generate a poster frame; both need a URL.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("edu-pick-\(UUID().uuidString).mov")
        guard (try? data.write(to: tmp)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let asset = AVURLAsset(url: tmp)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        var poster: Data?
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1080, height: 1080)
        let at = CMTime(seconds: seconds > 2 ? 1 : 0, preferredTimescale: 600)
        if let cg = try? await generator.image(at: at).image,
           let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) {
            poster = ProfileImage.preparePost(jpeg)
        }

        videoData = data
        durationSeconds = Int(seconds.rounded())
        if let poster { thumbnail = poster }
    }

    // MARK: - Save

    private func save() {
        // Title + coaching notes are public text, screened like a listing. The video/poster can't be
        // screened (nothing inspects pixels) — which is why an exercise is reportable.
        if let rejection = ContentFilter.reject(fields: [title, coachingNotes]) {
            filterMessage = rejection.message
            return
        }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = coachingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let rx = prescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalise the focus tags: split on commas, trim, drop blanks, re-join.
        let tags = focus.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")

        if let editing {
            data.updateExercise(editing, title: t, coachingNotes: notes, prescription: rx,
                                focus: tags, level: level, durationSeconds: durationSeconds,
                                thumbnail: thumbnail, video: videoData)
        } else {
            data.addExercise(programID: program.recordKey, title: t, coachingNotes: notes, prescription: rx,
                             focus: tags, level: level, durationSeconds: durationSeconds,
                             thumbnail: thumbnail, video: videoData)
        }
        dismiss()
    }

    /// "12:04" from a whole-second duration.
    static func durationLabel(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
