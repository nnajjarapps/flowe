import SwiftUI

/// "New message" composer — pick a recipient to start a thread. Tapping one pushes the
/// conversation inside this sheet's own navigation stack.
struct NewMessageSheet: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""

    private var results: [Instructor] {
        guard !search.isEmpty else { return data.instructors }
        let q = search.lowercased()
        return data.instructors.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { instructor in
                        NavigationLink {
                            ConversationView(instructor: instructor)
                        } label: {
                            row(instructor)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.floweBorder).padding(.leading, 74)
                    }
                }
                .padding(.top, 4)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .searchable(text: $search, prompt: "Search people")
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
            }
        }
    }

    private func row(_ instructor: Instructor) -> some View {
        HStack(spacing: 14) {
            AvatarView(id: instructor.img, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(instructor.name)
                    .font(FloweFont.serif(15))
                    .foregroundStyle(Color.floweInk)
                Text(instructor.city)
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundStyle(Color.floweMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

#Preview {
    NewMessageSheet()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
}
