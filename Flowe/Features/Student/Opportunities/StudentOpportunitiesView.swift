import SwiftUI

/// The **student-facing** half of the Flowe Pro career marketplace ([[FlowePro]]): browse the open
/// opportunities a student can act on (apprentice / assistant / front-desk / space — the `openToAll`
/// slice) and track every application through its pipeline stage. Presented as a sheet from the student
/// Profile — never a top-level tab (a "Jobs" tab dies empty at pilot scale; discovery hangs off the
/// identity surface instead).
///
/// Reuses the instructor-side `OpportunityCard` + `OpportunityDetailView`; the detail is router-agnostic,
/// so the "Message" action is injected here and routes through this view's own NavigationStack rather
/// than the InstructorRouter the student environment doesn't have.
struct StudentOpportunitiesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    private enum Tab: Hashable { case browse, applied }
    @State private var tab: Tab = .browse
    /// The tapped opportunity → its detail sheet (apply / withdraw / message).
    @State private var selected: Opportunity?
    /// DM navigation for the detail's injected "Message" action. Appending pushes `ConversationView`
    /// onto this stack; the detail sheet dismisses itself first, revealing the pushed conversation.
    @State private var path: [Counterpart] = []

    private var browse: [Opportunity] { data.studentBrowsableOpportunities }
    private var applied: [Opportunity] { data.myAppliedOpportunities }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    picker
                    switch tab {
                    case .browse:  list(browse, empty: browseEmpty)
                    case .applied: list(applied, empty: appliedEmpty, showsStage: true)
                    }
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .background(Color.flowWhite)
            .navigationTitle("Opportunities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep).fontWeight(.semibold)
                }
            }
            .navigationDestination(for: Counterpart.self) { ConversationView(counterpart: $0) }
            // Pull the open feed + my own applications/decisions. Offline / preview no-ops.
            .task { await data.syncOpportunities() }
            .refreshable { await data.syncOpportunities() }
        }
        .sheet(item: $selected) { opp in
            OpportunityDetailView(opportunity: opp, onMessage: { counterpart in
                // The detail has already dismissed itself; push the conversation onto our stack.
                path.append(counterpart)
            })
        }
    }

    // MARK: Segmented control

    private var picker: some View {
        Picker("View", selection: $tab) {
            Text("Browse").tag(Tab.browse)
            if applied.isEmpty {
                Text("Applied").tag(Tab.applied)
            } else {
                Text("Applied · \(applied.count)").tag(Tab.applied)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: tab) { Haptic.selection() }
    }

    // MARK: List

    @ViewBuilder
    private func list(_ items: [Opportunity], empty: some View, showsStage: Bool = false) -> some View {
        if items.isEmpty {
            empty
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            VStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, opp in
                    Button {
                        Haptic.tap()
                        selected = opp
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            OpportunityCard(opportunity: opp)
                            if showsStage { stageLine(for: opp) }
                        }
                    }
                    .buttonStyle(.plain)
                    .floweAppear(index)
                }
            }
        }
    }

    /// The live pipeline stage of the student's application to `opp`, shown under the card in the
    /// Applied tab so they see "Shortlisted" / "Offer" / "Hired" at a glance without opening the detail.
    private func stageLine(for opp: Opportunity) -> some View {
        let stage = data.myApplicationStage(for: opp)
        return HStack(spacing: 6) {
            Image(systemName: stage == .hired ? "checkmark.seal.fill"
                            : stage == .declined ? "xmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 11))
            Text(stage == .applied ? String(localized: "Applied") : stage.label)
                .font(FloweFont.mono(9))
        }
        .foregroundStyle(OpportunityDetailView.stageColor(stage))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(OpportunityDetailView.stageColor(stage).opacity(0.12), in: Capsule())
        .padding(.leading, 2)
    }

    // MARK: Empty states

    private var browseEmpty: some View {
        EmptyStateView(
            icon: "briefcase",
            title: "No open opportunities",
            message: "Studios post apprenticeships, assistant and front-desk roles here. Check back soon."
        )
    }

    private var appliedEmpty: some View {
        EmptyStateView(
            icon: "paperplane",
            title: "No applications yet",
            message: "Browse open opportunities and apply — you'll track each one's status here."
        )
    }
}
