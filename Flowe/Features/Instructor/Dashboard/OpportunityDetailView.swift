import SwiftUI

/// A compact opportunity card for the instructor's Opportunities feed (Flowe Pro career marketplace).
/// Kind chip + title + poster + pay/commitment + location. The card is a link — applying/messaging
/// happens in the detail, never on the scrolling card.
struct OpportunityCard: View {
    let opportunity: Opportunity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(opportunity.kind.label, systemImage: opportunity.kind.icon)
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.flowePinkDeep)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.flowePink.opacity(0.12), in: Capsule())
                Spacer(minLength: 8)
                if opportunity.eligibility == .openToAll {
                    Text("OPEN TO ALL")
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweSuccess)
                }
            }

            Text(opportunity.title)
                .font(FloweFont.serif(17, .medium))
                .foregroundStyle(Color.floweInk)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text("by \(opportunity.posterName)")
                .font(FloweFont.sans(12, .medium))
                .foregroundStyle(Color.floweMuted)

            metaRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .floweCard(cornerRadius: 16)
    }

    private var metaRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !opportunity.payText.isEmpty || !opportunity.commitment.isEmpty {
                HStack(spacing: 8) {
                    if !opportunity.payText.isEmpty {
                        metaLabel("banknote", opportunity.payText)
                    }
                    if !opportunity.commitment.isEmpty {
                        metaLabel("clock", opportunity.commitment)
                    }
                }
            }
            if !opportunity.location.isEmpty {
                metaLabel("mappin.and.ellipse", opportunity.location)
            }
        }
    }

    private func metaLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Color.floweMuted)
            Text(text).font(FloweFont.sans(12)).foregroundStyle(Color.floweInk.opacity(0.8)).lineLimit(1)
        }
    }
}

/// The full opportunity, with the poster, the details, an eligibility note, and a "Message" CTA that
/// expresses interest via a DM (the lightweight apply — the formal application pipeline lands in a
/// later Flowe Pro phase). Presented as a sheet from the instructor Dashboard / Opportunities feed.
struct OpportunityDetailView: View {
    @Environment(\.dismiss) private var dismiss
    // Optional: the student side has no InstructorRouter in its environment. Reading it as an optional
    // (rather than a hard dependency) lets the SAME detail present crash-free from the student browse,
    // which supplies its own `onMessage` instead. See [[FlowePro]].
    @Environment(InstructorRouter.self) private var router: InstructorRouter?
    @Environment(MockDataStore.self) private var data

    let opportunity: Opportunity
    /// True when the signed-in instructor OWNS this post — swaps the "Message" apply CTA for Close /
    /// Delete management. Set only from the poster's own "My opportunities" surface.
    var manageable: Bool = false
    /// How to open a DM with someone, injected by the student browse (which routes via its own
    /// NavigationStack). When nil — the instructor Dashboard path — it falls back to the InstructorRouter.
    var onMessage: ((Counterpart) -> Void)? = nil

    @State private var confirmDelete = false
    @State private var applyNote = ""

    /// Open a conversation with `counterpart`, dismissing this sheet first. Routes through the injected
    /// `onMessage` (student) or the InstructorRouter (instructor) — whichever is present.
    private func message(_ counterpart: Counterpart) {
        dismiss()
        if let onMessage { onMessage(counterpart) }
        else { router?.openConversation(with: counterpart) }
    }

