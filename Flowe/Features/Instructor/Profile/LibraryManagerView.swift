import SwiftUI

/// The instructor's Flowe Education manager — their programs, each opening to its ordered exercises.
/// Reached from the Dashboard "Education" card. Brings its own `NavigationStack` (like `PackagesManagerView`).
struct LibraryManagerView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    @State private var showAddProgram = false
    @State private var editingProgram: Program?
    @State private var deletingProgram: Program?

    private var programs: [Program] {
        data.currentInstructor.map { data.ownedPrograms(for: $0) } ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if programs.isEmpty {
                        emptyState
                    } else {
                        ForEach(programs, id: \.localID) { programRow($0) }
                    }
                    addButton(title: "New program") { showAddProgram = true }
                        .accessibilityIdentifier("library.addProgram")
                }
                .padding(FlowSpacing.xl)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle("Education")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep)
                }
            }
            .task { await sync() }
            .refreshable { await sync() }
            .sheet(isPresented: $showAddProgram) { ComposeProgramSheet() }
            .sheet(item: $editingProgram) { ComposeProgramSheet(editing: $0) }
            .floweConfirm(
                isPresented: .init(get: { deletingProgram != nil },
                                   set: { if !$0 { deletingProgram = nil } }),
                title: "Delete this program?",
                message: "Every exercise in this program is removed too. This can't be undone.",
                confirmTitle: "Delete program and its exercises",
                isDestructive: true,
                cancelTitle: "Keep it"
            ) {
                if let program = deletingProgram { data.deleteProgram(program) }
            }
        }
    }

    private func sync() async {
        guard let me = data.currentInstructor else { return }
        await data.syncEducation(for: me)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Build your training library")
                .font(FloweFont.serif(18))
                .foregroundStyle(Color.floweInk)
            Text("Group short video exercises into programs your students can follow along with.")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func programRow(_ program: Program) -> some View {
        let count = data.currentInstructor.map { data.ownedExercises(for: $0, programID: program.recordKey).count } ?? 0
        return NavigationLink {
            ProgramExercisesView(program: program)
        } label: {
            HStack(spacing: FlowSpacing.md) {
                thumb(program.cover, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: program.title)
                        .font(FloweFont.serif(16))
                        .foregroundStyle(Color.floweInk)
                        .lineLimit(1)
                    Text("^[\(count) exercise](inflect: true)")
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                }
                Spacer(minLength: 8)
                rowMenu(edit: { editingProgram = program }, delete: { deletingProgram = program })
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Color.floweMuted)
            }
            .padding(FlowSpacing.md)
            .floweCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.program.\(program.localID.uuidString)")
    }

    // MARK: - Shared bits

    @ViewBuilder
    private func thumb(_ data: Data?, size: CGFloat) -> some View {
        if let data, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10).fill(FlowGradients.grad)
                .frame(width: size, height: size)
                .overlay(Image(systemName: "play.rectangle.on.rectangle.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.85)))
        }
    }

    private func rowMenu(edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        Menu {
            Button { edit() } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { delete() } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.floweMuted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Manage")
    }

    private func addButton(title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text(title).font(FloweFont.sans(14, .medium))
            }
            .foregroundStyle(Color.flowePinkDeep)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The exercises inside one program — add, edit, delete. Pushed from `LibraryManagerView`.
private struct ProgramExercisesView: View {
    @Environment(MockDataStore.self) private var data
    let program: Program

    @State private var showAddExercise = false
    @State private var editingExercise: VideoExercise?
    @State private var deletingExercise: VideoExercise?

    private var exercises: [VideoExercise] {
        data.currentInstructor.map { data.ownedExercises(for: $0, programID: program.recordKey) } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !program.summary.isEmpty {
                    Text(verbatim: program.summary)
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                }
                if exercises.isEmpty {
                    Text("Add your first exercise — a short clip with coaching notes.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                        .padding(.vertical, 8)
                } else {
                    ForEach(exercises, id: \.localID) { exerciseRow($0) }
                }
                Button {
                    showAddExercise = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text("Add exercise").font(FloweFont.sans(14, .medium))
                    }
                    .foregroundStyle(Color.flowePinkDeep)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.addExercise")
            }
            .padding(FlowSpacing.xl)
        }
        .background(Color.flowWhite.ignoresSafeArea())
        .navigationTitle(program.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddExercise) { ComposeExerciseSheet(program: program) }
        .sheet(item: $editingExercise) { ComposeExerciseSheet(program: program, editing: $0) }
        .floweConfirm(
            isPresented: .init(get: { deletingExercise != nil },
                               set: { if !$0 { deletingExercise = nil } }),
            title: "Delete this exercise?",
            confirmTitle: "Delete",
            isDestructive: true,
            cancelTitle: "Keep it"
        ) {
            if let exercise = deletingExercise { data.deleteExercise(exercise) }
        }
    }

    private func exerciseRow(_ exercise: VideoExercise) -> some View {
        HStack(spacing: FlowSpacing.md) {
            ZStack {
                if let bytes = exercise.thumbnail, let ui = UIImage(data: bytes) {
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(width: 56, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(FlowGradients.grad).frame(width: 56, height: 44)
                }
                Image(systemName: "play.circle.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.9))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: exercise.title)
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1)
                Text(verbatim: metaLine(exercise))
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
            }
            Spacer(minLength: 8)
            if exercise.pendingUpload {
                Image(systemName: "arrow.up.circle").font(.system(size: 13)).foregroundStyle(Color.floweMuted)
                    .accessibilityLabel("Uploading")
            }
            Menu {
                Button { editingExercise = exercise } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { deletingExercise = exercise } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.floweMuted).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .accessibilityLabel("Manage exercise")
        }
        .padding(FlowSpacing.md)
        .floweCard(cornerRadius: 14)
        .contentShape(Rectangle())
        .onTapGesture { editingExercise = exercise }
    }

    /// "12:04 · Beginner · core" — only the stated parts, "·"-joined.
    private func metaLine(_ exercise: VideoExercise) -> String {
        var parts: [String] = []
        if exercise.durationSeconds > 0 { parts.append(ComposeExerciseSheet.durationLabel(exercise.durationSeconds)) }
        if !exercise.level.isEmpty { parts.append(exercise.level.capitalized) }
        let tags = exercise.focus.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let first = tags.first { parts.append(first) }
        return parts.joined(separator: " · ")
    }
}
