import SwiftUI
import AVKit

/// The student's view of one instructor's **Flowe Education** library — programs of video exercises,
/// open and playable directly (v1 has no per-student gating). Lives in the profile's Library tab; reads
/// the same `programs`/`videoExercises` caches the instructor authors into (synced via `syncEducation`).
struct StudentLibrarySection: View {
    let instructor: Instructor
    @Environment(MockDataStore.self) private var data
    @State private var playing: VideoExercise?

    private var programs: [Program] { data.ownedPrograms(for: instructor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if programs.isEmpty {
                emptyState
            } else {
                ForEach(programs, id: \.localID) { programBlock($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $playing) { ExercisePlayerView(exercise: $0, instructorName: instructor.firstName) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No library yet")
                .font(FloweFont.serif(17))
                .foregroundStyle(Color.floweInk)
            Text("\(instructor.firstName) hasn't shared training videos yet. Check back — or book a session.")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
        }
        .padding(.vertical, 8)
    }

    private func programBlock(_ program: Program) -> some View {
        let exercises = data.ownedExercises(for: instructor, programID: program.recordKey)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: FlowSpacing.md) {
                if let bytes = program.cover, let ui = UIImage(data: bytes) {
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: program.title)
                        .font(FloweFont.serif(18))
                        .foregroundStyle(Color.floweInk)
                    Text("^[\(exercises.count) exercise](inflect: true)")
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                }
            }
            if !program.summary.isEmpty {
                Text(verbatim: program.summary)
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(exercises, id: \.localID) { exercise in
                    Button { playing = exercise } label: { exerciseCard(exercise) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func exerciseCard(_ exercise: VideoExercise) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let bytes = exercise.thumbnail, let ui = UIImage(data: bytes) {
                    Image(uiImage: ui).resizable().scaledToFill().frame(height: 92).clipped()
                } else {
                    Rectangle().fill(FlowGradients.grad).frame(height: 92)
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 5)
                if exercise.durationSeconds > 0 {
                    VStack { Spacer(); HStack { Spacer()
                        Text(ComposeExerciseSheet.durationLabel(exercise.durationSeconds))
                            .font(FloweFont.mono(9)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(6)
                    } }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: exercise.title)
                    .font(FloweFont.serif(13))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1)
                if let meta = metaLine(exercise) {
                    Text(verbatim: meta).font(FloweFont.mono(8)).foregroundStyle(Color.floweMuted).lineLimit(1)
                }
            }
            .padding(9)
        }
        .background(Color.flowWhite)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
    }

    private func metaLine(_ exercise: VideoExercise) -> String? {
        var parts: [String] = []
        if !exercise.level.isEmpty { parts.append(exercise.level.capitalized) }
        let tags = exercise.focus.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let first = tags.first { parts.append(first) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The exercise player — the clip plus its coaching notes and prescription. Fetches the video CKAsset on
/// demand (copied to a temp file so `AVPlayer` can read it after CloudKit reclaims the asset), and cleans
/// the temp file up on dismiss.
struct ExercisePlayerView: View {
    let exercise: VideoExercise
    let instructorName: String
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var phase: Phase = .loading
    @State private var tempURL: URL?

    private enum Phase { case loading, ready, failed }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    playerArea
                    VStack(alignment: .leading, spacing: 16) {
                        Text(verbatim: exercise.title)
                            .font(FloweFont.serif(22))
                            .foregroundStyle(Color.floweInk)
                        if !instructorName.isEmpty {
                            Text("with \(instructorName)")
                                .font(FloweFont.sans(13))
                                .foregroundStyle(Color.floweMuted)
                        }
                        if !exercise.prescription.isEmpty {
                            labeled("PRESCRIPTION", exercise.prescription)
                        }
                        if !exercise.coachingNotes.isEmpty {
                            Text(verbatim: exercise.coachingNotes)
                                .font(FloweFont.sans(14))
                                .foregroundStyle(Color.floweInk)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        chips
                    }
                    .padding(FlowSpacing.xl)
                }
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep)
                }
            }
        }
        .task { await load() }
        .onDisappear {
            player?.pause()
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        }
    }

    @ViewBuilder
    private var playerArea: some View {
        ZStack {
            Rectangle().fill(Color.black)
            switch phase {
            case .loading:
                ProgressView().tint(.white)
            case .ready:
                if let player { VideoPlayer(player: player) }
            case .failed:
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(.white.opacity(0.8))
                    Text("Couldn't load this video. Check your connection and try again.")
                        .font(FloweFont.sans(12)).foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
            }
        }
        .frame(height: 240)
    }

    private var chips: some View {
        let tags = exercise.focus.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return FlowLayout(spacing: 6) {
            if !exercise.level.isEmpty { SpecialtyTag(text: exercise.level.capitalized) }
            ForEach(tags, id: \.self) { SpecialtyTag(text: $0) }
        }
    }

    private func labeled(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(FloweFont.mono(10)).foregroundStyle(Color.flowePinkDeep)
            Text(verbatim: value).font(FloweFont.sans(15)).foregroundStyle(Color.floweInk)
        }
    }

    private func load() async {
        phase = .loading
        guard let url = await data.exerciseVideoURL(exercise) else { phase = .failed; return }
        tempURL = url
        player = AVPlayer(url: url)
        phase = .ready
        player?.play()
    }
}
