import SwiftUI

/// The glanceable safety glyph shown on the instructor's booking surfaces when a client has a
/// `ClientNote` with `hasFlags` set (injury / pregnancy / conditions). It shows ONLY that a safety
/// note exists — never any note content. Gate its presence on
/// `data.clientNote(forStudentID:)?.hasFlags == true`; this renders the glyph itself.
struct ClientNoteFlag: View {
    var size: CGFloat = 11
    var body: some View {
        Image(systemName: "cross.case.fill")
            .font(.system(size: size))
            .foregroundStyle(Color.floweCancel)
            .accessibilityLabel(Text("Has safety notes"))
    }
}

/// The instructor's PRIVATE notes editor for one client. A `Form`-based sheet that reads the existing
/// `ClientNote` (if any) for `studentID`, lets the instructor edit the structured safety fields plus
/// freeform notes, and saves back through `MockDataStore.saveClientNote`.
///
/// PRIVACY: this data lives ONLY in the CloudKit private database (the `ClientNote` @Model rides the
/// UserData config). It is never published to any shared/public record — the banner tells the
/// instructor exactly that. There is no *Service, no upload path for this model; `data.saveClientNote`
/// is a pure local-store write that the private mirror carries to the instructor's own devices.
struct ClientNoteEditorView: View {
    let studentID: String
    let studentName: String
    let onClose: () -> Void

    @Environment(MockDataStore.self) private var data

    @State private var hasInjury = false
    @State private var injuryNote = ""
    @State private var isPregnant = false
    @State private var pregnancyNote = ""
    @State private var conditions = ""
    @State private var emergencyContact = ""
    @State private var goals = ""
    @State private var notes = ""
    /// Seed the editor from the existing note exactly once (a re-render must not clobber edits).
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.flowePinkDeep)
                        Text("Private to you — only you can see this. This is never shared with the client or anyone else.")
                            .font(FloweFont.mono(10))
                            .foregroundStyle(Color.floweMuted)
                    }
                    .padding(.vertical, 2)
                }

                Section("SAFETY") {
                    Toggle("Has an injury", isOn: $hasInjury)
                    if hasInjury {
                        TextField("Injury details", text: $injuryNote, axis: .vertical)
                            .lineLimit(1...4)
                    }
                    Toggle("Pregnant", isOn: $isPregnant)
                    if isPregnant {
                        TextField("Notes", text: $pregnancyNote, axis: .vertical)
                            .lineLimit(1...4)
                    }
                }

                Section("CONDITIONS & ALLERGIES") {
                    TextField("Conditions", text: $conditions, axis: .vertical)
                        .lineLimit(1...5)
                }

                Section("EMERGENCY CONTACT") {
                    TextField("Emergency contact", text: $emergencyContact, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section("GOALS") {
                    TextField("Goals", text: $goals, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section("NOTES") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(Text("Client notes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveAndClose() }
                }
            }
        }
        .onAppear(perform: seedIfNeeded)
    }

    /// Load the existing note's values once, before the first edit.
    private func seedIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let note = data.clientNote(forStudentID: studentID) else { return }
        hasInjury = note.hasInjury
        injuryNote = note.injuryNote
        isPregnant = note.isPregnant
        pregnancyNote = note.pregnancyNote
        conditions = note.conditions
        emergencyContact = note.emergencyContact
        goals = note.goals
        notes = note.notes
    }

    private func saveAndClose() {
        data.saveClientNote(studentID: studentID,
                            hasInjury: hasInjury, injuryNote: injuryNote,
                            isPregnant: isPregnant, pregnancyNote: pregnancyNote,
                            conditions: conditions, notes: notes,
                            emergencyContact: emergencyContact, goals: goals)
        onClose()
    }
}