    private var canApply: Bool {
        opportunity.status == .open
            && (opportunity.eligibility == .openToAll || data.currentInstructor != nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if !opportunity.about.isEmpty {
                        section("ABOUT THIS OPPORTUNITY") {
                            Text(opportunity.about)
                                .font(FloweFont.sans(15))
                                .foregroundStyle(Color.floweInk)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    section("DETAILS") {
                        VStack(alignment: .leading, spacing: 10) {
                            detailRow("banknote", "Pay", opportunity.payText)
                            detailRow("clock", "Commitment", opportunity.commitment)
                            detailRow("mappin.and.ellipse", "Location", opportunity.location)
                            detailRow(opportunity.eligibility == .certifiedOnly ? "checkmark.seal" : "person.2",
                                      "Who can apply",
                                      opportunity.eligibility == .certifiedOnly
                                        ? String(localized: "Certified instructors")
                                        : String(localized: "Open to all — students welcome"))
                        }
                    }

                    if manageable { applicantsSection }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { manageable ? AnyView(manageBar) : AnyView(applyBar) }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep).fontWeight(.semibold)
                }
            }
            .confirmationDialog("Delete this opportunity?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { data.deleteOpportunity(opportunity); dismiss() }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("It's removed for everyone. This can't be undone.")
            }
        }
    }

    /// The poster's own controls: close it (stop accepting) or delete it. Only shown when `manageable`.
    private var manageBar: some View {
        HStack(spacing: 12) {
            if opportunity.status == .open {
                Button {
                    data.closeOpportunity(opportunity); dismiss()
                } label: {
                    Text("Close")
                        .font(FloweFont.sans(16, .medium))
                        .foregroundStyle(Color.flowePinkDeep)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.floweBorder, lineWidth: 1))
                }
            } else {
                Text("Closed")
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(Color.floweMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Text("Delete")
                    .font(FloweFont.sans(16, .medium))
                    .foregroundStyle(Color.floweCancel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.floweCancel.opacity(0.4), lineWidth: 1))
            }
        }
        .flowePressable()
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(opportunity.kind.label, systemImage: opportunity.kind.icon)
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.flowePinkDeep)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.flowePink.opacity(0.12), in: Capsule())
            Text(opportunity.title)
                .font(FloweFont.serif(26, .medium))
                .foregroundStyle(Color.floweInk)
                .fixedSize(horizontal: false, vertical: true)
            Text("Posted by \(opportunity.posterName)")
                .font(FloweFont.sans(13, .medium))
                .foregroundStyle(Color.floweMuted)
        }
    }

    private var posterFirstName: String {
        opportunity.posterName.split(separator: " ").first.map(String.init) ?? opportunity.posterName
    }

    /// The applicant's action area: apply (with an optional note), see the applied state + withdraw, or
    /// a message shortcut. The eligibility gate blocks a student on a certified-only post.
    @ViewBuilder
    private var applyBar: some View {
        VStack(spacing: 10) {
            if let app = data.myApplication(for: opportunity), !app.withdrawn {
                let stage = data.myApplicationStage(for: opportunity)
                HStack(spacing: 10) {
                    Label(stage == .applied ? String(localized: "Applied") : stage.label,
                          systemImage: stage == .hired ? "checkmark.seal.fill"
                                     : stage == .declined ? "xmark.circle" : "checkmark.circle.fill")
                        .font(FloweFont.sans(15, .medium))
                        .foregroundStyle(OpportunityDetailView.stageColor(stage))
                    Spacer()
                    Button("Message") {
                        message(Counterpart(id: opportunity.posterID, name: opportunity.posterName))
                    }
                    .font(FloweFont.sans(14, .medium))
                    .tint(Color.flowePinkDeep)
                    // A hired/declined applicant can't withdraw — the decision is made.
                    if stage != .hired && stage != .declined {
                        Button("Withdraw") { data.withdrawApplication(for: opportunity) }
                            .font(FloweFont.sans(14))
                            .tint(Color.floweMuted)
                    }
                }
                .padding(.vertical, 8)
            } else if canApply {
                TextField("Add a note (optional)", text: $applyNote, axis: .vertical)
                    .font(FloweFont.sans(14))
                    .lineLimit(1...3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
                Button {
                    data.apply(to: opportunity, note: applyNote)
                } label: {
                    Text("Apply")
                        .font(FloweFont.sans(16, .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(FlowGradients.gradDark)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                .flowePressable()
                .accessibilityIdentifier("opportunity.apply")
            } else {
                Text("This one's for certified instructors.")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .padding(.top, 8)
        .background(.ultraThinMaterial)
    }

    /// The poster's applicant list — who has applied, their role, and their note. Stage controls land in
    /// the next phase; for now it's the inbox. Only shown when `manageable`.
    private var applicantsSection: some View {
        let apps = data.applications(for: opportunity)
        return section("APPLICANTS · \(apps.count)") {
            if apps.isEmpty {
                Text("No applicants yet. Share it or check back soon.")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
            } else {
                VStack(spacing: 10) {
                    ForEach(apps) { applicantRow($0) }
                }
            }
        }
    }

    private func applicantRow(_ app: OpportunityApplication) -> some View {
        let stage = data.stage(for: app)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                InitialAvatar(name: app.applicantName, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.applicantName.isEmpty ? "Someone" : app.applicantName)
                            .font(FloweFont.sans(14, .medium))
                            .foregroundStyle(Color.floweInk)
                        Text(app.role == .instructor ? "INSTRUCTOR" : "STUDENT")
                            .font(FloweFont.mono(8))
                            .foregroundStyle(Color.floweMuted)
                    }
                    if !app.note.isEmpty {
                        Text(app.note)
                            .font(FloweFont.sans(13))
                            .foregroundStyle(Color.floweInk.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                // The stage picker — advancing/declining upserts an ApplicationDecision addressed to
                // the applicant, who then sees their status.
                Menu {
                    Button("Shortlist") { data.setStage(for: app, to: .shortlisted) }
                    Button("Talking")   { data.setStage(for: app, to: .talking) }
                    Button("Offer")     { data.setStage(for: app, to: .offer) }
                    Button("Hire")      { data.setStage(for: app, to: .hired) }
                    Divider()
                    Button("Not selected", role: .destructive) { data.setStage(for: app, to: .declined) }
                    if stage != .applied {
                        Button("Reset to Applied") { data.setStage(for: app, to: .applied) }
                    }
                } label: {
                    stageBadge(stage)
                }
            }
            Button {
                message(Counterpart(id: app.applicantID, name: app.applicantName))
            } label: {
                Label("Message", systemImage: "bubble.right")
                    .font(FloweFont.sans(12, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .floweCard(cornerRadius: 14)
    }

    /// A pill showing an application's current pipeline stage (tappable → the stage Menu).
    private func stageBadge(_ stage: ApplicationStage) -> some View {
        HStack(spacing: 3) {
            Text(stage.label)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
        }
        .font(FloweFont.mono(9))
        .foregroundStyle(Self.stageColor(stage))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Self.stageColor(stage).opacity(0.14), in: Capsule())
    }

    static func stageColor(_ stage: ApplicationStage) -> Color {
        switch stage {
        case .hired:    return .floweSuccess
        case .declined: return .floweMuted
        default:        return .flowePinkDeep
        }
    }

    private func detailRow(_ icon: String, _ label: LocalizedStringKey, _ value: String) -> some View {
        Group {
            if !value.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Color.flowePinkDeep)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label).font(FloweFont.mono(9)).foregroundStyle(Color.floweMuted)
                        Text(value).font(FloweFont.sans(14)).foregroundStyle(Color.floweInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: title)
            content()
        }
    }
}

// MARK: - Compose

/// Post a new opportunity to the career marketplace. Gated at the entry point on the instructor being
/// discoverable (a hidden studio shouldn't recruit). Fields are free-text and content-screened like any
/// public listing. See [[FlowePro]].
struct ComposeOpportunitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    @State private var kind: OpportunityKind = .cover
    @State private var eligibility: OpportunityEligibility = .certifiedOnly
    @State private var title = ""
    @State private var about = ""
    @State private var payText = ""
    @State private var commitment = ""
    @State private var filterMessage: String?
    /// Soft on-device moderation concern (Flowe Intelligence) → "post anyway / edit?" dialog.
    @State private var moderationConcern: String?

    /// ✨ Draft-from-a-note (Flowe Intelligence, Tier 2).
    @State private var aiNote = ""
    @State private var drafting = false

    private var canPost: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                // ✨ On-device quick draft — one line in, the fields below filled to edit. Shown only when
                // the model is available; otherwise absent and the form works exactly as before.
                if FloweAI.isAvailable {
                    Section {
                        TextField("e.g. sub my Thursday reformer, ₪180", text: $aiNote, axis: .vertical)
                            .lineLimit(1...3)
                        Button {
                            draftFromNote()
                        } label: {
                            HStack(spacing: 6) {
                                if drafting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(drafting ? "Drafting…" : "Draft with AI")
                            }
                            .foregroundStyle(Color.flowePinkDeep)
                        }
                        .disabled(drafting || aiNote.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("opportunity.aiDraft")
                    } header: {
                        HStack { Text("Quick draft"); Spacer(); AIPrivacyBadge() }
                    } footer: {
                        Text("Describe it in a line — I'll fill in the fields below for you to edit. It stays on your device.")
                    }
                }

                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(OpportunityKind.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("What kind of opportunity?")
                }

                Section {
                    Picker("Who can apply", selection: $eligibility) {
                        Text("Certified only").tag(OpportunityEligibility.certifiedOnly)
                        Text("Open to all").tag(OpportunityEligibility.openToAll)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("Who can apply?")
                } footer: {
                    Text(eligibility == .certifiedOnly
                         ? "Only certified instructors will be able to apply."
                         : "Open to students too — good for assistant, front-desk or apprentice roles.")
                }

                Section {
                    TextField("e.g. Sub my Mat class this Thursday", text: $title)
                } header: {
                    Text("Title")
                }

                Section {
                    TextField("What's the opportunity? Who are you looking for?", text: $about, axis: .vertical)
                        .lineLimit(4...9)
                } header: {
                    Text("Details")
                }

                Section {
                    TextField("e.g. ₪180 / class, or 60% split", text: $payText)
                } header: {
                    Text("Pay")
                }

                Section {
                    TextField("e.g. One-off · Thu 8:00, or Weekly · Sundays", text: $commitment)
                } header: {
                    Text("Commitment")
                } footer: {
                    Text("Your studio location is used automatically. Interested people reach you through Flowe messages.")
                }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle("Post an Opportunity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { post() }.disabled(!canPost)
                        .accessibilityIdentifier("opportunity.post")
                }
            }
            .alert("Check your post",
                   isPresented: .init(get: { filterMessage != nil }, set: { if !$0 { filterMessage = nil } })) {
                Button("OK", role: .cancel) { filterMessage = nil }
            } message: {
                Text(filterMessage ?? "")
            }
            .confirmationDialog("A quick check",
                                isPresented: .init(get: { moderationConcern != nil },
                                                   set: { if !$0 { moderationConcern = nil } }),
                                titleVisibility: .visible,
                                presenting: moderationConcern) { _ in
                Button("Post anyway") { moderationConcern = nil; finishPost() }
                Button("Edit", role: .cancel) { moderationConcern = nil }
            } message: { concern in
                Text(concern)
            }
        }
    }

    private func post() {
        // Public content, so it's screened like a listing (Guideline 1.2).
        if let rejection = ContentFilter.reject(fields: [title, about, payText, commitment]) {
            filterMessage = rejection.message
            return
        }
        guard FloweAI.isAvailable else { finishPost(); return }
        Task {
            if let concern = await FloweAI.moderationConcern([title, about, commitment].joined(separator: "\n")) {
                moderationConcern = concern
                return
            }
            finishPost()
        }
    }

    private func finishPost() {
        data.addOpportunity(kind: kind, eligibility: eligibility,
                            title: title, about: about, payText: payText, commitment: commitment)
        dismiss()
    }

    /// Fill the form from a one-line note, on-device. Only overwrites a field the model actually produced,
    /// so a re-draft never blanks something the instructor already tweaked. They still edit + post.
    private func draftFromNote() {
        let note = aiNote.trimmingCharacters(in: .whitespaces)
        guard !note.isEmpty, !drafting else { return }
        drafting = true
        Task {
            defer { drafting = false }
            if #available(iOS 26, *), FloweAI.isAvailable,
               let d = try? await FloweIntelligence.shared.draftOpportunity(from: note) {
                withAnimation {
                    kind = FloweAI.opportunityKind(from: d.kind)
                    eligibility = FloweAI.opportunityEligibility(from: d.eligibility)
                    if !d.title.isEmpty { title = d.title }
                    if !d.about.isEmpty { about = d.about }
                    if !d.payText.isEmpty { payText = d.payText }
                    if !d.commitment.isEmpty { commitment = d.commitment }
                }
                Haptic.selection()
            }
        }
    }
}
