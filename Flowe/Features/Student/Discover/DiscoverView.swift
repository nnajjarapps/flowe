import SwiftUI

/// Discover screen: greeting header, search, category filter, featured hero, instructor list.
struct DiscoverView: View {
    @Environment(MockDataStore.self) private var data

    @State private var search = ""
    @State private var filter = "All"
    @State private var selected: Instructor?

    private var filteredInstructors: [Instructor] {
        data.instructors.filter { ins in
            (filter == "All" || ins.specialties.contains(filter)) &&
            (search.isEmpty
             || ins.name.lowercased().contains(search.lowercased())
             || ins.city.lowercased().contains(search.lowercased()))
        }
    }

    private var showFeatured: Bool { filter == "All" && search.isEmpty }

    private var listLabel: String {
        let prefix = filter == "All" ? "NEAR YOU" : filter.uppercased()
        return "\(prefix) · \(filteredInstructors.count) INSTRUCTORS"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                FilterChipsBar(items: FloweConstants.discoverCategories, selection: $filter)
                    .padding(.bottom, 16)

                if showFeatured {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(text: "FEATURED")
                        FeaturedHeroCard {
                            if let first = data.instructors.first { selected = first }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(text: listLabel)
                    VStack(spacing: 12) {
                        ForEach(filteredInstructors) { ins in
                            InstructorCard(instructor: ins) { selected = ins }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(Color.flowWhite)
        .sheet(item: $selected) { ins in
            BookingSheet(instructor: ins) { selected = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GOOD MORNING")
                        .font(FloweFont.mono(11))
                        .foregroundStyle(Color.flowePinkDeep)
                    (Text("Find your ")
                        .font(FloweFont.serif(22))
                     + Text("instructor.")
                        .font(FloweFont.serif(22, .regular, italic: true)))
                        .foregroundStyle(Color.floweInk)
                }
                Spacer()
                Button {
                } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.floweInk)
                        .frame(width: 36, height: 36)
                        .background(Color.floweCardBg)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.floweBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.floweMuted)
                TextField("", text: $search, prompt: Text("Name or city…").foregroundColor(Color.floweMuted))
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweInk)
                    .autocorrectionDisabled()
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.floweMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.floweCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.floweBorder, lineWidth: 1))
        }
    }
}

#Preview {
    DiscoverView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
}
