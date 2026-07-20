import SwiftUI

/// Reports a piece of content, and optionally blocks its author in the same pass — the two things
/// App Store Review Guideline 1.2 requires an app hosting user content to offer.
///
/// Blocking is offered here because the two almost always go together: someone bothered enough to
/// report is usually also done hearing from the person.
struct ReportSheet: View {
    let reportedID: String
    let reportedName: String
    let content: ReportedContent
    let contentID: String
    /// The offending text, copied into the report so it survives deletion of the original.
    let snapshot: String

    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    @State private var reason: ReportReason = .harassment
    @State private var details = ""
    @State private var alsoBlock = true
    @State private var isSending = false
    @State private var failed = false

    private var subject: String { reportedName.isEmpty ? "this user" : reportedName }

    var body: some View {
        NavigationStack {
            Form {
                Section("Why are you reporting this?") {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    TextField("Anything else we should know?", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("report.details")
                } header: {
                    Text("Details (optional)")
                }

                Section {
                    Toggle("Also block \(subject)", isOn: $alsoBlock)
                        .tint(Color.flowePinkDeep)
                        .accessibilityIdentifier("report.alsoBlock")
                } footer: {
                    Text("Blocking hides their messages and their profile from you.")
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            if isSending { ProgressView().controlSize(.small) }
                            Text(isSending ? "Sending…" : "Submit Report")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isSending)
                    .accessibilityIdentifier("report.submit")
                } footer: {
                    Text("Reports go to the Flowe team for review. We remove content and accounts "
                         + "that break our rules.")
                }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSending)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Color.floweMuted)
                        .disabled(isSending)
                }
            }
            .alert("Couldn't send your report", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again. "
                     + (alsoBlock ? "\(subject) has still been blocked." : ""))
            }
        }
    }

    private func submit() {
        isSending = true
        Task {
            let sent = await data.report(
                reportedID: reportedID,
                reportedName: reportedName,
                content: content,
                contentID: contentID,
                reason: reason,
                snapshot: snapshot,
                details: details
            )
            // Block regardless of whether the report reached the server — the user asked to stop
            // seeing this person, and that shouldn't depend on the network.
            if alsoBlock { data.block(id: reportedID, name: reportedName) }
            isSending = false
            if sent { dismiss() } else { failed = true }
        }
    }
}

#Preview {
    ReportSheet(reportedID: "preview", reportedName: "Alex Rivera",
                content: .message, contentID: "1", snapshot: "Example message")
        .environment(MockDataStore.preview)
}
